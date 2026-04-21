#!/usr/bin/env bash
# ==============================================================================
# setup_nginx.sh – Nginx Build-from-Source + .deb-Paketerstellung
# Zielumgebung : Ubuntu 24.04 ARM64, ISPConfig
#
# Nginx baut mit klassischem ./configure && make && make install
# OpenSSL wird aus Source gebaut (fuer HTTP/3 QUIC-Support)
#
# Alle Third-Party-Module werden als DYNAMISCHE Module gebaut
# (--add-dynamic-module=) und als separate .deb-Pakete verpackt,
# analog zum Ondrej Surry PPA (ppa:ondrej/nginx).
#
# Paketstruktur:
#   nginx-custom_VERSION_arch.deb          – Core-Binary + eingebaute Module
#   libnginx-mod-http-brotli_VERSION_arch.deb
#   libnginx-mod-http-cache-purge_VERSION_arch.deb
#   ... (siehe THIRD_PARTY_MODULES unten)
#
# Empfohlener Ablauf:
#   1. setup_nginx.sh package   → .deb-Pakete erstellen (KEIN install)
#   2. setup_nginx.sh install   → Backup + dpkg -i
#
# Konfiguration:
#   /etc/nginx/ wird NICHT in die Pakete gepackt → ISPConfig-Configs bleiben
#
# Deinstallation:
#   setup_nginx.sh uninstall
#   oder: dpkg -r libnginx-mod-* nginx-custom
# ==============================================================================
set -Eeuo pipefail

if [[ ! -f "setup_nginx.env" ]]; then
  echo "FEHLER: setup_nginx.env nicht gefunden. Bitte aus setup_nginx.env.example erstellen." >&2
  exit 1
fi
source "setup_nginx.env"

NGINX_TARBALL_URL="https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
OPENSSL_TARBALL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"

# ------------------------------------------------------------------------------
# Third-Party-Module – als assoziative Arrays
#
# Jedes Modul wird als DYNAMISCHES Modul gebaut und bekommt ein eigenes .deb.
# Die Reihenfolge in THIRD_PARTY_MODULES ist wichtig: ndk VOR lua (Abhaengigkeit).
#
# MOD_GITURL     – Git-Repository-URL
# MOD_GITREF     – Branch oder Tag (git clone --branch)
# MOD_DIRNAME    – Verzeichnisname unter $BUILD_ROOT/nginx-modules/
# MOD_PKGNAME    – .deb-Paketname (entspricht PPA-Namenskonvention)
# MOD_SOFILES    – Leerzeichen-getrennte Liste der .so-Dateien
# MOD_DESC       – Kurzbeschreibung fuer das Paket
# MOD_LOADCONF   – Name der .conf-Datei in /usr/share/nginx/modules-available/
# MOD_EXTRADEPS  – Zusaetzliche Paket-Abhaengigkeiten (Leerzeichen-getrennt)
# MOD_NEEDS_SUBMODULE – "yes" wenn git submodule update --init noetig ist
# ------------------------------------------------------------------------------
declare -A MOD_GITURL MOD_GITREF MOD_DIRNAME MOD_PKGNAME MOD_SOFILES \
           MOD_DESC MOD_LOADCONF MOD_EXTRADEPS MOD_NEEDS_SUBMODULE

# --- 1. NDK (Nginx Development Kit) – Basis fuer lua u.a. -------------------
MOD_DIRNAME[ndk]="ngx_devel_kit"
MOD_GITURL[ndk]="https://github.com/vision5/ngx_devel_kit.git"
MOD_GITREF[ndk]="v0.3.3"
MOD_PKGNAME[ndk]="libnginx-mod-http-ndk"
MOD_SOFILES[ndk]="ndk_module.so"
MOD_DESC[ndk]="Nginx Development Kit (Basis fuer lua u.a.)"
MOD_LOADCONF[ndk]="mod-http-ndk"
MOD_EXTRADEPS[ndk]="nginx-custom"
MOD_NEEDS_SUBMODULE[ndk]="no"

# --- 2. Brotli Compression ---------------------------------------------------
MOD_DIRNAME[brotli]="ngx_brotli"
MOD_GITURL[brotli]="https://github.com/google/ngx_brotli.git"
MOD_GITREF[brotli]="master"
MOD_PKGNAME[brotli]="libnginx-mod-http-brotli"
MOD_SOFILES[brotli]="ngx_http_brotli_filter_module.so ngx_http_brotli_static_module.so"
MOD_DESC[brotli]="HTTP Brotli compression (filter + static)"
MOD_LOADCONF[brotli]="mod-http-brotli"
MOD_EXTRADEPS[brotli]="nginx-custom libbrotli1"
MOD_NEEDS_SUBMODULE[brotli]="yes"

# --- 3. Headers More Filter --------------------------------------------------
MOD_DIRNAME[headers-more]="headers-more-nginx-module"
MOD_GITURL[headers-more]="https://github.com/openresty/headers-more-nginx-module.git"
MOD_GITREF[headers-more]="v0.37"
MOD_PKGNAME[headers-more]="libnginx-mod-http-headers-more-filter"
MOD_SOFILES[headers-more]="ngx_http_headers_more_filter_module.so"
MOD_DESC[headers-more]="Set/clear/add HTTP headers"
MOD_LOADCONF[headers-more]="mod-http-headers-more-filter"
MOD_EXTRADEPS[headers-more]="nginx-custom"
MOD_NEEDS_SUBMODULE[headers-more]="no"

# --- 4. Cache Purge ----------------------------------------------------------
MOD_DIRNAME[cache-purge]="ngx_cache_purge"
MOD_GITURL[cache-purge]="https://github.com/FRiCKLE/ngx_cache_purge.git"
MOD_GITREF[cache-purge]="master"
MOD_PKGNAME[cache-purge]="libnginx-mod-http-cache-purge"
MOD_SOFILES[cache-purge]="ngx_http_cache_purge_module.so"
MOD_DESC[cache-purge]="Cache content purging"
MOD_LOADCONF[cache-purge]="mod-http-cache-purge"
MOD_EXTRADEPS[cache-purge]="nginx-custom"
MOD_NEEDS_SUBMODULE[cache-purge]="no"

# --- 5. Auth PAM -------------------------------------------------------------
MOD_DIRNAME[auth-pam]="ngx_http_auth_pam_module"
MOD_GITURL[auth-pam]="https://github.com/sto/ngx_http_auth_pam_module.git"
MOD_GITREF[auth-pam]="v1.5.3"
MOD_PKGNAME[auth-pam]="libnginx-mod-http-auth-pam"
MOD_SOFILES[auth-pam]="ngx_http_auth_pam_module.so"
MOD_DESC[auth-pam]="PAM authentication"
MOD_LOADCONF[auth-pam]="mod-http-auth-pam"
MOD_EXTRADEPS[auth-pam]="nginx-custom libpam0g"
MOD_NEEDS_SUBMODULE[auth-pam]="no"

# --- 6. DAV Ext --------------------------------------------------------------
MOD_DIRNAME[dav-ext]="nginx-dav-ext-module"
MOD_GITURL[dav-ext]="https://github.com/arut/nginx-dav-ext-module.git"
MOD_GITREF[dav-ext]="v3.0.0"
MOD_PKGNAME[dav-ext]="libnginx-mod-http-dav-ext"
MOD_SOFILES[dav-ext]="ngx_http_dav_ext_module.so"
MOD_DESC[dav-ext]="WebDAV extensions (PROPFIND, OPTIONS, LOCK, UNLOCK)"
MOD_LOADCONF[dav-ext]="mod-http-dav-ext"
MOD_EXTRADEPS[dav-ext]="nginx-custom libexpat1"
MOD_NEEDS_SUBMODULE[dav-ext]="no"

