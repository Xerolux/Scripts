#!/usr/bin/env bash
# ==============================================================================
# setup_local_repo.sh - Lokales apt-Repository fuer Custom-Build-Pakete
#
# Zielumgebung : Ubuntu 24.04 ARM64
# Pakete       : postfix-custom, dovecot-core-custom, dovecot-pigeonhole-custom,
#                nginx-custom, php8.5-custom und deren Sub-Pakete
#
# Features:
#   - GPG-signiertes Repository (Release + InRelease, Ed25519)
#   - SHA256 + SHA512 Checksummen
#   - Uncompressed + gzip Packages Index
#   - Automatisches Cleanup alter Paketversionen
#   - Lock-File gegen parallele Updates
#   - Paketsignierung (dpkg-sig bevorzugt, debsigs als Fallback)
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/setup_local_repo.env" ]] && [[ -f "$SCRIPT_DIR/setup_local_repo.env.example" ]]; then
  cp -n "$SCRIPT_DIR/setup_local_repo.env.example" "$SCRIPT_DIR/setup_local_repo.env" 2>/dev/null || true
  echo "HINWEIS: setup_local_repo.env wurde aus setup_local_repo.env.example erstellt." >&2
fi
if [[ ! -f "$SCRIPT_DIR/setup_local_repo.env" ]]; then
  echo "FEHLER: setup_local_repo.env nicht gefunden. Bitte in $SCRIPT_DIR aus setup_local_repo.env.example erstellen." >&2
  exit 1
fi
source "$SCRIPT_DIR/setup_local_repo.env"

GPG_KEY_ID="${GPG_KEY_ID:-}"
GPG_KEY_NAME="${GPG_KEY_NAME:-Custom Build Repo}"
GPG_KEY_EMAIL="${GPG_KEY_EMAIL:-root@localhost}"
GPG_KEYRING_DIR="${GPG_KEYRING_DIR:-/root/.gnupg}"

GPG_PUBLIC_KEY="/etc/apt/keyrings/xerolux-repo.gpg"
APT_KEYRING_DIR="/etc/apt/keyrings"
REPO_ARCH="$(dpkg --print-architecture 2>/dev/null || echo arm64)"
LOCK_FILE="${REPO_DIR:-/var/local/custom-repo}/.repo.lock"

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
die() { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausfuehren."
}

check_os_arch() {
  local os_id os_version_id os_major_version arch

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_id="${ID:-}"
    os_version_id="${VERSION_ID:-}"
  else
    os_id="unknown"
    os_version_id="unknown"
  fi

  os_major_version=$(echo "$os_version_id" | cut -d. -f1)
  arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")

  if [ "$os_id" != "ubuntu" ] || [ -z "$os_major_version" ] || [ "$os_major_version" -lt 24 ]; then
    echo "FEHLER: Dieses Skript unterstuetzt nur Ubuntu 24.04 (oder neuer)." >&2
    exit 1
  fi

  if [ "$arch" != "arm64" ]; then
    echo "WARNUNG: Dieses Skript ist fuer arm64 ausgelegt. Aktuelle Architektur: $arch." >&2
  fi
}

usage() {
  cat <<'USAGE'
Verwendung:
  setup_local_repo.sh install       – Erstellt Repo, traegt es in apt ein, kopiert Pakete
  setup_local_repo.sh update        – Kopiert neue Pakete, aktualisiert Index + Signatur
  setup_local_repo.sh uninstall     – Entfernt Repo aus apt, loescht Dateien
  setup_local_repo.sh status        – Zeigt Status des Repositories
  setup_local_repo.sh verify        – Prueft alle Checksummen und Signaturen
  setup_local_repo.sh cleanup       – Entfernt alte Paketversionen, haelt nur neueste
  setup_local_repo.sh init-gpg      – Erstellt GPG-Schluessel (einmalig)
  setup_local_repo.sh export-key    – Exportiert oeffentlichen Schluessel nach /etc/apt/keyrings/
  setup_local_repo.sh sign-repo     – Signiert Repository neu (Release + InRelease)
  setup_local_repo.sh sign-debs     – Signiert alle .deb-Pakete im Repo (dpkg-sig/debsigs)
USAGE
}

