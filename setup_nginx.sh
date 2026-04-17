#!/usr/bin/env bash
# ==============================================================================
# setup_nginx.sh – Nginx Build-from-Source + .deb-Paketerstellung
# Zielumgebung : Ubuntu 24.04 ARM64, ISPConfig
#
# Nginx baut mit klassischem ./configure && make && make install
# OpenSSL wird aus Source gebaut (fuer HTTP/3 QUIC-Support)
#
# Empfohlener Ablauf:
#   1. setup_nginx.sh package   → .deb erstellen (KEIN install)
#   2. setup_nginx.sh install   → Backup + dpkg -i
#
# Konfiguration:
#   /etc/nginx/ wird NICHT in die Pakete gepackt → ISPConfig-Configs bleiben
#
# Deinstallation:
#   setup_nginx.sh uninstall
#   oder: dpkg -r nginx-custom
# ==============================================================================
set -Eeuo pipefail

if [[ ! -f "setup_nginx.env" ]]; then
  echo "FEHLER: setup_nginx.env nicht gefunden. Bitte aus setup_nginx.env.example erstellen." >&2
  exit 1
fi
source "setup_nginx.env"

NGINX_TARBALL_URLS=(
  "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
  "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
)

OPENSSL_TARBALL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"

NGINX_BROTLI_VERSION="master"
NGINX_HEADERS_MORE_VERSION="v0.37"
NGINX_CACHE_PURGE_VERSION="master"

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
die()  { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausführen."
}

usage() {
  cat <<'EOF'
Verwendung:
  setup_nginx.sh [--screen] <Befehl>

Optionen:
  --screen         Skript in einer GNU Screen Session ausführen (optional)

Befehle:
  package          – Quellen laden, bauen, .deb erstellen (KEIN install)
  install          – Backup + dpkg -i des erzeugten .deb
  backup           – Nur Backup erstellen
  restore          – Letztes Backup einspielen
  restore /root/nginx-backup/<timestamp>
  status           – Zustand + Module anzeigen
  list-backups     – Verfügbare Backups auflisten
  check-config     – nginx -t ausführen
  uninstall        – Custom-Paket via dpkg -r entfernen
  verify           – Modul-Verifikation (nach Installation)

Deinstallation manuell:
  dpkg -r nginx-custom
EOF
}