# --- 7. Echo -----------------------------------------------------------------
MOD_DIRNAME[echo]="echo-nginx-module"
MOD_GITURL[echo]="https://github.com/openresty/echo-nginx-module.git"
MOD_GITREF[echo]="v0.63"
MOD_PKGNAME[echo]="libnginx-mod-http-echo"
MOD_SOFILES[echo]="ngx_http_echo_module.so"
MOD_DESC[echo]="Echo, sleep, time, exec and more (debug helper)"
MOD_LOADCONF[echo]="mod-http-echo"
MOD_EXTRADEPS[echo]="nginx-custom"
MOD_NEEDS_SUBMODULE[echo]="no"

# --- 8. Fancy Index ----------------------------------------------------------
MOD_DIRNAME[fancyindex]="ngx-fancyindex"
MOD_GITURL[fancyindex]="https://github.com/aperezdc/ngx-fancyindex.git"
MOD_GITREF[fancyindex]="v0.5.2"
MOD_PKGNAME[fancyindex]="libnginx-mod-http-fancyindex"
MOD_SOFILES[fancyindex]="ngx_http_fancyindex_module.so"
MOD_DESC[fancyindex]="Fancy directory listings"
MOD_LOADCONF[fancyindex]="mod-http-fancyindex"
MOD_EXTRADEPS[fancyindex]="nginx-custom"
MOD_NEEDS_SUBMODULE[fancyindex]="no"

# --- 9. GeoIP2 ---------------------------------------------------------------
MOD_DIRNAME[geoip2]="ngx_http_geoip2_module"
MOD_GITURL[geoip2]="https://github.com/leev/ngx_http_geoip2_module.git"
MOD_GITREF[geoip2]="3.4"
MOD_PKGNAME[geoip2]="libnginx-mod-http-geoip2"
MOD_SOFILES[geoip2]="ngx_http_geoip2_module.so ngx_stream_geoip2_module.so"
MOD_DESC[geoip2]="GeoIP2 lookup (MaxMind libmaxminddb, HTTP + Stream)"
MOD_LOADCONF[geoip2]="mod-http-geoip2"
MOD_EXTRADEPS[geoip2]="nginx-custom libmaxminddb0"
MOD_NEEDS_SUBMODULE[geoip2]="no"

# --- 10. Substitutions Filter ------------------------------------------------
MOD_DIRNAME[subs-filter]="ngx_http_substitutions_filter_module"
MOD_GITURL[subs-filter]="https://github.com/yaoweibin/ngx_http_substitutions_filter_module.git"
MOD_GITREF[subs-filter]="master"
MOD_PKGNAME[subs-filter]="libnginx-mod-http-subs-filter"
MOD_SOFILES[subs-filter]="ngx_http_subs_filter_module.so"
MOD_DESC[subs-filter]="Regular expression substitutions in response bodies"
MOD_LOADCONF[subs-filter]="mod-http-subs-filter"
MOD_EXTRADEPS[subs-filter]="nginx-custom"
MOD_NEEDS_SUBMODULE[subs-filter]="no"

# --- 11. Upload Progress -----------------------------------------------------
MOD_DIRNAME[uploadprogress]="nginx-upload-progress-module"
MOD_GITURL[uploadprogress]="https://github.com/masterzen/nginx-upload-progress-module.git"
MOD_GITREF[uploadprogress]="v0.9.4"
MOD_PKGNAME[uploadprogress]="libnginx-mod-http-uploadprogress"
MOD_SOFILES[uploadprogress]="ngx_http_uploadprogress_module.so"
MOD_DESC[uploadprogress]="Upload progress tracking"
MOD_LOADCONF[uploadprogress]="mod-http-uploadprogress"
MOD_EXTRADEPS[uploadprogress]="nginx-custom"
MOD_NEEDS_SUBMODULE[uploadprogress]="no"

# --- 12. Upstream Fair -------------------------------------------------------
MOD_DIRNAME[upstream-fair]="nginx-upstream-fair"
MOD_GITURL[upstream-fair]="https://github.com/gnosek/nginx-upstream-fair.git"
MOD_GITREF[upstream-fair]="master"
MOD_PKGNAME[upstream-fair]="libnginx-mod-http-upstream-fair"
MOD_SOFILES[upstream-fair]="ngx_http_upstream_fair_module.so"
MOD_DESC[upstream-fair]="Fair upstream load balancing"
MOD_LOADCONF[upstream-fair]="mod-http-upstream-fair"
MOD_EXTRADEPS[upstream-fair]="nginx-custom"
MOD_NEEDS_SUBMODULE[upstream-fair]="no"

# --- 13. Nchan (Pub/Sub WebSocket) -------------------------------------------
MOD_DIRNAME[nchan]="nchan"
MOD_GITURL[nchan]="https://github.com/slact/nchan.git"
MOD_GITREF[nchan]="v1.3.7"
MOD_PKGNAME[nchan]="libnginx-mod-nchan"
MOD_SOFILES[nchan]="ngx_nchan_module.so"
MOD_DESC[nchan]="Pub/Sub messaging via WebSocket, Long-Poll, EventSource"
MOD_LOADCONF[nchan]="mod-nchan"
MOD_EXTRADEPS[nchan]="nginx-custom"
MOD_NEEDS_SUBMODULE[nchan]="no"

# --- 14. RTMP Streaming ------------------------------------------------------
MOD_DIRNAME[rtmp]="nginx-rtmp-module"
MOD_GITURL[rtmp]="https://github.com/arut/nginx-rtmp-module.git"
MOD_GITREF[rtmp]="v1.2.2"
MOD_PKGNAME[rtmp]="libnginx-mod-rtmp"
MOD_SOFILES[rtmp]="ngx_rtmp_module.so"
MOD_DESC[rtmp]="RTMP/HLS/MPEG-DASH live streaming"
MOD_LOADCONF[rtmp]="mod-rtmp"
MOD_EXTRADEPS[rtmp]="nginx-custom"
MOD_NEEDS_SUBMODULE[rtmp]="no"

# --- 15. Lua (benoetigt NDK + LuaJIT) ----------------------------------------
MOD_DIRNAME[lua]="lua-nginx-module"
MOD_GITURL[lua]="https://github.com/openresty/lua-nginx-module.git"
MOD_GITREF[lua]="v0.10.27"
MOD_PKGNAME[lua]="libnginx-mod-http-lua"
MOD_SOFILES[lua]="ngx_http_lua_module.so"
MOD_DESC[lua]="Embed Lua into Nginx (requires NDK + LuaJIT)"
MOD_LOADCONF[lua]="mod-http-lua"
MOD_EXTRADEPS[lua]="nginx-custom libnginx-mod-http-ndk libluajit-5.1-2"
MOD_NEEDS_SUBMODULE[lua]="no"

# --- 16. VHost Traffic Status (Extra, nicht im PPA) --------------------------
MOD_DIRNAME[vts]="nginx-module-vts"
MOD_GITURL[vts]="https://github.com/vozlt/nginx-module-vts.git"
MOD_GITREF[vts]="v0.2.3"
MOD_PKGNAME[vts]="libnginx-mod-http-vts"
MOD_SOFILES[vts]="ngx_http_vhost_traffic_status_module.so"
MOD_DESC[vts]="Virtual host traffic status monitoring"
MOD_LOADCONF[vts]="mod-http-vts"
MOD_EXTRADEPS[vts]="nginx-custom"
MOD_NEEDS_SUBMODULE[vts]="no"

