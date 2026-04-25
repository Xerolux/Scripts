#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BACKTITLE="Server Setup & Management"

SCRIPT_FILES=(
  setup_dovecot.sh
  setup_postfix.sh
  setup_php.sh
  setup_nginx.sh
  setup-zpush.sh
  setup_local_repo.sh
  setup_backup_restore.sh
  unban_ip.sh
  f2b_test.sh
)

require_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail fehlt. Bitte installieren: sudo apt-get install -y whiptail" >&2
    exit 1
  fi
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    fi
    whiptail --title "Root erforderlich" --msgbox "Dieses Menue benoetigt root (sudo nicht gefunden)." 10 60
    exit 1
  fi
}

ensure_executable_scripts() {
  local f
  for f in "${SCRIPT_FILES[@]}"; do
    [ -f "$SCRIPT_DIR/$f" ] || continue
    chmod 755 "$SCRIPT_DIR/$f" 2>/dev/null || chmod +x "$SCRIPT_DIR/$f" 2>/dev/null || true
  done
}

ensure_env_files() {
  local ex
  for ex in "$SCRIPT_DIR"/*.env.example; do
    [ -f "$ex" ] || continue
    local target="${ex%.example}"
    if [ ! -f "$target" ]; then
      cp -n "$ex" "$target" 2>/dev/null || true
    fi
  done
}

msg_error() {
  whiptail --title "Fehler" --msgbox "$1" 10 70
}

pause_done() {
  local rc="$1"
  echo
  echo "Fertig (Exit-Code: $rc)"
  read -r -p "Enter fuer Menue..." _
}

run_action() {
  local script="$1"
  shift

  local path="$SCRIPT_DIR/$script"
  if [ ! -f "$path" ]; then
    msg_error "Script nicht gefunden: $path"
    return 1
  fi

  chmod 755 "$path" 2>/dev/null || chmod +x "$path" 2>/dev/null || true

  clear
  echo "============================================================"
  echo "Starte: $script $*"
  echo "============================================================"
  echo

  bash "$path" "$@"
  local rc=$?

  pause_done "$rc"
  return "$rc"
}

ask_yes_no() {
  local title="$1"
  local text="$2"
  if whiptail --title "$title" --yesno "$text" 10 70; then
    return 0
  fi
  return 1
}

input_box() {
  local title="$1"
  local text="$2"
  local init="${3:-}"
  whiptail --title "$title" --inputbox "$text" 12 80 "$init" 3>&1 1>&2 2>&3
}

run_with_optional_screen_cmd() {
  local script="$1"
  shift
  local -a args=( "$@" )

  if ask_yes_no "Screen" "In GNU Screen Session starten (--screen)?"; then
    run_action "$script" --screen "${args[@]}"
  else
    run_action "$script" "${args[@]}"
  fi
}

run_custom_args() {
  local script="$1"
  local args_text
  local -a args=()

  args_text="$(input_box "Custom Args" "Argumente fuer ${script} eingeben (wie in der Konsole):" "")" || return 0
  if [ -z "${args_text// }" ]; then
    msg_error "Keine Argumente eingegeben."
    return 0
  fi

  read -r -a args <<< "$args_text"
  run_action "$script" "${args[@]}"
}

menu_setup_dovecot() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "setup_dovecot.sh" --menu "Befehl waehlen" 22 90 14 \
      package "Core + Pigeonhole + Pakete bauen" \
      package-dovecot "Nur dovecot-core Paket bauen" \
      package-pigeonhole "Nur pigeonhole Paket bauen" \
      install "Backup + Pakete installieren" \
      build-only "Nur kompilieren" \
      backup "Nur Backup erstellen" \
      restore "Restore (optional mit Pfad)" \
      status "Status anzeigen" \
      list-backups "Backups auflisten" \
      list-packages "Pakete auflisten" \
      check-updates "Nach Updates suchen" \
      check-config "dovecot -n" \
      uninstall "Custom Pakete entfernen" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      package|package-dovecot|package-pigeonhole|install|build-only|backup|status|list-backups|list-packages|check-updates|check-config|uninstall)
        run_with_optional_screen_cmd "setup_dovecot.sh" "$choice"
        ;;
      restore)
        local restore_path
        restore_path="$(input_box "Restore" "Optional Backup-Pfad (leer = latest):" "")" || continue
        if [ -n "${restore_path// }" ]; then
          run_with_optional_screen_cmd "setup_dovecot.sh" restore "$restore_path"
        else
          run_with_optional_screen_cmd "setup_dovecot.sh" restore
        fi
        ;;
      custom)
        run_custom_args "setup_dovecot.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_setup_postfix() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "setup_postfix.sh" --menu "Befehl waehlen" 20 80 12 \
      package "Pakete bauen" \
      install "Backup + installieren" \
      backup "Backup erstellen" \
      restore "Restore (optional mit Pfad)" \
      status "Status anzeigen" \
      list-backups "Backups auflisten" \
      check-updates "Nach Updates suchen" \
      check-config "postfix check" \
      uninstall "Custom Pakete entfernen" \
      verify "Modul-Verifikation" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      package|install|backup|status|list-backups|check-updates|check-config|uninstall|verify)
        run_with_optional_screen_cmd "setup_postfix.sh" "$choice"
        ;;
      restore)
        local restore_path
        restore_path="$(input_box "Restore" "Optional Backup-Pfad (leer = latest):" "")" || continue
        if [ -n "${restore_path// }" ]; then
          run_action "setup_postfix.sh" restore "$restore_path"
        else
          run_with_optional_screen_cmd "setup_postfix.sh" restore
        fi
        ;;
      custom)
        run_custom_args "setup_postfix.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_setup_php() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "setup_php.sh" --menu "Befehl waehlen" 20 85 12 \
      package "Pakete bauen" \
      install "Backup + installieren" \
      backup "Backup erstellen" \
      restore "Restore (optional mit Pfad)" \
      status "Status anzeigen" \
      list-backups "Backups auflisten" \
      list-extensions "Verfuegbare PECL Extensions" \
      check-config "PHP/FPM Check" \
      uninstall "Custom Pakete entfernen" \
      verify "Verifikation" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      package|install|backup|status|list-backups|list-extensions|check-config|uninstall|verify)
        run_with_optional_screen_cmd "setup_php.sh" "$choice"
        ;;
      restore)
        local restore_path
        restore_path="$(input_box "Restore" "Optional Backup-Pfad (leer = latest):" "")" || continue
        if [ -n "${restore_path// }" ]; then
          run_action "setup_php.sh" restore "$restore_path"
        else
          run_with_optional_screen_cmd "setup_php.sh" restore
        fi
        ;;
      custom)
        run_custom_args "setup_php.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_setup_nginx() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "setup_nginx.sh" --menu "Befehl waehlen" 20 85 12 \
      package "Pakete bauen" \
      install "Backup + installieren" \
      backup "Backup erstellen" \
      restore "Restore (optional mit Pfad)" \
      status "Status anzeigen" \
      list-backups "Backups auflisten" \
      list-modules "Verfuegbare Module" \
      check-updates "Nach Updates suchen" \
      check-config "nginx -t" \
      uninstall "Custom Pakete entfernen" \
      verify "Verifikation" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      package|install|backup|status|list-backups|list-modules|check-updates|check-config|uninstall|verify)
        run_with_optional_screen_cmd "setup_nginx.sh" "$choice"
        ;;
      restore)
        local restore_path
        restore_path="$(input_box "Restore" "Optional Backup-Pfad (leer = latest):" "")" || continue
        if [ -n "${restore_path// }" ]; then
          run_action "setup_nginx.sh" restore "$restore_path"
        else
          run_with_optional_screen_cmd "setup_nginx.sh" restore
        fi
        ;;
      custom)
        run_custom_args "setup_nginx.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_setup_local_repo() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "setup_local_repo.sh" --menu "Befehl waehlen" 20 85 12 \
      install "Repo einrichten" \
      update "Repo aktualisieren" \
      uninstall "Repo entfernen" \
      status "Repo Status" \
      init-gpg "GPG Schluessel erzeugen" \
      export-key "Public Key exportieren" \
      sign-repo "Release/InRelease signieren" \
      sign-debs "Alle DEBs signieren" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      install|update|uninstall|status|init-gpg|export-key|sign-repo|sign-debs)
        run_action "setup_local_repo.sh" "$choice"
        ;;
      custom)
        run_custom_args "setup_local_repo.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_setup_backup_restore() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "setup_backup_restore.sh" --menu "Befehl waehlen" 22 90 14 \
      backup "Full Backup" \
      backup-postfix "Nur Postfix Backup" \
      backup-dovecot "Nur Dovecot Backup" \
      backup-nginx "Nur Nginx Backup" \
      restore "Full Restore (optional Pfad)" \
      restore-postfix "Nur Postfix Restore (optional Pfad)" \
      restore-dovecot "Nur Dovecot Restore (optional Pfad)" \
      restore-nginx "Nur Nginx Restore (optional Pfad)" \
      list "Backups auflisten" \
      verify "Backup verifizieren (optional Pfad)" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      backup|backup-postfix|backup-dovecot|backup-nginx|list)
        run_action "setup_backup_restore.sh" "$choice"
        ;;
      restore|restore-postfix|restore-dovecot|restore-nginx|verify)
        local arg
        arg="$(input_box "$choice" "Optional Backup-Pfad (leer = default):" "")" || continue
        if [ -n "${arg// }" ]; then
          run_action "setup_backup_restore.sh" "$choice" "$arg"
        else
          run_action "setup_backup_restore.sh" "$choice"
        fi
        ;;
      custom)
        run_custom_args "setup_backup_restore.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_unban_ip() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "unban_ip.sh" --menu "Aktion waehlen" 20 90 11 \
      auto "Automatikmodus (--domain/--prefix optional)" \
      bans "Nur Bans anzeigen" \
      unban "Gezieltes Unban/Whitelist" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      auto)
        local domain prefix
        local -a args=( )
        domain="$(input_box "Domain" "Domain fuer auto (leer = Script-Default):" "")" || continue
        prefix="$(input_box "IPv6 Prefix Length" "Prefix-Laenge (leer = Script-Default):" "")" || continue

        if [ -n "${domain// }" ]; then
          args+=(--domain "$domain")
        fi
        if [ -n "${prefix// }" ]; then
          args+=(--prefix-length "$prefix")
        fi
        if ask_yes_no "Testmodus" "Dry-Run aktivieren (--test)?"; then
          args+=(--test)
        fi
        run_action "unban_ip.sh" "${args[@]}"
        ;;
      bans)
        run_action "unban_ip.sh" --bans
        ;;
      unban)
        local target domain prefix
        local -a args=(--unban)
        target="$(input_box "Target" "IP/CIDR/Domain fuer --unban:" "")" || continue
        if [ -z "${target// }" ]; then
          msg_error "Kein Target eingegeben."
          continue
        fi
        args+=("$target")

        domain="$(input_box "Domain" "Optional --domain Wert (leer = default):" "")" || continue
        prefix="$(input_box "IPv6 Prefix Length" "Optional --prefix-length (leer = default):" "")" || continue
        if [ -n "${domain// }" ]; then
          args+=(--domain "$domain")
        fi
        if [ -n "${prefix// }" ]; then
          args+=(--prefix-length "$prefix")
        fi
        if ask_yes_no "Testmodus" "Dry-Run aktivieren (--test)?"; then
          args+=(--test)
        fi

        run_action "unban_ip.sh" "${args[@]}"
        ;;
      custom)
        run_custom_args "unban_ip.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_f2b_test() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "f2b_test.sh" --menu "Aktion" 14 70 6 \
      run "Testscript ausfuehren" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      run)
        run_action "f2b_test.sh"
        ;;
      custom)
        run_custom_args "f2b_test.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

menu_setup_zpush() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "setup-zpush.sh" --menu "Aktion" 14 70 6 \
      run "Setup ausfuehren" \
      custom "Eigene Argumente" \
      back "Zurueck" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      run)
        run_action "setup-zpush.sh"
        ;;
      custom)
        run_custom_args "setup-zpush.sh"
        ;;
      back)
        break
        ;;
    esac
  done
}

main_menu() {
  while true; do
    local choice
    choice=$(whiptail --clear --backtitle "$BACKTITLE" --title "Hauptmenue" --menu "Script waehlen" 22 90 14 \
      dovecot "setup_dovecot.sh" \
      postfix "setup_postfix.sh" \
      php "setup_php.sh" \
      nginx "setup_nginx.sh" \
      zpush "setup-zpush.sh" \
      localrepo "setup_local_repo.sh" \
      backuprestore "setup_backup_restore.sh" \
      unbanip "unban_ip.sh" \
      fail2bantest "f2b_test.sh" \
      perms "Execute-Rechte neu setzen" \
      exit "Beenden" 3>&1 1>&2 2>&3) || break

    case "$choice" in
      dovecot) menu_setup_dovecot ;;
      postfix) menu_setup_postfix ;;
      php) menu_setup_php ;;
      nginx) menu_setup_nginx ;;
      zpush) menu_setup_zpush ;;
      localrepo) menu_setup_local_repo ;;
      backuprestore) menu_setup_backup_restore ;;
      unbanip) menu_unban_ip ;;
      fail2bantest) menu_f2b_test ;;
      perms)
        ensure_executable_scripts
        whiptail --title "Rechte" --msgbox "Execute-Rechte fuer bekannte Scripts gesetzt (chmod 755)." 10 70
        ;;
      exit)
        break
        ;;
    esac
  done
}

git_update_and_restart() {
  if [ -d "$SCRIPT_DIR/.git" ]; then
    local output
    output="$(git -C "$SCRIPT_DIR" pull 2>&1)" || {
      whiptail --title "Git Fehler" --msgbox "git pull fehlgeschlagen:\n\n$output" 12 70
      return
    }
    if echo "$output" | grep -q "Already up to date\|Already up-to-date\|current"; then
      return
    fi
    whiptail --title "Git Update" --msgbox "Repo wurde aktualisiert. Menue wird neu gestartet...\n\n$output" 12 70
    exec bash "$0" "$@"
  fi
}

main() {
  require_whiptail
  ensure_root "$@"
  git_update_and_restart "$@"
  ensure_executable_scripts
  ensure_env_files
  main_menu
  clear
}

main "$@"