# ------------------------------------------------------------------------------
# Lock-File
# ------------------------------------------------------------------------------
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  if ! ln -s /proc/self "$LOCK_FILE" 2>/dev/null; then
    local pid=""
    [ -L "$LOCK_FILE" ] && pid="$(readlink "$LOCK_FILE" 2>/dev/null | sed 's|/proc/||;s|/self||')"
    die "Repository ist gesperrt (PID ${pid:-unknown}). Wenn nicht mehr aktiv: rm -f $LOCK_FILE"
  fi
  trap 'rm -f "$LOCK_FILE"' EXIT
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# ------------------------------------------------------------------------------
# GPG-Hilfsfunktionen
# ------------------------------------------------------------------------------
gpg_cmd() {
  gpg --batch --yes --no-tty --homedir "$GPG_KEYRING_DIR" "$@"
}

detect_gpg_key() {
  if [ -n "$GPG_KEY_ID" ]; then
    return 0
  fi

  local key_ids
  key_ids="$(gpg_cmd --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/{print $5}' | head -1)" || true

  if [ -n "$key_ids" ]; then
    GPG_KEY_ID="$key_ids"
    log "GPG-Schluessel automatisch erkannt: $GPG_KEY_ID"
    return 0
  fi

  return 1
}

init_gpg() {
  log "=== Erstelle GPG-Schluessel fuer Repository-Signierung ==="

  if detect_gpg_key 2>/dev/null; then
    log "GPG-Schluessel bereits vorhanden: $GPG_KEY_ID"
    log "Vorhandenen Schluessel verwenden. Fuer einen neuen Schluessel zuerst loeschen:"
    echo "  gpg --homedir $GPG_KEYRING_DIR --delete-secret-keys $GPG_KEY_ID"
    return 0
  fi

  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg

  mkdir -p "$GPG_KEYRING_DIR"
  chmod 700 "$GPG_KEYRING_DIR"

  local batch_file="/tmp/gpg-batch-$$"
  cat > "$batch_file" <<GPGCONF
%no-protection
Key-Type: Ed25519
Subkey-Type: Curve25519
Name-Real: ${GPG_KEY_NAME}
Name-Email: ${GPG_KEY_EMAIL}
Expire-Date: 0
%commit
GPGCONF

  log "Erstelle Ed25519/Curve25519 Schluessel..."
  gpg_cmd --gen-key --batch "$batch_file"
  rm -f "$batch_file"

  if ! detect_gpg_key; then
    die "GPG-Schluessel-Erstellung fehlgeschlagen"
  fi

  log "GPG-Schluessel erstellt: $GPG_KEY_ID"
  log "Fingerabdruck:"
  gpg_cmd --fingerprint "$GPG_KEY_ID" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG_FILE"

  export_key

  log "=== GPG-Schluessel bereit ==="
}

