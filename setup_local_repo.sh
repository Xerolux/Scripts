#!/usr/bin/env bash
# ==============================================================================
# setup_local_repo.sh - Lokales apt-Repository für Mailserver-Pakete
#
# Zielumgebung : Ubuntu 24.04 ARM64
# ==============================================================================
set -Eeuo pipefail

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/setup_local_repo.env" ]]; then
  echo "FEHLER: setup_local_repo.env nicht gefunden. Bitte in $SCRIPT_DIR aus setup_local_repo.env.example erstellen." >&2
  exit 1
fi
source "$SCRIPT_DIR/setup_local_repo.env"

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
die() { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausführen."
}

check_os_arch() {
  local os_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
  local os_version_id=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
  local os_major_version=$(echo "$os_version_id" | cut -d. -f1)
  local arch=$(dpkg --print-architecture)

  if [ "$os_id" != "ubuntu" ] || [ -z "$os_major_version" ] || [ "$os_major_version" -lt 24 ] || [ "$arch" != "arm64" ]; then
    echo "FEHLER: Dieses Skript unterstützt nur Ubuntu 24.04 (oder neuer) auf arm64." >&2
    exit 1
  fi
}

usage() {
  cat <<'USAGE'
Verwendung:
  setup_local_repo.sh install   – Erstellt das Repo, trägt es in apt ein und kopiert Pakete
  setup_local_repo.sh update    – Kopiert neue Pakete ins Repo und aktualisiert den Index
  setup_local_repo.sh uninstall – Entfernt das Repo aus apt und löscht die Dateien
  setup_local_repo.sh status    – Zeigt den Status des Repositories an
USAGE
}

install_repo() {
  log "=== Starte Installation des lokalen Repositories ==="

  if [ ! -d "$REPO_DIR" ]; then
    log "Erstelle Repository-Verzeichnis: $REPO_DIR"
    mkdir -p "$REPO_DIR"
  fi

  log "Installiere dpkg-dev (falls nicht vorhanden)..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-dev

  log "Kopiere vorhandene Pakete in das Repository..."
  local packages_copied=0
  if [ -d "$DOVECOT_PKG_DIR" ] && ls "$DOVECOT_PKG_DIR"/*.deb >/dev/null 2>&1; then
    cp -a "$DOVECOT_PKG_DIR"/*.deb "$REPO_DIR/"
    packages_copied=1
  fi
  if [ -d "$POSTFIX_PKG_DIR" ] && ls "$POSTFIX_PKG_DIR"/*.deb >/dev/null 2>&1; then
    cp -a "$POSTFIX_PKG_DIR"/*.deb "$REPO_DIR/"
    packages_copied=1
  fi

  if [ "$packages_copied" -eq 1 ]; then
    log "Erstelle/Aktualisiere Packages-Index..."
    cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"
    dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
  else
    log "Keine .deb Pakete zum Kopieren gefunden, erstelle leeres Repository."
    cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"
    touch Packages.gz
  fi

  local list_file="/etc/apt/sources.list.d/local-mail-repo.list"
  log "Trage Repository in apt ein ($list_file)..."
  echo "deb [trusted=yes] file:$REPO_DIR ./" > "$list_file"

  log "Aktualisiere apt Cache..."
  apt-get update -qq

  log "=== Installation abgeschlossen ==="
}

update_repo() {
  log "=== Aktualisiere lokales Repository ==="

  if [ ! -d "$REPO_DIR" ]; then
    log "Repository-Verzeichnis $REPO_DIR existiert nicht. Bitte zuerst 'install' ausführen."
    exit 1
  fi

  log "Kopiere neue Pakete..."
  if [ -d "$DOVECOT_PKG_DIR" ] && ls "$DOVECOT_PKG_DIR"/*.deb >/dev/null 2>&1; then
    cp -u "$DOVECOT_PKG_DIR"/*.deb "$REPO_DIR/" 2>/dev/null || true
  fi
  if [ -d "$POSTFIX_PKG_DIR" ] && ls "$POSTFIX_PKG_DIR"/*.deb >/dev/null 2>&1; then
    cp -u "$POSTFIX_PKG_DIR"/*.deb "$REPO_DIR/" 2>/dev/null || true
  fi

  log "Erstelle Packages-Index neu..."
  cd "$REPO_DIR" || die "Konnte nicht in $REPO_DIR wechseln"
  dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

  log "Aktualisiere apt Cache..."
  apt-get update -qq

  log "=== Aktualisierung abgeschlossen ==="
}

uninstall_repo() {
  log "=== Deinstalliere lokales Repository ==="
  local list_file="/etc/apt/sources.list.d/local-mail-repo.list"

  if [ -f "$list_file" ]; then
    log "Entferne apt sources list: $list_file"
    rm -f "$list_file"
  else
    log "apt sources list $list_file nicht gefunden."
  fi

  if [ -d "$REPO_DIR" ]; then
    log "Entferne Repository-Verzeichnis: $REPO_DIR"
    rm -rf "$REPO_DIR"
  else
    log "Repository-Verzeichnis $REPO_DIR nicht gefunden."
  fi

  log "Aktualisiere apt Cache..."
  apt-get update -qq || true

  log "=== Deinstallation abgeschlossen ==="
}

status_repo() {
  echo "=============================================="
  echo " Lokales Repository Status – $(date)"
  echo "=============================================="

  local list_file="/etc/apt/sources.list.d/local-mail-repo.list"
  if [ -f "$list_file" ]; then
    echo "  [OK] apt sources list existiert: $list_file"
    cat "$list_file" | sed 's/^/       /'
  else
    echo "  [--] apt sources list nicht gefunden ($list_file)"
  fi

  echo ""
  if [ -d "$REPO_DIR" ]; then
    echo "  [OK] Repository-Verzeichnis existiert: $REPO_DIR"
    echo "       Pakete im Repository:"
    ls -lh "$REPO_DIR"/*.deb 2>/dev/null | awk '{print "       - "$9}' || echo "       (keine Pakete)"
  else
    echo "  [--] Repository-Verzeichnis nicht gefunden ($REPO_DIR)"
  fi
  echo "=============================================="
}

main() {
  check_os_arch
  require_root
  touch "$LOG_FILE" || die "Kann Log-Datei nicht erstellen: $LOG_FILE"

  case "${1:-help}" in
    install)   install_repo ;;
    update)    update_repo ;;
    uninstall) uninstall_repo ;;
    status)    status_repo ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"