create_backup() {
  local ts backup_dir
  ts="$(date '+%F_%H%M%S')"
  backup_dir="$BACKUP_ROOT/$ts"
  mkdir -p "$backup_dir"
  log "Erstelle Backup in $backup_dir"

  systemctl stop nginx 2>/dev/null || true

  [ -d /etc/nginx ]                        && cp -a /etc/nginx                        "$backup_dir/etc_nginx"
  [ -f /usr/sbin/nginx ]                   && cp -a /usr/sbin/nginx                   "$backup_dir/usr_sbin_nginx"
  [ -d /usr/lib/nginx ]                    && cp -a /usr/lib/nginx                    "$backup_dir/usr_lib_nginx"
  [ -f /lib/systemd/system/nginx.service ] && cp -a /lib/systemd/system/nginx.service "$backup_dir/nginx.service"
  dpkg -l 2>/dev/null | awk '/^ii/ && /nginx/ {print $2}' > "$backup_dir/packages.txt" || true
  if command -v nginx >/dev/null 2>&1; then
    nginx -v > "$backup_dir/nginx-version.txt" 2>&1 || true
    nginx -V > "$backup_dir/nginx-compile.txt" 2>&1 || true
  fi
  if [ -d "$PACKAGE_DIR" ] && ls "$PACKAGE_DIR"/*.deb >/dev/null 2>&1; then
    cp -a "$PACKAGE_DIR" "$backup_dir/deb-packages" || true
  fi

  ln -sfn "$backup_dir" "$LATEST_LINK"
  log "Backup fertig: $backup_dir"
}

install_build_deps() {
  log "Installiere Build-Abhängigkeiten"

  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential make m4 pkg-config \
    libssl-dev \
    libpcre2-dev \
    libpcre3-dev \
    zlib1g-dev \
    libgd-dev \
    libgeoip-dev \
    libmaxminddb-dev \
    libxslt1-dev \
    libxml2-dev \
    libgoogle-perftools-dev \
    libbrotli-dev \
    ruby ruby-dev rubygems rpm \
    wget curl git

  if ! command -v fpm >/dev/null 2>&1; then
    log "Installiere fpm"
    gem install --no-document fpm
  else
    log "fpm bereits vorhanden: $(fpm --version)"
  fi
}

prepare_sources() {
  mkdir -p "$BUILD_ROOT"
  cd "$BUILD_ROOT"
  rm -rf "nginx-${NGINX_VERSION}"

  local ng_tar
  ng_tar="$BUILD_ROOT/nginx-${NGINX_VERSION}.tar.gz"

  if [ ! -f "$ng_tar" ]; then
    log "Lade Nginx $NGINX_VERSION Tarball"
    local url
    local downloaded=0
    for url in "${NGINX_TARBALL_URLS[@]}"; do
      log "Versuche Download: $url"
      if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar "$url" -o "$ng_tar"; then
        downloaded=1
        break
      fi
    done
    (( downloaded == 1 )) || die "Download fehlgeschlagen"
  else
    log "Nginx Tarball bereits vorhanden: $ng_tar"
  fi

  tar xzf "$ng_tar"
  [ -d "$BUILD_ROOT/nginx-${NGINX_VERSION}" ] \
    || die "Tarball entpackt kein Verzeichnis nginx-${NGINX_VERSION}"
  log "Quellen: $BUILD_ROOT/nginx-${NGINX_VERSION}"
}

prepare_openssl() {
  local ssl_dir="$BUILD_ROOT/openssl-${OPENSSL_VERSION}"
  local ssl_tar="$BUILD_ROOT/openssl-${OPENSSL_VERSION}.tar.gz"

  if [ -d "$ssl_dir" ] && [ -f "$ssl_dir/Configure" ]; then
    log "OpenSSL $OPENSSL_VERSION Quellen bereits vorhanden: $ssl_dir"
    return 0
  fi

  if [ ! -f "$ssl_tar" ]; then
    log "Lade OpenSSL $OPENSSL_VERSION Tarball"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar \
      "$OPENSSL_TARBALL_URL" -o "$ssl_tar" \
      || die "OpenSSL Download fehlgeschlagen"
  else
    log "OpenSSL Tarball bereits vorhanden: $ssl_tar"
  fi

  tar xzf "$ssl_tar" -C "$BUILD_ROOT"
  [ -d "$ssl_dir" ] || die "Tarball entpackt kein Verzeichnis openssl-${OPENSSL_VERSION}"
  log "OpenSSL Quellen: $ssl_dir"
}

download_third_party_modules() {
  local modules_dir="$BUILD_ROOT/nginx-modules"
  mkdir -p "$modules_dir"

  if [ ! -d "$modules_dir/ngx_brotli" ]; then
    log "Lade ngx_brotli $NGINX_BROTLI_VERSION"
    git clone --depth 1 --branch "$NGINX_BROTLI_VERSION" \
      https://github.com/google/ngx_brotli.git "$modules_dir/ngx_brotli"
    cd "$modules_dir/ngx_brotli" && git submodule update --init && cd "$BUILD_ROOT"
  else
    log "ngx_brotli bereits vorhanden"
  fi

  if [ ! -d "$modules_dir/headers-more-nginx-module" ]; then
    log "Lade headers-more-nginx-module $NGINX_HEADERS_MORE_VERSION"
    git clone --depth 1 --branch "$NGINX_HEADERS_MORE_VERSION" \
      https://github.com/openresty/headers-more-nginx-module.git \
      "$modules_dir/headers-more-nginx-module"
  else
    log "headers-more-nginx-module bereits vorhanden"
  fi

  if [ ! -d "$modules_dir/ngx_cache_purge" ]; then
    log "Lade ngx_cache_purge $NGINX_CACHE_PURGE_VERSION"
    git clone --depth 1 --branch "$NGINX_CACHE_PURGE_VERSION" \
      https://github.com/FRiCKLE/ngx_cache_purge.git \
      "$modules_dir/ngx_cache_purge"
  else
    log "ngx_cache_purge bereits vorhanden"
  fi
}

build_configure_args() {
  local CONF_ARGS=""

  log "Ermittle ./configure Argumente..."

  CONF_ARGS="$CONF_ARGS --prefix=/etc/nginx"
  CONF_ARGS="$CONF_ARGS --sbin-path=/usr/sbin/nginx"
  CONF_ARGS="$CONF_ARGS --modules-path=/usr/lib/nginx/modules"
  CONF_ARGS="$CONF_ARGS --conf-path=/etc/nginx/nginx.conf"
  CONF_ARGS="$CONF_ARGS --error-log-path=/var/log/nginx/error.log"
  CONF_ARGS="$CONF_ARGS --http-log-path=/var/log/nginx/access.log"
  CONF_ARGS="$CONF_ARGS --pid-path=/var/run/nginx.pid"
  CONF_ARGS="$CONF_ARGS --lock-path=/var/run/nginx.lock"
  CONF_ARGS="$CONF_ARGS --user=$NGINX_USER"
  CONF_ARGS="$CONF_ARGS --group=$NGINX_GROUP"

  log "  [+] Basispfade gesetzt"

  CONF_ARGS="$CONF_ARGS --with-compat"
  CONF_ARGS="$CONF_ARGS --with-file-aio"
  CONF_ARGS="$CONF_ARGS --with-threads"
  CONF_ARGS="$CONF_ARGS --with-cc-opt=-fPIE\ -fstack-protector-strong\ -D_FORTIFY_SOURCE=2\ -Wno-implicit-function-declaration"
  CONF_ARGS="$CONF_ARGS --with-ld-opt=-Wl,-z,relro\ -Wl,-z,now\ -pie"

  if [ -d "$BUILD_ROOT/openssl-${OPENSSL_VERSION}" ]; then
    log "  [+] SSL/TLS (OpenSSL ${OPENSSL_VERSION} aus Source – QUIC-faehig)"
    CONF_ARGS="$CONF_ARGS --with-openssl=$BUILD_ROOT/openssl-${OPENSSL_VERSION}"
    CONF_ARGS="$CONF_ARGS --with-openssl-opt=no-tests"
    CONF_ARGS="$CONF_ARGS --with-http_ssl_module"
    CONF_ARGS="$CONF_ARGS --with-stream_ssl_module"
    CONF_ARGS="$CONF_ARGS --with-mail_ssl_module"
    CONF_ARGS="$CONF_ARGS --with-stream_ssl_preread_module"
  elif pkg-config --exists openssl 2>/dev/null || [ -f /usr/include/openssl/ssl.h ]; then
    log "  [+] SSL/TLS (System OpenSSL – HTTP/3 QUIC ggf. eingeschraenkt)"
    CONF_ARGS="$CONF_ARGS --with-http_ssl_module"
    CONF_ARGS="$CONF_ARGS --with-stream_ssl_module"
    CONF_ARGS="$CONF_ARGS --with-mail_ssl_module"
    CONF_ARGS="$CONF_ARGS --with-stream_ssl_preread_module"
  else
    die "OpenSSL-Dev nicht gefunden – SSL ist Pflicht"
  fi

  log "  [+] HTTP/2"
  CONF_ARGS="$CONF_ARGS --with-http_v2_module"

  log "  [+] HTTP/3 (QUIC)"
  CONF_ARGS="$CONF_ARGS --with-http_v3_module"

  if pkg-config --exists libpcre2-8 2>/dev/null || [ -f /usr/include/pcre.h ]; then
    log "  [+] PCRE (Rewrite)"
    CONF_ARGS="$CONF_ARGS --with-pcre"
  else
    log "  [-] PCRE nicht gefunden"
  fi

  log "  [+] Real IP"
  CONF_ARGS="$CONF_ARGS --with-http_realip_module"

  log "  [+] Gzip"
  CONF_ARGS="$CONF_ARGS --with-http_gzip_static_module"

  log "  [+] Stub Status"
  CONF_ARGS="$CONF_ARGS --with-http_stub_status_module"

  log "  [+] Sub Filter"
  CONF_ARGS="$CONF_ARGS --with-http_sub_module"

  log "  [+] Addition"
  CONF_ARGS="$CONF_ARGS --with-http_addition_module"

  log "  [+] Auth Request"
  CONF_ARGS="$CONF_ARGS --with-http_auth_request_module"

  log "  [+] Random Index"
  CONF_ARGS="$CONF_ARGS --with-http_random_index_module"

  log "  [+] Secure Link"
  CONF_ARGS="$CONF_ARGS --with-http_secure_link_module"

  log "  [+] Slices"
  CONF_ARGS="$CONF_ARGS --with-http_slice_module"

  log "  [+] DEFLATE"
  CONF_ARGS="$CONF_ARGS --with-http_gunzip_module"

  if pkg-config --exists libgd 2>/dev/null || [ -f /usr/include/gd.h ]; then
    log "  [+] Image Filter (libgd)"
    CONF_ARGS="$CONF_ARGS --with-http_image_filter_module"
  else
    log "  [-] libgd nicht gefunden (Image Filter deaktiviert)"
  fi

  if pkg-config --exists libmaxminddb 2>/dev/null || [ -f /usr/include/maxminddb.h ]; then
    log "  [+] GeoIP2 (libmaxminddb)"
    CONF_ARGS="$CONF_ARGS --with-http_geoip_module=dynamic"
  else
    log "  [-] libmaxminddb nicht gefunden (GeoIP2 deaktiviert)"
  fi

  if pkg-config --exists libxslt 2>/dev/null || [ -f /usr/include/libxslt/xslt.h ]; then
    log "  [+] XSLT"
    CONF_ARGS="$CONF_ARGS --with-http_xslt_module"
  else
    log "  [-] libxslt nicht gefunden (XSLT deaktiviert)"
  fi

  log "  [+] Stream (TCP/UDP Proxy)"
  CONF_ARGS="$CONF_ARGS --with-stream"
  CONF_ARGS="$CONF_ARGS --with-stream_realip_module"

  log "  [+] Mail Proxy"
  CONF_ARGS="$CONF_ARGS --with-mail"

  if [ -f /usr/include/gperftools/malloc_extension.h ] || [ -f /usr/include/google/tcmalloc.h ]; then
    log "  [+] Google Perftools (tcmalloc)"
    CONF_ARGS="$CONF_ARGS --with-google_perftools_module"
  else
    log "  [-] Google Perftools nicht gefunden"
  fi

  log "  [+] WebDAV"
  CONF_ARGS="$CONF_ARGS --with-http_dav_module"

  log "  [+] FLV"
  CONF_ARGS="$CONF_ARGS --with-http_flv_module"

  log "  [+] MP4"
  CONF_ARGS="$CONF_ARGS --with-http_mp4_module"

  local modules_dir="$BUILD_ROOT/nginx-modules"

  if [ -d "$modules_dir/ngx_brotli" ]; then
    log "  [+] ngx_brotli (Brotli Compression)"
    CONF_ARGS="$CONF_ARGS --add-module=$modules_dir/ngx_brotli"
  else
    log "  [-] ngx_brotli nicht gefunden"
  fi

  if [ -d "$modules_dir/headers-more-nginx-module" ]; then
    log "  [+] headers-more-nginx-module"
    CONF_ARGS="$CONF_ARGS --add-module=$modules_dir/headers-more-nginx-module"
  else
    log "  [-] headers-more-nginx-module nicht gefunden"
  fi

  if [ -d "$modules_dir/ngx_cache_purge" ]; then
    log "  [+] ngx_cache_purge"
    CONF_ARGS="$CONF_ARGS --add-module=$modules_dir/ngx_cache_purge"
  else
    log "  [-] ngx_cache_purge nicht gefunden"
  fi

  printf '%s' "$CONF_ARGS"
}

build_nginx() {
  cd "$BUILD_ROOT/nginx-${NGINX_VERSION}"
  log "Baue Nginx $NGINX_VERSION"

  local conf_args
  conf_args="$(build_configure_args)"

  log "Configure-Argumente:${conf_args}"

  log "Führe ./configure aus"
  set +e
  ./configure ${conf_args} 2>&1 | tee -a "$LOG_FILE"
  local conf_rc=${PIPESTATUS[0]}
  set -e
  [ "$conf_rc" -eq 0 ] || die "./configure fehlgeschlagen (Exit $conf_rc)"

  log "Kompiliere Nginx (make -j$(nproc))"
  set +e
  make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
  local build_rc=${PIPESTATUS[0]}
  set -e
  [ "$build_rc" -eq 0 ] || die "Nginx make fehlgeschlagen (Exit $build_rc)"

  log "Nginx Build fertig"
}

create_deb_package() {
  local arch
  arch="$(dpkg --print-architecture)"
  mkdir -p "$PACKAGE_DIR"

  cd "$BUILD_ROOT/nginx-${NGINX_VERSION}"

  log "Installiere Nginx ins Staging: $STAGE_NGINX"
  rm -rf "$STAGE_NGINX"
  mkdir -p "$STAGE_NGINX"

  set +e
  make DESTDIR="$STAGE_NGINX" install 2>&1 | tee -a "$LOG_FILE"
  local inst_rc=${PIPESTATUS[0]}
  set -e
  [ "$inst_rc" -eq 0 ] || die "make install fehlgeschlagen (Exit $inst_rc)"

  rm -rf "${STAGE_NGINX}/etc/nginx"
  log "/etc/nginx aus Staging entfernt (Konfiguration wird nicht verpackt)"

  mkdir -p "${STAGE_NGINX}/var/log/nginx"
  mkdir -p "${STAGE_NGINX}/var/cache/nginx"

  mkdir -p "${STAGE_NGINX}/lib/systemd/system"
  cat > "${STAGE_NGINX}/lib/systemd/system/nginx.service" <<'NGXSRV'
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=https://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true
Restart=on-failure

[Install]
WantedBy=multi-user.target
NGXSRV
  log "systemd service file erstellt"

  mkdir -p "${STAGE_NGINX}/etc/logrotate.d"
  cat > "${STAGE_NGINX}/etc/logrotate.d/nginx-custom" <<'NGXLR'
/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid) || true
    endspost
}
NGXLR
  log "logrotate config erstellt"

  log "Staging-Inhalt (relevante Dateien):"
  find "$STAGE_NGINX" \( -name "nginx" -o -name "*.so" \) -type f | sort | tee -a "$LOG_FILE"

  local postinst="/tmp/nginx-postinst.sh"
  local postrm="/tmp/nginx-postrm.sh"

  cat > "$postinst" <<'POSTINST'
#!/bin/sh
set -e

if ! id -u www-data >/dev/null 2>&1; then
  adduser --system --group --no-create-home \
    --gecos "Web Server" --shell /usr/sbin/nologin www-data 2>/dev/null || true
fi

mkdir -p /var/log/nginx /var/cache/nginx
chown www-data:www-data /var/log/nginx 2>/dev/null || true

ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
command -v apt-mark >/dev/null 2>&1 && apt-mark hold nginx-custom || true
POSTINST
  chmod 755 "$postinst"

  cat > "$postrm" <<'POSTRM'
#!/bin/sh
set -e

command -v apt-mark >/dev/null 2>&1 && apt-mark unhold nginx-custom 2>/dev/null || true
rm -f /etc/logrotate.d/nginx-custom
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
POSTRM
  chmod 755 "$postrm"

  local deb_file="$PACKAGE_DIR/nginx-custom_${NGINX_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         nginx-custom \
    --version      "$NGINX_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Nginx $NGINX_VERSION – custom build (SSL/HTTP2/HTTP3+Brotli/GeoIP2/Stream, OpenSSL ${OPENSSL_VERSION})" \
    --depends      libssl3 \
    --depends      libpcre2-8-0 \
    --depends      zlib1g \
    --depends      libgd3 \
    --depends      "libmaxminddb0 | libmaxminddb0t64" \
    --depends      libxslt1.1 \
    --depends      libxml2 \
    --depends      "libbrotli1 | libbrotli1t64" \
    --depends      "libgoogle-perftools4 | libgoogle-perftools4t64" \
    --conflicts    nginx \
    --conflicts    nginx-core \
    --conflicts    nginx-full \
    --conflicts    nginx-light \
    --provides     nginx \
    --replaces     nginx \
    --deb-no-default-config-files \
    --after-install  "$postinst" \
    --after-remove   "$postrm" \
    --force \
    --package      "$deb_file" \
    --chdir        "$STAGE_NGINX" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"

  log "Paketinhalt-Verifikation:"
  dpkg-deb --contents "$deb_file" | awk '{print $NF}' \
    | grep -E "(nginx$|\.so)" \
    | sort | tee -a "$LOG_FILE" || true

  echo ""
  log "===== Paket fertig ====="
  find "$deb_file" -maxdepth 0 -printf "%s bytes %p\n" | tee -a "$LOG_FILE"
  echo ""
  echo "HINWEIS: /etc/nginx ist NICHT im Paket."
  echo "         Konfiguration wird durch 'backup' / 'restore' verwaltet."
  echo ""
  local repo_script
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  if [ -x "$repo_script" ]; then
    log "Aktualisiere lokales Repository..."
    "$repo_script" update || true
  fi

  echo "Nächster Schritt: $0 install"
}

verify_build() {
  echo ""
  echo "=============================================="
  echo " Nginx Modul-Verifikation"
  echo "=============================================="

  if command -v nginx >/dev/null 2>&1; then
    echo ""
    echo "--- Version ---"
    nginx -V 2>&1 || true

    echo ""
    echo "--- Konfigurationstest ---"
    nginx -t 2>&1 || true
  else
    echo "nginx-Binary nicht gefunden – Nginx noch nicht installiert"
  fi
  echo "=============================================="
}

install_packages() {
  local deb_file
  deb_file=$(find "$PACKAGE_DIR" -maxdepth 1 -name "nginx-custom_*.deb" 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$deb_file" ] || die "Kein nginx-custom.deb in $PACKAGE_DIR – bitte zuerst: $0 package"

  if [ ! -f /etc/nginx/nginx.conf ]; then
    log "WARNUNG: /etc/nginx/nginx.conf nicht gefunden!"
    read -r -p "Trotzdem fortfahren? (ja/nein): " antwort
    [ "$antwort" = "ja" ] || die "Abgebrochen"
  fi

  if dpkg-deb --contents "$deb_file" 2>/dev/null | awk '{print $NF}' | grep -q "^\./etc/nginx"; then
    die "FEHLER: $deb_file enthält /etc/nginx – Paket neu erstellen!"
  fi

  log "Installiere: $(basename "$deb_file")"
  dpkg -i "$deb_file"

  apt-get install -f -y || true

  log "Konfiguration in /etc/nginx: unverändert"
}

restart_service() {
  log "Starte Nginx neu"
  systemctl daemon-reload
  systemctl enable nginx
  systemctl restart nginx
}

post_checks() {
  log "Prüfe Installation"
  command -v nginx >/dev/null 2>&1 || die "nginx-Binary nicht gefunden"
  log "Nginx Version: $(nginx -v 2>&1)"

  log "Konfigurationscheck (nginx -t)"
  nginx -t >> "$LOG_FILE" 2>&1 \
    || log "WARNUNG: Konfigurationsfehler – Log prüfen: $LOG_FILE"

  if ! systemctl is-active --quiet nginx; then
    systemctl status nginx --no-pager || true
    die "Nginx läuft nicht"
  fi

  verify_build

  log "Installation abgeschlossen"
}

restore_from_backup() {
  local backup_dir="${1:-$LATEST_LINK}"
  [ -L "$backup_dir" ] && backup_dir="$(readlink -f "$backup_dir")"
  [ -d "$backup_dir" ] || die "Backup nicht gefunden: $backup_dir"
  log "Restore aus: $backup_dir"

  systemctl stop nginx 2>/dev/null || true

  if dpkg -s nginx-custom >/dev/null 2>&1; then
    log "Deinstalliere nginx-custom"
    dpkg -r nginx-custom || true
  fi

  if [ -d "$backup_dir/etc_nginx" ]; then
    rm -rf /etc/nginx
    cp -a "$backup_dir/etc_nginx" /etc/nginx
    chmod 755 /etc/nginx
    log "/etc/nginx wiederhergestellt"
  fi

  [ -f "$backup_dir/usr_sbin_nginx" ] && {
    cp -a "$backup_dir/usr_sbin_nginx" /usr/sbin/nginx
    chmod 755 /usr/sbin/nginx
  }
  [ -d "$backup_dir/usr_lib_nginx" ] && {
    rm -rf /usr/lib/nginx
    cp -a "$backup_dir/usr_lib_nginx" /usr/lib/nginx
  }

  [ -f "$backup_dir/nginx.service" ] && {
    cp -a "$backup_dir/nginx.service" /lib/systemd/system/nginx.service
    chmod 644 /lib/systemd/system/nginx.service
  }

  if [ -f "$backup_dir/packages.txt" ] && [ -s "$backup_dir/packages.txt" ]; then
    log "Stelle apt-Pakete wieder her"
    apt-get update -qq || true
    xargs -r apt-get install --reinstall -y < "$backup_dir/packages.txt" || true
  fi

  systemctl daemon-reload
  systemctl enable nginx
  systemctl restart nginx || true

  log "Restore abgeschlossen"
}

status_cmd() {
  echo "=============================================="
  echo " Nginx Status – $(date)"
  echo "=============================================="

  if command -v nginx >/dev/null 2>&1; then
    echo "Binary  : $(command -v nginx)"
    echo "Version : $(nginx -v 2>&1)"
  else
    echo "Nginx-Binary: NICHT GEFUNDEN"
  fi

  echo ""
  echo "--- Installiertes Custom-Paket ---"
  if dpkg -s nginx-custom >/dev/null 2>&1; then
    echo "  [OK] nginx-custom $(dpkg -s nginx-custom | awk '/^Version:/{print $2}')"
  else
    echo "  [--] nginx-custom nicht installiert"
  fi

  echo ""
  echo "--- systemctl status nginx ---"
  systemctl status nginx --no-pager || true

  echo ""
  if [ -L "$LATEST_LINK" ] || [ -d "$LATEST_LINK" ]; then
    echo "Letztes Backup: $(readlink -f "$LATEST_LINK" 2>/dev/null || echo "$LATEST_LINK")"
  else
    echo "Kein Backup vorhanden"
  fi

  echo ""
  echo "--- Verfügbare .deb-Pakete ---"
  if [ -d "$PACKAGE_DIR" ]; then
    find "$PACKAGE_DIR" -maxdepth 1 -name "*.deb" -printf "%s bytes %p\n" 2>/dev/null || echo "(keine Pakete erzeugt)"
  fi
}

list_backups() {
  echo "Verfügbare Backups in $BACKUP_ROOT:"
  [ -d "$BACKUP_ROOT" ] \
    && find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort \
    || echo "(kein Backup-Verzeichnis)"
}

check_config() {
  log "Konfigurationscheck"
  nginx -t || die "Konfigurationsfehler"
}

uninstall_cmd() {
  log "Deinstalliere nginx-custom"
  systemctl stop nginx 2>/dev/null || true
  if dpkg -s nginx-custom >/dev/null 2>&1; then
    dpkg -r nginx-custom
    log "nginx-custom entfernt"
  else
    log "nginx-custom war nicht installiert"
  fi
}

package_all() {
  log "=== Starte Nginx Paket-Build ==="
  install_build_deps
  prepare_sources
  prepare_openssl
  download_third_party_modules
  build_nginx
  create_deb_package
  log "=== Paket-Build abgeschlossen ==="
  echo ""
  local repo_script
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  if [ -x "$repo_script" ]; then
    log "Aktualisiere lokales Repository..."
    "$repo_script" update || true
  fi

  echo "Nächster Schritt: $0 install"
}

install_all() {
  log "=== Starte Installation ==="
  log "Schritt 1/4: Backup erstellen"
  create_backup
  log "Schritt 2/4: Paket installieren (/etc/nginx bleibt unberührt)"
  install_packages
  log "Schritt 3/4: Nginx neu starten"
  restart_service
  log "Schritt 4/4: Verifikation"
  post_checks
  log "=== Installation abgeschlossen ==="
  echo ""
  echo "Zusammenfassung:"
  echo "  Backup:        $LATEST_LINK"
  echo "  Paket:         $PACKAGE_DIR"
  echo "  Konfiguration: /etc/nginx  (UNVERÄNDERT)"
  echo "  Log:           $LOG_FILE"
}

check_os_arch() {
  local os_id
  local os_version_id
  local os_major_version
  local arch

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
    echo "FEHLER: Dieses Skript unterstützt nur Ubuntu 24.04 (oder neuer) auf arm64." >&2
    exit 1
  fi

}

main() {
  check_os_arch

  local use_screen=0
  local args=()
  for arg in "$@"; do
    [ "$arg" = "--screen" ] && use_screen=1 || args+=("$arg")
  done
  set -- "${args[@]+"${args[@]}"}"

  require_root

  if [ "$use_screen" -eq 1 ]; then
    if ! command -v screen >/dev/null 2>&1; then
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y screen
    fi
    echo "Starte Skript in Screen Session: nginx_build ..."
    exec screen -dmS nginx_build bash "$0" "$@"
  fi

  mkdir -p "$BACKUP_ROOT" "$PACKAGE_DIR"
  touch "$LOG_FILE"

  case "${1:-help}" in
    package)        package_all ;;
    install)        install_all ;;
    backup)         create_backup ;;
    restore)        restore_from_backup "${2:-$LATEST_LINK}" ;;
    status)         status_cmd ;;
    list-backups)   list_backups ;;
    check-config)   check_config ;;
    uninstall)      uninstall_cmd ;;
    verify)         verify_build ;;
    help|-h|--help) usage ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
