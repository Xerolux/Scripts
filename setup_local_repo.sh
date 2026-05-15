#!/usr/bin/env bash
# ==============================================================================
# setup_local_repo.sh – Xerolux APT Repository (Professional Edition)
#
# Struktur:
#   $REPO_DIR/testing/        – neue Pakete landen hier
#   $REPO_DIR/stable/         – nach X Tagen automatisch promoted
#   $REPO_DIR/xerolux-repo.gpg – oeffentlicher Schluessel
#   $REPO_DIR/.repo-changelog – Aenderungsprotokoll
#
# Features:
#   1. Ed25519 GPG-Signierung (Release + .deb)
#   2. SHA256 + SHA512 Checksummen
#   3. Acquire-By-Hash (atomare Updates)
#   4. Contents-$arch (apt-file Support)
#   5. Testing/Stable mit Auto-Promote (Cron)
#   6. Rollback (demote stable→testing)
#   7. Changelog (wer was wann)
#   8. apt Pinning (stable=990, testing=100)
#   9. Notification (Mail/Webhook)
#  10. Health-Check (apt update Test)
#  11. Download-Statistiken (nginx Log)
#  12. Multi-Arch vorbereitet
# ==============================================================================
set -Eeuo pipefail

trap 'rm -f /tmp/repo-batch-*$$* 2>/dev/null' EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/setup_local_repo.env" ]] && [[ -f "$SCRIPT_DIR/setup_local_repo.env.example" ]]; then
  cp -n "$SCRIPT_DIR/setup_local_repo.env.example" "$SCRIPT_DIR/setup_local_repo.env" 2>/dev/null || true
fi
if [[ ! -f "$SCRIPT_DIR/setup_local_repo.env" ]]; then
  echo "FEHLER: setup_local_repo.env nicht gefunden." >&2; exit 1
fi
source "$SCRIPT_DIR/setup_local_repo.env"

source "$SCRIPT_DIR/common.sh"

GPG_KEY_ID="${GPG_KEY_ID:-}"
GPG_KEY_NAME="${GPG_KEY_NAME:-Xerolux Build Repo}"
GPG_KEY_EMAIL="${GPG_KEY_EMAIL:-repo@xerolux.de}"
GPG_KEYRING_DIR="${GPG_KEYRING_DIR:-/root/.gnupg}"
GPG_PUBLIC_KEY="${GPG_PUBLIC_KEY:-/etc/apt/keyrings/xerolux-repo.gpg}"
APT_KEYRING_DIR="/etc/apt/keyrings"
REPO_ARCH="${REPO_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo arm64)}"
REPO_PROMOTE_DAYS="${REPO_PROMOTE_DAYS:-14}"
REPO_WEB_USER="${REPO_WEB_USER:-}"
REPO_WEB_GROUP="${REPO_WEB_GROUP:-}"
REPO_NOTIFY_EMAIL="${REPO_NOTIFY_EMAIL:-}"
REPO_NOTIFY_WEBHOOK="${REPO_NOTIFY_WEBHOOK:-}"
REPO_NGINX_LOG="${REPO_NGINX_LOG:-/var/log/nginx/repo.xerolux.de.access.log}"
APT_SOURCES_FILE="${APT_SOURCES_FILE:-/etc/apt/sources.list.d/xerolux-repo.list}"
APT_PREFS_FILE="${APT_PREFS_FILE:-/etc/apt/preferences.d/xerolux-repo.pref}"
REPO_URL="${REPO_URL:-https://repo.xerolux.de}"

REPO_TESTING="$REPO_DIR/testing"
REPO_STABLE="$REPO_DIR/stable"
LOCK_FILE="$REPO_DIR/.repo.lock"
TIMESTAMPS_FILE="$REPO_TESTING/.pkg-timestamps"
CHANGELOG_FILE="$REPO_DIR/.repo-changelog"

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------

changelog() {
  local action="$1" details="${2:-}"
  local entry="$(date '+%F %T') | $action | $details"
  echo "$entry" >> "$CHANGELOG_FILE"
  log "CHANGELOG: $action | $details"
}

usage() {
  cat <<'USAGE'
Verwendung:
  setup_local_repo.sh install        – Repo erstellen, Pakete kopieren, apt einrichten
  setup_local_repo.sh update          – Neue Pakete nach testing/, Index aktualisieren
  setup_local_repo.sh promote         – testing→stable (aelter als PROMOTE_DAYS)
  setup_local_repo.sh promote-all     – Alle testing→stable erzwingen
  setup_local_repo.sh auto-promote    – Wie promote + Cron einrichten
  setup_local_repo.sh demote          – stable→testing Rollback (alle oder einzelne)
  setup_local_repo.sh migrate         – Flat-Repo nach testing/stable migrieren
  setup_local_repo.sh diff            – Unterschied testing vs stable anzeigen
  setup_local_repo.sh status          – Status anzeigen
  setup_local_repo.sh verify          – Checksummen + Signaturen pruefen
  setup_local_repo.sh health-check    – apt update Test vom Repo
  setup_local_repo.sh stats           – Download-Statistiken (nginx Log)
  setup_local_repo.sh cleanup         – Alte Versionen entfernen
  setup_local_repo.sh uninstall       – Alles entfernen
  setup_local_repo.sh init-gpg        – GPG-Schluessel erstellen
  setup_local_repo.sh export-key      – Public Key exportieren
  setup_local_repo.sh sign-repo       – Release neu signieren
  setup_local_repo.sh sign-debs       – .deb Pakete signieren
  setup_local_repo.sh setup-pinning   – apt preferences erstellen
USAGE
}

