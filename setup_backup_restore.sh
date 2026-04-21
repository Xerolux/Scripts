#!/usr/bin/env bash
# ==============================================================================
# setup_backup_restore.sh – Umfassendes Backup/Restore fuer alle Custom-Builds
#
# Sichert:
#   - Alle Configs (postfix, dovecot, nginx, ISPConfig)
#   - Alle Custom-.deb-Pakete
#   - Alle aktuell installierten Ubuntu-Pakete (dpkg --get-selections)
#   - Apt-Cache der installierten Pakete (fuer Offline-Restore)
#   - SSL-Zertifikate, Cronjobs, Systemd-Units
#
# Restore:
#   - Komplett-Restore oder einzelne Dienste
#   - Pakete aus lokalem Cache oder Custom-Repo installieren
#
# Zielumgebung : Ubuntu 24.04 ARM64
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/setup_backup_restore.env" ]]; then
  echo "FEHLER: setup_backup_restore.env nicht gefunden. Bitte aus .example erstellen." >&2
  exit 1
fi
source "$SCRIPT_DIR/setup_backup_restore.env"

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
die()  { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausfuehren."
}

usage() {
  cat <<'EOF'
Verwendung:
  setup_backup_restore.sh backup                    – Vollbackup aller Dienste
  setup_backup_restore.sh backup-postfix            – Nur Postfix sichern
  setup_backup_restore.sh backup-dovecot            – Nur Dovecot sichern
  setup_backup_restore.sh backup-nginx              – Nur Nginx sichern
  setup_backup_restore.sh restore                   – Voll-restore (letztes Backup)
  setup_backup_restore.sh restore <backup-dir>      – Restore aus spezifischem Backup
  setup_backup_restore.sh restore-postfix [dir]     – Nur Postfix wiederherstellen
  setup_backup_restore.sh restore-dovecot [dir]     – Nur Dovecot wiederherstellen
  setup_backup_restore.sh restore-nginx [dir]       – Nur Nginx wiederherstellen
  setup_backup_restore.sh list                      – Verfuegbare Backups auflisten
  setup_backup_restore.sh verify <backup-dir>       – Backup-Integritaet pruefen
EOF
}

# ------------------------------------------------------------------------------
# Service Stop/Start
# ------------------------------------------------------------------------------
stop_services() {
  log "Stoppe Dienste..."
  systemctl stop postfix  2>/dev/null || true
  systemctl stop dovecot  2>/dev/null || true
  systemctl stop nginx    2>/dev/null || true
}

