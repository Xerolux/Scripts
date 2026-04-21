#!/usr/bin/env bash
# wrapper script with graphical menu (whiptail)

# Needs whiptail
if ! command -v whiptail >/dev/null; then
    echo "Bitte installiere 'whiptail': sudo apt-get install whiptail"
    # exit removed to avoid session issue during test
fi

HEIGHT=20
WIDTH=60
CHOICE_HEIGHT=10
BACKTITLE="Server Setup & Management Scripts"
TITLE="Hauptmenü"
MENU="Wähle das Script, das du ausführen möchtest:"

OPTIONS=(1 "Setup Dovecot"
         2 "Setup Postfix"
         3 "Setup PHP"
         4 "Setup NGINX"
         5 "Setup Z-Push"
         6 "Setup Local Repo"
         7 "Backup / Restore"
         8 "Unban IP"
         9 "Fail2Ban Test")

CHOICE=$(whiptail --clear \
                --backtitle "$BACKTITLE" \
                --title "$TITLE" \
                --menu "$MENU" \
                $HEIGHT $WIDTH $CHOICE_HEIGHT \
                "${OPTIONS[@]}" \
                3>&1 1>&2 2>&3)

clear

case $CHOICE in
    1) sudo bash setup_dovecot.sh ;;
    2) sudo bash setup_postfix.sh ;;
    3) sudo bash setup_php.sh ;;
    4) sudo bash setup_nginx.sh ;;
    5) sudo bash setup-zpush.sh ;;
    6) sudo bash setup_local_repo.sh ;;
    7) sudo bash setup_backup_restore.sh ;;
    8) sudo bash unban_ip.sh ;;
    9) sudo bash f2b_test.sh ;;
    *) echo "Abgebrochen." ;;
esac