# ------------------------------------------------------------------------------
# Lock
# ------------------------------------------------------------------------------
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  if ! ln -s /proc/self "$LOCK_FILE" 2>/dev/null; then
    local pid=""
    [ -L "$LOCK_FILE" ] && pid="$(readlink "$LOCK_FILE" 2>/dev/null | sed 's|/proc/||;s|/self||')"
    die "Repo gesperrt (PID ${pid:-?}). rm -f $LOCK_FILE"
  fi
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# ------------------------------------------------------------------------------
# Notification
# ------------------------------------------------------------------------------
notify() {
  local subject="$1" body="${2:-}"
  [ -z "$subject" ] && return

  if [ -n "$REPO_NOTIFY_EMAIL" ]; then
    echo "$body" | mail -s "[Xerolux Repo] $subject" "$REPO_NOTIFY_EMAIL" 2>/dev/null || true
  fi
  if [ -n "$REPO_NOTIFY_WEBHOOK" ]; then
    local payload
    payload="$(printf '{"text":"[%s] %s\\n%s"}' "$(hostname -s)" "$subject" "$body" | head -c 2000)"
    curl -sfS -X POST -H 'Content-Type: application/json' -d "$payload" "$REPO_NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------------------
# GPG
# ------------------------------------------------------------------------------
gpg_cmd() { gpg --batch --yes --no-tty --homedir "$GPG_KEYRING_DIR" "$@"; }

detect_gpg_key() {
  [ -n "$GPG_KEY_ID" ] && return 0
  local key_ids
  key_ids="$(gpg_cmd --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/{print $5}' | head -1)" || true
  [ -n "$key_ids" ] && { GPG_KEY_ID="$key_ids"; log "GPG erkannt: $GPG_KEY_ID"; return 0; }
  return 1
}

init_gpg() {
  log "=== Erstelle GPG-Schluessel ==="
  detect_gpg_key 2>/dev/null && { log "Bereits vorhanden: $GPG_KEY_ID"; return 0; }

  apt-get update -qq --allow-releaseinfo-change 2>/dev/null || apt-get update -qq 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg || die "gnupg installation failed"
  mkdir -p "$GPG_KEYRING_DIR" || die "Kann $GPG_KEYRING_DIR nicht erstellen"
  chmod 700 "$GPG_KEYRING_DIR" || die "Kann Permissions nicht ändern"

  local batch_file="/tmp/gpg-batch-$$"
  cat > "$batch_file" <<GPGCONF
%no-protection
Key-Type: Ed25519
Subkey-Type: Ed25519
Name-Real: ${GPG_KEY_NAME}
Name-Email: ${GPG_KEY_EMAIL}
Expire-Date: 0
%commit
GPGCONF
  log "Erstelle Ed25519..."
  gpg_cmd --gen-key --batch "$batch_file" || die "GPG Key-Erstellung fehlgeschlagen"
  rm -f "$batch_file"
  detect_gpg_key || die "GPG fehlgeschlagen"
  log "GPG erstellt: $GPG_KEY_ID"
  gpg_cmd --fingerprint "$GPG_KEY_ID" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG_FILE"
  export_key
  changelog "gpg-init" "Key $GPG_KEY_ID erstellt"
  log "=== GPG bereit ==="
}

export_key() {
  detect_gpg_key || die "Kein GPG. Zuerst: $0 init-gpg"
  mkdir -p "$APT_KEYRING_DIR" "$REPO_DIR"
  gpg_cmd --armor --export "$GPG_KEY_ID" > "$GPG_PUBLIC_KEY"
  gpg_cmd --armor --export "$GPG_KEY_ID" > "$REPO_DIR/xerolux-repo.gpg"
  chmod 644 "$GPG_PUBLIC_KEY" "$REPO_DIR/xerolux-repo.gpg"
  log "Public Key: $GPG_PUBLIC_KEY + $REPO_DIR/xerolux-repo.gpg"
}

# ------------------------------------------------------------------------------
# Index (fuer ein Verzeichnis)
# ------------------------------------------------------------------------------

cleanup_by_hash() {
  local target_dir="$1"
  local removed=0

  declare -A current_hashes
  local hash_files=""
  local contents_file="Contents-${REPO_ARCH}"
  hash_files="Packages Packages.gz ${contents_file} ${contents_file}.gz"
  while IFS= read -r deb; do
    hash_files+=" $(basename "$deb")"
  done < <(cd "$target_dir" && find . -maxdepth 1 -name '*.deb' -type f 2>/dev/null)

  for f in $hash_files; do
    [ -f "$target_dir/$f" ] || continue
    current_hashes["$(sha256sum "$target_dir/$f" | awk '{print $1}')"]=1
  done

  for hash_dir in MD5Sum SHA1 SHA256 SHA512; do
    local bh_dir="$target_dir/by-hash/$hash_dir"
    [ -d "$bh_dir" ] || continue
    while IFS= read -r stale; do
      [ -z "$stale" ] && continue
      local h="$(basename "$stale")"
      if [ "$hash_dir" = "SHA256" ] && [ -z "${current_hashes[$h]+x}" ]; then
        rm -f "$stale"
        removed=$((removed + 1))
      fi
    done < <(find "$bh_dir" -maxdepth 1 -type f 2>/dev/null)
  done

  [ "$removed" -gt 0 ] && log "by-hash cleanup: $removed veraltete Dateien entfernt"
}

build_index() {
  local suite="$1"
  local target_dir="$2"
  cd "$target_dir" || die "Kann nicht nach $target_dir"

  log "Index fuer $suite ($target_dir)..."

  if command -v apt-ftparchive >/dev/null 2>&1; then
    apt-ftparchive packages . > Packages 2>/dev/null
  else
    dpkg-scanpackages -m . /dev/null 2>/dev/null > Packages
  fi
  gzip -9kc Packages > Packages.gz

  local contents_file="Contents-${REPO_ARCH}"
  : > "$contents_file"
  if find . -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
    while IFS= read -r deb; do
      [ -f "$deb" ] || continue
      local pkg_name
      pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || continue)"
      dpkg-deb -c "$deb" 2>/dev/null | awk -v pkg="$pkg_name" '
        /^\.\// && !/\/$/ {
          f=substr($0, index($0,$6))
          gsub(/^\.\//,"",f)
          print f" "pkg
        }' >> "$contents_file"
    done < <(find . -maxdepth 1 -name '*.deb' -type f)
  fi
  gzip -9kc "$contents_file" > "${contents_file}.gz"

  local now; now="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  cat > Release <<RELEASEHEAD
Origin: Xerolux Repository
Label: Xerolux $suite
Suite: $suite
Codename: xerolux-$suite
Date: $now
Architectures: $REPO_ARCH
Components: ./
Description: Xerolux APT Repository ($suite)
Acquire-By-Hash: yes
RELEASEHEAD

  local hash_files="Packages Packages.gz ${contents_file} ${contents_file}.gz"
  while IFS= read -r deb; do
    hash_files+=" $(basename "$deb")"
  done < <(find . -maxdepth 1 -name '*.deb' -type f)

  mkdir -p by-hash/MD5Sum by-hash/SHA1 by-hash/SHA256 by-hash/SHA512

  local md5_block="" sha1_block="" sha256_block="" sha512_block=""
  local sha256sums_file="SHA256SUMS"

  for f in $hash_files; do
    [ -f "$f" ] || continue
    local size; size="$(stat -c '%s' "$f")"
    local sha256_h sha512_h
    sha256_h="$(sha256sum "$f" | awk '{print $1}')"
    sha512_h="$(sha512sum "$f" | awk '{print $1}')"
    local md5_h; md5_h="$(md5sum "$f" | awk '{print $1}')"
    local sha1_h; sha1_h="$(sha1sum "$f" | awk '{print $1}')"

    md5_block+=" ${md5_h} ${size} ${f}"$'\n'
    sha1_block+=" ${sha1_h} ${size} ${f}"$'\n'
    sha256_block+=" ${sha256_h} ${size} ${f}"$'\n'
    sha512_block+=" ${sha512_h} ${size} ${f}"$'\n'

    cp -f "$f" "by-hash/MD5Sum/${md5_h}" 2>/dev/null || true
    cp -f "$f" "by-hash/SHA1/${sha1_h}" 2>/dev/null || true
    cp -f "$f" "by-hash/SHA256/${sha256_h}" 2>/dev/null || true
    cp -f "$f" "by-hash/SHA512/${sha512_h}" 2>/dev/null || true
  done

  printf 'MD5Sum:\n%s' "$md5_block" >> Release
  printf 'SHA1:\n%s' "$sha1_block" >> Release
  printf 'SHA256:\n%s' "$sha256_block" >> Release
  printf 'SHA512:\n%s' "$sha512_block" >> Release

  if detect_gpg_key 2>/dev/null; then
    rm -f Release.gpg InRelease
    gpg_cmd --default-key "$GPG_KEY_ID" -abs -o Release.gpg Release
    gpg_cmd --default-key "$GPG_KEY_ID" --clearsign -o InRelease Release
    log "Release signiert ($suite)"
  else
    rm -f Release.gpg InRelease
    log "WARNUNG: Kein GPG - $suite nicht signiert"
  fi

  if find . -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
    find . -maxdepth 1 -name '*.deb' -type f -exec sha256sum {} \; > "$sha256sums_file"
  fi

  cleanup_by_hash "$target_dir"

  local cnt; cnt="$(grep -c '^Package:' Packages 2>/dev/null || echo 0)"
  log "$suite: $cnt Pakete indiziert (Acquire-By-Hash: yes, Contents: yes)"
}