# --- 17. HTTP Shibboleth (Extra, nicht im PPA) -------------------------------
MOD_DIRNAME[http-shibboleth]="ngx_http_shibboleth"
MOD_GITURL[http-shibboleth]="https://github.com/nginx-shib/nginx-http-shibboleth.git"
MOD_GITREF[http-shibboleth]="master"
MOD_PKGNAME[http-shibboleth]="libnginx-mod-http-shibboleth"
MOD_SOFILES[http-shibboleth]="ngx_http_shibboleth_module.so"
MOD_DESC[http-shibboleth]="Shibboleth SSO authentication via FastCGI"
MOD_LOADCONF[http-shibboleth]="mod-http-shibboleth"
MOD_EXTRADEPS[http-shibboleth]="nginx-custom"
MOD_NEEDS_SUBMODULE[http-shibboleth]="no"

# --- 18. HTTP Perl (embedded Perl interpreter) --------------------------------
MOD_DIRNAME[http-perl]="ngx_http_perl_module"
MOD_GITURL[http-perl]="built-in"
MOD_GITREF[http-perl]="built-in"
MOD_PKGNAME[http-perl]="libnginx-mod-http-perl"
MOD_SOFILES[http-perl]="ngx_http_perl_module.so"
MOD_DESC[http-perl]="Embedded Perl interpreter"
MOD_LOADCONF[http-perl]="mod-http-perl"
MOD_EXTRADEPS[http-perl]="nginx-custom libperl5.38"
MOD_NEEDS_SUBMODULE[http-perl]="no"

# Module in Build-Reihenfolge (ndk VOR lua, da lua von ndk abhaengt)
THIRD_PARTY_MODULES=(
  ndk
  brotli
  headers-more
  cache-purge
  auth-pam
  dav-ext
  echo
  fancyindex
  geoip2
  subs-filter
  uploadprogress
  upstream-fair
  nchan
  rtmp
  lua
  vts
  http-shibboleth
  http-perl
)

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
die()  { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausfuehren."
}

version_ge() {
  # usage: version_ge "1.30.0" "1.25.0"  => true
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

module_skip_reason() {
  local mod="$1"

  # nginx-upstream-fair nutzt alte Nginx-API (u.a. default_port) und baut
  # gegen aktuelle Nginx-Versionen nicht mehr.
  if [ "$mod" = "upstream-fair" ] && version_ge "$NGINX_VERSION" "1.25.0"; then
    echo "inkompatibel mit Nginx >= 1.25 (upstream API aenderte sich)"
    return 0
  fi

  return 1
}

update_local_repo_if_configured() {
  local repo_script repo_env
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  repo_env="$(dirname "$0")/setup_local_repo.env"
  local repo_env_example
  repo_env_example="$(dirname "$0")/setup_local_repo.env.example"
  local repo_dir=""

  if [ ! -x "$repo_script" ]; then
    return 0
  fi
  if [ ! -f "$repo_env" ] && [ -f "$repo_env_example" ]; then
    cp -n "$repo_env_example" "$repo_env" 2>/dev/null || true
    log "Lokales Repo-Env erstellt: $(basename "$repo_env") (aus .example)"
  fi
  if [ ! -f "$repo_env" ]; then
    log "Lokales Repository-Update uebersprungen: $(basename "$repo_env") fehlt"
    return 0
  fi

  repo_dir="$(
    (
      set +u
      # shellcheck disable=SC1090
      source "$repo_env" 2>/dev/null || true
      printf '%s' "${REPO_DIR:-}"
    )
  )"
  if [ -z "$repo_dir" ]; then
    log "Lokales Repository-Update uebersprungen: REPO_DIR ist nicht gesetzt"
    return 0
  fi
  if [ ! -d "$repo_dir" ]; then
    log "Lokales Repository-Update uebersprungen: REPO_DIR existiert nicht ($repo_dir)"
    return 0
  fi

  log "Aktualisiere lokales Repository..."
  "$repo_script" update || true
}

usage() {
  cat <<'EOF'
Verwendung:
  setup_nginx.sh [--screen] <Befehl>

Optionen:
  --screen         Skript in einer GNU Screen Session ausfuehren (optional)

Befehle:
  package          – Alle Quellen laden, bauen, .deb-Pakete erstellen (KEIN install)
  install          – Backup + dpkg -i aller erzeugten .deb-Pakete
  backup           – Nur Backup erstellen
  restore          – Letztes Backup einspielen
  restore /root/nginx-backup/<timestamp>
  status           – Zustand + installierte Module/Pakete anzeigen
  list-backups     – Verfügbare Backups auflisten
  check-config     – nginx -t ausfuehren
  uninstall        – Alle Custom-Pakete via dpkg -r entfernen
  verify           – Modul-Verifikation (nach Installation)
  list-modules     – Verfügbare Third-Party-Module auflisten

Deinstallation manuell:
  dpkg -r libnginx-mod-http-brotli libnginx-mod-http-ndk ... nginx-custom

Modul aktivieren (Beispiel):
  In /etc/nginx/nginx.conf ganz oben (vor events {}):
    include /usr/share/nginx/modules-available/mod-http-brotli.conf;
EOF
}

# ------------------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Build-Abhaengigkeiten
# ------------------------------------------------------------------------------
install_build_deps() {
  log "Installiere Build-Abhaengigkeiten"

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
    libpam0g-dev \
    libexpat1-dev \
    libluajit-5.1-dev \
    libperl-dev \
    ruby ruby-dev rubygems rpm \
    wget curl git

  # Paketsignierung ist optional: dpkg-sig bevorzugen, debsigs als Fallback.
  if apt-cache show dpkg-sig >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-sig || true
  elif apt-cache show debsigs >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y debsigs || true
  else
    log "Kein Paketsignierungs-Tool in den Repos gefunden – Signierung wird bei Bedarf uebersprungen"
  fi

  if ! command -v fpm >/dev/null 2>&1; then
    log "Installiere fpm"
    gem install --no-document fpm
  else
    log "fpm bereits vorhanden: $(fpm --version)"
  fi
}

# ------------------------------------------------------------------------------
# Quellen: Nginx Tarball
# ------------------------------------------------------------------------------
prepare_sources() {
  mkdir -p "$BUILD_ROOT"
  cd "$BUILD_ROOT"
  rm -rf "nginx-${NGINX_VERSION}"

  local ng_tar
  ng_tar="$BUILD_ROOT/nginx-${NGINX_VERSION}.tar.gz"

  if [ ! -f "$ng_tar" ]; then
    log "Lade Nginx $NGINX_VERSION Tarball"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar \
      "$NGINX_TARBALL_URL" -o "$ng_tar" \
      || die "Download Nginx Tarball fehlgeschlagen"
  else
    log "Nginx Tarball bereits vorhanden: $ng_tar"
  fi

  tar xzf "$ng_tar"
  [ -d "$BUILD_ROOT/nginx-${NGINX_VERSION}" ] \
    || die "Tarball entpackt kein Verzeichnis nginx-${NGINX_VERSION}"
  log "Quellen: $BUILD_ROOT/nginx-${NGINX_VERSION}"
}

