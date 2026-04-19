#!/usr/bin/env bash
# ==============================================================================
# setup_local_repo.sh - Lokales apt-Repository fuer Custom-Build-Pakete
#
# Zielumgebung : Ubuntu 24.04 ARM64
# Pakete       : postfix-custom, dovecot-core-custom, dovecot-pigeonhole-custom,
#                nginx-custom, php8.5-custom und deren Sub-Pakete
#
# Features:
#   - GPT-signiertes Repository (Release + InRelease)
#   - GPG-Schluessel-Generierung und -Export
#   - SHA256-Checksummen
#   - dpkg-sig Paketsignierung (optional)
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/setup_local_repo.env" ]]; then
  echo "FEHLER: setup_local_repo.env nicht gefunden. Bitte in $SCRIPT_DIR aus setup_local_repo.env.example erstellen." >&2
  exit 1
fi
source "$SCRIPT_DIR/setup_local_repo.env"

GPG_KEY_ID="${GPG_KEY_ID:-}"
GPG_KEY_NAME="${GPG_KEY_NAME:-Custom Build Repo}"
GPG_KEY_EMAIL="${GPG_KEY_EMAIL:-root@localhost}"
GPG_KEYRING_DIR="${GPG_KEYRING_DIR:-/root/.gnupg}"

GPG_PUBLIC_KEY="/etc/apt/keyrings/custom-repo.gpg"
APT_KEYRING_DIR="/etc/apt/keyrings"

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

  if [ "$os_id" != "ubuntu" ] || [ -z "$os_major_version" ] || [ "$os_major_version" -lt 24 ] || [ "$arch" != "arm64" ]; then
    echo "FEHLER: Dieses Skript unterstuetzt nur Ubuntu 24.04 (oder neuer) auf arm64." >&2
    exit 1
  fi
}

usage() {
  cat <<'USAGE'
Verwendung:
  setup_local_repo.sh install       – Erstellt Repo, traegt es in apt ein, kopiert Pakete
  setup_local_repo.sh update        – Kopiert neue Pakete, aktualisiert Index + Signatur
  setup_local_repo.sh uninstall     – Entfernt Repo aus apt, loescht Dateien
  setup_local_repo.sh status        – Zeigt Status des Repositories
  setup_local_repo.sh init-gpg      – Erstellt GPG-Schluessel (einmalig)
  setup_local_repo.sh export-key    – Exportiert oeffentlichen Schluessel nach /etc/apt/keyrings/
  setup_local_repo.sh sign-repo     – Signiert Repository neu (Release + InRelease)
  setup_local_repo.sh sign-debs     – Signiert alle .deb-Pakete im Repo mit dpkg-sig
USAGE
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
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${GPG_KEY_NAME}
Name-Email: ${GPG_KEY_EMAIL}
Expire-Date: 0
%commit
GPGCONF

  log "Erstelle 4096-bit RSA Schluessel..."
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
  dpkg-scanpackages -m . /dev/null 2>/dev/null | gzip -9c > Packages.gz
}

