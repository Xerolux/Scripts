#!/usr/bin/env bash
# ==============================================================================
# setup_postfix.sh – Postfix Build-from-Source + .deb-Paketerstellung
# Zielumgebung : Ubuntu 24.04 ARM64, ISPConfig, MariaDB, Dovecot, SASL
#
# Postfix baut anders als Dovecot – kein ./configure sondern:
#   make makefiles CCARGS="..." AUXLIBS="..."
#   make
#   make install  (oder: sh postfix-install -non-interactive ...)
#
# Empfohlener Ablauf:
#   1. setup_postfix.sh package   → .deb erstellen (KEIN install)
#   2. setup_postfix.sh install   → Backup + dpkg -i
#
# Konfiguration:
#   /etc/postfix/ wird NICHT in die Pakete gepackt → ISPConfig-Configs bleiben
#
# Deinstallation:
#   setup_postfix.sh uninstall
#   oder: dpkg -r postfix-custom
# ==============================================================================
set -Eeuo pipefail

if [[ ! -f "setup_postfix.env" ]]; then
  echo "FEHLER: setup_postfix.env nicht gefunden. Bitte aus setup_postfix.env.example erstellen." >&2
  exit 1
fi
source "setup_postfix.env"

# ftp.porcupine.org ist ein FTP-Server und unterstützt kein HTTPS → http://
POSTFIX_TARBALL_URLS=(
  "https://github.com/vdukhovni/postfix/archive/refs/tags/v${POSTFIX_VERSION}.tar.gz"
  "https://ftp.gwdg.de/pub/misc/postfix/official/postfix-${POSTFIX_VERSION}.tar.gz"
  "https://fossies.org/linux/misc/postfix-${POSTFIX_VERSION}.tar.gz"
  "http://ftp.porcupine.org/mirrors/postfix-release/official/postfix-${POSTFIX_VERSION}.tar.gz"
  "http://de.postfix.org/ftpmirror/official/postfix-${POSTFIX_VERSION}.tar.gz"
)

# ------------------------------------------------------------------------------
# Postfix Map-Package-Definitionen
#
# Mit dynamicmaps=yes baut Postfix Map-Typen als dynamische .so-Module.
# Diese werden als separate .deb-Pakete verpackt, analog zu den offiziellen
# Ubuntu-Paketen (postfix-mysql, postfix-pgsql, postfix-ldap, usw.).
#
# Jede Map hat:
#   MAP_SONAME   – Name der .so-Datei (in /usr/lib/postfix/)
#   MAP_PKGNAME  – .deb-Paketname
#   MAP_DESC     – Kurzbeschreibung
#   MAP_DEPS     – Zusaetzliche Paket-Abhaengigkeiten (Leerzeichen-getrennt)
#   MAP_CONFLICTS – Offizielles Ubuntu-Paket das ersetzt wird
# ------------------------------------------------------------------------------
declare -A MAP_SONAME MAP_PKGNAME MAP_DESC MAP_DEPS MAP_CONFLICTS

# --- MySQL/MariaDB -----------------------------------------------------------
MAP_SONAME[mysql]="postfix-mysql.so"
MAP_PKGNAME[mysql]="postfix-custom-mysql"
MAP_DESC[mysql]="MySQL map support for Postfix"
MAP_DEPS[mysql]="postfix-custom libmariadb3"
MAP_CONFLICTS[mysql]="postfix-mysql"

# --- PostgreSQL ---------------------------------------------------------------
MAP_SONAME[pgsql]="postfix-pgsql.so"
MAP_PKGNAME[pgsql]="postfix-custom-pgsql"
MAP_DESC[pgsql]="PostgreSQL map support for Postfix"
MAP_DEPS[pgsql]="postfix-custom libpq5"
MAP_CONFLICTS[pgsql]="postfix-pgsql"

# --- LDAP ---------------------------------------------------------------------
MAP_SONAME[ldap]="postfix-ldap.so"
MAP_PKGNAME[ldap]="postfix-custom-ldap"
MAP_DESC[ldap]="LDAP map support for Postfix"
MAP_DEPS[ldap]="postfix-custom libldap-2.5-0"
MAP_CONFLICTS[ldap]="postfix-ldap"

# --- SQLite -------------------------------------------------------------------
MAP_SONAME[sqlite]="postfix-sqlite.so"
MAP_PKGNAME[sqlite]="postfix-custom-sqlite"
MAP_DESC[sqlite]="SQLite map support for Postfix"
MAP_DEPS[sqlite]="postfix-custom libsqlite3-0"
MAP_CONFLICTS[sqlite]="postfix-sqlite"

# --- PCRE ---------------------------------------------------------------------
MAP_SONAME[pcre]="postfix-pcre.so"
MAP_PKGNAME[pcre]="postfix-custom-pcre"
MAP_DESC[pcre]="PCRE map support for Postfix"
MAP_DEPS[pcre]="postfix-custom libpcre2-8-0"
MAP_CONFLICTS[pcre]="postfix-pcre"

# --- LMDB ---------------------------------------------------------------------
MAP_SONAME[lmdb]="postfix-lmdb.so"
MAP_PKGNAME[lmdb]="postfix-custom-lmdb"
MAP_DESC[lmdb]="LMDB map support for Postfix"
MAP_DEPS[lmdb]="postfix-custom liblmdb0"
MAP_CONFLICTS[lmdb]="postfix-lmdb"

# --- CDB ----------------------------------------------------------------------
MAP_SONAME[cdb]="postfix-cdb.so"
MAP_PKGNAME[cdb]="postfix-custom-cdb"
MAP_DESC[cdb]="CDB map support for Postfix"
MAP_DEPS[cdb]="postfix-custom libcdb1"
MAP_CONFLICTS[cdb]="postfix-cdb"

MAP_TYPES=(
  mysql
  pgsql
  ldap
  sqlite
  pcre
  lmdb
  cdb
)

# Installationspfade (passend zu bestehender ISPConfig-Installation)
# Diese werden in der Funktion create_deb_package direkt verwendet
# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
die()  { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausführen."
}

