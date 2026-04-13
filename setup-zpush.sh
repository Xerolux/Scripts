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
# Package Check / Install
############################################

install_zpush_from_github_release() {
  local zpush_version="${ZPUSH_VERSION:-2.7.6}"
  local archive_url="https://github.com/Z-Hub/Z-Push/archive/refs/tags/${zpush_version}.tar.gz"
  local archive_path="/tmp/zpush-${zpush_version}.tar.gz"
  local extract_dir="/tmp/Z-Push-${zpush_version}"

  log "Installiere Z-Push aus GitHub Release ${zpush_version} (Fallback)"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl tar php-fpm php-imap php-mbstring php-curl php-xml php-soap php-intl

  curl -fsSL "$archive_url" -o "$archive_path"
  rm -rf "$extract_dir"
  tar -xzf "$archive_path" -C /tmp

  [[ -d "$extract_dir/src" ]] || fail "Z-Push Release enthält kein src-Verzeichnis: ${extract_dir}/src"

  mkdir -p /usr/share/z-push
  cp -a "$extract_dir/src/." /usr/share/z-push/

  mkdir -p /etc/z-push
  [[ -f "/etc/z-push/z-push.conf.php" ]] || cp -a /usr/share/z-push/config.php /etc/z-push/z-push.conf.php
  [[ -f "/etc/z-push/imap.conf.php" ]] || cp -a /usr/share/z-push/backend/imap/config.php /etc/z-push/imap.conf.php

  [[ -f "/usr/share/z-push/index.php" ]] || fail "Fallback-Installation unvollständig: /usr/share/z-push/index.php fehlt"
}

