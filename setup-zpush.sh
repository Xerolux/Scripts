#!/usr/bin/env bash
set -euo pipefail

############################################
# Z-Push PRO Setup (with rollback & safety)
############################################

if [[ ! -f "setup-zpush.env" ]]; then
  echo "FEHLER: setup-zpush.env nicht gefunden. Bitte aus setup-zpush.env.example erstellen." >&2
  exit 1
fi
source "setup-zpush.env"

ZPUSH_DIR="/etc/z-push"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

TMP_DIR="/root/zpush-setup-backup-$(date +%s)"

############################################
# Logging
############################################

log() { echo -e "\n==> $*"; }
warn() { echo "WARNUNG: $*" >&2; }
fail() { echo "FEHLER: $*" >&2; exit 1; }

############################################
# Rollback Handler
############################################

rollback() {
  echo
  echo "!!! FEHLER - ROLLBACK wird durchgeführt !!!"

  if [[ -d "$TMP_DIR" ]]; then
    cp -a "$TMP_DIR/nginx/." "$NGINX_AVAILABLE/" 2>/dev/null || true
    cp -a "$TMP_DIR/zpush/." "$ZPUSH_DIR/" 2>/dev/null || true
    systemctl reload nginx || true
  fi

  echo "Rollback abgeschlossen."
}

trap rollback ERR

############################################
# Root Check
############################################

[[ $EUID -eq 0 ]] || fail "Bitte als root ausführen."

############################################
# Backup
############################################

log "Backup erstellen: $TMP_DIR"
mkdir -p "$TMP_DIR/nginx"
mkdir -p "$TMP_DIR/zpush"

cp -a "$NGINX_AVAILABLE/"* "$TMP_DIR/nginx/" 2>/dev/null || true
cp -a "$ZPUSH_DIR/"* "$TMP_DIR/zpush/" 2>/dev/null || true

############################################
# PHP Socket Detection
############################################

detect_php_sock() {
  if [[ -S /run/php/php-fpm.sock ]]; then
    echo "/run/php/php-fpm.sock"
    return
  fi

  find /run/php -name "php*-fpm.sock" | sort -V | tail -n1
}

PHP_SOCK="$(detect_php_sock)"
[[ -n "$PHP_SOCK" ]] || fail "Kein PHP Socket gefunden"

log "PHP Socket: $PHP_SOCK"

############################################
# SSL Detection
############################################

SSL_BASE="$(find /etc/letsencrypt/live -type d | grep "$SSL_SEARCH_DOMAIN" | head -n1)"
[[ -d "$SSL_BASE" ]] || fail "Kein Zertifikat gefunden"

log "SSL Path: $SSL_BASE"

############################################
# IMAP Folder Detection
############################################

log "IMAP Ordner erkennen"

MAILBOXES="$(doveadm mailbox list -u "$TEST_USER" 2>/dev/null || true)"

SENT="Sent"
DRAFTS="Drafts"
TRASH="Trash"
SPAM="Junk"

if [[ -n "$MAILBOXES" ]]; then
  echo "$MAILBOXES" | grep -q "INBOX.Sent" && SENT="INBOX.Sent"
  echo "$MAILBOXES" | grep -q "INBOX.Drafts" && DRAFTS="INBOX.Drafts"
  echo "$MAILBOXES" | grep -q "INBOX.Trash" && TRASH="INBOX.Trash"
  echo "$MAILBOXES" | grep -q "INBOX.Junk" && SPAM="INBOX.Junk"
fi

echo "Sent:   $SENT"
echo "Drafts: $DRAFTS"
echo "Trash:  $TRASH"
echo "Spam:   $SPAM"

############################################
# Z-Push Config
############################################

log "Z-Push konfigurieren"

sed -i "s|IMAP_SERVER.*|define('IMAP_SERVER', '${MAIL_HOST}');|g" /etc/z-push/imap.conf.php
sed -i "s|IMAP_PORT.*|define('IMAP_PORT', 993);|g" /etc/z-push/imap.conf.php
sed -i "s|IMAP_OPTIONS.*|define('IMAP_OPTIONS', '/ssl');|g" /etc/z-push/imap.conf.php

sed -i "s|IMAP_SENTFOLDER.*|define('IMAP_SENTFOLDER', '${SENT}');|g" /etc/z-push/imap.conf.php
sed -i "s|IMAP_DRAFTSFOLDER.*|define('IMAP_DRAFTSFOLDER', '${DRAFTS}');|g" /etc/z-push/imap.conf.php
sed -i "s|IMAP_TRASHFOLDER.*|define('IMAP_TRASHFOLDER', '${TRASH}');|g" /etc/z-push/imap.conf.php
sed -i "s|IMAP_SPAMFOLDER.*|define('IMAP_SPAMFOLDER', '${SPAM}');|g" /etc/z-push/imap.conf.php

############################################
# Nginx Config (Temp)
############################################

TMP_CONF="/tmp/zpush-nginx.conf"

log "Nginx Config schreiben (temp)"

cat > "$TMP_CONF" <<EOF
server {
    listen 80;
    server_name ${PUSH_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${PUSH_DOMAIN};

    ssl_certificate ${SSL_BASE}/fullchain.pem;
    ssl_certificate_key ${SSL_BASE}/privkey.pem;

    location = / { return 301 /Microsoft-Server-ActiveSync; }

    location ~* ^/Microsoft-Server-ActiveSync/?$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/z-push/index.php;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~* ^/AutoDiscover/AutoDiscover.xml$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/z-push/autodiscover/autodiscover.php;
        fastcgi_pass unix:${PHP_SOCK};
    }
}
EOF

############################################
# Activate Config
############################################

TARGET_CONF="${NGINX_AVAILABLE}/${PUSH_DOMAIN}.conf"

cp "$TMP_CONF" "$TARGET_CONF"
ln -sfn "$TARGET_CONF" "${NGINX_ENABLED}/"

############################################
# Test nginx
############################################

log "Teste nginx config"

nginx -t

############################################
# Reload
############################################

systemctl reload nginx

############################################
# Connectivity Tests
############################################

log "Teste IMAPS Verbindung"

timeout 10 bash -c "echo | openssl s_client -connect ${MAIL_HOST}:993 -servername ${MAIL_HOST}" >/dev/null 2>&1 \
  && echo "IMAP OK" || warn "IMAP FAIL"

log "Teste ActiveSync Endpoint"

curl -k -I https://${PUSH_DOMAIN}/Microsoft-Server-ActiveSync || warn "HTTP FAIL"

############################################
# DONE
############################################

log "SUCCESS 🚀"

echo
echo "Z-Push läuft jetzt unter:"
echo "https://${PUSH_DOMAIN}/Microsoft-Server-ActiveSync"