# ------------------------------------------------------------------------------
# Cleanup alte Versionen
# ------------------------------------------------------------------------------
cleanup_old_versions() {
  local target_dir="$1"
  cd "$target_dir" || return 0

  local removed=0
  declare -A latest_pkg

  for deb in ./*.deb; do
    [ -f "$deb" ] || continue
    local pkg_name pkg_ver
    pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || continue)"
    pkg_ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || echo 0)"

    if [ -n "${latest_pkg[$pkg_name]+x}" ]; then
      local existing_file existing_ver
      existing_file="${latest_pkg[$pkg_name]}"
      existing_ver="$(dpkg-deb -f "$existing_file" Version 2>/dev/null || echo 0)"

      if dpkg --compare-versions "$pkg_ver" gt "$existing_ver"; then
        log "  Cleanup: $(basename "$existing_file") ($existing_ver) -> entfernt"
        changelog "cleanup" "$suite: $(basename "$existing_file") $existing_ver entfernt (neuer: $pkg_ver)"
        rm -f "$existing_file"
        latest_pkg[$pkg_name]="$deb"
        removed=$((removed + 1))
      else
        log "  Cleanup: $(basename "$deb") ($pkg_ver) -> entfernt"
        changelog "cleanup" "$suite: $(basename "$deb") $pkg_ver entfernt (behalten: $existing_ver)"
        rm -f "$deb"
        removed=$((removed + 1))
      fi
    else
      latest_pkg[$pkg_name]="$deb"
    fi
  done
  [ "$removed" -gt 0 ] && log "  $removed alte Version(en) entfernt"
}

# ------------------------------------------------------------------------------
# Berechtigungen
# ------------------------------------------------------------------------------
fix_permissions() {
  [ -z "$REPO_WEB_USER" ] || [ -z "$REPO_WEB_GROUP" ] && return 0
  chown -R "$REPO_WEB_USER:$REPO_WEB_GROUP" "$REPO_DIR"
  find "$REPO_DIR" -type d -exec chmod 755 {} \;
  find "$REPO_DIR" -type f -exec chmod 644 {} \;
}

# ------------------------------------------------------------------------------
# Timestamps fuer promotion tracking
# ------------------------------------------------------------------------------
record_timestamps() {
  local ts_file="$TIMESTAMPS_FILE"
  local now; now="$(date '+%Y-%m-%d')"
  mkdir -p "$(dirname "$ts_file")"
  touch "$ts_file"

  declare -A existing
  while IFS=' ' read -r pkg ts; do
    [ -n "$pkg" ] && existing["$pkg"]="$ts"
  done < "$ts_file"

  for deb in "$REPO_TESTING"/*.deb; do
    [ -f "$deb" ] || continue
    local bn; bn="$(basename "$deb")"
    if [ -z "${existing[$bn]+x}" ]; then
      echo "$bn $now" >> "$ts_file"
      changelog "add-testing" "$bn"
    fi
  done
}

promote_packages() {
  local force="${1:-no}"
  [ -d "$REPO_TESTING" ] || return 0

  local now_epoch; now_epoch="$(date '+%s')"
  local threshold=$((REPO_PROMOTE_DAYS * 86400))
  local promoted=0
  local promoted_list=""

  touch "$TIMESTAMPS_FILE"

  local tmp_ts; tmp_ts="$(mktemp)"
  while IFS=' ' read -r pkg ts; do
    [ -n "$pkg" ] || continue

    local pkg_epoch
    pkg_epoch="$(date -d "$ts" '+%s' 2>/dev/null || echo 0)"
    local age=$((now_epoch - pkg_epoch))

    if [ "$force" = "yes" ] || [ "$age" -ge "$threshold" ]; then
      if [ -f "$REPO_TESTING/$pkg" ]; then
        mv "$REPO_TESTING/$pkg" "$REPO_STABLE/"
        log "  Promote: $pkg (seit $ts, $((age/86400))d alt)"
        changelog "promote" "$pkg testing→stable (seit $ts, $((age/86400))d)"
        promoted_list+="  $pkg ($ts, $((age/86400))d alt)"$'\n'
        promoted=$((promoted + 1))
      fi
    else
      echo "$pkg $ts" >> "$tmp_ts"
    fi
  done < "$TIMESTAMPS_FILE"

  mv "$tmp_ts" "$TIMESTAMPS_FILE"

  if [ "$promoted" -gt 0 ]; then
    log "Promoted: $promoted Paket(e) testing→stable"
    cleanup_old_versions "$REPO_STABLE"
    build_index stable "$REPO_STABLE"
    build_index testing "$REPO_TESTING"
    fix_permissions
    notify "Promote: $promoted Paket(e)→stable" "$promoted_list"
  else
    log "Nichts zu promoted (Schwelle: ${REPO_PROMOTE_DAYS} Tage)"
  fi
}

# ------------------------------------------------------------------------------
# Rollback: stable→testing (demote)
# ------------------------------------------------------------------------------
demote_packages() {
  local pattern="${1:-}"
  [ -d "$REPO_STABLE" ] || die "stable/ nicht gefunden"

  local demoted=0 demoted_list=""
  local now; now="$(date '+%Y-%m-%d')"

  for deb in "$REPO_STABLE"/*.deb; do
    [ -f "$deb" ] || continue
    local bn; bn="$(basename "$deb")"
    if [ -n "$pattern" ]; then
      [[ "$bn" != *"$pattern"* ]] && continue
    fi
    mv "$deb" "$REPO_TESTING/"
    echo "$bn $now" >> "$TIMESTAMPS_FILE"
    log "  Demote: $bn stable→testing"
    changelog "demote" "$bn stable→testing"
    demoted_list+="  $bn"$'\n'
    demoted=$((demoted + 1))
  done

  if [ "$demoted" -gt 0 ]; then
    cleanup_old_versions "$REPO_TESTING"
    build_index stable "$REPO_STABLE"
    build_index testing "$REPO_TESTING"
    fix_permissions
    notify "Rollback: $demoted Paket(e) stable→testing" "$demoted_list"
    log "Demoted: $demoted Paket(e)"
  else
    log "Nichts zu demoten"
  fi
}

# ------------------------------------------------------------------------------
# Migration: flat→testing/stable
# ------------------------------------------------------------------------------
migrate_repo() {
  [ -d "$REPO_DIR" ] || die "Repo-Dir nicht gefunden: $REPO_DIR"

  if ! ls "$REPO_DIR"/*.deb >/dev/null 2>&1; then
    log "Keine .deb im Flat-Layout – nichts zu migrieren"
    return 0
  fi

  local count=0
  mkdir -p "$REPO_STABLE"

  for deb in "$REPO_DIR"/*.deb; do
    [ -f "$deb" ] || continue
    local bn; bn="$(basename "$deb")"
    if [ -f "$REPO_STABLE/$bn" ]; then
      rm -f "$deb"
    else
      mv "$deb" "$REPO_STABLE/"
      count=$((count + 1))
    fi
  done

  log "Migration: $count Pakete nach stable/ verschoben"
  changelog "migrate" "$count Pakete flat→stable"

  mkdir -p "$REPO_TESTING"

  rm -f "$REPO_DIR"/Packages "$REPO_DIR"/Packages.gz \
        "$REPO_DIR"/Release "$REPO_DIR"/Release.gpg \
        "$REPO_DIR"/InRelease "$REPO_DIR"/SHA256SUMS 2>/dev/null || true

  build_index stable "$REPO_STABLE"
  build_index testing "$REPO_TESTING"
  fix_permissions
  update_apt_sources
}

# ------------------------------------------------------------------------------
# Diff testing vs stable
# ------------------------------------------------------------------------------
show_diff() {
  echo "=============================================="
  echo " testing vs stable – $(date)"
  echo "=============================================="

  declare -A stable_pkgs testing_pkgs
  local deb pkg_name pkg_ver

  for deb in "$REPO_STABLE"/*.deb; do
    [ -f "$deb" ] || continue
    pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || continue)"
    pkg_ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || echo "?")"
    stable_pkgs["$pkg_name"]="$pkg_ver"
  done

  for deb in "$REPO_TESTING"/*.deb; do
    [ -f "$deb" ] || continue
    pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || continue)"
    pkg_ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || echo "?")"
    testing_pkgs["$pkg_name"]="$pkg_ver"
  done

  echo ""
  echo "  Neue Pakete (nur in testing):"
  local found=0
  for pkg_name in "${!testing_pkgs[@]}"; do
    if [ -z "${stable_pkgs[$pkg_name]+x}" ]; then
      echo "    + $pkg_name ${testing_pkgs[$pkg_name]}"
      found=$((found + 1))
    fi
  done
  [ "$found" -eq 0 ] && echo "    (keine)"

  echo ""
  echo "  Aktualisierungen (testing > stable):"
  found=0
  for pkg_name in "${!testing_pkgs[@]}"; do
    if [ -n "${stable_pkgs[$pkg_name]+x}" ]; then
      if [ "${testing_pkgs[$pkg_name]}" != "${stable_pkgs[$pkg_name]}" ]; then
        echo "    ↑ $pkg_name  ${stable_pkgs[$pkg_name]} → ${testing_pkgs[$pkg_name]}"
        found=$((found + 1))
      fi
    fi
  done
  [ "$found" -eq 0 ] && echo "    (keine)"

  echo ""
  echo "  Nur in stable (nicht mehr in testing):"
  found=0
  for pkg_name in "${!stable_pkgs[@]}"; do
    if [ -z "${testing_pkgs[$pkg_name]+x}" ]; then
      echo "    - $pkg_name ${stable_pkgs[$pkg_name]}"
      found=$((found + 1))
    fi
  done
  [ "$found" -eq 0 ] && echo "    (keine)"

  if [ -f "$TIMESTAMPS_FILE" ]; then
    echo ""
    echo "  Pending Promotions (naechste faellig):"
    local now_epoch; now_epoch="$(date '+%s')"
    while IFS=' ' read -r pkg ts; do
      [ -n "$pkg" ] || continue
      local pkg_epoch age remaining
      pkg_epoch="$(date -d "$ts" '+%s' 2>/dev/null || echo 0)"
      age=$(( (now_epoch - pkg_epoch) / 86400 ))
      remaining=$((REPO_PROMOTE_DAYS - age))
      if [ "$remaining" -gt 0 ]; then
        echo "    $pkg → in ${remaining}d (seit $ts, ${age}d alt)"
      else
        echo "    $pkg → FAELLIG (seit $ts, ${age}d alt)"
      fi
    done < "$TIMESTAMPS_FILE"
  fi

  echo "=============================================="
}

# ------------------------------------------------------------------------------
# apt sources + pinning
# ------------------------------------------------------------------------------
update_apt_sources() {
  local list_file="$APT_SOURCES_FILE"
  mkdir -p "$(dirname "$list_file")"
  [ -f "$list_file" ] && cp "$list_file" "${list_file}.bak"

  if [ -f "$GPG_PUBLIC_KEY" ] && detect_gpg_key 2>/dev/null; then
    cat > "$list_file" <<EOF
deb [signed-by=$GPG_PUBLIC_KEY] $REPO_URL/ stable ./
# deb [signed-by=$GPG_PUBLIC_KEY] $REPO_URL/ testing ./
EOF
  else
    cat > "$list_file" <<EOF
deb [trusted=yes] $REPO_URL/ stable ./
# deb [trusted=yes] $REPO_URL/ testing ./
EOF
  fi
  log "apt sources: $list_file"
}

setup_pinning() {
  local prefs_file="$APT_PREFS_FILE"
  mkdir -p "$(dirname "$prefs_file")"

  cat > "$prefs_file" <<'PREFS'
Explanation: Xerolux Repository Pinning
Package: *
Pin: release o=Xerolux Repository, n=xerolux-stable
Pin-Priority: 990

Package: *
Pin: release o=Xerolux Repository, n=xerolux-testing
Pin-Priority: 100
PREFS

  log "apt preferences: $prefs_file (stable=990, testing=100)"
  changelog "pinning" "$prefs_file erstellt"
}

# ------------------------------------------------------------------------------
# Health-Check
# ------------------------------------------------------------------------------
health_check() {
  echo "=============================================="
  echo " Health-Check – $(date)"
  echo "=============================================="

  local errors=0 warnings=0

  echo ""
  echo "  [1] Repo-Verzeichnisse"
  for d in "$REPO_DIR" "$REPO_STABLE" "$REPO_TESTING"; do
    if [ -d "$d" ]; then
      echo "    OK  $d"
    else
      echo "    FEHLT  $d"
      errors=$((errors + 1))
    fi
  done

  echo ""
  echo "  [2] Index-Dateien"
  for suite in stable testing; do
    local d="$REPO_DIR/$suite"
    for f in Packages Packages.gz Release Release.gpg InRelease; do
      if [ -f "$d/$f" ]; then
        echo "    OK  $suite/$f"
      else
        echo "    FEHLT  $suite/$f"
        [ "$f" = "Release.gpg" ] || [ "$f" = "InRelease" ] && warnings=$((warnings + 1)) || errors=$((errors + 1))
      fi
    done
  done

  echo ""
  echo "  [3] Acquire-By-Hash"
  for suite in stable testing; do
    if [ -d "$REPO_DIR/$suite/by-hash/SHA256" ]; then
      local cnt; cnt="$(ls "$REPO_DIR/$suite/by-hash/SHA256/" 2>/dev/null | wc -l)"
      echo "    OK  $suite/by-hash/SHA256 ($cnt Dateien)"
    else
      echo "    FEHLT  $suite/by-hash/SHA256"
      warnings=$((warnings + 1))
    fi
  done

  echo ""
  echo "  [4] Contents"
  for suite in stable testing; do
    local cf="$REPO_DIR/$suite/Contents-${REPO_ARCH}"
    if [ -f "$cf" ] && [ -s "$cf" ]; then
      echo "    OK  $suite/Contents-${REPO_ARCH} ($(wc -l < "$cf") Eintraege)"
    else
      echo "    LEER  $suite/Contents-${REPO_ARCH}"
      warnings=$((warnings + 1))
    fi
  done

  echo ""
  echo "  [5] GPG"
  if [ -f "$GPG_PUBLIC_KEY" ]; then
    echo "    OK  $GPG_PUBLIC_KEY"
  else
    echo "    FEHLT  $GPG_PUBLIC_KEY"
    errors=$((errors + 1))
  fi
  if detect_gpg_key 2>/dev/null; then
    echo "    OK  GPG Key: $GPG_KEY_ID"
  else
    echo "    FEHLT  Kein GPG Key"
    errors=$((errors + 1))
  fi

  echo ""
  echo "  [6] Signaturen"
  for suite in stable testing; do
    if [ -f "$REPO_DIR/$suite/InRelease" ] && detect_gpg_key 2>/dev/null; then
      if gpg_cmd --verify "$REPO_DIR/$suite/InRelease" 2>&1 | grep -q 'Good signature'; then
        echo "    OK  $suite/InRelease"
      else
        echo "    FEHLER  $suite/InRelease Signatur ungueltig"
        errors=$((errors + 1))
      fi
    else
      echo "    --  $suite/InRelease"
    fi
  done

  echo ""
  echo "  [7] apt Sources"
  if [ -f "$APT_SOURCES_FILE" ]; then
    echo "    OK  $APT_SOURCES_FILE"
    grep '^deb ' "$APT_SOURCES_FILE" | sed 's/^/         /'
  else
    echo "    FEHLT  $APT_SOURCES_FILE"
    errors=$((errors + 1))
  fi

  echo ""
  echo "  [8] apt Pinning"
  if [ -f "$APT_PREFS_FILE" ]; then
    echo "    OK  $APT_PREFS_FILE"
  else
    echo "    --  $APT_PREFS_FILE (optional)"
  fi

  echo ""
  echo "  [9] apt update Test"
  local apt_output
  apt_output="$(apt-get update -o Dir::Etc::sourcelist="$APT_SOURCES_FILE" -o APT::Get::List-Cleanup=0 2>&1)" || true
  if echo "$apt_output" | grep -qi "error\|failed\|fehlgeschlagen"; then
    echo "    FEHLER  apt update fehlgeschlagen"
    echo "$apt_output" | grep -i "error\|failed\|fehlgeschlagen" | head -5 | sed 's/^/           /'
    errors=$((errors + 1))
  else
    echo "    OK  apt update erfolgreich"
  fi

  echo ""
  echo "  [10] Download Test"
  local test_url="$REPO_URL/stable/Packages.gz"
  if curl -sfS -o /dev/null "$test_url" 2>/dev/null; then
    echo "    OK  $test_url"
  else
    echo "    FEHLER  $test_url nicht erreichbar"
    errors=$((errors + 1))
  fi

  local test_key="$REPO_URL/xerolux-repo.gpg"
  if curl -sfS -o /dev/null "$test_key" 2>/dev/null; then
    echo "    OK  $test_key"
  else
    echo "    FEHLER  $test_key nicht erreichbar"
    errors=$((errors + 1))
  fi

  echo ""
  echo "=============================================="
  if [ "$errors" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    echo "  ERGEBNIS: Alle Checks bestanden"
  elif [ "$errors" -eq 0 ]; then
    echo "  ERGEBNIS: OK ($warnings Warnung(en))"
  else
    echo "  ERGEBNIS: $errors Fehler, $warnings Warnung(en)"
  fi
  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Download-Statistiken
# ------------------------------------------------------------------------------
show_stats() {
  echo "=============================================="
  echo " Download-Statistiken – $(date)"
  echo "=============================================="

  if [ ! -f "$REPO_NGINX_LOG" ]; then
    echo "  Kein Nginx-Log gefunden: $REPO_NGINX_LOG"
    echo "  Pfad anpassen in setup_local_repo.env: REPO_NGINX_LOG"
    echo "=============================================="
    return
  fi

  echo ""
  echo "  Top 20 Pakete (letzte 30 Tage):"
  zgrep -h '\.deb' "$REPO_NGINX_LOG" "$REPO_NGINX_LOG".[0-9].gz 2>/dev/null \
    | awk -v days=30 '
      {
        split($4, d, "[/:]")
        ts = mktime(d[4]" "((d[3]+0)?"d[3]":"0")" "d[2]" "d[5]" "d[6]" "d[7])
      }
      /GET.*\.deb/ {
        match($0, /GET ([^ ]+\.deb)/, a)
        if (a[1]) {
          n = split(a[1], p, "/")
          print p[n]
        }
      }
    ' 2>/dev/null | sort | uniq -c | sort -rn | head -20 | awk '{printf "    %-6s %s\n", $1"x", $2}'

  echo ""
  echo "  Downloads pro Tag (letzte 14 Tage):"
  zgrep -h '\.deb' "$REPO_NGINX_LOG" "$REPO_NGINX_LOG".[0-9].gz 2>/dev/null \
    | awk '{
        split($4, d, "[/:]")
        print d[2]"/"d[3]"/"substr(d[4],3)
      }' 2>/dev/null | sort | uniq -c | sort -r | head -14 | awk '{printf "    %-12s %s\n", $2, $1}'

  echo ""
  echo "  Total .deb Downloads:"
  local total; total="$(zgrep -hc '\.deb' "$REPO_NGINX_LOG" "$REPO_NGINX_LOG".[0-9].gz 2>/dev/null | awk '{s+=$1}END{print s}')"
  echo "    ${total:-0}"

  echo ""
  echo "  Unique IPs:"
  zgrep -h '\.deb' "$REPO_NGINX_LOG" "$REPO_NGINX_LOG".[0-9].gz 2>/dev/null \
    | awk '{print $1}' 2>/dev/null | sort -u | wc -l | awk '{printf "    %s\n", $1}'

  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Paketsignierung
# ------------------------------------------------------------------------------
sign_debs() {
  local target_dir="${1:-$REPO_TESTING}"
  local sign_tool=""
  command -v dpkg-sig >/dev/null 2>&1 && sign_tool="dpkg-sig"
  command -v debsigs >/dev/null 2>&1 && sign_tool="debsigs"

  if [ -z "$sign_tool" ]; then
    apt-get update -qq --allow-releaseinfo-change 2>/dev/null || apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-sig >/dev/null 2>&1 && sign_tool="dpkg-sig" || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y debsigs >/dev/null 2>&1 && sign_tool="debsigs" || true
  fi

  [ -z "$sign_tool" ] && { log "Kein Signier-Tool – ueberspringe"; return 0; }
  detect_gpg_key || die "Kein GPG. $0 init-gpg"

  local ok=0 fail=0
  for deb in "$target_dir"/*.deb; do
    [ -f "$deb" ] || continue
    if [ "$sign_tool" = "dpkg-sig" ]; then
      dpkg-sig --verify "$deb" 2>/dev/null | grep -q "GOODSIG" && { ok=$((ok+1)); continue; }
      dpkg-sig -k "$GPG_KEY_ID" --sign builder "$deb" 2>&1 | tee -a "$LOG_FILE" && ok=$((ok+1)) || fail=$((fail+1))
    else
      debsigs --sign=origin --default-key="$GPG_KEY_ID" "$deb" 2>&1 | tee -a "$LOG_FILE" && ok=$((ok+1)) || fail=$((fail+1))
    fi
  done
  log "Signiert: $ok, Fehlgeschlagen: $fail"
  changelog "sign-debs" "$target_dir: $ok signiert, $fail fehlgeschlagen"
}

# ------------------------------------------------------------------------------
# Befehle
# ------------------------------------------------------------------------------
install_repo() {
  log "=== Installiere Xerolux Repository ==="
  acquire_lock

  apt-get update -qq --allow-releaseinfo-change 2>/dev/null || apt-get update -qq 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-dev gnupg apt-utils || die "apt-get install fehlgeschlagen"

  mkdir -p "$REPO_TESTING" "$REPO_STABLE"

  rm -f "$REPO_DIR"/{Packages,Packages.gz,Release,Release.gpg,InRelease,SHA256SUMS,custom-repo.gpg} 2>/dev/null || true
  rm -f "$APT_SOURCES_FILE.bak" 2>/dev/null || true

  local packages_copied=0
  for pkg_dir in "$DOVECOT_PKG_DIR" "$POSTFIX_PKG_DIR" "$NGINX_PKG_DIR" "$PHP_PKG_DIR"; do
    if [ -d "$pkg_dir" ] && find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
      cp -a "$pkg_dir"/*.deb "$REPO_TESTING/"
      packages_copied=1
    fi
  done

  record_timestamps
  cleanup_old_versions "$REPO_TESTING"
  build_index testing "$REPO_TESTING"
  build_index stable "$REPO_STABLE"
  fix_permissions
  update_apt_sources
  setup_pinning

  if [ -f "$GPG_PUBLIC_KEY" ]; then
    log "Public Key zum Download: $REPO_URL/xerolux-repo.gpg"
  fi

  changelog "install" "Repository erstellt"

  log "apt Cache aktualisieren..."
  apt-get update -qq --allow-releaseinfo-change 2>/dev/null || apt-get update -qq 2>/dev/null || true
  log "=== Installation abgeschlossen ==="
}

update_repo() {
  log "=== Aktualisiere Repository ==="
  [ -d "$REPO_TESTING" ] || die "Repo nicht gefunden. Zuerst: $0 install"
  acquire_lock

  local new_count=0 new_list=""
  for pkg_dir in "$DOVECOT_PKG_DIR" "$POSTFIX_PKG_DIR" "$NGINX_PKG_DIR" "$PHP_PKG_DIR"; do
    if [ -d "$pkg_dir" ] && find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
      while IFS= read -r deb; do
        [ -f "$deb" ] || continue
        local bn; bn="$(basename "$deb")"
        if [ ! -f "$REPO_TESTING/$bn" ] && [ ! -f "$REPO_STABLE/$bn" ]; then
          cp -a "$deb" "$REPO_TESTING/"
          new_list+="  $bn"$'\n'
          new_count=$((new_count + 1))
        fi
      done < <(find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f)
    fi
  done

  if [ "$new_count" -gt 0 ]; then
    log "$new_count neue Paket(e) nach testing/"
    record_timestamps
    cleanup_old_versions "$REPO_TESTING"
    build_index testing "$REPO_TESTING"
    fix_permissions
    changelog "update" "$new_count neue Pakete nach testing"
    notify "Update: $new_count neue Pakete" "$new_list"
  else
    log "Keine neuen Pakete"
  fi

  promote_packages no
  update_apt_sources
  log "=== Update abgeschlossen ==="
}

promote_repo() {
  local force="${1:-no}"
  [ -d "$REPO_TESTING" ] || die "Repo nicht gefunden"
  acquire_lock
  promote_packages "$force"
}

setup_cron() {
  local cron_line="0 3 * * * $SCRIPT_DIR/setup_local_repo.sh auto-promote >> $LOG_FILE 2>&1"
  local tmp; tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'setup_local_repo.sh.*auto-promote' > "$tmp" || true
  echo "$cron_line" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  log "Cron eingerichtet: taeglich 03:00 auto-promote ($REPO_PROMOTE_DAYS Tage)"
  changelog "cron-setup" "auto-promote alle $REPO_PROMOTE_DAYS Tage"
}

verify_repo() {
  local suite
  for suite in testing stable; do
    local d="$REPO_DIR/$suite"
    [ -d "$d" ] || continue
    cd "$d" || continue

    echo "=============================================="
    echo " $suite – $(date)"
    echo "=============================================="

    if [ -f SHA256SUMS ] && ls ./*.deb >/dev/null 2>&1; then
      local ok_n fail_n
      ok_n="$(sha256sum -c SHA256SUMS 2>&1 | grep -c ': OK$' || echo 0)"
      fail_n="$(sha256sum -c SHA256SUMS 2>&1 | grep -c ': FAILED' || echo 0)"
      echo "  SHA256: $ok_n OK, $fail_n FAILED"
    else
      echo "  SHA256: --"
    fi

    if [ -f InRelease ] && detect_gpg_key 2>/dev/null; then
      gpg_cmd --verify InRelease 2>&1 | grep -q 'Good signature' && echo "  Signatur: OK ($GPG_KEY_ID)" || echo "  Signatur: FEHLER"
    else
      echo "  Signatur: --"
    fi

    if [ -d by-hash/SHA256 ]; then
      local bh_cnt; bh_cnt="$(ls by-hash/SHA256/ 2>/dev/null | wc -l)"
      echo "  By-Hash: $bh_cnt Dateien"
    else
      echo "  By-Hash: --"
    fi

    local deb_n; deb_n="$(ls ./*.deb 2>/dev/null | wc -l)"
    local idx_n; idx_n="$(grep -c '^Package:' Packages 2>/dev/null || echo 0)"
    echo "  Pakete: $deb_n Dateien, $idx_n im Index"
    echo "=============================================="
  done
}

status_repo() {
  echo "=============================================="
  echo " Xerolux Repository Status – $(date)"
  echo "=============================================="

  echo ""
  echo "  Repo-Dir: $REPO_DIR"
  echo "  URL:      $REPO_URL"
  echo "  Arch:     $REPO_ARCH"
  echo "  Promote:  nach $REPO_PROMOTE_DAYS Tagen"

  echo ""
  for suite in testing stable; do
    local d="$REPO_DIR/$suite"
    if [ -d "$d" ]; then
      local cnt; cnt="$(ls "$d"/*.deb 2>/dev/null | wc -l)"
      local disk; disk="$(du -sh "$d" 2>/dev/null | cut -f1)"
      echo "  $suite/: $cnt .deb Pakete ($disk)"
      [ -f "$d/InRelease" ] && echo "    [OK] GPG signiert" || echo "    [--] nicht signiert"
      [ -f "$d/Packages" ] && echo "    [OK] Packages Index" || echo "    [--] kein Index"
      [ -d "$d/by-hash/SHA256" ] && echo "    [OK] Acquire-By-Hash" || echo "    [--] kein By-Hash"
      [ -f "$d/Contents-${REPO_ARCH}" ] && echo "    [OK] Contents" || echo "    [--] kein Contents"
    else
      echo "  $suite/: nicht vorhanden"
    fi
  done

  echo ""
  if [ -f "$TIMESTAMPS_FILE" ]; then
    echo "  Testing Timestamps:"
    while IFS=' ' read -r pkg ts; do
      [ -n "$pkg" ] || continue
      local age
      age=$(( ( $(date '+%s') - $(date -d "$ts" '+%s' 2>/dev/null || echo 0) ) / 86400 ))
      local remaining=$((REPO_PROMOTE_DAYS - age))
      if [ "$remaining" -gt 0 ]; then
        echo "    $pkg → ${ts} (${age}d alt, in ${remaining}d)"
      else
        echo "    $pkg → ${ts} (${age}d alt, FAELLIG)"
      fi
    done < "$TIMESTAMPS_FILE"
  fi

  echo ""
  [ -f "$GPG_PUBLIC_KEY" ] && echo "  [OK] GPG Key: $GPG_PUBLIC_KEY" || echo "  [--] GPG Key fehlt"
  [ -f "$REPO_DIR/xerolux-repo.gpg" ] && echo "  [OK] Download: $REPO_URL/xerolux-repo.gpg"
  [ -f "$APT_SOURCES_FILE" ] && echo "  [OK] Sources: $APT_SOURCES_FILE" || echo "  [--] Sources nicht konfiguriert"
  [ -f "$APT_PREFS_FILE" ] && echo "  [OK] Pinning: $APT_PREFS_FILE" || echo "  [--] Pinning nicht konfiguriert"
  [ -f "$CHANGELOG_FILE" ] && echo "  [OK] Changelog: $(wc -l < "$CHANGELOG_FILE") Eintraege"

  echo ""
  local cron_check
  cron_check="$(crontab -l 2>/dev/null | grep 'auto-promote' || true)"
  [ -n "$cron_check" ] && echo "  [OK] Cron: auto-promote aktiv" || echo "  [--] Cron nicht eingerichtet ($0 auto-promote)"

  echo ""
  echo "  Letzte Changelog-Eintraege:"
  tail -5 "$CHANGELOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "    $line"
  done

  echo "=============================================="
}

uninstall_repo() {
  log "=== Deinstalliere Repository ==="
  acquire_lock
  rm -f "$APT_SOURCES_FILE" "$APT_PREFS_FILE"
  rm -rf "$REPO_DIR"
  rm -f "$GPG_PUBLIC_KEY"
  apt-get update -qq --allow-releaseinfo-change 2>/dev/null || apt-get update -qq 2>/dev/null || true
  changelog "uninstall" "Repository entfernt"
  log "=== Deinstallation abgeschlossen ==="
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  check_os_arch
  require_root
  touch "$LOG_FILE" || die "Kann Log nicht erstellen: $LOG_FILE"

  case "${1:-help}" in
    install)       install_repo ;;
    update)        update_repo ;;
    promote)       promote_repo no ;;
    promote-all)   promote_repo yes ;;
    auto-promote)  promote_repo no; setup_cron ;;
    demote)        acquire_lock; demote_packages "${2:-}" ;;
    migrate)       acquire_lock; migrate_repo ;;
    diff)          show_diff ;;
    status)        status_repo ;;
    verify)        verify_repo ;;
    health-check)  health_check ;;
    stats)         show_stats ;;
    cleanup)       acquire_lock; cleanup_old_versions "$REPO_TESTING"; cleanup_old_versions "$REPO_STABLE"; build_index testing "$REPO_TESTING"; build_index stable "$REPO_STABLE"; fix_permissions ;;
    uninstall)     uninstall_repo ;;
    init-gpg)      init_gpg ;;
    export-key)    export_key ;;
    sign-repo)     acquire_lock; build_index testing "$REPO_TESTING"; build_index stable "$REPO_STABLE"; fix_permissions ;;
    sign-debs)     sign_debs ;;
    setup-pinning) setup_pinning ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