# ------------------------------------------------------------------------------
# Quellen: OpenSSL
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Quellen: Third-Party-Module via git clone
# ------------------------------------------------------------------------------
download_third_party_modules() {
  local modules_dir="$BUILD_ROOT/nginx-modules"
  mkdir -p "$modules_dir"

  for mod in "${THIRD_PARTY_MODULES[@]}"; do
    local dirname="${MOD_DIRNAME[$mod]}"
    local giturl="${MOD_GITURL[$mod]}"
    local gitref="${MOD_GITREF[$mod]}"
    local target="$modules_dir/$dirname"
    local skip_reason=""

    if skip_reason="$(module_skip_reason "$mod")"; then
      log "  [SKIP] $dirname – $skip_reason"
      continue
    fi

    [ "$giturl" = "built-in" ] && continue

    if [ -d "$target" ]; then
      log "  [OK] $dirname bereits vorhanden"
      continue
    fi

    log "Lade $dirname ($gitref)"
    local clone_rc=0
    if [ "$gitref" = "master" ]; then
      GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$giturl" "$target" || clone_rc=$?
    else
      GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$gitref" "$giturl" "$target" || clone_rc=$?
    fi

    # Legacy fallback fuer upstream-fair (einige alte URLs triggern GitHub Auth-Prompt/404).
    if [ "$clone_rc" -ne 0 ] && [ "$mod" = "upstream-fair" ]; then
      rm -rf "$target"
      local fallback_url="https://github.com/gnosek/nginx-upstream-fair-module.git"
      log "  [WARN] $dirname Clone fehlgeschlagen ueber primäre URL, versuche Fallback..."
      clone_rc=0
      if [ "$gitref" = "master" ]; then
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$fallback_url" "$target" || clone_rc=$?
      else
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$gitref" "$fallback_url" "$target" || clone_rc=$?
      fi
    fi

    if [ "$clone_rc" -ne 0 ]; then
      log "  [WARN] $dirname konnte nicht geklont werden (ohne Login-Prompt). Modul wird uebersprungen."
      rm -rf "$target"
      continue
    fi

    if [ "${MOD_NEEDS_SUBMODULE[$mod]}" = "yes" ]; then
      log "Initialisiere Submodules fuer $dirname"
      (cd "$target" && GIT_TERMINAL_PROMPT=0 git submodule update --init)
    fi

    log "  [OK] $dirname geklont"
  done
}

# ------------------------------------------------------------------------------
# ./configure Argumente zusammenbauen
#
# Alle Third-Party-Module werden mit --add-dynamic-module= gebaut,
# damit sie als .so-Dateien vorliegen und separat verpackt werden koennen.
# --with-compat ist PFLICHT fuer dynamische Module.
# ------------------------------------------------------------------------------
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

  CC_OPT="-fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wno-implicit-function-declaration"
  LD_OPT="-Wl,-z,relro -Wl,-z,now -pie"

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
    log "  [+] GeoIP (nginx built-in, legacy)"
    CONF_ARGS="$CONF_ARGS --with-http_geoip_module=dynamic"
  else
    log "  [-] libmaxminddb nicht gefunden (GeoIP deaktiviert)"
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

  # --- Third-Party-Module als DYNAMISCHE Module -------------------------------
  local modules_dir="$BUILD_ROOT/nginx-modules"
  local mod_count=0

  for mod in "${THIRD_PARTY_MODULES[@]}"; do
    local dirname="${MOD_DIRNAME[$mod]}"
    local target="$modules_dir/$dirname"
    local giturl="${MOD_GITURL[$mod]}"
    local skip_reason=""

    if skip_reason="$(module_skip_reason "$mod")"; then
      log "  [SKIP] Dynamic: ${MOD_PKGNAME[$mod]} – $skip_reason"
      continue
    fi

    if [ "$giturl" = "built-in" ]; then
      continue
    fi

    if [ -d "$target" ]; then
      log "  [+] Dynamic: ${MOD_PKGNAME[$mod]} ($dirname)"
      CONF_ARGS="$CONF_ARGS --add-dynamic-module=$target"
      mod_count=$((mod_count + 1))
    else
      log "  [-] Dynamic: ${MOD_PKGNAME[$mod]} – Quellen nicht gefunden ($target)"
    fi
  done

  # Built-in dynamic modules (nicht via git, sondern in nginx-quellen)
  if pkg-config --exists perl 2>/dev/null || [ -f /usr/include/perl/perl.h ]; then
    log "  [+] Dynamic: libnginx-mod-http-perl (built-in)"
    CONF_ARGS="$CONF_ARGS --with-http_perl_module=dynamic"
    mod_count=$((mod_count + 1))
  else
    log "  [-] Perl nicht gefunden (libperl-dev installieren)"
  fi

  log "  => $mod_count dynamische Third-Party-Module konfiguriert"

  printf '%s' "$CONF_ARGS"
}

# ------------------------------------------------------------------------------
# LuaJIT-Pfade ermitteln (fuer lua-nginx-module)
# ------------------------------------------------------------------------------
detect_luajit_paths() {
  local lj_lib="" lj_inc=""

  if pkg-config --exists luajit 2>/dev/null; then
    lj_lib="$(pkg-config --variable=libdir luajit 2>/dev/null || true)"
    lj_inc="$(pkg-config --variable=includedir luajit 2>/dev/null || true)"
  fi

  if [ -z "$lj_lib" ]; then
    lj_lib="$(find /usr/lib -name 'libluajit*.so' -exec dirname {} \; 2>/dev/null | head -1)"
  fi
  if [ -z "$lj_inc" ]; then
    lj_inc="$(find /usr/include -name 'luajit.h' -exec dirname {} \; 2>/dev/null | head -1)"
  fi

  if [ -n "$lj_lib" ] && [ -n "$lj_inc" ]; then
    log "LuaJIT gefunden: LIB=$lj_lib INC=$lj_inc"
    export LUAJIT_LIB="$lj_lib"
    export LUAJIT_INC="$lj_inc"
  else
    log "WARNUNG: LuaJIT nicht gefunden – lua-nginx-module wird vermutlich fehlschlagen"
    log "         Installieren: apt-get install libluajit-5.1-dev"
  fi
}