ensure_zpush_packages() {
  local required_packages=(
    "z-push-common"
    "z-push-backend-imap"
    "z-push-ipc-sharedmemory"
  )
  local missing_packages=()
  local pkg

  if [[ -f "/usr/share/z-push/index.php" && -f "/usr/share/z-push/backend/imap/config.php" ]]; then
    log "Z-Push Dateien bereits vorhanden"
    return 0
  fi

  for pkg in "${required_packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing_packages+=("$pkg")
    fi
  done

  if (( ${#missing_packages[@]} > 0 )); then
    log "Installiere fehlende Z-Push Pakete: ${missing_packages[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if ! apt-get install -y "${missing_packages[@]}"; then
      warn "APT-Installation fehlgeschlagen (z.B. auf Ubuntu Noble ohne Z-Push-Pakete). Nutze GitHub-Fallback."
      install_zpush_from_github_release
    fi
  else
    log "Alle Z-Push Pakete bereits installiert"
  fi
}

ensure_zpush_packages

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

ensure_zpush_installed() {
  [[ -f "/usr/share/z-push/index.php" ]] && return 0
  fail "Z-Push scheint nicht installiert zu sein (/usr/share/z-push/index.php fehlt). Installiere z.B.: apt install -y z-push-common z-push-backend-imap"
}

detect_main_zpush_conf() {
  local candidates=(
    "/etc/z-push/z-push.conf.php"
    "/usr/share/z-push/config.php"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

bootstrap_imap_conf() {
  local src_candidates=(
    "/usr/share/z-push/backend/imap/config.php"
    "/usr/share/z-push/backend/imap/config.php.default"
    "/usr/share/z-push/backend/imap/config.php.dist"
    "/usr/share/z-push/backend/imap/config.php.sample"
  )
  local src
  mkdir -p "/etc/z-push"
  for src in "${src_candidates[@]}"; do
    if [[ -f "$src" ]]; then
      cp -a "$src" "/etc/z-push/imap.conf.php"
      return 0
    fi
  done
  return 1
}

detect_imap_conf() {
  local candidates=(
    "/etc/z-push/imap.conf.php"
    "/etc/z-push/backend/imap/config.php"
    "/usr/share/z-push/backend/imap/config.php"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

ensure_zpush_installed
MAIN_ZPUSH_CONF="$(detect_main_zpush_conf || true)"
[[ -n "${MAIN_ZPUSH_CONF}" ]] || fail "Keine Z-Push Hauptconfig gefunden (/etc/z-push/z-push.conf.php oder /usr/share/z-push/config.php)."
IMAP_CONF="$(detect_imap_conf || true)"
if [[ -z "${IMAP_CONF}" ]]; then
  log "IMAP Config fehlt - versuche /etc/z-push/imap.conf.php aus Template zu erzeugen"
  bootstrap_imap_conf || fail "Keine IMAP Config gefunden und kein Template verfügbar. Prüfe Paket z-push-backend-imap."
  IMAP_CONF="$(detect_imap_conf || true)"
fi
[[ -n "${IMAP_CONF}" ]] || fail "Keine IMAP Config gefunden. Prüfe Paket z-push-backend-imap und Pfade unter /etc/z-push bzw. /usr/share/z-push."
log "Z-Push Hauptconfig: ${MAIN_ZPUSH_CONF}"
log "IMAP Config: ${IMAP_CONF}"

sed -i -E "s|^.*BACKEND_PROVIDER.*$|define('BACKEND_PROVIDER', 'BackendIMAP');|g" "${MAIN_ZPUSH_CONF}"

sed -i -E "s|^[[:space:]]*define\\('IMAP_SERVER'.*|define('IMAP_SERVER', '${MAIL_HOST}');|g" "${IMAP_CONF}"
sed -i -E "s|^[[:space:]]*define\\('IMAP_PORT'.*|define('IMAP_PORT', 993);|g" "${IMAP_CONF}"
sed -i -E "s|^[[:space:]]*define\\('IMAP_OPTIONS'.*|define('IMAP_OPTIONS', '/ssl');|g" "${IMAP_CONF}"

sed -i -E "s|^[[:space:]]*define\\('IMAP_SENTFOLDER'.*|define('IMAP_SENTFOLDER', '${SENT}');|g" "${IMAP_CONF}"
sed -i -E "s|^[[:space:]]*define\\('IMAP_DRAFTSFOLDER'.*|define('IMAP_DRAFTSFOLDER', '${DRAFTS}');|g" "${IMAP_CONF}"
sed -i -E "s|^[[:space:]]*define\\('IMAP_TRASHFOLDER'.*|define('IMAP_TRASHFOLDER', '${TRASH}');|g" "${IMAP_CONF}"
sed -i -E "s|^[[:space:]]*define\\('IMAP_SPAMFOLDER'.*|define('IMAP_SPAMFOLDER', '${SPAM}');|g" "${IMAP_CONF}"

php -l "${MAIN_ZPUSH_CONF}" >/dev/null || fail "Z-Push Hauptconfig hat Syntaxfehler: ${MAIN_ZPUSH_CONF}"
php -l "${IMAP_CONF}" >/dev/null || fail "Z-Push IMAP Config hat Syntaxfehler: ${IMAP_CONF}"

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

if timeout 10 bash -c "echo | openssl s_client -connect ${MAIL_HOST}:993 -servername ${MAIL_HOST}" >/dev/null 2>&1; then
  echo "IMAP OK"
else
  warn "IMAP FAIL"
fi

log "Teste ActiveSync Endpoint"

HTTP_CODE="$(curl -k -sS -o /tmp/zpush-endpoint-check.out -w "%{http_code}" https://"${PUSH_DOMAIN}"/Microsoft-Server-ActiveSync || true)"
echo "HTTP Status: ${HTTP_CODE}"
if [[ -z "${HTTP_CODE}" || "${HTTP_CODE}" == "000" ]]; then
  warn "HTTP FAIL (keine Antwort)"
elif [[ "${HTTP_CODE}" =~ ^5 ]]; then
  warn "ActiveSync liefert HTTP ${HTTP_CODE} (Serverfehler). Prüfe /var/log/nginx/error.log und PHP-FPM Logs."
fi

############################################
# DONE
############################################

log "SUCCESS 🚀"

echo
echo "Z-Push läuft jetzt unter:"
echo "https://${PUSH_DOMAIN}/Microsoft-Server-ActiveSync"