export_key() {
  log "Exportiere oeffentlichen Schluessel..."

  if ! detect_gpg_key; then
    die "Kein GPG-Schluessel gefunden. Zuerst: $0 init-gpg"
  fi

  mkdir -p "$APT_KEYRING_DIR"

  gpg_cmd --armor --export "$GPG_KEY_ID" > "$GPG_PUBLIC_KEY"
  chmod 644 "$GPG_PUBLIC_KEY"

  log "Oeffentlicher Schluessel exportiert: $GPG_PUBLIC_KEY"
  log "Fingerabdruck:"
  gpg_cmd --fingerprint "$GPG_KEY_ID" 2>/dev/null | grep -E "^[[:space:]]+[0-9A-F]" | head -1 | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Repository-Index erstellen
# ------------------------------------------------------------------------------
generate_packages_index() {
  cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"

  log "Erstelle Packages-Index..."

  dpkg-scanpackages -m . /dev/null 2>/dev/null > Packages
  gzip -9kc Packages > Packages.gz

  local pkg_count
  pkg_count="$(grep -c '^Package:' Packages 2>/dev/null || echo 0)"
  log "Packages-Index erstellt: $pkg_count Pakete"
}

# ------------------------------------------------------------------------------
# Release-Datei erstellen (einmaliger Hash-Durchlauf)
# ------------------------------------------------------------------------------
generate_release() {
  cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"

  log "Erstelle Release-Datei..."

  local now
  now="$(date -u '+%a, %d %b %Y %H:%M:%S UTC')"

  cat > Release <<RELEASEHEAD
Origin: Custom Build Repository
Label: Custom Build Repository
Suite: stable
Codename: custom
Date: $now
Architectures: $REPO_ARCH
Components: ./
Description: Lokales Repository fuer Custom-Build-Pakete
RELEASEHEAD

  local md5_sum sha1_sum sha256_sum sha512_sum size
  local md5_block="" sha1_block="" sha256_block="" sha512_block=""

  for f in Packages Packages.gz $(ls ./*.deb 2>/dev/null || true); do
    [ -f "$f" ] || continue
    size="$(stat -c '%s' "$f")"

    md5_sum="$(md5sum "$f" | awk '{print $1}')"
    sha1_sum="$(sha1sum "$f" | awk '{print $1}')"
    sha256_sum="$(sha256sum "$f" | awk '{print $1}')"
    sha512_sum="$(sha512sum "$f" | awk '{print $1}')"

    md5_block+=" ${md5_sum} ${size} ${f}"$'\n'
    sha1_block+=" ${sha1_sum} ${size} ${f}"$'\n'
    sha256_block+=" ${sha256_sum} ${size} ${f}"$'\n'
    sha512_block+=" ${sha512_sum} ${size} ${f}"$'\n'
  done

  printf 'MD5Sum:\n%s' "$md5_block" >> Release
  printf 'SHA1:\n%s' "$sha1_block" >> Release
  printf 'SHA256:\n%s' "$sha256_block" >> Release
  printf 'SHA512:\n%s' "$sha512_block" >> Release

  log "Release-Datei erstellt (Date: $now)"
}

sign_release() {
  cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"

  if ! detect_gpg_key 2>/dev/null; then
    log "WARNUNG: Kein GPG-Schluessel – Release wird nicht signiert"
    log "         Spaeter nachholen: $0 init-gpg && $0 sign-repo"
    return 0
  fi

  log "Signiere Release mit GPG-Schluessel $GPG_KEY_ID..."

  rm -f Release.gpg InRelease

  gpg_cmd --default-key "$GPG_KEY_ID" -abs -o Release.gpg Release
  gpg_cmd --default-key "$GPG_KEY_ID" --clearsign -o InRelease Release

  log "Release.gpg und InRelease erstellt"
}

# ------------------------------------------------------------------------------
# Cleanup alte Paketversionen - haelt nur die neueste
# ------------------------------------------------------------------------------
cleanup_old_versions() {
  cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"

  log "Bereinige alte Paketversionen..."

  local removed=0
  declare -A latest_pkg

  for deb in ./*.deb; do
    [ -f "$deb" ] || continue
    local pkg_name
    pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || continue)"
    local pkg_ver
    pkg_ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || echo 0)"

    if [ -n "${latest_pkg[$pkg_name]+x}" ]; then
      local existing_ver existing_file
      existing_file="${latest_pkg[$pkg_name]}"
      existing_ver="$(dpkg-deb -f "$existing_file" Version 2>/dev/null || echo 0)"

      if dpkg --compare-versions "$pkg_ver" gt "$existing_ver"; then
        log "  Entferne alte Version: $(basename "$existing_file") ($existing_ver)"
        rm -f "$existing_file"
        latest_pkg[$pkg_name]="$deb"
        removed=$((removed + 1))
      else
        log "  Entferne alte Version: $(basename "$deb") ($pkg_ver)"
        rm -f "$deb"
        removed=$((removed + 1))
      fi
    else
      latest_pkg[$pkg_name]="$deb"
    fi
  done

  if [ "$removed" -gt 0 ]; then
    log "Cleanup: $removed alte Version(en) entfernt"
  else
    log "Cleanup: Alle Pakete aktuell"
  fi
}

# ------------------------------------------------------------------------------
# SHA256-Checksummen
# ------------------------------------------------------------------------------
generate_checksums() {
  if [ -d "$REPO_DIR" ] && ls "$REPO_DIR"/*.deb >/dev/null 2>&1; then
    log "Erstelle SHA256SUMS..."
    cd "$REPO_DIR"
    sha256sum ./*.deb > SHA256SUMS
    log "SHA256SUMS erstellt ($(wc -l < SHA256SUMS) Pakete)"
  fi
}

# ------------------------------------------------------------------------------
# Alle .deb-Pakete im Repo signieren (dpkg-sig bevorzugt, debsigs als Fallback)
# ------------------------------------------------------------------------------
sign_debs() {
  local sign_tool=""
  if command -v dpkg-sig >/dev/null 2>&1; then
    sign_tool="dpkg-sig"
  elif command -v debsigs >/dev/null 2>&1; then
    sign_tool="debsigs"
  else
    log "Installiere Paketsignierungs-Tool..."
    apt-get update -qq
    if DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-sig >/dev/null 2>&1; then
      sign_tool="dpkg-sig"
    elif DEBIAN_FRONTEND=noninteractive apt-get install -y debsigs debsig-verify >/dev/null 2>&1 \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y debsigs >/dev/null 2>&1; then
      sign_tool="debsigs"
    fi
  fi

  if [ -z "$sign_tool" ]; then
    log "Kein Paketsignierungs-Tool verfuegbar – ueberspringe .deb-Signierung"
    return 0
  fi

  log "=== Signiere .deb-Pakete mit $sign_tool ==="

  if ! detect_gpg_key; then
    die "Kein GPG-Schluessel. Zuerst: $0 init-gpg"
  fi

  local deb_count=0
  local deb_fail=0

  for deb in "$REPO_DIR"/*.deb; do
    [ -f "$deb" ] || continue

    if [ "$sign_tool" = "dpkg-sig" ]; then
      if dpkg-sig --verify "$deb" 2>/dev/null | grep -q "GOODSIG"; then
        log "  [OK] $(basename "$deb") bereits signiert"
        deb_count=$((deb_count + 1))
        continue
      fi

      log "  Signiere $(basename "$deb")..."
      if dpkg-sig -k "$GPG_KEY_ID" --sign builder "$deb" 2>&1 | tee -a "$LOG_FILE"; then
        deb_count=$((deb_count + 1))
      else
        log "  [FAIL] $(basename "$deb")"
        deb_fail=$((deb_fail + 1))
      fi
    elif debsigs --sign=origin --default-key="$GPG_KEY_ID" "$deb" 2>&1 | tee -a "$LOG_FILE"; then
      log "  [OK] $(basename "$deb") signiert"
      deb_count=$((deb_count + 1))
    else
      log "  [FAIL] $(basename "$deb")"
      deb_fail=$((deb_fail + 1))
    fi
  done

  log "Signiert: $deb_count, Fehlgeschlagen: $deb_fail"
}

# ------------------------------------------------------------------------------
# Kompletten Repository-Index + Signierung erneuern
# ------------------------------------------------------------------------------
rebuild_repo() {
  cleanup_old_versions
  generate_packages_index
  generate_checksums
  generate_release
  sign_release
}

# ------------------------------------------------------------------------------
# apt sources.list aktualisieren (mit signed-by wenn Schluessel vorhanden)
# ------------------------------------------------------------------------------
update_apt_sources() {
  local list_file="/etc/apt/sources.list.d/local-mail-repo.list"

  [ -f "$list_file" ] && cp "$list_file" "${list_file}.bak"

  if [ -f "$GPG_PUBLIC_KEY" ] && detect_gpg_key 2>/dev/null; then
    echo "deb [signed-by=$GPG_PUBLIC_KEY] file:$REPO_DIR ./" > "$list_file"
    log "apt sources list aktualisiert (signed-by=$GPG_PUBLIC_KEY)"
  else
    echo "deb [trusted=yes] file:$REPO_DIR ./" > "$list_file"
    log "apt sources list aktualisiert (trusted=yes – kein GPG-Schluessel)"
  fi
}

# ------------------------------------------------------------------------------
# Verify: Checksummen und Signaturen pruefen
# ------------------------------------------------------------------------------
verify_repo() {
  cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"

  local errors=0

  echo "=============================================="
  echo " Repository Verifikation – $(date)"
  echo "=============================================="

  echo ""
  echo "1. SHA256SUMS pruefen..."
  if [ -f SHA256SUMS ]; then
    if sha256sum -c SHA256SUMS 2>&1 | grep -v ': OK$'; then
      echo "  [FAIL] SHA256 Fehler gefunden!"
      errors=$((errors + 1))
    else
      local ok_count
      ok_count="$(sha256sum -c SHA256SUMS 2>&1 | grep -c ': OK$' || echo 0)"
      echo "  [OK] $ok_count Pakete verifiziert"
    fi
  else
    echo "  [--] Keine SHA256SUMS vorhanden"
  fi

  echo ""
  echo "2. Release-Signatur pruefen..."
  if [ -f InRelease ]; then
    if gpg_cmd --verify InRelease 2>&1 | grep -q 'Good signature'; then
      echo "  [OK] InRelease Signatur gueltig (Key: $GPG_KEY_ID)"
    else
      gpg_cmd --verify InRelease 2>&1 | tail -2
      errors=$((errors + 1))
    fi
  elif [ -f Release.gpg ] && [ -f Release ]; then
    if gpg_cmd --verify Release.gpg Release 2>&1 | grep -q 'Good signature'; then
      echo "  [OK] Release.gpg Signatur gueltig (Key: $GPG_KEY_ID)"
    else
      gpg_cmd --verify Release.gpg Release 2>&1 | tail -2
      errors=$((errors + 1))
    fi
  else
    echo "  [--] Keine signierte Release-Datei vorhanden"
  fi

  echo ""
  echo "3. .deb Paket-Signaturen pruefen..."
  if command -v dpkg-sig >/dev/null 2>&1; then
    local signed=0 unsigned=0
    for deb in ./*.deb; do
      [ -f "$deb" ] || continue
      if dpkg-sig --verify "$deb" 2>/dev/null | grep -q "GOODSIG"; then
        signed=$((signed + 1))
      else
        echo "  [UNSIGNED] $(basename "$deb")"
        unsigned=$((unsigned + 1))
      fi
    done
    echo "  Signiert: $signed, Unsigniert: $unsigned"
  else
    echo "  [--] dpkg-sig nicht installiert"
  fi

  echo ""
  echo "4. Packages Index pruefen..."
  if [ -f Packages ] && [ -f Packages.gz ]; then
    local pkg_in_index
    pkg_in_index="$(grep -c '^Package:' Packages 2>/dev/null || echo 0)"
    local deb_count
    deb_count="$(ls ./*.deb 2>/dev/null | wc -l)"
    echo "  Packages Eintraege: $pkg_in_index, .deb Dateien: $deb_count"
    if [ "$pkg_in_index" -ne "$deb_count" ]; then
      echo "  [WARN] Diskrepanz zwischen Index und Dateien"
      errors=$((errors + 1))
    else
      echo "  [OK] Index und Dateien konsistent"
    fi

    if zcat Packages.gz | diff - Packages >/dev/null 2>&1; then
      echo "  [OK] Packages.gz stimmt mit Packages ueberein"
    else
      echo "  [FAIL] Packages.gz weicht von Packages ab"
      errors=$((errors + 1))
    fi
  else
    echo "  [--] Packages/Packages.gz fehlen"
    errors=$((errors + 1))
  fi

  echo ""
  if [ "$errors" -eq 0 ]; then
    echo "Ergebnis: Alle Prüfungen bestanden"
  else
    echo "Ergebnis: $errors Fehler gefunden"
  fi
  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Befehle
# ------------------------------------------------------------------------------
install_repo() {
  log "=== Starte Installation des lokalen Repositories ==="

  acquire_lock
  mkdir -p "$REPO_DIR"

  log "Installiere Abhaengigkeiten..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-dev gnupg

  log "Kopiere vorhandene Pakete in das Repository..."
  local packages_copied=0
  for pkg_dir in "$DOVECOT_PKG_DIR" "$POSTFIX_PKG_DIR" "$NGINX_PKG_DIR" "$PHP_PKG_DIR"; do
    if [ -d "$pkg_dir" ] && ls "$pkg_dir"/*.deb >/dev/null 2>&1; then
      cp -a "$pkg_dir"/*.deb "$REPO_DIR/"
      packages_copied=1
    fi
  done

  if [ "$packages_copied" -eq 1 ]; then
    rebuild_repo
  else
    log "Keine .deb Pakete zum Kopieren gefunden, erstelle leeres Repository."
    cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"
    touch Packages
    gzip -9kc Packages > Packages.gz
    generate_release
    sign_release
  fi

  update_apt_sources

  log "Aktualisiere apt Cache..."
  apt-get update -qq

  log "=== Installation abgeschlossen ==="
}

update_repo() {
  log "=== Aktualisiere lokales Repository ==="

  if [ ! -d "$REPO_DIR" ]; then
    die "Repository-Verzeichnis $REPO_DIR existiert nicht. Bitte zuerst 'install' ausfuehren."
  fi

  acquire_lock

  log "Kopiere neue Pakete..."
  for pkg_dir in "$DOVECOT_PKG_DIR" "$POSTFIX_PKG_DIR" "$NGINX_PKG_DIR" "$PHP_PKG_DIR"; do
    if [ -d "$pkg_dir" ] && ls "$pkg_dir"/*.deb >/dev/null 2>&1; then
      cp -a "$pkg_dir"/*.deb "$REPO_DIR/" 2>/dev/null || true
    fi
  done

  rebuild_repo
  update_apt_sources

  log "Aktualisiere apt Cache..."
  apt-get update -qq

  log "=== Aktualisierung abgeschlossen ==="
}

uninstall_repo() {
  log "=== Deinstalliere lokales Repository ==="
  local list_file="/etc/apt/sources.list.d/local-mail-repo.list"

  acquire_lock

  [ -f "$list_file" ] && { log "Entferne apt sources list: $list_file"; rm -f "$list_file"; }
  [ -d "$REPO_DIR" ] && { log "Entferne Repository-Verzeichnis: $REPO_DIR"; rm -rf "$REPO_DIR"; }
  [ -f "$GPG_PUBLIC_KEY" ] && { log "Entferne oeffentlichen Schluessel: $GPG_PUBLIC_KEY"; rm -f "$GPG_PUBLIC_KEY"; }

  apt-get update -qq || true
  log "=== Deinstallation abgeschlossen ==="
}

status_repo() {
  echo "=============================================="
  echo " Lokales Repository Status – $(date)"
  echo "=============================================="

  local list_file="/etc/apt/sources.list.d/local-mail-repo.list"
  if [ -f "$list_file" ]; then
    echo "  [OK] apt sources list: $list_file"
    sed 's/^/       /' < "$list_file"
  else
    echo "  [--] apt sources list nicht gefunden"
  fi

  echo ""
  if [ -f "$GPG_PUBLIC_KEY" ]; then
    echo "  [OK] GPG Public Key: $GPG_PUBLIC_KEY"
  else
    echo "  [--] GPG Public Key nicht exportiert"
  fi

  if detect_gpg_key 2>/dev/null; then
    echo "  [OK] GPG Signierschluessel: $GPG_KEY_ID"
  else
    echo "  [--] Kein GPG Signierschluessel"
  fi

  echo ""
  if [ -d "$REPO_DIR" ]; then
    echo "  [OK] Repository: $REPO_DIR"
    [ -f "$REPO_DIR/Packages" ] && echo "  [OK] Packages Index vorhanden"
    [ -f "$REPO_DIR/Packages.gz" ] && echo "  [OK] Packages.gz vorhanden"
    [ -f "$REPO_DIR/Release" ] && echo "  [OK] Release-Datei vorhanden"
    [ -f "$REPO_DIR/Release.gpg" ] && echo "  [OK] Release.gpg (signiert)"
    [ -f "$REPO_DIR/InRelease" ] && echo "  [OK] InRelease (clearsign)"
    [ -f "$REPO_DIR/SHA256SUMS" ] && echo "  [OK] SHA256SUMS vorhanden"

    echo ""
    echo "  Pakete:"
    local pkg_count
    pkg_count="$(find "$REPO_DIR" -maxdepth 1 -name "*.deb" | wc -l)"
    echo "  $pkg_count .deb-Pakete im Repository"
    find "$REPO_DIR" -maxdepth 1 -name "*.deb" -exec basename {} \; | sort | awk '{print "    - "$1}'
  else
    echo "  [--] Repository nicht gefunden ($REPO_DIR)"
  fi
  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  check_os_arch
  require_root
  touch "$LOG_FILE" || die "Kann Log-Datei nicht erstellen: $LOG_FILE"

  case "${1:-help}" in
    install)      install_repo ;;
    update)       update_repo ;;
    uninstall)    uninstall_repo ;;
    status)       status_repo ;;
    verify)       verify_repo ;;
    cleanup)      cd "$REPO_DIR" || die "Repo nicht gefunden"; cleanup_old_versions; rebuild_repo ;;
    init-gpg)     init_gpg ;;
    export-key)   export_key ;;
    sign-repo)    generate_release; sign_release ;;
    sign-debs)    sign_debs ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