# ------------------------------------------------------------------------------
# Nginx bauen: configure + make
# ------------------------------------------------------------------------------
build_nginx() {
  cd "$BUILD_ROOT/nginx-${NGINX_VERSION}"
  log "Baue Nginx $NGINX_VERSION"

  detect_luajit_paths

  local conf_args
  conf_args="$(build_configure_args)"
  local -a conf_args_array=()
  if [ -n "$conf_args" ]; then
    # build_configure_args liefert eine leerzeichengetrennte Argumentliste.
    # Wir splitten sie bewusst in ein Array, damit ./configure jedes Flag separat bekommt.
    read -r -a conf_args_array <<< "$conf_args"
  fi

  log "Configure-Argumente:${conf_args}"
  log "CC_OPT: ${CC_OPT:-}"
  log "LD_OPT: ${LD_OPT:-}"

  log "Fuehre ./configure aus"
  set +e
  ./configure \
    --with-cc-opt="${CC_OPT:-}" \
    --with-ld-opt="${LD_OPT:-}" \
    "${conf_args_array[@]}" 2>&1 | tee -a "$LOG_FILE"
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

# ------------------------------------------------------------------------------
# Staging: make install ins Staging-Verzeichnis
# ------------------------------------------------------------------------------
stage_install() {
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

  log "Staging-Inhalt:"
  find "$STAGE_NGINX" \( -name "nginx" -o -name "*.so" \) -type f 2>/dev/null \
    | sort | tee -a "$LOG_FILE"

  local so_count
  so_count="$(find "$STAGE_NGINX" -name '*.so' -type f 2>/dev/null | wc -l)"
  log "Dynamische Module im Staging: $so_count .so-Dateien"

  if [ "$so_count" -eq 0 ]; then
    log "WARNUNG: Keine .so-Dateien im Staging – pruefe ob --add-dynamic-module korrekt war"
  fi
}

# ------------------------------------------------------------------------------
# Post-Install / Post-Remove Scripts (fuer fpm)
# ------------------------------------------------------------------------------
create_maintainer_scripts() {
  local postinst="/tmp/nginx-core-postinst.sh"
  local postrm="/tmp/nginx-core-postrm.sh"

  cat > "$postinst" <<'POSTINST'
#!/bin/sh
set -e

if ! id -u www-data >/dev/null 2>&1; then
  adduser --system --group --no-create-home \
    --gecos "Web Server" --shell /usr/sbin/nologin www-data 2>/dev/null || true
fi

mkdir -p /var/log/nginx /var/cache/nginx
chown www-data:www-data /var/log/nginx 2>/dev/null || true

mkdir -p /usr/share/nginx/modules-available

# Copy default configs on fresh install
if [ ! -f /etc/nginx/nginx.conf ]; then
  echo "INFO: Keine nginx.conf gefunden – installiere Default-Konfiguration"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/snippets /etc/nginx/conf.d
  cp -a /usr/share/nginx/custom-defaults/nginx.conf /etc/nginx/nginx.conf
  cp -a /usr/share/nginx/custom-defaults/sites-available/default /etc/nginx/sites-available/default
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  cp -a /usr/share/nginx/custom-defaults/snippets/fastcgi-php.conf /etc/nginx/snippets/fastcgi-php.conf
  mkdir -p /var/www/html
  echo "<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>nginx is running (custom build)</h1></body></html>" > /var/www/html/index.html
fi

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
}

create_module_maintainer_scripts() {
  local mod_postinst="/tmp/nginx-mod-postinst.sh"
  local mod_postrm="/tmp/nginx-mod-postrm.sh"

  cat > "$mod_postinst" <<'MODPOSTINST'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
MODPOSTINST
  chmod 755 "$mod_postinst"

  cat > "$mod_postrm" <<'MODPOSTRM'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
MODPOSTRM
  chmod 755 "$mod_postrm"
}

# ------------------------------------------------------------------------------
# SHA256-Checksummen fuer alle erzeugten .deb-Pakete
# ------------------------------------------------------------------------------
generate_checksums() {
  if [ -d "$PACKAGE_DIR" ] && ls "$PACKAGE_DIR"/*.deb >/dev/null 2>&1; then
    log "Erstelle SHA256SUMS fuer Pakete..."
    cd "$PACKAGE_DIR"
    sha256sum ./*.deb > SHA256SUMS
    log "SHA256SUMS erstellt: $(wc -l < SHA256SUMS) Pakete"
    tee -a "$LOG_FILE" < SHA256SUMS
  fi
}

# ------------------------------------------------------------------------------
# .deb-Pakete mit dpkg-sig signieren (optional, benoetigt GPG-Schluessel)
# ------------------------------------------------------------------------------
sign_packages() {
  local sign_tool=""
  if command -v dpkg-sig >/dev/null 2>&1; then
    sign_tool="dpkg-sig"
  elif command -v debsigs >/dev/null 2>&1; then
    sign_tool="debsigs"
  else
    log "Kein Paketsignierungs-Tool installiert – ueberspringe Paketsignierung"
    return 0
  fi

  local gpg_key_id="${GPG_KEY_ID:-}"
  if [ -z "$gpg_key_id" ]; then
    gpg_key_id="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/{print $5}' | head -1)" || true
  fi

  if [ -z "$gpg_key_id" ]; then
    log "Kein GPG-Schluessel gefunden – ueberspringe Paketsignierung"
    return 0
  fi

  log "Signiere .deb-Pakete mit $sign_tool (GPG-Schluessel $gpg_key_id)..."
  local sign_count=0
  local sign_fail=0
  for deb in "$PACKAGE_DIR"/*.deb; do
    [ -f "$deb" ] || continue

    if [ "$sign_tool" = "dpkg-sig" ]; then
      if dpkg-sig --verify "$deb" 2>/dev/null | grep -q "GOODSIG"; then
        continue
      fi
      if dpkg-sig -k "$gpg_key_id" --sign builder "$deb" >/dev/null 2>&1; then
        sign_count=$((sign_count + 1))
      else
        sign_fail=$((sign_fail + 1))
      fi
    elif debsigs --sign=origin --default-key="$gpg_key_id" "$deb" >/dev/null 2>&1; then
      sign_count=$((sign_count + 1))
    else
      sign_fail=$((sign_fail + 1))
    fi
  done
  log "$sign_count Pakete signiert, $sign_fail fehlgeschlagen"
}

# ------------------------------------------------------------------------------
# .deb-Paket: nginx-custom (Core)
#
# Enthaelt: Binary, systemd unit, logrotate, Hilfsverzeichnisse
# Enthaelt NICHT: /etc/nginx, Third-Party-Module (.so)
# ------------------------------------------------------------------------------
create_core_package() {
  local arch
  arch="$(dpkg --print-architecture)"
  mkdir -p "$PACKAGE_DIR"

  mkdir -p "${STAGE_NGINX}/var/log/nginx"
  mkdir -p "${STAGE_NGINX}/var/cache/nginx"
  mkdir -p "${STAGE_NGINX}/usr/share/nginx/modules-available"

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
LimitNOFILE=65535
ProtectSystem=full
PrivateDevices=true
ProtectHome=true
NoNewPrivileges=true

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

  # Third-Party .so aus dem Core-Staging entfernen – die kommen in eigene Pakete
  local so_staging_dir="${STAGE_NGINX}/usr/lib/nginx/modules"
  if [ -d "$so_staging_dir" ]; then
    local third_party_so_count=0
    for mod in "${THIRD_PARTY_MODULES[@]}"; do
      local so
      for so in ${MOD_SOFILES[$mod]}; do
        if [ -f "$so_staging_dir/$so" ]; then
          log "Verschiebe $so in Modul-Staging"
          rm -f "$so_staging_dir/$so"
          third_party_so_count=$((third_party_so_count + 1))
        fi
      done
    done
    log "$third_party_so_count Third-Party-.so aus Core-Staging entfernt"

    # Verbleibende .so-Dateien (nginx built-in dynamic modules wie geoip) bleiben im Core-Paket
    local remaining_so
    remaining_so="$(find "$so_staging_dir" -name '*.so' -type f 2>/dev/null | wc -l)"
    log "Verbleibende .so im Core-Paket (built-in dynamic): $remaining_so"
  fi

  mkdir -p "${STAGE_NGINX}/usr/share/nginx/custom-defaults"
  mkdir -p "${STAGE_NGINX}/usr/share/nginx/custom-defaults/sites-available"
  mkdir -p "${STAGE_NGINX}/usr/share/nginx/custom-defaults/sites-enabled"
  mkdir -p "${STAGE_NGINX}/usr/share/nginx/custom-defaults/snippets"

  cat > "${STAGE_NGINX}/usr/share/nginx/custom-defaults/nginx.conf" <<'NGINXCONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;

    gzip on;

    include /etc/nginx/sites-enabled/*;
}
NGINXCONF

  cat > "${STAGE_NGINX}/usr/share/nginx/custom-defaults/sites-available/default" <<'DEFAULTSITE'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html index.htm index.php;

    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.5-fpm.sock;
    }
}
DEFAULTSITE

  cat > "${STAGE_NGINX}/usr/share/nginx/custom-defaults/snippets/fastcgi-php.conf" <<'FASTCGI'
fastcgi_split_path_info ^(.+\.php)(/.+)$;
fastcgi_pass unix:/run/php/php8.5-fpm.sock;
fastcgi_index index.php;
include fastcgi_params;
FASTCGI

  create_maintainer_scripts

  mkdir -p "${STAGE_NGINX}/usr/lib/tmpfiles.d"
  cat > "${STAGE_NGINX}/usr/lib/tmpfiles.d/nginx-custom.conf" <<'EOF'
# Nginx runtime directories
d /run/nginx 0710 www-data root -
d /var/cache/nginx 0750 www-data root -
EOF
  log "tmpfiles.d config erstellt"

  mkdir -p "${STAGE_NGINX}/usr/share/man/man8"
  if [ -f "$BUILD_ROOT/nginx-${NGINX_VERSION}/docs/man/nginx.8" ]; then
    cp "$BUILD_ROOT/nginx-${NGINX_VERSION}/docs/man/nginx.8" "${STAGE_NGINX}/usr/share/man/man8/nginx.8"
    gzip -f "${STAGE_NGINX}/usr/share/man/man8/nginx.8" 2>/dev/null || true
  fi

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
    --description  "Nginx $NGINX_VERSION – custom build (SSL/HTTP2/HTTP3/Stream/Mail, OpenSSL ${OPENSSL_VERSION})" \
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
    --conflicts    nginx-common \
    --provides     nginx \
    --provides     nginx-common \
    --replaces     nginx \
    --replaces     nginx-common \
    --deb-no-default-config-files \
    --after-install  "/tmp/nginx-core-postinst.sh" \
    --after-remove   "/tmp/nginx-core-postrm.sh" \
    --force \
    --package      "$deb_file" \
    --chdir        "$STAGE_NGINX" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"

  log "Core-Paket-Inhalt:"
  dpkg-deb --contents "$deb_file" | awk '{print $NF}' \
    | grep -E "(nginx$|\.so|nginx\.service)" \
    | sort | tee -a "$LOG_FILE" || true
}

# ------------------------------------------------------------------------------
# .deb-Pakete: Jeweils ein Paket pro Third-Party-Modul
#
# Struktur pro Paket:
#   /usr/lib/nginx/modules/<modul>.so
#   /usr/share/nginx/modules-available/mod-<name>.conf  (load_module Direktive)
#
# Aktivierung: include in /etc/nginx/nginx.conf:
#   include /usr/share/nginx/modules-available/mod-http-brotli.conf;
# ------------------------------------------------------------------------------
create_module_packages() {
  local arch
  arch="$(dpkg --print-architecture)"

  local so_staging_dir="${STAGE_NGINX}/usr/lib/nginx/modules"
  [ -d "$so_staging_dir" ] || die "Module-Staging nicht gefunden: $so_staging_dir"

  create_module_maintainer_scripts

  local pkg_count=0
  local pkg_fail=0

  for mod in "${THIRD_PARTY_MODULES[@]}"; do
    local pkg_name="${MOD_PKGNAME[$mod]}"
    local so_files="${MOD_SOFILES[$mod]}"
    local desc="${MOD_DESC[$mod]}"
    local loadconf="${MOD_LOADCONF[$mod]}"
    local extra_deps="${MOD_EXTRADEPS[$mod]}"
    local skip_reason=""

    if skip_reason="$(module_skip_reason "$mod")"; then
      log "  [SKIP] $pkg_name – $skip_reason"
      continue
    fi

    log "Erstelle Paket: $pkg_name"

    # Pruefen ob mindestens eine .so-Datei existiert
    local found_any=0
    for so in $so_files; do
      if [ -f "$so_staging_dir/$so" ]; then
        found_any=1
      else
        # Fallback: .so kann auch im objs/ Verzeichnis liegen
        local objs_so="$BUILD_ROOT/nginx-${NGINX_VERSION}/objs/$so"
        if [ -f "$objs_so" ]; then
          log "  Kopiere $so aus objs/ (Fallback)"
          cp "$objs_so" "$so_staging_dir/$so"
          found_any=1
        fi
      fi
    done

    if [ "$found_any" -eq 0 ]; then
      log "  WARNUNG: Keine .so-Dateien fuer $pkg_name gefunden – ueberspringe"
      pkg_fail=$((pkg_fail + 1))
      continue
    fi

    # Modul-Staging erstellen
    local mod_stage="/tmp/nginx-mod-stage-${mod}"
    rm -rf "$mod_stage"
    mkdir -p "$mod_stage/usr/lib/nginx/modules"
    mkdir -p "$mod_stage/usr/share/nginx/modules-available"

    # .so-Dateien kopieren
    for so in $so_files; do
      if [ -f "$so_staging_dir/$so" ]; then
        cp "$so_staging_dir/$so" "$mod_stage/usr/lib/nginx/modules/"
        log "  [OK] $so"
      else
        log "  [!!] $so NICHT GEFUNDEN"
      fi
    done

    # load_module .conf erstellen
    {
      for so in $so_files; do
        echo "load_module modules/$so;"
      done
    } > "$mod_stage/usr/share/nginx/modules-available/${loadconf}.conf"
    log "  Config: /usr/share/nginx/modules-available/${loadconf}.conf"

    # Spezieller Hinweis fuer lua: ndk VOR lua laden
    if [ "$mod" = "lua" ]; then
      sed -i '1i\# WICHTIG: ndk_module.so MUSS vor lua geladen werden. Nicht mod-http-ndk.conf gleichzeitig laden!' \
        "$mod_stage/usr/share/nginx/modules-available/${loadconf}.conf"
      cat >> "$mod_stage/usr/share/nginx/modules-available/${loadconf}.conf" <<LUALOAD
load_module modules/ndk_module.so;
LUALOAD
    fi

    # fpm .deb erstellen
    local deb_file="$PACKAGE_DIR/${pkg_name}_${NGINX_VERSION}_${arch}.deb"

    local fpm_deps=""
    local dep
    for dep in $extra_deps; do
      fpm_deps="$fpm_deps --depends $dep"
    done

    set +e
    eval fpm \
      --input-type   dir \
      --output-type  deb \
      --name         "$pkg_name" \
      --version      "$NGINX_VERSION" \
      --iteration    1 \
      --architecture "$arch" \
      --maintainer   "\"local build <root@localhost>\"" \
      --description  "\"$desc (nginx $NGINX_VERSION)\"" \
      ${fpm_deps} \
      --deb-no-default-config-files \
      --after-install  "/tmp/nginx-mod-postinst.sh" \
      --after-remove   "/tmp/nginx-mod-postrm.sh" \
      --force \
      --package      "$deb_file" \
      --chdir        "$mod_stage" \
      . 2>&1 | tee -a "$LOG_FILE"
    local fpm_rc=${PIPESTATUS[0]}
    set -e

    if [ "$fpm_rc" -eq 0 ]; then
      log "  Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
      pkg_count=$((pkg_count + 1))
    else
      log "  FEHLER: fpm fuer $pkg_name fehlgeschlagen (Exit $fpm_rc)"
      pkg_fail=$((pkg_fail + 1))
    fi

    rm -rf "$mod_stage"
  done

  log "Modul-Pakete erstellt: $pkg_count erfolgreich, $pkg_fail fehlgeschlagen"
}

# ------------------------------------------------------------------------------
# Alle Pakete erstellen (Core + Module)
# ------------------------------------------------------------------------------
create_all_packages() {
  stage_install
  create_core_package
  create_module_packages

  echo ""
  log "===== Alle Pakete fertig ====="
  echo ""
  echo "Erzeugte Pakete:"
  find "$PACKAGE_DIR" -maxdepth 1 -name "*.deb" -printf "  %s bytes %p\n" 2>/dev/null \
    | sort -t/ -k6 | tee -a "$LOG_FILE"

  generate_checksums

  echo ""
  echo "HINWEIS: /etc/nginx ist NICHT in den Paketen."
  echo "         Konfiguration wird durch 'backup' / 'restore' verwaltet."
  echo ""
  echo "Module aktivieren (Beispiel fuer /etc/nginx/nginx.conf):"
  echo "  include /usr/share/nginx/modules-available/mod-http-brotli.conf;"
  echo ""

  echo "Naechster Schritt: $0 install"
}

# ------------------------------------------------------------------------------
# Modul-Verifikation
# ------------------------------------------------------------------------------
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

    echo ""
    echo "--- Verfuegbare dynamische Module ---"
    if [ -d /usr/lib/nginx/modules ]; then
      find /usr/lib/nginx/modules -name "*.so" -type f | sort
    else
      echo "(kein Modul-Verzeichnis)"
    fi

    echo ""
    echo "--- Verfuegbare Module-Configs ---"
    if [ -d /usr/share/nginx/modules-available ]; then
      ls -1 /usr/share/nginx/modules-available/*.conf 2>/dev/null || echo "(keine Configs)"
    else
      echo "(kein modules-available Verzeichnis)"
    fi

    echo ""
    echo "--- Installierte Custom-Pakete ---"
    local found=0
    for pkg in nginx-custom $(for mod in "${THIRD_PARTY_MODULES[@]}"; do echo "${MOD_PKGNAME[$mod]}"; done); do
      if dpkg -s "$pkg" >/dev/null 2>&1; then
        printf "  [OK] %-45s %s\n" "$pkg" "$(dpkg -s "$pkg" | awk '/^Version:/{print $2}')"
        found=$((found + 1))
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "  (keine Custom-Pakete installiert)"
    fi
  else
    echo "nginx-Binary nicht gefunden – Nginx noch nicht installiert"
  fi
  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Pakete via dpkg installieren
# ------------------------------------------------------------------------------
install_packages() {
  local deb_core
  deb_core=$(find "$PACKAGE_DIR" -maxdepth 1 -name "nginx-custom_*.deb" 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$deb_core" ] || die "Kein nginx-custom.deb in $PACKAGE_DIR – bitte zuerst: $0 package"

  if [ ! -f /etc/nginx/nginx.conf ]; then
    log "WARNUNG: /etc/nginx/nginx.conf nicht gefunden!"
    read -r -p "Trotzdem fortfahren? (ja/nein): " antwort
    [ "$antwort" = "ja" ] || die "Abgebrochen"
  fi

  if dpkg-deb --contents "$deb_core" 2>/dev/null | awk '{print $NF}' | grep -q "^\./etc/nginx"; then
    die "FEHLER: $deb_core enthaelt /etc/nginx – Paket neu erstellen!"
  fi

  log "Installiere Core: $(basename "$deb_core")"
  DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_core"

  local deb_modules
  deb_modules=$(find "$PACKAGE_DIR" -maxdepth 1 -name "libnginx-mod-*.deb" 2>/dev/null | sort || true)
  if [ -n "$deb_modules" ]; then
    log "Installiere Modul-Pakete..."
    for deb_mod in $deb_modules; do
      log "  Installiere: $(basename "$deb_mod")"
    done
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_modules" 2>&1 | tee -a "$LOG_FILE" || true
  else
    log "Keine Modul-Pakete gefunden"
  fi

  apt-get install -f -y || true

  log "Konfiguration in /etc/nginx: unveraendert"
}

# ------------------------------------------------------------------------------
# Dienst neu starten
# ------------------------------------------------------------------------------
restart_service() {
  log "Starte Nginx neu"
  systemctl daemon-reload
  systemctl enable nginx
  systemctl restart nginx
}

# ------------------------------------------------------------------------------
# Post-Install Checks
# ------------------------------------------------------------------------------
post_checks() {
  log "Pruefe Installation"
  command -v nginx >/dev/null 2>&1 || die "nginx-Binary nicht gefunden"
  log "Nginx Version: $(nginx -v 2>&1)"

  log "Konfigurationscheck (nginx -t)"
  nginx -t >> "$LOG_FILE" 2>&1 \
    || log "WARNUNG: Konfigurationsfehler – Log pruefen: $LOG_FILE"

  if ! systemctl is-active --quiet nginx; then
    systemctl status nginx --no-pager || true
    die "Nginx laeuft nicht"
  fi

  verify_build

  log "Installation abgeschlossen"
}

# ------------------------------------------------------------------------------
# Restore
# ------------------------------------------------------------------------------
restore_from_backup() {
  local backup_dir="${1:-$LATEST_LINK}"
  [ -L "$backup_dir" ] && backup_dir="$(readlink -f "$backup_dir")"
  [ -d "$backup_dir" ] || die "Backup nicht gefunden: $backup_dir"
  log "Restore aus: $backup_dir"

  systemctl stop nginx 2>/dev/null || true

  for pkg in $(for mod in "${THIRD_PARTY_MODULES[@]}"; do echo "${MOD_PKGNAME[$mod]}"; done) nginx-custom; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "Deinstalliere $pkg"
      dpkg -r "$pkg" || true
    fi
  done

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

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------
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
  echo "--- Installierte Custom-Pakete ---"
  local found=0
  for pkg in nginx-custom $(for mod in "${THIRD_PARTY_MODULES[@]}"; do echo "${MOD_PKGNAME[$mod]}"; done); do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      printf "  [OK] %-45s %s\n" "$pkg" "$(dpkg -s "$pkg" | awk '/^Version:/{print $2}')"
      found=$((found + 1))
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "  (keine Custom-Pakete installiert)"
  fi

  echo ""
  echo "--- Dynamische Module (/usr/lib/nginx/modules/) ---"
  if [ -d /usr/lib/nginx/modules ]; then
    find /usr/lib/nginx/modules -name "*.so" -type f | sort
  else
    echo "(kein Modul-Verzeichnis)"
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
  echo "--- Verfuegbare .deb-Pakete ---"
  if [ -d "$PACKAGE_DIR" ]; then
    find "$PACKAGE_DIR" -maxdepth 1 -name "*.deb" -printf "%s bytes %p\n" 2>/dev/null || echo "(keine Pakete erzeugt)"
  fi
}

list_backups() {
  echo "Verfuegbare Backups in $BACKUP_ROOT:"
  [ -d "$BACKUP_ROOT" ] \
    && find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort \
    || echo "(kein Backup-Verzeichnis)"
}

check_config() {
  log "Konfigurationscheck"
  nginx -t || die "Konfigurationsfehler"
}

list_modules_cmd() {
  echo "=============================================="
  echo " Verfuegbare Third-Party-Module"
  echo "=============================================="
  printf "%-25s %-40s %s\n" "PAKETNAME" "MODUL-DIR" "BESCHREIBUNG"
  printf "%-25s %-40s %s\n" "-------------------------" "----------------------------------------" "--------------------"
  for mod in "${THIRD_PARTY_MODULES[@]}"; do
    local skip_reason=""
    if skip_reason="$(module_skip_reason "$mod")"; then
      printf "%-25s %-40s %s [SKIP: %s]\n" "${MOD_PKGNAME[$mod]}" "${MOD_DIRNAME[$mod]}" "${MOD_DESC[$mod]}" "$skip_reason"
    else
      printf "%-25s %-40s %s\n" "${MOD_PKGNAME[$mod]}" "${MOD_DIRNAME[$mod]}" "${MOD_DESC[$mod]}"
    fi
  done
  echo ""
  echo "Gesamt: ${#THIRD_PARTY_MODULES[@]} Module"
  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Deinstallation: Module zuerst (Reverse-Dependency), dann Core
# ------------------------------------------------------------------------------
uninstall_cmd() {
  log "Deinstalliere alle nginx-custom Pakete"
  systemctl stop nginx 2>/dev/null || true

  for mod in "${THIRD_PARTY_MODULES[@]}"; do
    local pkg="${MOD_PKGNAME[$mod]}"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "  Entferne $pkg"
      dpkg -r "$pkg" || true
    fi
  done

  for pkg in nginx-custom-doc nginx-custom-dev nginx-custom; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "  Entferne $pkg"
      dpkg -r "$pkg" || true
    fi
  done

  log "Deinstallation abgeschlossen"
}

# ------------------------------------------------------------------------------
# Vollstaendiger Paket-Build (Schritt 1 – nichts installieren)
# ------------------------------------------------------------------------------
package_all() {
  log "=== Starte Nginx Paket-Build ==="
  log "Module: ${#THIRD_PARTY_MODULES[@]} Third-Party-Module als separate .deb-Pakete"
  install_build_deps
  prepare_sources
  prepare_openssl
  download_third_party_modules
  build_nginx
  create_all_packages
  create_nginx_dev_package
  create_nginx_doc_package
  sign_packages
  update_local_repo_if_configured
  log "=== Paket-Build abgeschlossen ==="
  echo ""

  echo "Naechster Schritt: $0 install"
}

# ------------------------------------------------------------------------------
# .deb-Paket: nginx-custom-dev (Header + nginx-Module-Build-Hilfsdateien)
# ------------------------------------------------------------------------------
create_nginx_dev_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  local dev_stage="/tmp/nginx-dev-stage"
  rm -rf "$dev_stage"
  mkdir -p "$dev_stage"

  local build_dir="$BUILD_ROOT/nginx-${NGINX_VERSION}"

  # Header
  if [ -d "$build_dir/src/core" ]; then
    mkdir -p "$dev_stage/usr/include/nginx"
    for hdir in core event event/modules http http/modules mail stream os/unix; do
      if [ -d "$build_dir/src/$hdir" ]; then
        mkdir -p "$dev_stage/usr/include/nginx/$(basename "$hdir")"
        cp "$build_dir/src/$hdir"/*.h "$dev_stage/usr/include/nginx/$(basename "$hdir")/" 2>/dev/null || true
      fi
    done
    find "$build_dir/src" -maxdepth 2 -name "*.h" -exec cp {} "$dev_stage/usr/include/nginx/" \; 2>/dev/null || true
  fi

  # auto/config.h und ngx_auto_config.h
  if [ -f "$build_dir/objs/ngx_auto_config.h" ]; then
    mkdir -p "$dev_stage/usr/include/nginx"
    cp "$build_dir/objs/ngx_auto_config.h" "$dev_stage/usr/include/nginx/"
  fi

  local hdr_count
  hdr_count=$(find "$dev_stage" -name "*.h" | wc -l)

  if [ "$hdr_count" -eq 0 ]; then
    log "SKIP nginx-custom-dev – keine Header gefunden"
    rm -rf "$dev_stage"
    return 0
  fi
  log "Nginx dev: $hdr_count Header-Dateien kopiert"

  mkdir -p "$dev_stage/usr/share/doc/nginx-custom-dev"

  local deb_file="$PACKAGE_DIR/nginx-custom-dev_${NGINX_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         nginx-custom-dev \
    --version      "$NGINX_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Nginx $NGINX_VERSION – development headers" \
    --depends      nginx-custom \
    --conflicts    nginx-dev \
    --provides     nginx-dev \
    --replaces     nginx-dev \
    --deb-no-default-config-files \
    --force \
    --package      "$deb_file" \
    --chdir        "$dev_stage" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
  rm -rf "$dev_stage"
}

# ------------------------------------------------------------------------------
# .deb-Paket: nginx-custom-doc (Dokumentation)
# ------------------------------------------------------------------------------
create_nginx_doc_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  local doc_stage="/tmp/nginx-doc-stage"
  rm -rf "$doc_stage"
  mkdir -p "$doc_stage"

  local build_dir="$BUILD_ROOT/nginx-${NGINX_VERSION}"

  # HTML documentation
  if [ -d "$build_dir/docs" ]; then
    mkdir -p "$doc_stage/usr/share/doc/nginx-custom/html"
    cp -a "$build_dir/docs"/* "$doc_stage/usr/share/doc/nginx-custom/html/" 2>/dev/null || true
  fi

  # Man pages from staging
  local man_dir="${STAGE_NGINX}/usr/share/man"
  if [ -d "$man_dir" ]; then
    cp -a "$man_dir" "$doc_stage/usr/share/" 2>/dev/null || true
  fi

  local doc_count
  doc_count=$(find "$doc_stage" -type f | wc -l)
  if [ "$doc_count" -eq 0 ]; then
    log "SKIP nginx-custom-doc – keine Dokumentation gefunden"
    rm -rf "$doc_stage"
    return 0
  fi

  mkdir -p "$doc_stage/usr/share/doc/nginx-custom-doc"

  local deb_file="$PACKAGE_DIR/nginx-custom-doc_${NGINX_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         nginx-custom-doc \
    --version      "$NGINX_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Nginx $NGINX_VERSION – documentation" \
    --depends      nginx-custom \
    --deb-no-default-config-files \
    --force \
    --package      "$deb_file" \
    --chdir        "$doc_stage" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
  rm -rf "$doc_stage"
}

# ------------------------------------------------------------------------------
# Installation (Schritt 2 – Backup + dpkg -i)
# ------------------------------------------------------------------------------
install_all() {
  log "=== Starte Installation ==="
  log "Schritt 1/4: Backup erstellen"
  create_backup
  log "Schritt 2/4: Pakete installieren (/etc/nginx bleibt unberuehrt)"
  install_packages
  log "Schritt 3/4: Nginx neu starten"
  restart_service
  log "Schritt 4/4: Verifikation"
  post_checks
  log "=== Installation abgeschlossen ==="
  echo ""
  echo "Zusammenfassung:"
  echo "  Backup:        $LATEST_LINK"
  echo "  Pakete:        $PACKAGE_DIR"
  echo "  Konfiguration: /etc/nginx  (UNVERAENDERT)"
  echo "  Log:           $LOG_FILE"
  echo ""
  echo "Module aktivieren (Beispiel fuer /etc/nginx/nginx.conf):"
  echo "  include /usr/share/nginx/modules-available/mod-http-brotli.conf;"
}

# ------------------------------------------------------------------------------
# OS/Arch Pruefung
# ------------------------------------------------------------------------------
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
    echo "FEHLER: Dieses Skript unterstuetzt nur Ubuntu 24.04 (oder neuer) auf arm64." >&2
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
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
    list-modules)   list_modules_cmd ;;
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