start_services() {
  log "Starte Dienste..."
  systemctl start postfix  2>/dev/null || true
  systemctl start dovecot  2>/dev/null || true
  systemctl start nginx    2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Einzelne Backup-Funktionen
# ------------------------------------------------------------------------------
backup_postfix() {
  local dest="$1"
  log "  Sichere Postfix..."
  mkdir -p "$dest/postfix"

  [ -d /etc/postfix ]                       && cp -a /etc/postfix                       "$dest/postfix/etc_postfix"
  [ -d /usr/lib/postfix ]                   && cp -a /usr/lib/postfix                   "$dest/postfix/usr_lib_postfix"
  [ -f /lib/systemd/system/postfix.service ] && cp -a /lib/systemd/system/postfix.service "$dest/postfix/postfix.service"
  [ -f /etc/aliases ]                       && cp -a /etc/aliases                       "$dest/postfix/etc_aliases"

  if command -v postconf >/dev/null 2>&1; then
    postconf          > "$dest/postfix/postconf.txt"     2>&1 || true
    postconf -m       > "$dest/postfix/postconf-maps.txt" 2>&1 || true
    postfix version   > "$dest/postfix/version.txt"      2>&1 || true
  fi
  dpkg -l 2>/dev/null | awk '/^ii/ && /postfix/ {print $2, $3}' > "$dest/postfix/packages.txt" || true
}

backup_dovecot() {
  local dest="$1"
  log "  Sichere Dovecot..."
  mkdir -p "$dest/dovecot"

  [ -d /etc/dovecot ]                        && cp -a /etc/dovecot                        "$dest/dovecot/etc_dovecot"
  [ -d /usr/lib/dovecot ]                    && cp -a /usr/lib/dovecot                    "$dest/dovecot/usr_lib_dovecot"
  [ -f /lib/systemd/system/dovecot.service ] && cp -a /lib/systemd/system/dovecot.service "$dest/dovecot/dovecot.service"
  [ -f /lib/systemd/system/dovecot.socket ]  && cp -a /lib/systemd/system/dovecot.socket  "$dest/dovecot/dovecot.socket"
  [ -f /etc/default/dovecot ]                && cp -a /etc/default/dovecot                "$dest/dovecot/etc_default_dovecot"

  if command -v dovecot >/dev/null 2>&1; then
    dovecot --version > "$dest/dovecot/version.txt" 2>&1 || true
    dovecot -n        > "$dest/dovecot/dovecot-n.txt" 2>&1 || true
  fi
  dpkg -l 2>/dev/null | awk '/^ii/ && /dovecot/ {print $2, $3}' > "$dest/dovecot/packages.txt" || true
}

backup_nginx() {
  local dest="$1"
  log "  Sichere Nginx..."
  mkdir -p "$dest/nginx"

  [ -d /etc/nginx ]                        && cp -a /etc/nginx                        "$dest/nginx/etc_nginx"
  [ -d /usr/lib/nginx ]                    && cp -a /usr/lib/nginx                    "$dest/nginx/usr_lib_nginx"
  [ -f /lib/systemd/system/nginx.service ] && cp -a /lib/systemd/system/nginx.service "$dest/nginx/nginx.service"

  if command -v nginx >/dev/null 2>&1; then
    nginx -v > "$dest/nginx/version.txt"    2>&1 || true
    nginx -V > "$dest/nginx/compile.txt"    2>&1 || true
    nginx -T > "$dest/nginx/full-config.txt" 2>&1 || true
  fi
  dpkg -l 2>/dev/null | awk '/^ii/ && /nginx/ {print $2, $3}' > "$dest/nginx/packages.txt" || true
}

backup_system() {
  local dest="$1"
  log "  Sichere System-Daten..."
  mkdir -p "$dest/system"

  dpkg --get-selections > "$dest/system/dpkg-selections.txt" 2>/dev/null || true
  apt-mark showhold     > "$dest/system/apt-hold.txt"        2>/dev/null || true

  [ -f /etc/resolv.conf ]       && cp -a /etc/resolv.conf       "$dest/system/resolv.conf"
  [ -f /etc/hosts ]             && cp -a /etc/hosts             "$dest/system/hosts"
  [ -f /etc/hostname ]          && cp -a /etc/hostname          "$dest/system/hostname"
  [ -f /etc/mailname ]          && cp -a /etc/mailname          "$dest/system/mailname"

  if [ -d /etc/ssl ]; then cp -a /etc/ssl "$dest/system/etc_ssl" 2>/dev/null || true; fi

  if [ -d /etc/letsencrypt ]; then
    log "  Sichere Let's Encrypt..."
    cp -a /etc/letsencrypt "$dest/system/letsencrypt" 2>/dev/null || true
  fi

  if [ -d /etc/logrotate.d ]; then cp -a /etc/logrotate.d "$dest/system/logrotate.d" 2>/dev/null || true; fi

  crontab -l > "$dest/system/crontab-root.txt" 2>/dev/null || true

  if [ -d /usr/local/ispconfig ]; then
    log "  Sichere ISPConfig..."
    mkdir -p "$dest/system/ispconfig"
    cp -a /usr/local/ispconfig "$dest/system/ispconfig/" 2>/dev/null || true
    if [ -f /etc/ispconfig_db_encrypt.key ]; then cp -a /etc/ispconfig_db_encrypt.key "$dest/system/ispconfig/" 2>/dev/null || true; fi
  fi
}

backup_deb_cache() {
  local dest="$1"
  log "  Cache installierter .deb-Pakete..."
  mkdir -p "$dest/apt-cache"

  local pkg_list="$dest/system/dpkg-selections.txt"
  if [ -f "$pkg_list" ]; then
    while IFS=$'\t' read -r pkg state; do
      if [ "$state" = "install" ] && [ -n "$pkg" ]; then
        local cached
        cached="$(find /var/cache/apt/archives/ -name "${pkg}_*.deb" 2>/dev/null | head -1)"
        if [ -n "$cached" ] && [ -f "$cached" ]; then
          cp -a "$cached" "$dest/apt-cache/" 2>/dev/null || true
        fi
      fi
    done < "$pkg_list"
  fi

  for pkg_dir in "$POSTFIX_PKG_DIR" "$DOVECOT_PKG_DIR" "$NGINX_PKG_DIR"; do
    if [ -d "$pkg_dir" ] && ls "$pkg_dir"/*.deb >/dev/null 2>&1; then
      cp -a "$pkg_dir"/*.deb "$dest/apt-cache/" 2>/dev/null || true
    fi
  done

  local deb_count
  deb_count=$(find "$dest/apt-cache" -name "*.deb" 2>/dev/null | wc -l)
  log "  $deb_count .deb-Pakete im Cache"
}

# ------------------------------------------------------------------------------
# Voll-Backup
# ------------------------------------------------------------------------------
do_full_backup() {
  local ts backup_dir
  ts="$(date '+%F_%H%M%S')"
  backup_dir="$BACKUP_ROOT/$ts"
  mkdir -p "$backup_dir"

  log "===== Voll-Backup nach $backup_dir ====="

  stop_services

  backup_postfix  "$backup_dir"
  backup_dovecot  "$backup_dir"
  backup_nginx    "$backup_dir"
  backup_system   "$backup_dir"
  backup_deb_cache "$backup_dir"

  ln -sfn "$backup_dir" "$LATEST_LINK"

  start_services

  local size
  size="$(du -sh "$backup_dir" 2>/dev/null | cut -f1)"
  log "===== Backup fertig: $backup_dir ($size) ====="
  log "Restore: $0 restore $backup_dir"
}

do_single_backup() {
  local what="$1"
  local ts backup_dir
  ts="$(date '+%F_%H%M%S')"
  backup_dir="$BACKUP_ROOT/${ts}_${what}"
  mkdir -p "$backup_dir"

  log "===== Backup $what nach $backup_dir ====="

  case "$what" in
    postfix) systemctl stop postfix  2>/dev/null || true; backup_postfix "$backup_dir"; systemctl start postfix 2>/dev/null || true ;;
    dovecot) systemctl stop dovecot  2>/dev/null || true; backup_dovecot "$backup_dir"; systemctl start dovecot 2>/dev/null || true ;;
    nginx)   systemctl stop nginx    2>/dev/null || true; backup_nginx   "$backup_dir"; systemctl start nginx   2>/dev/null || true ;;
    *) die "Unbekannter Dienst: $what" ;;
  esac

  ln -sfn "$backup_dir" "$LATEST_LINK"
  log "===== Backup $what fertig: $backup_dir ====="
}

# ------------------------------------------------------------------------------
# Einzelne Restore-Funktionen
# ------------------------------------------------------------------------------
restore_postfix() {
  local src="$1"
  [ -d "$src/postfix" ] || die "Kein Postfix-Backup in $src gefunden"

  log "  Stelle Postfix wieder her..."
  [ -d "$src/postfix/etc_postfix" ]     && cp -a "$src/postfix/etc_postfix"     /etc/postfix
  [ -d "$src/postfix/usr_lib_postfix" ] && cp -a "$src/postfix/usr_lib_postfix" /usr/lib/postfix
  [ -f "$src/postfix/postfix.service" ] && cp -a "$src/postfix/postfix.service" /lib/systemd/system/postfix.service
  [ -f "$src/postfix/etc_aliases" ]     && cp -a "$src/postfix/etc_aliases"     /etc/aliases

  if command -v newaliases >/dev/null 2>&1; then newaliases 2>/dev/null || true; fi
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
  log "  Postfix wiederhergestellt"
}

restore_dovecot() {
  local src="$1"
  [ -d "$src/dovecot" ] || die "Kein Dovecot-Backup in $src gefunden"

  log "  Stelle Dovecot wieder her..."
  [ -d "$src/dovecot/etc_dovecot" ]           && cp -a "$src/dovecot/etc_dovecot"           /etc/dovecot
  [ -d "$src/dovecot/usr_lib_dovecot" ]       && cp -a "$src/dovecot/usr_lib_dovecot"       /usr/lib/dovecot
  [ -f "$src/dovecot/dovecot.service" ]       && cp -a "$src/dovecot/dovecot.service"       /lib/systemd/system/dovecot.service
  [ -f "$src/dovecot/dovecot.socket" ]        && cp -a "$src/dovecot/dovecot.socket"        /lib/systemd/system/dovecot.socket
  [ -f "$src/dovecot/etc_default_dovecot" ]   && cp -a "$src/dovecot/etc_default_dovecot"   /etc/default/dovecot

  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
  log "  Dovecot wiederhergestellt"
}

restore_nginx() {
  local src="$1"
  [ -d "$src/nginx" ] || die "Kein Nginx-Backup in $src gefunden"

  log "  Stelle Nginx wieder her..."
  [ -d "$src/nginx/etc_nginx" ]         && cp -a "$src/nginx/etc_nginx"         /etc/nginx
  [ -d "$src/nginx/usr_lib_nginx" ]     && cp -a "$src/nginx/usr_lib_nginx"     /usr/lib/nginx
  [ -f "$src/nginx/nginx.service" ]     && cp -a "$src/nginx/nginx.service"     /lib/systemd/system/nginx.service

  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
  if command -v nginx >/dev/null 2>&1; then nginx -t 2>/dev/null || log "  WARNUNG: nginx -t fehlgeschlagen"; fi
  log "  Nginx wiederhergestellt"
}

restore_system() {
  local src="$1"
  [ -d "$src/system" ] || return 0

  log "  Stelle System-Daten wieder her..."
  [ -f "$src/system/resolv.conf" ]  && cp -a "$src/system/resolv.conf"  /etc/resolv.conf
  [ -f "$src/system/hosts" ]        && cp -a "$src/system/hosts"        /etc/hosts
  [ -f "$src/system/hostname" ]     && cp -a "$src/system/hostname"     /etc/hostname
  [ -f "$src/system/mailname" ]     && cp -a "$src/system/mailname"     /etc/mailname

  if [ -d "$src/system/etc_ssl" ]; then
    cp -a "$src/system/etc_ssl" /etc/ssl 2>/dev/null || true
  fi

  if [ -d "$src/system/letsencrypt" ]; then
    cp -a "$src/system/letsencrypt" /etc/letsencrypt 2>/dev/null || true
  fi

  if [ -d "$src/system/logrotate.d" ]; then
    cp -a "$src/system/logrotate.d/"* /etc/logrotate.d/ 2>/dev/null || true
  fi

  if [ -f "$src/system/crontab-root.txt" ] && [ -s "$src/system/crontab-root.txt" ]; then
    crontab "$src/system/crontab-root.txt" 2>/dev/null || true
  fi

  if [ -d "$src/system/ispconfig" ]; then
    if [ -d "$src/system/ispconfig/ispconfig" ]; then cp -a "$src/system/ispconfig/ispconfig" /usr/local/ 2>/dev/null || true; fi
    if [ -f "$src/system/ispconfig/ispconfig_db_encrypt.key" ]; then cp -a "$src/system/ispconfig/ispconfig_db_encrypt.key" /etc/ 2>/dev/null || true; fi
  fi

  if [ -f "$src/system/apt-hold.txt" ] && [ -s "$src/system/apt-hold.txt" ]; then
    xargs -a "$src/system/apt-hold.txt" apt-mark hold 2>/dev/null || true
  fi

  log "  System-Daten wiederhergestellt"
}

restore_deb_cache() {
  local src="$1"
  [ -d "$src/apt-cache" ] || return 0

  local deb_count
  deb_count=$(find "$src/apt-cache" -name "*.deb" 2>/dev/null | wc -l)
  log "  Installiere $deb_count Pakete aus Cache..."

  if [ "$deb_count" -gt 0 ]; then
    dpkg -i "$src/apt-cache/"*.deb 2>/dev/null || true
  fi
}

# ------------------------------------------------------------------------------
# Voll-Restore
# ------------------------------------------------------------------------------
resolve_backup_dir() {
  local input="${1:-}"
  if [ -n "$input" ]; then
    echo "$input"
  elif [ -L "$LATEST_LINK" ]; then
    readlink -f "$LATEST_LINK"
  else
    die "Kein Backup-Verzeichnis angegeben und kein 'latest' Link gefunden"
  fi
}

do_full_restore() {
  local backup_dir
  backup_dir="$(resolve_backup_dir "${1:-}")"

  [ -d "$backup_dir" ] || die "Backup-Verzeichnis nicht gefunden: $backup_dir"

  log "===== Voll-Restore von $backup_dir ====="

  stop_services

  restore_deb_cache "$backup_dir"
  restore_postfix   "$backup_dir"
  restore_dovecot   "$backup_dir"
  restore_nginx     "$backup_dir"
  restore_system    "$backup_dir"

  start_services

  log "===== Restore fertig ====="
}

do_single_restore() {
  local what="$1"
  local backup_dir
  backup_dir="$(resolve_backup_dir "${2:-}")"

  [ -d "$backup_dir" ] || die "Backup-Verzeichnis nicht gefunden: $backup_dir"

  log "===== Restore $what von $backup_dir ====="

  case "$what" in
    postfix) systemctl stop postfix  2>/dev/null || true; restore_postfix "$backup_dir"; systemctl start postfix  2>/dev/null || true ;;
    dovecot) systemctl stop dovecot  2>/dev/null || true; restore_dovecot "$backup_dir"; systemctl start dovecot  2>/dev/null || true ;;
    nginx)   systemctl stop nginx    2>/dev/null || true; restore_nginx   "$backup_dir"; systemctl start nginx   2>/dev/null || true ;;
    *) die "Unbekannter Dienst: $what" ;;
  esac

  log "===== Restore $what fertig ====="
}

# ------------------------------------------------------------------------------
# List / Verify
# ------------------------------------------------------------------------------
list_backups() {
  echo "=============================================="
  echo " Verfuegbare Backups – $BACKUP_ROOT"
  echo "=============================================="

  if [ ! -d "$BACKUP_ROOT" ] || [ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]; then
    echo "  Keine Backups vorhanden."
    return 0
  fi

  for d in "$BACKUP_ROOT"/*/; do
    [ -d "$d" ] || continue
    local name size
    name="$(basename "$d")"
    size="$(du -sh "$d" 2>/dev/null | cut -f1)"

    local contents=""
    [ -d "$d/postfix" ]  && contents="${contents}postfix "
    [ -d "$d/dovecot" ]  && contents="${contents}dovecot "
    [ -d "$d/nginx" ]    && contents="${contents}nginx "
    [ -d "$d/system" ]   && contents="${contents}system "
    [ -d "$d/apt-cache" ] && contents="${contents}apt-cache"

    local deb_count=0
    [ -d "$d/apt-cache" ] && deb_count=$(find "$d/apt-cache" -name "*.deb" 2>/dev/null | wc -l)

    printf "  %-22s  %5s  [%s]  %d debs\n" "$name" "$size" "$contents" "$deb_count"
  done

  echo ""
  if [ -L "$LATEST_LINK" ]; then
    echo "  latest -> $(readlink "$LATEST_LINK")"
  fi
  echo "=============================================="
}

verify_backup() {
  local backup_dir="${1:-}"
  [ -z "$backup_dir" ] && die "Bitte Backup-Verzeichnis angeben"
  [ -d "$backup_dir" ] || die "Backup-Verzeichnis nicht gefunden: $backup_dir"

  local errors=0

  echo "Pruefe Backup: $backup_dir"
  echo "-------------------------------------------"

  for svc in postfix dovecot nginx; do
    if [ -d "$backup_dir/$svc" ]; then
      local files
      files=$(find "$backup_dir/$svc" -type f 2>/dev/null | wc -l)
      printf "  %-12s  %d Dateien  " "$svc" "$files"
      if [ "$files" -gt 0 ]; then
        echo "[OK]"
      else
        echo "[LEER]"
        ((errors++))
      fi
    else
      printf "  %-12s  -- nicht vorhanden\n" "$svc"
    fi
  done

  if [ -d "$backup_dir/system" ]; then
    local sys_files
    sys_files=$(find "$backup_dir/system" -type f 2>/dev/null | wc -l)
    printf "  %-12s  %d Dateien  [OK]\n" "system" "$sys_files"
  fi

  if [ -d "$backup_dir/apt-cache" ]; then
    local deb_count
    deb_count=$(find "$backup_dir/apt-cache" -name "*.deb" 2>/dev/null | wc -l)
    printf "  %-12s  %d .deb-Pakete  " "apt-cache" "$deb_count"
    if [ "$deb_count" -gt 0 ]; then
      echo "[OK]"
    else
      echo "[LEER]"
    fi
  fi

  echo "-------------------------------------------"
  if [ "$errors" -eq 0 ]; then
    echo "Backup sieht gut aus."
  else
    echo "WARNUNG: $errors Probleme gefunden."
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  require_root
  mkdir -p "$BACKUP_ROOT"
  touch "$LOG_FILE" || die "Kann Log-Datei nicht erstellen: $LOG_FILE"

  case "${1:-help}" in
    backup)           do_full_backup ;;
    backup-postfix)   do_single_backup postfix ;;
    backup-dovecot)   do_single_backup dovecot ;;
    backup-nginx)     do_single_backup nginx ;;
    restore)          do_full_restore "${2:-}" ;;
    restore-postfix)  do_single_restore postfix "${2:-}" ;;
    restore-dovecot)  do_single_restore dovecot "${2:-}" ;;
    restore-nginx)    do_single_restore nginx "${2:-}" ;;
    list)             list_backups ;;
    verify)           verify_backup "${2:-}" ;;
    help|-h|--help)   usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