# ------------------------------------------------------------------------------
# Release-Datei erstellen und signieren
# ------------------------------------------------------------------------------
generate_release() {
  cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"

  log "Erstelle Release-Datei..."

  cat > Release <<RELEASEHEAD
Origin: Custom Build Repository
Label: Custom Build Repository
Suite: stable
Codename: custom
Architectures: arm64
Components: ./
Description: Lokales Repository fuer Custom-Build-Pakete
RELEASEHEAD

  echo "MD5Sum:" >> Release
  for f in Packages.gz $(ls *.deb 2>/dev/null || true); do
    [ -f "$f" ] || continue
    local md5 size
    md5="$(md5sum "$f" | awk '{print $1}')"
    size="$(stat -c '%s' "$f")"
    echo " $(printf '%s' "$md5") $(printf '%16s' "$size") $f" >> Release
  done

  echo "SHA1:" >> Release
  for f in Packages.gz $(ls *.deb 2>/dev/null || true); do
    [ -f "$f" ] || continue
    local sha1 size
    sha1="$(sha1sum "$f" | awk '{print $1}')"
    size="$(stat -c '%s' "$f")"
    echo " $(printf '%s' "$sha1") $(printf '%16s' "$size") $f" >> Release
  done

  echo "SHA256:" >> Release
  for f in Packages.gz $(ls *.deb 2>/dev/null || true); do
    [ -f "$f" ] || continue
    local sha256 size
    sha256="$(sha256sum "$f" | awk '{print $1}')"
    size="$(stat -c '%s' "$f")"
    echo " $(printf '%s' "$sha256") $(printf '%16s' "$size") $f" >> Release
  done

  log "Release-Datei erstellt"
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
# SHA256-Checksummen
# ------------------------------------------------------------------------------
generate_checksums() {
  if [ -d "$REPO_DIR" ] && ls "$REPO_DIR"/*.deb >/dev/null 2>&1; then
    log "Erstelle SHA256SUMS..."
    cd "$REPO_DIR"
    sha256sum *.deb > SHA256SUMS
    log "SHA256SUMS erstellt ($(wc -l < SHA256SUMS) Pakete)"
  fi
}

# ------------------------------------------------------------------------------
# dpkg-sig: Alle .deb-Pakete im Repo signieren
# ------------------------------------------------------------------------------
sign_debs() {
  log "=== Signiere .deb-Pakete mit dpkg-sig ==="

  if ! command -v dpkg-sig >/dev/null 2>&1; then
    log "Installiere dpkg-sig..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-sig
  fi

  if ! detect_gpg_key; then
    die "Kein GPG-Schluessel. Zuerst: $0 init-gpg"
  fi

  local deb_count=0
  local deb_fail=0

  for deb in "$REPO_DIR"/*.deb; do
    [ -f "$deb" ] || continue

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
  done

  log "Signiert: $deb_count, Fehlgeschlagen: $deb_fail"
}

# ------------------------------------------------------------------------------
# Kompletten Repository-Index + Signierung erneuern
# ------------------------------------------------------------------------------
rebuild_repo() {
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

  if [ -f "$GPG_PUBLIC_KEY" ] && detect_gpg_key 2>/dev/null; then
    echo "deb [signed-by=$GPG_PUBLIC_KEY] file:$REPO_DIR ./" > "$list_file"
    log "apt sources list aktualisiert (signed-by=$GPG_PUBLIC_KEY)"
  else
    echo "deb [trusted=yes] file:$REPO_DIR ./" > "$list_file"
    log "apt sources list aktualisiert (trusted=yes – kein GPG-Schluessel)"
  fi
}

# ------------------------------------------------------------------------------
# Befehle
# ------------------------------------------------------------------------------
install_repo() {
  log "=== Starte Installation des lokalen Repositories ==="

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
    touch Packages.gz
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

  log "Kopiere neue Pakete..."
  for pkg_dir in "$DOVECOT_PKG_DIR" "$POSTFIX_PKG_DIR" "$NGINX_PKG_DIR" "$PHP_PKG_DIR"; do
    if [ -d "$pkg_dir" ] && ls "$pkg_dir"/*.deb >/dev/null 2>&1; then
      cp -u "$pkg_dir"/*.deb "$REPO_DIR/" 2>/dev/null || true
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
    if [ -f "$REPO_DIR/Release" ]; then echo "  [OK] Release-Datei vorhanden"; fi
    if [ -f "$REPO_DIR/Release.gpg" ]; then echo "  [OK] Release.gpg (signiert)"; fi
    if [ -f "$REPO_DIR/InRelease" ]; then echo "  [OK] InRelease (clearsign)"; fi
    if [ -f "$REPO_DIR/SHA256SUMS" ]; then echo "  [OK] SHA256SUMS vorhanden"; fi

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
    init-gpg)     init_gpg ;;
    export-key)   export_key ;;
    sign-repo)    generate_release; sign_release ;;
    sign-debs)    sign_debs ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
