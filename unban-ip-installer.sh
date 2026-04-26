#!/usr/bin/env bash
# ==============================================================================
# Unban IP Systemd Service Installer
# ==============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/unban-ip"
SYSTEMD_DIR="/etc/systemd/system"
LOG_DIR="/var/log/unban-ip"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Fehler: Dieses Script benötigt Root-Rechte.${NC}" >&2
    exit 1
  fi
}

log_success() { echo -e "${GREEN}✓ $*${NC}"; }
log_error() { echo -e "${RED}✗ $*${NC}" >&2; }
log_info() { echo -e "${BLUE}ℹ $*${NC}"; }
log_warn() { echo -e "${YELLOW}⚠ $*${NC}"; }

install() {
  log_info "Installiere Unban IP Service..."

  # Erstelle Installationsverzeichnis
  mkdir -p "$INSTALL_DIR" "$LOG_DIR"
  log_success "Verzeichnisse erstellt"

  # Kopiere Script und .env
  cp "$SCRIPT_DIR/unban_ip.sh" "$INSTALL_DIR/"
  chmod 755 "$INSTALL_DIR/unban_ip.sh"

  if [[ ! -f "$INSTALL_DIR/unban_ip.env" ]]; then
    if [[ -f "$SCRIPT_DIR/unban_ip.env" ]]; then
      cp "$SCRIPT_DIR/unban_ip.env" "$INSTALL_DIR/"
    elif [[ -f "$SCRIPT_DIR/unban_ip.env.example" ]]; then
      cp "$SCRIPT_DIR/unban_ip.env.example" "$INSTALL_DIR/unban_ip.env"
      log_warn "unban_ip.env erstellt aus .example - bitte bearbeiten!"
    else
      log_error "unban_ip.env.example nicht gefunden"
      return 1
    fi
  else
    log_info "unban_ip.env existiert bereits - wird nicht überschrieben"
  fi
  chmod 600 "$INSTALL_DIR/unban_ip.env"
  log_success "Script und Konfiguration installiert"

  # Kopiere systemd Service File
  if [[ -f "$SCRIPT_DIR/unban-ip.service" ]]; then
    cp "$SCRIPT_DIR/unban-ip.service" "$SYSTEMD_DIR/"
    chmod 644 "$SYSTEMD_DIR/unban-ip.service"
    log_success "Service-Datei installiert"
  else
    log_error "unban-ip.service nicht in $SCRIPT_DIR gefunden"
    return 1
  fi

  # Kopiere systemd Timer File
  if [[ -f "$SCRIPT_DIR/unban-ip.timer" ]]; then
    cp "$SCRIPT_DIR/unban-ip.timer" "$SYSTEMD_DIR/"
    chmod 644 "$SYSTEMD_DIR/unban-ip.timer"
    log_success "Timer-Datei installiert"
  else
    log_error "unban-ip.timer nicht in $SCRIPT_DIR gefunden"
    return 1
  fi

  # Reload systemd
  systemctl daemon-reload
  log_success "Systemd neu geladen"

  # Enable und starte Timer
  systemctl enable unban-ip.timer
  log_success "Timer aktiviert"

  # Erste Ausführung mit Delay
  log_info "Starte Timer..."
  systemctl start unban-ip.timer

  # Status anzeigen
  echo
  log_success "Installation erfolgreich abgeschlossen!"
  echo
  log_info "Nächste Ausführungen:"
  systemctl list-timers unban-ip.timer
  echo
  log_info "Konfiguration anpassen:"
  echo "  sudo nano $INSTALL_DIR/unban_ip.env"
  echo
  log_info "Status prüfen:"
  echo "  sudo systemctl status unban-ip.timer"
  echo "  sudo journalctl -u unban-ip.service -f"
}

uninstall() {
  log_info "Deinstalliere Unban IP Service..."

  # Stoppe und deaktiviere Timer
  if systemctl is-active --quiet unban-ip.timer; then
    systemctl stop unban-ip.timer
    log_success "Timer gestoppt"
  fi

  if systemctl is-enabled --quiet unban-ip.timer; then
    systemctl disable unban-ip.timer
    log_success "Timer deaktiviert"
  fi

  # Entferne systemd Files
  rm -f "$SYSTEMD_DIR/unban-ip.service" "$SYSTEMD_DIR/unban-ip.timer"
  log_success "Service-Dateien entfernt"

  # Reload systemd
  systemctl daemon-reload
  log_success "Systemd neu geladen"

  # Frage nach Datenlöschung
  if [[ -d "$INSTALL_DIR" ]]; then
    echo
    read -p "Sollen auch die Dateien in $INSTALL_DIR gelöscht werden? (j/N) " -r
    if [[ $REPLY =~ ^[Jj]$ ]]; then
      rm -rf "$INSTALL_DIR"
      log_success "Installation verzeichnis gelöscht"
    else
      log_info "Dateien behalten in $INSTALL_DIR"
    fi
  fi

  echo
  log_success "Deinstallation erfolgreich!"
}

update_interval() {
  local interval="$1"

  if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
    log_error "Interval muss eine Zahl (Minuten) sein"
    return 1
  fi

  if [[ "$interval" -lt 1 ]]; then
    log_error "Interval muss mindestens 1 Minute sein"
    return 1
  fi

  log_info "Aktualisiere Interval auf $interval Minuten..."

  # Stoppe Timer
  systemctl stop unban-ip.timer

  # Update timer file
  sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${interval}min/" "$SYSTEMD_DIR/unban-ip.timer"

  # Reload systemd
  systemctl daemon-reload

  # Starte Timer neu
  systemctl start unban-ip.timer

  log_success "Interval aktualisiert auf $interval Minuten"
  systemctl list-timers unban-ip.timer
}

status() {
  echo -e "${BLUE}=== Unban IP Service Status ===${NC}"
  echo

  if systemctl is-enabled --quiet unban-ip.timer; then
    log_success "Service ist installiert und aktiviert"
  else
    log_warn "Service ist nicht aktiviert"
  fi
  echo

  systemctl status unban-ip.timer || true
  echo

  log_info "Nächste Ausführung:"
  systemctl list-timers unban-ip.timer
  echo

  log_info "Letzte Protokolleinträge:"
  journalctl -u unban-ip.service --no-pager -n 5
}

usage() {
  cat <<EOF
Verwendung:
  sudo $0 [COMMAND]

Kommandos:
  install              Installation durchführen
  uninstall            Service entfernen
  status               Service-Status anzeigen
  update <MINUTEN>     Interval aktualisieren (Standard: 30)

Beispiele:
  sudo $0 install                # Standard 30 Minuten
  sudo $0 status
  sudo $0 update 60              # Alle 60 Minuten
  sudo $0 uninstall
EOF
}

main() {
  require_root

  local cmd="${1:-install}"

  case "$cmd" in
    install)
      install
      ;;
    uninstall)
      uninstall
      ;;
    status)
      status
      ;;
    update)
      if [[ -z "${2:-}" ]]; then
        log_error "update benötigt ein Interval in Minuten"
        usage
        exit 1
      fi
      update_interval "$2"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      log_error "Unbekanntes Kommando: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