usage() {
  cat <<'EOF'
Verwendung:
  setup_postfix.sh [--screen] <Befehl>

Optionen:
  --screen         Skript in einer GNU Screen Session ausführen (optional)

Befehle:
  package          – Quellen laden, bauen, .deb erstellen (KEIN install)
  install          – Backup + dpkg -i des erzeugten .deb
  backup           – Nur Backup erstellen
  restore          – Letztes Backup einspielen
  restore /root/postfix-backup/<timestamp>
  status           – Zustand + Module anzeigen
  list-backups     – Verfügbare Backups auflisten
  check-config     – postfix check ausführen
  uninstall        – Custom-Paket via dpkg -r entfernen
  verify           – Modul-Verifikation (nach Installation)

Deinstallation manuell:
  dpkg -r postfix-custom
EOF
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

# ------------------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------------------
create_backup() {
  local ts backup_dir
  ts="$(date '+%F_%H%M%S')"
  backup_dir="$BACKUP_ROOT/$ts"
  mkdir -p "$backup_dir"
  log "Erstelle Backup in $backup_dir"

  systemctl stop postfix 2>/dev/null || true

  # Konfiguration – WICHTIG: bleibt beim install unberührt
  [ -d /etc/postfix ]                       && cp -a /etc/postfix                       "$backup_dir/etc_postfix"
  # Binaries
  [ -f /usr/sbin/postfix ]                  && cp -a /usr/sbin/postfix                  "$backup_dir/usr_sbin_postfix"
  [ -d /usr/lib/postfix ]                   && cp -a /usr/lib/postfix                   "$backup_dir/usr_lib_postfix"
  [ -d /usr/libexec/postfix ]               && cp -a /usr/libexec/postfix               "$backup_dir/usr_libexec_postfix"
  # Systemd
  [ -f /lib/systemd/system/postfix.service ] && cp -a /lib/systemd/system/postfix.service "$backup_dir/postfix.service"
  # Paketliste
  dpkg -l 2>/dev/null | awk '/^ii/ && /postfix/ {print $2}' > "$backup_dir/packages.txt" || true
  # Laufende Konfiguration
  if command -v postconf >/dev/null 2>&1; then
    postfix version > "$backup_dir/postfix-version.txt" 2>&1 || true
    postconf         > "$backup_dir/postfix-config.txt"   2>&1 || true
    postconf -m      > "$backup_dir/postfix-maps.txt"     2>&1 || true
  fi
  # Pakete mit sichern
  if [ -d "$PACKAGE_DIR" ] && ls "$PACKAGE_DIR"/*.deb >/dev/null 2>&1; then
    cp -a "$PACKAGE_DIR" "$backup_dir/deb-packages" || true
  fi

  ln -sfn "$backup_dir" "$LATEST_LINK"
  log "Backup fertig: $backup_dir"
}

# ------------------------------------------------------------------------------
# Build-Abhängigkeiten
# Postfix nutzt kein ./configure sondern CCARGS/AUXLIBS in make makefiles
# ------------------------------------------------------------------------------
install_build_deps() {
  log "Installiere Build-Abhängigkeiten"

  # libmysqlclient-dev (Oracle) kollidiert mit libmariadb-dev
  if dpkg -s libmysqlclient-dev >/dev/null 2>&1; then
    log "Entferne libmysqlclient-dev (kollidiert mit libmariadb-dev)"
    apt-get remove -y libmysqlclient-dev || true
  fi

  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential make m4 pkg-config \
    libssl-dev \
    libsasl2-dev \
    libmariadb-dev \
    libldap2-dev \
    libpcre2-dev \
    libpcre3-dev \
    libsqlite3-dev \
    liblmdb-dev \
    libicu-dev \
    libpam0g-dev \
    ruby ruby-dev rubygems rpm \
    libpq-dev \
    libcdb-dev \
    wget curl

  # Paketsignierung ist optional: dpkg-sig bevorzugen, debsigs als Fallback.
  if apt-cache show dpkg-sig >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-sig || true
  elif apt-cache show debsigs >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y debsigs debsig-verify \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y debsigs \
      || true
  else
    log "Kein Paketsignierungs-Tool in den Repos gefunden – Signierung wird bei Bedarf uebersprungen"
  fi

  # fpm für .deb-Erstellung
  if ! command -v fpm >/dev/null 2>&1; then
    log "Installiere fpm"
    gem install --no-document fpm
  else
    log "fpm bereits vorhanden: $(fpm --version)"
  fi
}

# ------------------------------------------------------------------------------
# Quellen herunterladen
# ------------------------------------------------------------------------------
prepare_sources() {
  mkdir -p "$BUILD_ROOT"
  cd "$BUILD_ROOT"
  rm -rf "postfix-${POSTFIX_VERSION}"

  local pf_tar
  pf_tar="$BUILD_ROOT/postfix-${POSTFIX_VERSION}.tar.gz"

  if [ ! -f "$pf_tar" ]; then
    log "Lade Postfix $POSTFIX_VERSION Tarball"
    local url
    local downloaded=0
    for url in "${POSTFIX_TARBALL_URLS[@]}"; do
      log "Versuche Download: $url"
      if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar "$url" -o "$pf_tar"; then
        downloaded=1
        break
      fi
    done
    (( downloaded == 1 )) || die "Download fehlgeschlagen"
  else
    log "Postfix Tarball bereits vorhanden: $pf_tar"
  fi

  tar xzf "$pf_tar"
  if [ ! -d "$BUILD_ROOT/postfix-${POSTFIX_VERSION}" ] && ls -d "$BUILD_ROOT/postfix-v${POSTFIX_VERSION}"* >/dev/null 2>&1; then
    mv "$BUILD_ROOT/postfix-v${POSTFIX_VERSION}"* "$BUILD_ROOT/postfix-${POSTFIX_VERSION}"
  elif [ ! -d "$BUILD_ROOT/postfix-${POSTFIX_VERSION}" ] && ls -d "$BUILD_ROOT/postfix-"* >/dev/null 2>&1; then
    mv "$BUILD_ROOT/postfix-"* "$BUILD_ROOT/postfix-${POSTFIX_VERSION}"
  fi

  [ -d "$BUILD_ROOT/postfix-${POSTFIX_VERSION}" ] \
    || die "Tarball entpackt kein Verzeichnis postfix-${POSTFIX_VERSION}"
  log "Quellen: $BUILD_ROOT/postfix-${POSTFIX_VERSION}"
}

# ------------------------------------------------------------------------------
# CCARGS + AUXLIBS zusammenbauen
#
# Postfix-Build-System:
#   CCARGS  = Compiler-Flags und Feature-Defines (-DHAS_MYSQL usw.)
#   AUXLIBS = Linker-Libs für statisch eingebaute Features (MySQL, SASL, LDAP)
#   AUXLIBS_LMDB / AUXLIBS_PCRE / AUXLIBS_SQLITE = separate Variablen für
#             dynamisch geladene Maps (Postfix 3.x)
#
# Wichtig: Postfix prüft NICHT automatisch ob Libs vorhanden sind.
# Wir prüfen selbst mit [ -f ... ] bevor wir Flags setzen.
#
# Module-Übersicht für ISPConfig auf saturn:
#   -DHAS_MYSQL         MariaDB/MySQL virtual_mailbox_maps, transport_maps usw.
#   -DUSE_SASL_AUTH     SMTP-Auth via Cyrus SASL (Dovecot-SASL-Socket)
#   -DUSE_CYRUS_SASL    Cyrus SASL Bibliothek
#   -DHAS_LDAP          LDAP-Lookups (optional)
#   -DHAS_PCRE          Perl-kompatible Regex für header_checks, body_checks
#   -DHAS_SQLITE        SQLite Maps
#   -DHAS_LMDB          LMDB Maps (Ersatz für hash/btree in Postfix 3.11)
#   -DUSE_TLS           TLS/STARTTLS Support (PFLICHT für modernen Mailserver)
#   -DHAS_ICU           Unicode/SMTPUTF8 Support (EAI)
# ------------------------------------------------------------------------------
build_ccargs() {
  local CCARGS=""
  local AUXLIBS=""
  local AUXLIBS_LMDB=""
  local AUXLIBS_PCRE=""
  local AUXLIBS_SQLITE=""

  log "Ermittle CCARGS/AUXLIBS..."

  # --- TLS (OpenSSL) – PFLICHT -----------------------------------------------
  if pkg-config --exists openssl 2>/dev/null || [ -f /usr/include/openssl/ssl.h ]; then
    log "  [+] TLS/OpenSSL"
    CCARGS="$CCARGS -DUSE_TLS"
    AUXLIBS="$AUXLIBS -lssl -lcrypto"
  else
    die "OpenSSL-Dev nicht gefunden – TLS ist Pflicht"
  fi

  # --- Cyrus SASL – für SMTP-Auth (ISPConfig nutzt Dovecot SASL Socket) ------
  if [ -f /usr/include/sasl/sasl.h ]; then
    log "  [+] Cyrus SASL"
    CCARGS="$CCARGS -DUSE_SASL_AUTH -DUSE_CYRUS_SASL -I/usr/include/sasl"
    AUXLIBS="$AUXLIBS -lsasl2"
  else
    log "  [-] Cyrus SASL nicht gefunden (libsasl2-dev prüfen)"
  fi

  # --- MariaDB/MySQL – für virtual_mailbox_maps etc. (ISPConfig) -------------
  local mysql_inc=""
  for p in /usr/include/mysql /usr/include/mariadb; do
    [ -f "$p/mysql.h" ] && mysql_inc="$p" && break
  done
  local mysql_lib=""
  for l in mariadb mysqlclient; do
    [ -f "/usr/lib/aarch64-linux-gnu/lib${l}.so" ] && mysql_lib="${l}" && break
    [ -f "/usr/lib/lib${l}.so" ]                    && mysql_lib="${l}" && break
  done
  if [ -n "$mysql_inc" ] && [ -n "$mysql_lib" ]; then
    log "  [+] MariaDB/MySQL ($mysql_inc, lib: lib${mysql_lib})"
    CCARGS="$CCARGS -DHAS_MYSQL -I${mysql_inc}"
    AUXLIBS="$AUXLIBS -l${mysql_lib} -lz -lm"
  else
    log "  [-] MySQL/MariaDB nicht gefunden (mysql_inc=$mysql_inc, lib=$mysql_lib)"
  fi

  # --- OpenLDAP – für LDAP-Lookups -------------------------------------------
  if [ -f /usr/include/ldap.h ]; then
    log "  [+] OpenLDAP"
    CCARGS="$CCARGS -DHAS_LDAP"
    AUXLIBS="$AUXLIBS -lldap -llber"
  else
    log "  [-] OpenLDAP nicht gefunden"
  fi

  # --- PCRE2 – für header_checks, body_checks --------------------------------
  if pkg-config --exists libpcre2-8 2>/dev/null; then
    log "  [+] PCRE2"
    CCARGS="$CCARGS -DHAS_PCRE2 $(pkg-config --cflags libpcre2-8)"
    AUXLIBS_PCRE="$(pkg-config --libs libpcre2-8)"
  elif [ -f /usr/include/pcre.h ]; then
    log "  [+] PCRE (v1)"
    CCARGS="$CCARGS -DHAS_PCRE"
    AUXLIBS_PCRE="-lpcre"
  else
    log "  [-] PCRE nicht gefunden"
  fi

  # --- LMDB – Ersatz für hash/btree (wichtig in Postfix 3.11) ---------------
  # -DNO_DB: Berkeley DB (db.h) explizit deaktivieren, da LMDB als
  # Standard-Datenbanktyp gesetzt ist. Ohne diesen Flag bricht makedefs ab.
  if [ -f /usr/include/lmdb.h ]; then
    log "  [+] LMDB"
    CCARGS="$CCARGS -DHAS_LMDB -DNO_DB"
    AUXLIBS_LMDB="-llmdb"
  else
    log "  [-] LMDB nicht gefunden (liblmdb-dev prüfen)"
    die "LMDB ist Pflicht (default_database_type=lmdb) – liblmdb-dev installieren"
  fi

  # --- SQLite ----------------------------------------------------------------
  if pkg-config --exists sqlite3 2>/dev/null; then
    log "  [+] SQLite"
    CCARGS="$CCARGS -DHAS_SQLITE $(pkg-config --cflags sqlite3)"
    AUXLIBS_SQLITE="$(pkg-config --libs sqlite3) -lpthread"
  else
    log "  [-] SQLite nicht gefunden"
  fi

  # --- ICU – SMTPUTF8 / Email Address Internationalization ------------------
  if pkg-config --exists icu-uc icu-i18n 2>/dev/null; then
    log "  [+] ICU (SMTPUTF8)"
    CCARGS="$CCARGS -DHAS_ICU $(pkg-config --cflags icu-uc icu-i18n)"
    AUXLIBS="$AUXLIBS $(pkg-config --libs icu-uc icu-i18n)"
  else
    log "  [-] ICU nicht gefunden (libicu-dev prüfen)"
  fi

  # --- PostgreSQL ------------------------------------------------------------
  if [ -f /usr/include/postgresql/libpq-fe.h ]; then
    log "  [+] PostgreSQL"
    CCARGS="$CCARGS -DHAS_PGSQL -I/usr/include/postgresql"
    AUXLIBS="$AUXLIBS -lpq"
  else
    log "  [-] PostgreSQL nicht gefunden (libpq-dev prüfen)"
  fi

  # --- CDB -------------------------------------------------------------------
  if [ -f /usr/include/cdb.h ]; then
    log "  [+] CDB"
    CCARGS="$CCARGS -DHAS_CDB"
    AUXLIBS="$AUXLIBS -lcdb"
  else
    log "  [-] CDB nicht gefunden (libcdb-dev prüfen)"
  fi

  # --- Sicherheitshärtung (analog zu Debian-Paketen) ------------------------
  CCARGS="$CCARGS -DNO_NIS"
  CCARGS="$CCARGS -DFD_SETSIZE=2048"
  CCARGS="$CCARGS -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
  CCARGS="$CCARGS -Wno-implicit-function-declaration"
  AUXLIBS="$AUXLIBS -Wl,-z,relro -Wl,-z,now"

  # Ergebnis exportieren
  printf 'CCARGS=%q\n'        "${CCARGS}"
  printf 'AUXLIBS=%q\n'       "${AUXLIBS}"
  printf 'AUXLIBS_LMDB=%q\n' "${AUXLIBS_LMDB}"
  printf 'AUXLIBS_PCRE=%q\n' "${AUXLIBS_PCRE}"
  printf 'AUXLIBS_SQLITE=%q\n' "${AUXLIBS_SQLITE}"
}

# ------------------------------------------------------------------------------
# Postfix bauen
# ------------------------------------------------------------------------------
build_postfix() {
  cd "$BUILD_ROOT/postfix-${POSTFIX_VERSION}"
  log "Baue Postfix $POSTFIX_VERSION"

  # CCARGS/AUXLIBS ermitteln
  local flags_file
  flags_file="$(mktemp)"
  build_ccargs > "$flags_file"
  # shellcheck source=/dev/null
  source "$flags_file"
  rm -f "$flags_file"

  log "CCARGS: $CCARGS"
  log "AUXLIBS: $AUXLIBS"
  log "AUXLIBS_LMDB: $AUXLIBS_LMDB"
  log "AUXLIBS_PCRE: $AUXLIBS_PCRE"
  log "AUXLIBS_SQLITE: $AUXLIBS_SQLITE"

  # Makefiles generieren (Postfix-eigenes Build-System)
  set +e
  make makefiles \
    CCARGS="${CCARGS}" \
    AUXLIBS="${AUXLIBS}" \
    AUXLIBS_LMDB="${AUXLIBS_LMDB}" \
    AUXLIBS_PCRE="${AUXLIBS_PCRE}" \
    AUXLIBS_SQLITE="${AUXLIBS_SQLITE}" \
    pie=yes \
    dynamicmaps=yes \
    default_database_type=lmdb \
    default_cache_db_type=lmdb \
    2>&1 | tee -a "$LOG_FILE"
  local mk_rc=${PIPESTATUS[0]}
  set -e
  [ "$mk_rc" -eq 0 ] || die "make makefiles fehlgeschlagen (Exit $mk_rc)"

  log "Kompiliere Postfix (make -j$(nproc))"
  set +e
  make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
  local build_rc=${PIPESTATUS[0]}
  set -e
  [ "$build_rc" -eq 0 ] || die "Postfix make fehlgeschlagen (Exit $build_rc)"

  log "Postfix Build fertig"
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
# .deb-Paket erstellen via fpm
#
# Postfix hat kein DESTDIR-Konzept wie autotools-Projekte.
# Lösung: postfix-install Script mit install_root= Parameter verwenden.
# Damit werden alle Dateien in ein Staging-Verzeichnis installiert.
#
# /etc/postfix wird NICHT verpackt – ISPConfig-Konfiguration bleibt.
# ------------------------------------------------------------------------------
create_deb_package() {
  local arch
  arch="$(dpkg --print-architecture)"
  mkdir -p "$PACKAGE_DIR"

  cd "$BUILD_ROOT/postfix-${POSTFIX_VERSION}"

  log "Installiere Postfix ins Staging: $STAGE_POSTFIX"
  rm -rf "$STAGE_POSTFIX"
  mkdir -p "$STAGE_POSTFIX"

  export LD_LIBRARY_PATH="$BUILD_ROOT/postfix-${POSTFIX_VERSION}/lib:${LD_LIBRARY_PATH:-}"

  # postfix-install ist das offizielle Install-Script
  # install_root= setzt das Staging-Verzeichnis
  set +e
  sh postfix-install -non-interactive \
    install_root="$STAGE_POSTFIX" \
    daemon_directory=/usr/lib/postfix/sbin \
    command_directory=/usr/sbin \
    queue_directory=/var/spool/postfix \
    data_directory=/var/lib/postfix \
    config_directory=/etc/postfix \
    shlib_directory=/usr/lib/postfix \
    meta_directory=/etc/postfix \
    manpage_directory=/usr/share/man \
    html_directory=/usr/share/doc/postfix/html \
    readme_directory=/usr/share/doc/postfix/readme \
    2>&1 | tee -a "$LOG_FILE"
  local inst_rc=${PIPESTATUS[0]}
  set -e
  unset LD_LIBRARY_PATH
  [ "$inst_rc" -eq 0 ] || die "postfix-install fehlgeschlagen (Exit $inst_rc)"

  # Gzip man pages
  find "${STAGE_POSTFIX}/usr/share/man" -type f -name '*.?' ! -name '*.gz' -exec gzip -f {} \; 2>/dev/null || true

  # /etc/postfix aus Staging – nur Konfigurationsdateien entfernen,
  # Meta-Files (postfix.service, postfix-files, post-install, postfix-script)
  # behalten – sie werden fuer den Betrieb benoetigt.
  if [ -d "${STAGE_POSTFIX}/etc/postfix" ]; then
    cd "${STAGE_POSTFIX}/etc/postfix"
    # Backup dynamicmaps.cf before removing *.cf files
    if [ -f dynamicmaps.cf ]; then
      cp dynamicmaps.cf dynamicmaps.cf.dpkg-backup
    fi
    for f in *.cf *.proto ACCESS aliases canonical \
             generic header_checks relocated transport \
             virtual mime_types; do
      rm -f "$f" 2>/dev/null || true
    done
    # Restore critical meta files if they were removed
    if [ -f dynamicmaps.cf.dpkg-backup ]; then
      mv dynamicmaps.cf.dpkg-backup dynamicmaps.cf
    fi
    cd "$BUILD_ROOT"
    log "/etc/postfix: Konfig-Dateien entfernt, Meta-Files behalten"
  fi

  # Staging-Inhalt prüfen
  log "Staging-Inhalt (relevante Dateien):"
  find "$STAGE_POSTFIX" \( -name "postfix" -o -name "postconf" -o -name "smtpd" \
    -o -name "*.so" -o -name "postfix.service" \) | sort | tee -a "$LOG_FILE"

  # Systemd-Unit: von meta_directory nach /lib/systemd/system kopieren
  if [ -f "${STAGE_POSTFIX}/etc/postfix/postfix.service" ]; then
    mkdir -p "${STAGE_POSTFIX}/lib/systemd/system"
    cp "${STAGE_POSTFIX}/etc/postfix/postfix.service" "${STAGE_POSTFIX}/lib/systemd/system/postfix.service"
    log "Systemd-Unit nach /lib/systemd/system kopiert"

    # Hardening-Einstellungen in der [Service]-Sektion ergaenzen
    local svc="${STAGE_POSTFIX}/lib/systemd/system/postfix.service"
    if grep -q '\[Service\]' "$svc"; then
      sed -i '/\[Service\]/a\LimitNOFILE=65535\nProtectSystem=full\nPrivateDevices=true\nProtectHome=true\nNoNewPrivileges=false' "$svc"
      log "Systemd-Unit: Hardening-Einstellungen hinzugefuegt"
    fi

    # Original in /etc/postfix behalten (Postfix benoetigt ihn dort)
  fi

  # tmpfiles.d Konfiguration fuer Runtime-Verzeichnisse
  mkdir -p "${STAGE_POSTFIX}/usr/lib/tmpfiles.d"
  cat > "${STAGE_POSTFIX}/usr/lib/tmpfiles.d/postfix-custom.conf" <<'EOF'
# Postfix runtime directories
d /run/postfix 2775 postfix postdrop -
d /var/spool/postfix 2775 postfix postdrop -
d /var/spool/postfix/maildrop 1730 postfix postdrop -
d /var/spool/postfix/public 2755 postfix postdrop -
EOF
  log "tmpfiles.d/postfix-custom.conf erstellt"

  # Post-Install / Post-Remove Scripts
  local postinst="/tmp/postfix-postinst.sh"
  local postrm="/tmp/postfix-postrm.sh"

  cat > "$postinst" <<'POSTINST'
#!/bin/sh
set -e

# System-User/Group anlegen falls nicht vorhanden
if ! id -u postfix >/dev/null 2>&1; then
  adduser --system --group --home /var/spool/postfix --no-create-home \
    --gecos "Postfix Mail Server" --shell /usr/sbin/nologin postfix 2>/dev/null || true
fi
if ! getent group postdrop >/dev/null 2>&1; then
  addgroup --system postdrop 2>/dev/null || true
fi

# Verzeichnisse erstellen
mkdir -p /var/spool/postfix /var/lib/postfix /var/run/postfix
chown postfix:postfix /var/lib/postfix 2>/dev/null || true

# Logrotate
if [ ! -f /etc/logrotate.d/postfix-custom ]; then
  cat > /etc/logrotate.d/postfix-custom <<'LR'
/var/log/mail.log /var/log/mail.err /var/log/mail.info {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 syslog adm
}
LR
fi

# Create chroot structure for postfix
if [ -d /var/spool/postfix ]; then
  mkdir -p /var/spool/postfix/etc
  mkdir -p /var/spool/postfix/dev
  mkdir -p /var/spool/postfix/usr/lib
  for f in /etc/localtime /etc/nsswitch.conf /etc/resolv.conf /etc/hosts /etc/services; do
    [ -f "$f" ] && cp "$f" /var/spool/postfix${f} 2>/dev/null || true
  done
fi

  # Build initial alias database
  if [ -f /etc/postfix/aliases ] || [ -f /etc/aliases ]; then
    command -v newaliases >/dev/null 2>&1 && newaliases 2>/dev/null || true
  fi

  # Copy default Postfix configs on fresh install
  if [ ! -f /etc/postfix/main.cf ]; then
    echo "INFO: Keine main.cf gefunden – installiere Default-Konfiguration"
    if [ -f /usr/share/postfix/main.cf.dist ]; then
      cp /usr/share/postfix/main.cf.dist /etc/postfix/main.cf
    fi
    if [ -f /usr/share/postfix/master.cf.dist ]; then
      cp /usr/share/postfix/master.cf.dist /etc/postfix/master.cf
    fi
    # Run basic postconf for default settings
    command -v postconf >/dev/null 2>&1 && {
      postconf -e "myhostname = $(hostname -f 2>/dev/null || hostname)"
      postconf -e "mydestination = \$myhostname, localhost.localdomain, localhost"
      postconf -e "inet_interfaces = all"
      postconf -e "inet_protocols = all"
    } || true
    # Build alias database
    command -v newaliases >/dev/null 2>&1 && newaliases 2>/dev/null || true
  fi

  # Create rsyslog config for postfix if missing
  if [ ! -f /etc/rsyslog.d/postfix.conf ] && [ -d /etc/rsyslog.d ]; then
    echo "mail.* -/var/log/mail.log" > /etc/rsyslog.d/postfix-custom.conf 2>/dev/null || true
  fi

  ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true

# apt-mark hold – verhindert ueberschreiben durch apt upgrade
command -v apt-mark >/dev/null 2>&1 && apt-mark hold postfix-custom || true
POSTINST
  chmod 755 "$postinst"

  cat > "$postrm" <<'POSTRM'
#!/bin/sh
set -e

command -v apt-mark >/dev/null 2>&1 && apt-mark unhold postfix-custom 2>/dev/null || true
rm -f /etc/logrotate.d/postfix-custom
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
POSTRM
  chmod 755 "$postrm"

  local deb_file="$PACKAGE_DIR/postfix-custom_${POSTFIX_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  # Map-.so aus Core-Staging entfernen – die kommen in eigene Pakete
  local shlib_dir="${STAGE_POSTFIX}/usr/lib/postfix"
  if [ -d "$shlib_dir" ]; then
    local map_so_count=0
    for m in "${MAP_TYPES[@]}"; do
      local soname="${MAP_SONAME[$m]}"
      if [ -f "$shlib_dir/$soname" ]; then
        log "Verschiebe $soname aus Core-Staging"
        rm -f "$shlib_dir/$soname"
        map_so_count=$((map_so_count + 1))
      fi
    done
    log "$map_so_count Map-.so aus Core-Staging entfernt"
  fi

  # dynamicmaps.cf patchen: nur noch Core-Eintraege behalten
  if [ -f "${STAGE_POSTFIX}/etc/postfix/dynamicmaps.cf" ]; then
    local dmcfg="${STAGE_POSTFIX}/etc/postfix/dynamicmaps.cf"
    for m in "${MAP_TYPES[@]}"; do
      local soname="${MAP_SONAME[$m]}"
      sed -i "/${soname}/d" "$dmcfg" 2>/dev/null || true
    done
    log "dynamicmaps.cf: Map-Eintraege entfernt (werden in Map-Pakete ausgelagert)"
  fi

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         postfix-custom \
    --version      "$POSTFIX_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Postfix MTA $POSTFIX_VERSION – custom build (ISPConfig/SASL/TLS)" \
    --depends      "libssl3 | libssl3t64" \
    --depends      "libsasl2-2 | libsasl2-2t64" \
    --depends      libicu74 \
    --conflicts    postfix \
    --provides     postfix \
    --replaces     postfix \
    --deb-no-default-config-files \
    --after-install  "$postinst" \
    --after-remove   "$postrm" \
    --force \
    --package      "$deb_file" \
    --chdir        "$STAGE_POSTFIX" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"

  # Paketinhalt verifizieren
  log "Paketinhalt-Verifikation:"
  dpkg-deb --contents "$deb_file" | awk '{print $NF}' \
    | grep -E "(postfix$|postconf|smtpd|postfix\.service)" \
    | sort | tee -a "$LOG_FILE" || true

  # Map-Typen prüfen
  log "Verfügbare Map-Typen werden nach Installation sichtbar via: postconf -m"

  echo ""
  log "===== Paket fertig ====="
  find "$deb_file" -maxdepth 0 -printf "%s bytes %p\n" | tee -a "$LOG_FILE"

  generate_checksums

  echo ""
  echo "HINWEIS: /etc/postfix ist NICHT im Paket."
  echo "         Konfiguration wird durch 'backup' / 'restore' verwaltet."
  echo ""
  echo "Nächster Schritt: $0 install"
}

# ------------------------------------------------------------------------------
# .deb-Pakete: Postfix Map-Module (separat)
#
# Jede dynamisch geladene Map (mysql, pgsql, ldap, sqlite, pcre, lmdb, cdb)
# bekommt ein eigenes .deb-Paket.
#
# Struktur pro Paket:
#   /usr/lib/postfix/<soname>          – Shared Object
#   /usr/share/postfix/dynamicmaps.d/<soname>.cf – dynamicmaps Eintrag
#
# Nach der Installation traegt postinst den Map-Typ in dynamicmaps.cf ein.
# ------------------------------------------------------------------------------
create_map_packages() {
  local arch
  arch="$(dpkg --print-architecture)"

  local build_dir="$BUILD_ROOT/postfix-${POSTFIX_VERSION}"
  local shlib_dir="${STAGE_POSTFIX}/usr/lib/postfix"

  # Map-.so koennen im Staging liegen (wurden dort ggf. schon entfernt)
  # oder im Build-Verzeichnis unter lib/
  local map_src_dir="$build_dir/lib"

  local mod_postinst="/tmp/postfix-map-postinst.sh"
  local mod_postrm="/tmp/postfix-map-postrm.sh"

  cat > "$mod_postinst" <<'MAPPOSTINST'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
MAPPOSTINST
  chmod 755 "$mod_postinst"

  cat > "$mod_postrm" <<'MAPPOSTRM'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
MAPPOSTRM
  chmod 755 "$mod_postrm"

  local pkg_ok=0
  local pkg_fail=0

  for m in "${MAP_TYPES[@]}"; do
    local soname="${MAP_SONAME[$m]}"
    local pkg_name="${MAP_PKGNAME[$m]}"
    local desc="${MAP_DESC[$m]}"
    local deps="${MAP_DEPS[$m]}"
    local conflicts="${MAP_CONFLICTS[$m]}"

    log "Erstelle Map-Paket: $pkg_name"

    # .so finden: zuerst im Build-lib-Verzeichnis, dann im Staging, dann in src/util/
    local so_src=""
    if [ -f "$map_src_dir/$soname" ]; then
      so_src="$map_src_dir/$soname"
    elif [ -f "$shlib_dir/$soname" ]; then
      so_src="$shlib_dir/$soname"
    elif [ -f "$build_dir/src/util/$soname" ]; then
      so_src="$build_dir/src/util/$soname"
    elif [ -f "$build_dir/src/global/$soname" ]; then
      so_src="$build_dir/src/global/$soname"
    fi

    if [ -z "$so_src" ]; then
      log "  [SKIP] $pkg_name – $soname nicht gefunden"
      pkg_fail=$((pkg_fail + 1))
      continue
    fi

    local map_stage="/tmp/postfix-map-stage-${m}"
    rm -rf "$map_stage"
    mkdir -p "$map_stage/usr/lib/postfix"
    mkdir -p "$map_stage/usr/share/doc/${pkg_name}"
    mkdir -p "$map_stage/usr/share/postfix/dynamicmaps.d"

    cp "$so_src" "$map_stage/usr/lib/postfix/"
    log "  [OK] $soname"

    # dynamicmaps.d Eintrag erstellen
    # Format: maptype  soname  path-to-driver  make(1)  flags
    local maptype
    maptype="${soname#postfix-}"
    maptype="${maptype%.so}"
    printf "%s\t%s\t/usr/lib/postfix/%s\tdict_%s_open\t%s\n" "${maptype}" "${soname}" "${soname}" "${maptype}" "${maptype}" \
      > "$map_stage/usr/share/postfix/dynamicmaps.d/${soname}.cf"

    # Man page (falls vorhanden)
    local man_file="$build_dir/man/man5/${maptype}_table.5"
    if [ -f "$man_file" ]; then
      mkdir -p "$map_stage/usr/share/man/man5"
      cp "$man_file" "$map_stage/usr/share/man/man5/${maptype}_table.5"
      gzip -f "$map_stage/usr/share/man/man5/${maptype}_table.5" 2>/dev/null || true
    fi

    local deb_file="$PACKAGE_DIR/${pkg_name}_${POSTFIX_VERSION}_${arch}.deb"

    local fpm_deps=""
    local dep
    for dep in $deps; do
      fpm_deps="$fpm_deps --depends $dep"
    done

    set +e
    eval fpm \
      --input-type   dir \
      --output-type  deb \
      --name         "$pkg_name" \
      --version      "$POSTFIX_VERSION" \
      --iteration    1 \
      --architecture "$arch" \
      --maintainer   "\"local build <root@localhost>\"" \
      --description  "\"$desc (Postfix $POSTFIX_VERSION)\"" \
      ${fpm_deps} \
      --conflicts    "$conflicts" \
      --provides     "$conflicts" \
      --replaces     "$conflicts" \
      --deb-no-default-config-files \
      --after-install  "$mod_postinst" \
      --after-remove   "$mod_postrm" \
      --force \
      --package      "$deb_file" \
      --chdir        "$map_stage" \
      . 2>&1 | tee -a "$LOG_FILE"
    local fpm_rc=${PIPESTATUS[0]}
    set -e

    if [ "$fpm_rc" -eq 0 ]; then
      log "  Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
      pkg_ok=$((pkg_ok + 1))
    else
      log "  [FAIL] fpm fuer $pkg_name (Exit $fpm_rc)"
      pkg_fail=$((pkg_fail + 1))
    fi

    rm -rf "$map_stage"
  done

  log "Map-Pakete: $pkg_ok erfolgreich, $pkg_fail fehlgeschlagen/uebersprungen"
}

# ------------------------------------------------------------------------------
# .deb-Paket: postfix-custom-dev (Header-Dateien)
#
# Enthaelt die Postfix-Include-Header fuer die Entwicklung von
# Postfix-Plugins und Third-Party-Erweiterungen.
# ------------------------------------------------------------------------------
create_dev_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  local build_dir="$BUILD_ROOT/postfix-${POSTFIX_VERSION}"
  local dev_stage="/tmp/postfix-dev-stage"
  rm -rf "$dev_stage"
  mkdir -p "$dev_stage/usr/include/postfix"
  mkdir -p "$dev_stage/usr/share/doc/postfix-custom-dev"

  # Header aus dem Quellverzeichnis kopieren
  local hdr_count=0
  for h in "$build_dir"/src/include/*.h; do
    if [ -f "$h" ]; then
      cp "$h" "$dev_stage/usr/include/postfix/"
      hdr_count=$((hdr_count + 1))
    fi
  done
  log "Postfix dev: $hdr_count Header-Dateien kopiert"

  if [ "$hdr_count" -eq 0 ]; then
    log "SKIP postfix-custom-dev – keine Header-Dateien gefunden"
    rm -rf "$dev_stage"
    return 0
  fi

  local deb_file="$PACKAGE_DIR/postfix-custom-dev_${POSTFIX_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         postfix-custom-dev \
    --version      "$POSTFIX_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Postfix $POSTFIX_VERSION – development headers" \
    --depends      postfix-custom \
    --conflicts    postfix-dev \
    --provides     postfix-dev \
    --replaces     postfix-dev \
    --deb-no-default-config-files \
    --force \
    --package      "$deb_file" \
    --chdir        "$dev_stage" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
  rm -rf "$dev_stage"
}

# ------------------------------------------------------------------------------
# Nach-Install Verifikation
# ------------------------------------------------------------------------------
verify_build() {
  echo ""
  echo "=============================================="
  echo " Postfix Modul-Verifikation"
  echo "=============================================="

  if command -v postconf >/dev/null 2>&1; then
    echo ""
    echo "--- Verfügbare Map-Typen (postconf -m) ---"
    postconf -m | tr '\n' ' '
    echo ""
    echo ""
    echo "--- Wichtige Map-Typen ---"
    local maps
    maps="$(postconf -m)"
    for m in mysql ldap pcre lmdb sqlite; do
      if echo "$maps" | grep -qw "$m"; then
        echo "  [OK] $m"
      else
        echo "  [!!] $m FEHLT"
      fi
    done

    echo ""
    echo "--- TLS-Support ---"
    postconf -a 2>/dev/null | grep -i tls || echo "  (postconf -a nicht verfügbar)"

    echo ""
    echo "--- SASL-Support ---"
    postconf -A 2>/dev/null | head -5 || echo "  (postconf -A nicht verfügbar)"

    echo ""
    echo "--- Version ---"
    postfix version 2>/dev/null || true
  else
    echo "postconf nicht gefunden – Postfix noch nicht installiert"
  fi
  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Paket via dpkg installieren
# ------------------------------------------------------------------------------
install_packages() {
  local deb_file
  deb_file=$(find "$PACKAGE_DIR" -maxdepth 1 -name "postfix-custom_*.deb" 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$deb_file" ] || die "Kein postfix-custom.deb in $PACKAGE_DIR – bitte zuerst: $0 package"

  # Sicherheitscheck: /etc/postfix muss vorhanden sein
  if [ ! -f /etc/postfix/main.cf ]; then
    log "WARNUNG: /etc/postfix/main.cf nicht gefunden!"
    read -r -p "Trotzdem fortfahren? (ja/nein): " antwort
    [ "$antwort" = "ja" ] || die "Abgebrochen"
  fi

  # Prüfen ob /etc/postfix im Paket steckt (Sicherheit)
  if dpkg-deb --contents "$deb_file" 2>/dev/null | awk '{print $NF}' | grep -q "^\./etc/postfix"; then
    die "FEHLER: $deb_file enthält /etc/postfix – Paket neu erstellen!"
  fi

  log "Installiere: $(basename "$deb_file")"
  DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_file"

  # Map-Pakete installieren
  local deb_maps
  deb_maps=$(find "$PACKAGE_DIR" -maxdepth 1 -name "postfix-custom-*_*.deb" 2>/dev/null | sort || true)
  if [ -n "$deb_maps" ]; then
    log "Installiere Map-Pakete..."
    for deb_map in $deb_maps; do
      log "  $(basename "$deb_map")"
    done
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_maps" 2>&1 | tee -a "$LOG_FILE" || true
  fi

  # Fehlende Abhängigkeiten nachziehen
  apt-get install -f -y || true

  log "Konfiguration in /etc/postfix: unverändert"
}

# ------------------------------------------------------------------------------
# Dienst neu starten
# ------------------------------------------------------------------------------
restart_service() {
  log "Starte Postfix neu"
  systemctl daemon-reload
  systemctl enable postfix
  systemctl restart postfix
}

# ------------------------------------------------------------------------------
# Post-Checks
# ------------------------------------------------------------------------------
post_checks() {
  log "Prüfe Installation"
  command -v postfix >/dev/null 2>&1 || die "postfix-Binary nicht gefunden"
  log "Postfix Version: $(postfix version 2>&1)"

  log "Konfigurationscheck (postfix check)"
  postfix check >> "$LOG_FILE" 2>&1 \
    || log "WARNUNG: Konfigurationsfehler – Log prüfen: $LOG_FILE"

  if ! systemctl is-active --quiet postfix; then
    systemctl status postfix --no-pager || true
    die "Postfix läuft nicht"
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

  systemctl stop postfix 2>/dev/null || true

  # Custom-Paket zuerst deinstallieren
  if dpkg -s postfix-custom >/dev/null 2>&1; then
    log "Deinstalliere postfix-custom"
    dpkg -r postfix-custom || true
  fi

  # Konfiguration
  if [ -d "$backup_dir/etc_postfix" ]; then
    rm -rf /etc/postfix
    cp -a "$backup_dir/etc_postfix" /etc/postfix
    chmod 755 /etc/postfix
    log "/etc/postfix wiederhergestellt"
  fi

  # Binaries
  [ -f "$backup_dir/usr_sbin_postfix" ] && {
    cp -a "$backup_dir/usr_sbin_postfix" /usr/sbin/postfix
    chmod 755 /usr/sbin/postfix
  }
  [ -d "$backup_dir/usr_lib_postfix" ] && {
    rm -rf /usr/lib/postfix
    cp -a "$backup_dir/usr_lib_postfix" /usr/lib/postfix
  }

  # Systemd
  [ -f "$backup_dir/postfix.service" ] && {
    cp -a "$backup_dir/postfix.service" /lib/systemd/system/postfix.service
    chmod 644 /lib/systemd/system/postfix.service
  }

  # apt-Pakete (alte Installation aus apt)
  if [ -f "$backup_dir/packages.txt" ] && [ -s "$backup_dir/packages.txt" ]; then
    log "Stelle apt-Pakete wieder her"
    apt-get update -qq || true
    xargs -r apt-get install --reinstall -y < "$backup_dir/packages.txt" || true
  fi

  systemctl daemon-reload
  systemctl enable postfix
  systemctl restart postfix || true

  log "Restore abgeschlossen"
}

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------
status_cmd() {
  echo "=============================================="
  echo " Postfix Status – $(date)"
  echo "=============================================="

  if command -v postfix >/dev/null 2>&1; then
    echo "Binary  : $(command -v postfix)"
    echo "Version : $(postfix version 2>/dev/null || echo 'unbekannt')"
  else
    echo "Postfix-Binary: NICHT GEFUNDEN"
  fi

  echo ""
  echo "--- Installiertes Custom-Paket ---"
  if dpkg -s postfix-custom >/dev/null 2>&1; then
    echo "  [OK] postfix-custom $(dpkg -s postfix-custom | awk '/^Version:/{print $2}')"
  else
    echo "  [--] postfix-custom nicht installiert"
  fi

  echo ""
  echo "--- systemctl status postfix ---"
  systemctl status postfix --no-pager || true

  if command -v postconf >/dev/null 2>&1; then
    echo ""
    echo "--- Map-Typen (postconf -m) ---"
    postconf -m | tr '\n' ' '
    echo ""
  fi

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
  postfix check || die "Konfigurationsfehler"
}

uninstall_cmd() {
  log "Deinstalliere postfix-custom Pakete"
  systemctl stop postfix 2>/dev/null || true
  for m in "${MAP_TYPES[@]}"; do
    local pkg="${MAP_PKGNAME[$m]}"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      dpkg -r "$pkg" || true
      log "$pkg entfernt"
    fi
  done
  if dpkg -s postfix-custom-dev >/dev/null 2>&1; then
    dpkg -r postfix-custom-dev || true
    log "postfix-custom-dev entfernt"
  fi
  if dpkg -s postfix-custom >/dev/null 2>&1; then
    dpkg -r postfix-custom
    log "postfix-custom entfernt"
  else
    log "postfix-custom war nicht installiert"
  fi
}

# ------------------------------------------------------------------------------
# Vollständiger Paket-Build (Schritt 1 – nichts installieren)
# ------------------------------------------------------------------------------
package_all() {
  log "=== Starte Postfix Paket-Build ==="
  install_build_deps
  prepare_sources
  build_postfix
  create_deb_package
  create_map_packages
  create_dev_package
  sign_packages
  log "=== Paket-Build abgeschlossen ==="
  echo ""
  update_local_repo_if_configured

  echo "Nächster Schritt: $0 install"
}

# ------------------------------------------------------------------------------
# Installation (Schritt 2 – Backup + dpkg -i)
# ------------------------------------------------------------------------------
install_all() {
  log "=== Starte Installation ==="
  log "Schritt 1/4: Backup erstellen"
  create_backup
  log "Schritt 2/4: Paket installieren (/etc/postfix bleibt unberührt)"
  install_packages
  log "Schritt 3/4: Postfix neu starten"
  restart_service
  log "Schritt 4/4: Verifikation"
  post_checks
  log "=== Installation abgeschlossen ==="
  echo ""
  echo "Zusammenfassung:"
  echo "  Backup:        $LATEST_LINK"
  echo "  Paket:         $PACKAGE_DIR"
  echo "  Konfiguration: /etc/postfix  (UNVERÄNDERT)"
  echo "  Log:           $LOG_FILE"
}

# ------------------------------------------------------------------------------
# Main
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
    echo "FEHLER: Dieses Skript unterstützt nur Ubuntu 24.04 (oder neuer) auf arm64." >&2
    exit 1
  fi

}

main() {
  check_os_arch

  # --screen vor den restlichen Argumenten herausfiltern
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
    echo "Starte Skript in Screen Session: postfix_build ..."
    exec screen -dmS postfix_build bash "$0" "$@"
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
