#!/usr/bin/env bash
# ==============================================================================
# setup_dovecot.sh – Dovecot Build-from-Source + .deb-Paketerstellung
# Zielumgebung : Ubuntu 24.04 ARM64, ISPConfig, Postfix, vmail, SQL-Auth
#
# Empfohlener Ablauf:
#   1. setup_dovecot.sh package   → .deb-Pakete bauen (nichts installieren)
#   2. setup_dovecot.sh install   → Backup + dpkg -i der erzeugten Pakete
#
# Deinstallation später:
#   setup_dovecot.sh uninstall
#   oder: dpkg -r dovecot-pigeonhole-custom dovecot-core-custom
#
# Restore auf altes System:
#   setup_dovecot.sh restore [<backup-dir>]
# ==============================================================================
set -Eeuo pipefail

if [[ ! -f "setup_dovecot.env" ]]; then
  echo "FEHLER: setup_dovecot.env nicht gefunden. Bitte aus setup_dovecot.env.example erstellen." >&2
  exit 1
fi
source "setup_dovecot.env"

# Offizielle Tarballs (stabiler als Git-Clone, enthalten fertige configure-Skripte)
DOVECOT_TARBALL="https://dovecot.org/releases/2.4/dovecot-${DOVECOT_VERSION}.tar.gz"
PIGEONHOLE_TARBALL="https://pigeonhole.dovecot.org/releases/2.4/dovecot-pigeonhole-${PIGEONHOLE_VERSION}.tar.gz"

PREFIX="/usr"
SYSCONFDIR="/etc"
LOCALSTATEDIR="/var"
LIBEXECDIR="/usr/lib/dovecot"
SSLDIR="/etc/ssl"

# Staging-Verzeichnisse (DESTDIR für make install)
STAGE_DOVECOT="/tmp/dovecot-stage"
STAGE_PIGEONHOLE="/tmp/pigeonhole-stage"

# ------------------------------------------------------------------------------
# Dovecot Sub-Package-Definitionen
#
# Ubuntu/Debian teilt Dovecot in viele separate Pakete auf:
#   dovecot-mysql, dovecot-pgsql, dovecot-sqlite, dovecot-ldap,
#   dovecot-gssapi, dovecot-solr, dovecot-imapd, dovecot-pop3d, dovecot-lmtpd
#
# Jedes Sub-Paket enthaelt nur die entsprechenden .so-Module.
# Der Core-Paket (dovecot-core-custom) stellt das Binary + Core-Module bereit.
#
# SUB_SOFIND   – find-Pattern fuer die .so-Dateien (unter modules/)
# SUB_PKGNAME  – .deb-Paketname
# SUB_DESC     – Kurzbeschreibung
# SUB_DEPS     – Zusaetzliche Paket-Abhaengigkeiten (Leerzeichen-getrennt)
# SUB_CONFLICTS – Offizielles Ubuntu-Paket das ersetzt wird
# ------------------------------------------------------------------------------
declare -A SUB_SOFIND SUB_PKGNAME SUB_DESC SUB_DEPS SUB_CONFLICTS

# --- MySQL/MariaDB -----------------------------------------------------------
SUB_SOFIND[mysql]="libdriver_mysql.so"
SUB_PKGNAME[mysql]="dovecot-custom-mysql"
SUB_DESC[mysql]="Dovecot MySQL/MariaDB support"
SUB_DEPS[mysql]="dovecot-core-custom libmariadb3"
SUB_CONFLICTS[mysql]="dovecot-mysql"

# --- PostgreSQL ---------------------------------------------------------------
SUB_SOFIND[pgsql]="libdriver_pgsql.so"
SUB_PKGNAME[pgsql]="dovecot-custom-pgsql"
SUB_DESC[pgsql]="Dovecot PostgreSQL support"
SUB_DEPS[pgsql]="dovecot-core-custom libpq5"
SUB_CONFLICTS[pgsql]="dovecot-pgsql"

# --- SQLite -------------------------------------------------------------------
SUB_SOFIND[sqlite]="libdriver_sqlite.so"
SUB_PKGNAME[sqlite]="dovecot-custom-sqlite"
SUB_DESC[sqlite]="Dovecot SQLite support"
SUB_DEPS[sqlite]="dovecot-core-custom libsqlite3-0"
SUB_CONFLICTS[sqlite]="dovecot-sqlite"

# --- LDAP ---------------------------------------------------------------------
SUB_SOFIND[ldap]="libauthdb_ldap.so"
SUB_PKGNAME[ldap]="dovecot-custom-ldap"
SUB_DESC[ldap]="Dovecot LDAP support"
SUB_DEPS[ldap]="dovecot-core-custom libldap-2.5-0"
SUB_CONFLICTS[ldap]="dovecot-ldap"

# --- GSSAPI/Kerberos ----------------------------------------------------------
SUB_SOFIND[gssapi]="libmech_gssapi.so"
SUB_PKGNAME[gssapi]="dovecot-custom-gssapi"
SUB_DESC[gssapi]="Dovecot GSSAPI/Kerberos authentication"
SUB_DEPS[gssapi]="dovecot-core-custom libkrb5-3"
SUB_CONFLICTS[gssapi]="dovecot-gssapi"

# --- Solr (FTS) ---------------------------------------------------------------
SUB_SOFIND[solr]="lib21_fts_solr_plugin.so"
SUB_PKGNAME[solr]="dovecot-custom-solr"
SUB_DESC[solr]="Dovecot Solr full-text search"
SUB_DEPS[solr]="dovecot-core-custom libexpat1"
SUB_CONFLICTS[solr]="dovecot-solr"

# --- IMAP protocol ------------------------------------------------------------
SUB_SOFIND[imapd]="lib02_imap_acl_plugin.so"
SUB_PKGNAME[imapd]="dovecot-custom-imapd"
SUB_DESC[imapd]="Dovecot IMAP daemon"
SUB_DEPS[imapd]="dovecot-core-custom"
SUB_CONFLICTS[imapd]="dovecot-imapd"

# --- POP3 protocol ------------------------------------------------------------
SUB_SOFIND[pop3d]="libpop3"
SUB_PKGNAME[pop3d]="dovecot-custom-pop3d"
SUB_DESC[pop3d]="Dovecot POP3 daemon"
SUB_DEPS[pop3d]="dovecot-core-custom"
SUB_CONFLICTS[pop3d]="dovecot-pop3d"

# --- LMTP protocol ------------------------------------------------------------
SUB_SOFIND[lmtpd]="liblmtp"
SUB_PKGNAME[lmtpd]="dovecot-custom-lmtpd"
SUB_DESC[lmtpd]="Dovecot LMTP server"
SUB_DEPS[lmtpd]="dovecot-core-custom"
SUB_CONFLICTS[lmtpd]="dovecot-lmtpd"

DOVECOT_SUBPACKAGES=(
  mysql
  pgsql
  sqlite
  ldap
  gssapi
  solr
  imapd
  pop3d
  lmtpd
)

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
die() { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausführen."
}

usage() {
  cat <<'EOF'
Verwendung:
  setup_dovecot.sh [--screen] <Befehl>

Optionen:
  --screen              Skript in einer GNU Screen Session ausführen (optional)

Befehle:
  package              – Beide Pakete bauen (dovecot-core + pigeonhole)
  package-dovecot      – Nur dovecot-core bauen + .deb erstellen
  package-pigeonhole   – Nur pigeonhole bauen + .deb erstellen
                         (setzt fertigen dovecot-core Tarball voraus)
  install              – Backup + dpkg -i der erzeugten .deb-Pakete
  build-only           – Nur kompilieren, kein Paket, kein install
  backup               – Nur Backup erstellen
  restore              – Letztes Backup einspielen
  restore /root/dovecot-backup/<timestamp>
  status               – Zustand anzeigen
  list-backups         – Verfügbare Backups auflisten
  list-packages        – Erzeugte .deb-Pakete auflisten
  check-config         – dovecot -n ausführen
  uninstall            – Custom-Pakete via dpkg -r entfernen

Deinstallation manuell:
  dpkg -r dovecot-pigeonhole-custom dovecot-core-custom
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

  systemctl stop dovecot 2>/dev/null || true

  [ -d /etc/dovecot ]                        && cp -a /etc/dovecot                        "$backup_dir/etc_dovecot"
  [ -f /usr/sbin/dovecot ]                   && cp -a /usr/sbin/dovecot                   "$backup_dir/usr_sbin_dovecot"
  [ -d /usr/lib/dovecot ]                    && cp -a /usr/lib/dovecot                    "$backup_dir/usr_lib_dovecot"
  [ -f /lib/systemd/system/dovecot.service ] && cp -a /lib/systemd/system/dovecot.service "$backup_dir/dovecot.service"
  [ -f /lib/systemd/system/dovecot.socket ]  && cp -a /lib/systemd/system/dovecot.socket  "$backup_dir/dovecot.socket"
  [ -f /etc/default/dovecot ]                && cp -a /etc/default/dovecot                "$backup_dir/etc_default_dovecot"
  # SQL-Config gesondert sichern (Zugangsdaten, nur root lesbar)
  [ -f /etc/dovecot/dovecot-sql.conf ]       && cp -a /etc/dovecot/dovecot-sql.conf       "$backup_dir/dovecot-sql.conf"
  [ -f /etc/dovecot/dh.pem ]                 && cp -a /etc/dovecot/dh.pem                 "$backup_dir/dh.pem"

  dpkg -l 2>/dev/null | awk '/^ii/ && /dovecot/ {print $2}' > "$backup_dir/packages.txt" || true

  if command -v dovecot >/dev/null 2>&1; then
    dovecot --version > "$backup_dir/dovecot-version.txt" 2>&1 || true
    dovecot -n        > "$backup_dir/dovecot-config.txt"  2>&1 || true
  fi

  # Erzeugte Custom-.deb-Pakete mit sichern
  if [ -d "$PACKAGE_DIR" ] && ls "$PACKAGE_DIR"/*.deb >/dev/null 2>&1; then
    cp -a "$PACKAGE_DIR" "$backup_dir/deb-packages" || true
  fi

  ln -sfn "$backup_dir" "$LATEST_LINK"
  log "Backup fertig: $backup_dir"
}

# ------------------------------------------------------------------------------
# Build-Abhängigkeiten + fpm
# ------------------------------------------------------------------------------
install_build_deps() {
  log "Installiere Build-Abhängigkeiten"

  # saturn nutzt MariaDB 12.x – libmysqlclient-dev (Oracle) muss vorher
  # entfernt werden da es mit libmariadb-dev kollidiert.
  # libmariadb-dev liefert dieselbe API für --with-mysql im Dovecot-Build.
  if dpkg -s libmysqlclient-dev >/dev/null 2>&1; then
    log "Entferne libmysqlclient-dev (kollidiert mit libmariadb-dev)"
    apt-get remove -y libmysqlclient-dev || true
  fi

  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential autoconf automake libtool pkg-config gettext make git \
    wget curl \
    libssl-dev \
    libbz2-dev \
    zlib1g-dev \
    liblz4-dev \
    libzstd-dev \
    libsqlite3-dev \
    libicu-dev \
    libcap-dev \
    libpam0g-dev \
    bison flex \
    libmariadb-dev \
    libldap2-dev \
    libexttextcat-dev \
    libsodium-dev \
    liblua5.4-dev \
    libsasl2-dev \
    libkrb5-dev \
    libgssapi-krb5-2 \
    libsystemd-dev \
    libunwind-dev \
    libgdbm-dev \
    ruby ruby-dev rubygems rpm \
    libpq-dev \
    libclucene-dev \
    libcurl4-openssl-dev \
    libexpat1-dev \
    dpkg-sig

  if ! command -v fpm >/dev/null 2>&1; then
    log "Installiere fpm"
    gem install --no-document fpm
  else
    log "fpm bereits vorhanden: $(fpm --version)"
  fi
}

# ------------------------------------------------------------------------------
# Quellen klonen
# ------------------------------------------------------------------------------
prepare_sources() {
  mkdir -p "$BUILD_ROOT"
  cd "$BUILD_ROOT"
  rm -rf core pigeonhole

  # Dovecot Tarball
  local dc_tar="dovecot-${DOVECOT_VERSION}.tar.gz"
  if [ ! -f "$dc_tar" ]; then
    log "Lade Dovecot $DOVECOT_VERSION Tarball"
    wget -q --show-progress "$DOVECOT_TARBALL" -O "$dc_tar"       || curl -L --progress-bar "$DOVECOT_TARBALL" -o "$dc_tar"       || die "Download Dovecot Tarball fehlgeschlagen"
  else
    log "Dovecot Tarball bereits vorhanden: $dc_tar"
  fi
  tar xzf "$dc_tar"
  mv "dovecot-${DOVECOT_VERSION}" core
  log "Dovecot Quellen: $BUILD_ROOT/core"
  [ -x core/configure ] || die "configure fehlt im Dovecot-Tarball"

  # Pigeonhole Tarball
  local ph_tar="dovecot-pigeonhole-${PIGEONHOLE_VERSION}.tar.gz"
  if [ ! -f "$ph_tar" ]; then
    log "Lade Pigeonhole $PIGEONHOLE_VERSION Tarball"
    wget -q --show-progress "$PIGEONHOLE_TARBALL" -O "$ph_tar"       || curl -L --progress-bar "$PIGEONHOLE_TARBALL" -o "$ph_tar"       || die "Download Pigeonhole Tarball fehlgeschlagen"
  else
    log "Pigeonhole Tarball bereits vorhanden: $ph_tar"
  fi
  tar xzf "$ph_tar"
  mv "dovecot-pigeonhole-${PIGEONHOLE_VERSION}" pigeonhole
  log "Pigeonhole Quellen: $BUILD_ROOT/pigeonhole"
  [ -x pigeonhole/configure ] || die "configure fehlt im Pigeonhole-Tarball"
}

# ------------------------------------------------------------------------------
# Dovecot Core: configure + make (kein make install ins echte System)
# ------------------------------------------------------------------------------
build_dovecot() {
  cd "$BUILD_ROOT/core"
  log "Konfiguriere Dovecot $DOVECOT_VERSION"

  # Kein autogen.sh – Tarball enthält fertige configure-Skripte
  [ -x ./configure ] || die "configure fehlt in $BUILD_ROOT/core – Tarball prüfen"

  # ---- Configure-Flags Übersicht ----
  #
  # PROTOKOLLE (werden als .so-Module gebaut, keine separaten apt-Pakete nötig):
  #   imap, pop3, lmtp automatisch dabei wenn --prefix gesetzt
  #
  # IMAP IDLE / Push-Mail:
  #   --with-notify=inotify  Kernel meldet neue Mails sofort (<1s), kein Polling
  #   --with-ioloop=best     epoll auf Linux, effizient bei vielen IDLE-Verbindungen
  #
  # DATENBANK / AUTH:
  #   --with-mysql           passdb/userdb driver=sql (ISPConfig nutzt MySQL)
  #   --with-sqlite          SQLite als leichtgewichtige Alternative
  #   --with-ldap            LDAP-Auth (optional, ISPConfig kann LDAP nutzen)
  #   --with-pam             PAM-Auth Fallback
  #   --with-gssapi          Kerberos/GSSAPI für Enterprise-Umgebungen
  #
  # SICHERHEIT:
  #   --with-sodium          argon2id Passwort-Hashing (sicherer als MD5/SHA)
  #   --with-ssl=openssl     TLS via OpenSSL (Pflicht für IMAPS/POP3S)
  #
  # KOMPRESSION (Mailbox-Speicherung und Übertragung):
  #   --with-zlib            gz  – weit verbreitet
  #   --with-bzlib           bz2 – bessere Kompression als gz
  #   --with-lzma            xz  – sehr hohe Kompression
  #   --with-lz4             lz4 – sehr schnell, gut für SSD
  #   --with-zstd            zst – beste Balance Speed/Ratio (empfohlen)
  #
  # EXTRAS:
  #   --with-lua             Sieve-Lua-Skripte, push-notification Hooks
  #   --with-icu             Unicode-Unterstützung (Suche in nicht-ASCII Mails)
  #   --with-exttextcat      Spracherkennung für Spam-Filter
  #   --with-unwind          Bessere Crash-Backtraces (Debugging)
  #   --with-systemd         systemd socket activation + journal logging
  #
  # NICHT GESETZT (bewusst):
  #   --with-cassandra       Nur für sehr große Deployments
  #   --enable-doveadm-http  REST-API, kein Bedarf in dieser Umgebung
  CFLAGS="-fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -O2" \
  LDFLAGS="-Wl,-z,relro -Wl,-z,now -pie" \
  ./configure \
    systemdsystemunitdir=/lib/systemd/system \
    --enable-maintainer-mode \
    --prefix="$PREFIX" \
    --sysconfdir="$SYSCONFDIR" \
    --localstatedir="$LOCALSTATEDIR" \
    --libexecdir="$LIBEXECDIR" \
    --with-ssldir="$SSLDIR" \
    --with-ssl=openssl \
    --with-notify=inotify \
    --with-ioloop=best \
    --with-mysql \
    --with-sqlite \
    --with-pgsql \
    --with-solr \
    --with-lucene \
    --with-ldap=yes \
    --with-pam \
    --with-gssapi \
    --with-sodium \
    --with-lua \
    --with-icu \
    --with-exttextcat \
    --with-unwind \
    --with-systemd \
    --with-zlib \
    --with-bzlib \
    --with-lzma \
    --with-lz4 \
    --with-zstd
  log "Dovecot configure OK"

  log "Baue Dovecot (make -j$(nproc))"
  set +e
  make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
  local dc_rc=${PIPESTATUS[0]}
  set -e
  [ "$dc_rc" -eq 0 ] || die "Dovecot make fehlgeschlagen (Exit $dc_rc)"
  log "Dovecot Build fertig"
}

# ------------------------------------------------------------------------------
# Pigeonhole (Sieve): configure + make
#
# dovecot-config wird benötigt damit Pigeonhole die richtigen Include-Pfade
# und Modulverzeichnisse vom Dovecot-Build kennt.
#
# Wo liegt dovecot-config nach "make install DESTDIR=..."?
#   Dovecot installiert es nach: $DESTDIR/$LIBEXECDIR/dovecot-config
#   also:  /tmp/dovecot-stage/usr/lib/dovecot/dovecot-config
#
# WICHTIG: --with-dovecot erwartet den DATEI-Pfad zu dovecot-config,
#          NICHT ein Verzeichnis.
# ------------------------------------------------------------------------------
build_pigeonhole() {
  # --------------------------------------------------------------------------
  # Pigeonhole muss gegen die frisch gebauten Dovecot 2.4 Headers+Libs bauen.
  #
  # Strategie:
  #   1. Dovecot ins Staging installieren → Headers + Libs + dovecot-config
  #   2. Alte System-dovecot-Headers und -Libs deinstallieren (sauber)
  #      statt temporär verstecken (race condition / unbound variable Probleme)
  #   3. Staging-Libs via ldconfig bekannt machen
  #   4. Pigeonhole bauen mit --with-dovecot=Staging-Verzeichnis
  #   5. Nur src/ bauen (kein testsuite/) – Tests linken gegen interne
  #      Symbole die nicht Teil der öffentlichen API sind
  # --------------------------------------------------------------------------

  log "Installiere Dovecot-Core ins Staging (für Pigeonhole-Build)"
  cd "$BUILD_ROOT/core"
  rm -rf "$STAGE_DOVECOT"
  make install DESTDIR="$STAGE_DOVECOT"

  # dovecot-config im Staging finden
  local dovecot_config_dir
  dovecot_config_dir="$(find "$STAGE_DOVECOT" -name "dovecot-config" -type f 2>/dev/null     | head -1 | xargs -r dirname)"
  [ -n "$dovecot_config_dir" ] || die "dovecot-config nicht im Staging gefunden"
  log "dovecot-config Verzeichnis: $dovecot_config_dir"
  chmod +x "$dovecot_config_dir/dovecot-config"

  local staging_inc="$STAGE_DOVECOT/usr/include"
  local staging_lib="$STAGE_DOVECOT/usr/lib"

  # Alte System-dovecot-Headers entfernen damit Pigeonhole zwingend
  # die neuen 2.4 Headers aus dem Staging verwendet
  if [ -d /usr/include/dovecot ]; then
    log "Entferne alte System-dovecot-Headers /usr/include/dovecot"
    rm -rf /usr/include/dovecot
  fi

  # Staging-Headers ins System-Include-Verzeichnis verlinken
  ln -sfn "${staging_inc}/dovecot" /usr/include/dovecot
  log "Staging-Headers verlinkt: /usr/include/dovecot → ${staging_inc}/dovecot"

  # Staging-Libs via ldconfig bekannt machen
  echo "$staging_lib" > /etc/ld.so.conf.d/dovecot-staging.conf
  echo "$staging_lib/dovecot" >> /etc/ld.so.conf.d/dovecot-staging.conf
  ldconfig
  log "Staging-Libs registriert: $staging_lib"

  # Libtool .la-Dateien enthalten hardcodierte Installationspfade (/usr/lib/dovecot/).
  # Pigeonhole liest diese beim Linken – findet die Dateien aber nicht weil Dovecot
  # noch nicht ins echte System installiert ist (nur im Staging).
  # Lösung: alle .la-Dateien im Staging patchen: /usr/lib/ → Staging-Pfad
  log "Patche .la-Dateien im Staging (libtool hardcoded paths)"
  find "$STAGE_DOVECOT" -name "*.la" | while read -r la_file; do
    sed -i \
      -e "s|libdir='/usr/lib/dovecot'|libdir='${staging_lib}/dovecot'|g" \
      -e "s|libdir=\"/usr/lib/dovecot\"|libdir=\"${staging_lib}/dovecot\"|g" \
      -e "s| /usr/lib/dovecot/lib| ${staging_lib}/dovecot/lib|g" \
      -e "s|'/usr/lib/dovecot/lib|'${staging_lib}/dovecot/lib|g" \
      "$la_file"
  done
  log ".la-Dateien gepatcht: $(find "$STAGE_DOVECOT" -name "*.la" | wc -l) Dateien"

  cd "$BUILD_ROOT/pigeonhole"
  log "Konfiguriere Pigeonhole $PIGEONHOLE_VERSION"
  # Kein autogen.sh nötig – Tarball enthält vorgenerierte configure-Skripte
  [ -x ./configure ] || die "configure fehlt in $BUILD_ROOT/pigeonhole – Tarball prüfen"

  set +e
  CPPFLAGS="-I${staging_inc}"   LDFLAGS="-L${staging_lib} -L${staging_lib}/dovecot -Wl,-rpath,${staging_lib} -Wl,-rpath,${staging_lib}/dovecot"   ./configure     --with-dovecot="$dovecot_config_dir"     2>&1 | tee -a "$LOG_FILE"
  local ph_conf_rc=${PIPESTATUS[0]}
  set -e
  [ "$ph_conf_rc" -eq 0 ] || die "Pigeonhole configure fehlgeschlagen (Exit $ph_conf_rc)"

  # ---- Makefile-Patches für hardcodierte Pfade --------------------------------
  # configure schreibt absolute Pfade in generierte Makefiles.
  # Bekanntes Problem: SETTINGS_HISTORY_PY zeigt auf /usr/lib/dovecot/dovecot/settings-history.py
  # Lösung: Echten Pfad im Staging finden und direkt in SETTINGS_HISTORY_PY eintragen
  log "Patche SETTINGS_HISTORY_PY in Pigeonhole Makefiles"

  local settings_hist_py
  settings_hist_py="$(find "$STAGE_DOVECOT" -name "settings-history.py" 2>/dev/null | head -1)"
  if [ -z "$settings_hist_py" ]; then
    # Fallback: in Dovecot-Quellen suchen
    settings_hist_py="$(find "$BUILD_ROOT/core" -name "settings-history.py" 2>/dev/null | head -1)"
  fi

  if [ -n "$settings_hist_py" ]; then
    log "settings-history.py: $settings_hist_py"
    find "$BUILD_ROOT/pigeonhole" -name "Makefile" -print0 \
      | xargs -0 grep -l "settings-history.py" 2>/dev/null \
      | while read -r mk; do
          sed -i "s|^SETTINGS_HISTORY_PY = .*|SETTINGS_HISTORY_PY = ${settings_hist_py}|" "$mk"
          log "Gepatch: $mk"
        done
  else
    die "settings-history.py nicht gefunden – Dovecot-Core-Build prüfen"
  fi



  # Die Test-Binaries in lib-sieve/util/ linken gegen interne Dovecot-Testsymbole
  # (test_out_reason_quiet, test_dir_get usw.) die nicht in libdovecot.so exportiert sind.
  # Loesung: noinst_PROGRAMS und TESTS in der generierten Makefile leeren bevor make laeuft.
  log "Deaktiviere Test-Binaries in lib-sieve/util/Makefile"
  local util_mk="$BUILD_ROOT/pigeonhole/src/lib-sieve/util/Makefile"
  if [ -f "$util_mk" ]; then
    sed -i 's/^noinst_PROGRAMS *=.*/noinst_PROGRAMS =/' "$util_mk"
    sed -i 's/^TESTS *=.*/TESTS =/' "$util_mk"
    log "Test-Binaries deaktiviert"
  else
    log "WARNUNG: $util_mk nicht gefunden"
  fi

  log "Baue Pigeonhole (make -j$(nproc))"
  set +e
  CPPFLAGS="-I${staging_inc}" \
  LDFLAGS="-L${staging_lib} -L${staging_lib}/dovecot -Wl,-rpath,${staging_lib} -Wl,-rpath,${staging_lib}/dovecot" \
  make -j"$(nproc)" \
    2>&1 | tee -a "$LOG_FILE"
  local ph_make_rc=${PIPESTATUS[0]}
  set -e
  [ "$ph_make_rc" -eq 0 ] || die "Pigeonhole make fehlgeschlagen (Exit $ph_make_rc)"

  # Vollständige install-Targets
  log "Installiere Pigeonhole ins Staging"
  set +e
  CPPFLAGS="-I${staging_inc}" \
  LDFLAGS="-L${staging_lib} -L${staging_lib}/dovecot -Wl,-rpath,${staging_lib} -Wl,-rpath,${staging_lib}/dovecot" \
  make install DESTDIR="$STAGE_PIGEONHOLE" 2>&1 | tee -a "$LOG_FILE"
  local ph_inst_rc=${PIPESTATUS[0]}
  set -e
  [ "$ph_inst_rc" -eq 0 ] || die "Pigeonhole make install fehlgeschlagen (Exit $ph_inst_rc)"

  # Gzip man pages
  find "${STAGE_PIGEONHOLE}/usr/share/man" -type f -name '*.?' ! -name '*.gz' -exec gzip -f {} \; 2>/dev/null || true

  # Aufräumen: ldconfig-Eintrag entfernen, Symlink ersetzen durch echten Link
  rm -f /etc/ld.so.conf.d/dovecot-staging.conf
  rm -f /usr/include/dovecot
  ldconfig

  log "Pigeonhole Build fertig"
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
  if ! command -v dpkg-sig >/dev/null 2>&1; then
    log "dpkg-sig nicht installiert – ueberspringe Paketsignierung"
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

  log "Signiere .deb-Pakete mit GPG-Schluessel $gpg_key_id..."
  local sign_count=0
  for deb in "$PACKAGE_DIR"/*.deb; do
    [ -f "$deb" ] || continue
    if dpkg-sig --verify "$deb" 2>/dev/null | grep -q "GOODSIG"; then
      continue
    fi
    if dpkg-sig -k "$gpg_key_id" --sign builder "$deb" >/dev/null 2>&1; then
      sign_count=$((sign_count + 1))
    fi
  done
  log "$sign_count Pakete signiert"
}

# ------------------------------------------------------------------------------
# .deb-Pakete erstellen via fpm
#
# Paketinhalt:
#   dovecot-core-custom      → alles aus STAGE_DOVECOT OHNE /etc/dovecot:
#                              /usr/sbin/, /usr/bin/, /usr/lib/dovecot/,
#                              /usr/lib/libdovecot*.so*, /usr/share/dovecot/,
#                              /lib/systemd/system/dovecot.*
#
#   dovecot-pigeonhole-custom → alles aus STAGE_PIGEONHOLE OHNE /etc:
#                              Sieve-Module (.so), sieve-Binary, ManageSieve
#
# /etc/dovecot wird BEWUSST NICHT verpackt – Konfiguration bleibt beim
# Backup/Restore-Mechanismus dieses Skripts.
#
# Post-Install: ldconfig + systemctl daemon-reload
# Post-Remove:  ldconfig + systemctl daemon-reload
# ------------------------------------------------------------------------------
create_deb_packages() {
  local arch
  arch="$(dpkg --print-architecture)"
  mkdir -p "$PACKAGE_DIR"

  # ---- Post-Install / Post-Remove Scripts ------------------------------------
  local postinst="/tmp/dovecot-postinst.sh"
  local postrm="/tmp/dovecot-postrm.sh"

  cat > "$postinst" <<'POSTINST'
#!/bin/sh
set -e

if ! id -u dovecot >/dev/null 2>&1; then
  adduser --system --group --home /var/run/dovecot --no-create-home \
    --gecos "Dovecot Mail Server" --shell /usr/sbin/nologin dovecot 2>/dev/null || true
fi
if ! id -u dovenull >/dev/null 2>&1; then
  adduser --system --group --home /var/run/dovecot --no-create-home \
    --gecos "Dovecot Login User" --shell /usr/sbin/nologin dovenull 2>/dev/null || true
fi

mkdir -p /var/run/dovecot /var/lib/dovecot
chown dovecot:dovecot /var/lib/dovecot 2>/dev/null || true

# Copy default configs on fresh install
if [ ! -f /etc/dovecot/dovecot.conf ]; then
  echo "INFO: Keine dovecot.conf gefunden – installiere Default-Konfiguration"
  if [ -d /usr/share/dovecot ]; then
    cp -a /usr/share/dovecot/dovecot.conf /etc/dovecot/dovecot.conf 2>/dev/null || true
    mkdir -p /etc/dovecot/conf.d
    if [ -d /usr/share/dovecot/conf.d ]; then
      for f in /usr/share/dovecot/conf.d/*.conf; do
        [ -f "$f" ] && cp -a "$f" /etc/dovecot/conf.d/ 2>/dev/null || true
      done
    fi
  fi
  # Generate DH params if missing
  if [ ! -f /etc/dovecot/dh.pem ] && command -v openssl >/dev/null 2>&1; then
    openssl dhparam -out /etc/dovecot/dh.pem 2048 2>/dev/null &
  fi
fi

# Create PAM config for dovecot if missing
if [ ! -f /etc/pam.d/dovecot ]; then
  echo "auth    required        pam_unix.so    nullok" > /etc/pam.d/dovecot
  echo "account required        pam_unix.so" >> /etc/pam.d/dovecot
fi

# Create /etc/default/dovecot if missing
if [ ! -f /etc/default/dovecot ]; then
  echo "# Dovecot startup configuration" > /etc/default/dovecot
  echo "ENABLED=1" >> /etc/default/dovecot
fi

if [ ! -f /etc/logrotate.d/dovecot-custom ]; then
  cat > /etc/logrotate.d/dovecot-custom <<'LR'
/var/log/dovecot.log /var/log/dovecot-error.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 dovecot adm
    postrotate
        command -v dovecot >/dev/null 2>&1 && dovecot log reopen 2>/dev/null || true
    endspost
}
LR
fi

ldconfig
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
  command -v apt-mark >/dev/null 2>&1 && apt-mark hold dovecot-core-custom dovecot-pigeonhole-custom || true
  for sp in "${DOVECOT_SUBPACKAGES[@]}"; do
    command -v apt-mark >/dev/null 2>&1 && apt-mark hold "${SUB_PKGNAME[$sp]}" 2>/dev/null || true
  done
POSTINST
  chmod 755 "$postinst"

  cat > "$postrm" <<'POSTRM'
#!/bin/sh
set -e

command -v apt-mark >/dev/null 2>&1 && apt-mark unhold dovecot-core-custom dovecot-pigeonhole-custom 2>/dev/null || true
rm -f /etc/logrotate.d/dovecot-custom
ldconfig
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
POSTRM
  chmod 755 "$postrm"

  # ---- dovecot-core-custom.deb -----------------------------------------------
  log "Erzeuge Staging für dovecot-core-custom.deb"
  rm -rf "$STAGE_DOVECOT"
  cd "$BUILD_ROOT/core"
  make install DESTDIR="$STAGE_DOVECOT"

  # Gzip man pages
  find "${STAGE_DOVECOT}/usr/share/man" -type f -name '*.?' ! -name '*.gz' -exec gzip -f {} \; 2>/dev/null || true

  # /etc/dovecot NICHT ins Paket – Konfiguration via backup/restore
  rm -rf "${STAGE_DOVECOT}/etc/dovecot"

  # tmpfiles.d: Runtime-Verzeichnisse bei Bedarf erzeugen (wie offizielle Pakete)
  mkdir -p "${STAGE_DOVECOT}/usr/lib/tmpfiles.d"
  cat > "${STAGE_DOVECOT}/usr/lib/tmpfiles.d/dovecot-custom.conf" <<'EOF'
# Dovecot runtime directories
d /run/dovecot 0755 dovecot dovecot -
d /run/dovecot/login 0755 dovenull dovenull -
d /var/run/dovecot 0755 dovecot dovecot -
d /var/run/dovecot/login 0755 dovenull dovenull -
EOF

  # Systemd-Hardening: Schutzmechanismen wie offizielle Ubuntu-Pakete
  if [ -f "${STAGE_DOVECOT}/lib/systemd/system/dovecot.service" ]; then
    sed -i '/^\[Service\]/a LimitNOFILE=65535\nProtectSystem=full\nPrivateDevices=true\nProtectHome=true' \
      "${STAGE_DOVECOT}/lib/systemd/system/dovecot.service"
    log "Systemd-Hardening angewendet"
  fi

  # Übersicht was tatsächlich drin ist
  log "Staging-Inhalt (relevante Dateien):"
  find "$STAGE_DOVECOT" \( -name "dovecot" -o -name "doveadm" -o -name "dovecot-config" \
    -o -name "*.so" -o -name "*.so.*" -o -name "dovecot.service" \) \
    | sort | tee -a "$LOG_FILE"

  local deb_core="$PACKAGE_DIR/dovecot-core-custom_${DOVECOT_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_core")"

  # Sub-Package .so aus Core-Staging entfernen – die kommen in eigene Pakete
  local mod_dir="${STAGE_DOVECOT}/usr/lib/dovecot/modules"
  local sub_so_count=0
  for sp in "${DOVECOT_SUBPACKAGES[@]}"; do
    local sofind="${SUB_SOFIND[$sp]}"
    local found_sos
    found_sos="$(find "$mod_dir" -name "*${sofind}*" -type f 2>/dev/null || true)"
    if [ -n "$found_sos" ]; then
      echo "$found_sos" | while read -r f; do
        log "Verschiebe $(basename "$f") aus Core-Staging"
        rm -f "$f"
        sub_so_count=$((sub_so_count + 1))
      done
    fi
    # Also remove protocol binaries (imap, pop3, lmtp) from staging
    if [ "$sp" = "imapd" ]; then
      for b in imap imap-login imap-urlauth imap-urlauth-login imap-urlauth-worker imap-hibernate; do
        rm -f "${STAGE_DOVECOT}/usr/lib/dovecot/$b" 2>/dev/null || true
      done
    elif [ "$sp" = "pop3d" ]; then
      for b in pop3 pop3-login; do
        rm -f "${STAGE_DOVECOT}/usr/lib/dovecot/$b" 2>/dev/null || true
      done
    elif [ "$sp" = "lmtpd" ]; then
      rm -f "${STAGE_DOVECOT}/usr/lib/dovecot/lmtp" 2>/dev/null || true
    fi
    # Remove SQL driver .so from toplevel lib dir
    if [ "$sp" = "mysql" ] || [ "$sp" = "pgsql" ] || [ "$sp" = "sqlite" ]; then
      local drvname
      drvname="${sofind}"
      rm -f "${STAGE_DOVECOT}/usr/lib/dovecot/${drvname}" 2>/dev/null || true
    fi
    # Remove LDAP shared lib
    if [ "$sp" = "ldap" ]; then
      rm -f "${STAGE_DOVECOT}/usr/lib/dovecot/libdovecot-ldap.so"* 2>/dev/null || true
    fi
  done
  log "$sub_so_count Sub-Package-.so aus Core-Staging entfernt"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         dovecot-core-custom \
    --version      "$DOVECOT_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Dovecot IMAP/POP3 $DOVECOT_VERSION – custom build (core)" \
    --depends      libssl3 \
    --depends      libpam0g \
    --depends      libicu74 \
    --depends      libsodium23 \
    --depends      "liblua5.4-0 | liblua5.3-0" \
    --depends      libsasl2-2 \
    --depends      "libexttextcat-2.0-0 | libexttextcat2t64" \
    --depends      "libunwind8 | libunwind8t64" \
    --depends      "libzstd1 | libzstd1t64" \
    --depends      "liblz4-1 | liblz4-1t64" \
    --depends      libbz2-1.0 \
    --depends      liblzma5 \
    --depends      "libcap2 | libcap2t64" \
    --conflicts    dovecot-core \
    --provides     dovecot-core \
    --replaces     dovecot-core \
    --conflicts    dovecot-imapd \
    --conflicts    dovecot-pop3d \
    --conflicts    dovecot-lmtpd \
    --conflicts    dovecot-mysql \
    --conflicts    dovecot-pgsql \
    --conflicts    dovecot-sqlite \
    --conflicts    dovecot-ldap \
    --conflicts    dovecot-gssapi \
    --conflicts    dovecot-solr \
    --conflicts    dovecot-dev \
    --replaces     dovecot-imapd \
    --replaces     dovecot-pop3d \
    --replaces     dovecot-lmtpd \
    --replaces     dovecot-mysql \
    --replaces     dovecot-pgsql \
    --replaces     dovecot-sqlite \
    --replaces     dovecot-ldap \
    --replaces     dovecot-gssapi \
    --replaces     dovecot-solr \
    --deb-no-default-config-files \
    --after-install  "$postinst" \
    --after-remove   "$postrm" \
    --force \
    --package      "$deb_core" \
    --chdir        "$STAGE_DOVECOT" \
    .

  log "Erzeugt: $(basename "$deb_core") ($(du -sh "$deb_core" | cut -f1))"

  # ---- dovecot-pigeonhole-custom.deb -----------------------------------------
  log "Prüfe Pigeonhole-Staging (wurde bereits in build_pigeonhole erstellt)"
  # STAGE_PIGEONHOLE wurde in build_pigeonhole() via make install DESTDIR befüllt
  [ -d "$STAGE_PIGEONHOLE" ] || die "Pigeonhole-Staging fehlt – zuerst 'package' ausführen"

  # /etc aus Staging entfernen
  rm -rf "${STAGE_PIGEONHOLE:?}/etc"

  log "Pigeonhole Staging-Inhalt:"
  find "$STAGE_PIGEONHOLE" \( -name "*.so" -o -name "*sieve*" -o -name "*managesieve*" \) \
    | sort | tee -a "$LOG_FILE"

  local deb_sieve="$PACKAGE_DIR/dovecot-pigeonhole-custom_${PIGEONHOLE_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_sieve")"
  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         dovecot-pigeonhole-custom \
    --version      "$PIGEONHOLE_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Dovecot Pigeonhole/Sieve $PIGEONHOLE_VERSION – custom build" \
    --depends      dovecot-core-custom \
    --conflicts    dovecot-sieve \
    --conflicts    dovecot-managesieved \
    --provides     dovecot-sieve \
    --provides     dovecot-managesieved \
    --replaces     dovecot-sieve \
    --replaces     dovecot-managesieved \
    --deb-no-default-config-files \
    --after-install  "$postinst" \
    --after-remove   "$postrm" \
    --force \
    --package      "$deb_sieve" \
    --chdir        "$STAGE_PIGEONHOLE" \
    .

  log "Erzeugt: $(basename "$deb_sieve") ($(du -sh "$deb_sieve" | cut -f1))"

  # ---- Paketinhalt kurz verifizieren -----------------------------------------
  log "Verifikation dovecot-core-custom:"
  dpkg-deb --contents "$deb_core" \
    | awk '{print $NF}' \
    | grep -E "(sbin/dovecot$|bin/doveadm|\.so|dovecot\.service|dovecot-config)" \
    | sort | tee -a "$LOG_FILE" || true

  log "Verifikation dovecot-pigeonhole-custom:"
  dpkg-deb --contents "$deb_sieve" \
    | awk '{print $NF}' \
    | grep -E "(\.so|sieve|managesieve)" \
    | sort | tee -a "$LOG_FILE" || true

  # ---- Sub-Pakete (mysql, pgsql, sqlite, ldap, gssapi, solr, imapd, pop3d, lmtpd)
  create_sub_packages

  # ---- Abschlussmeldung ------------------------------------------------------
  echo ""
  log "===== Fertige Pakete ====="
  find "$PACKAGE_DIR" -maxdepth 1 -name "*.deb" -printf "%s bytes %p\n" | tee -a "$LOG_FILE"

  generate_checksums

  echo ""
  echo "HINWEIS: /etc/dovecot ist NICHT in den Paketen."
  echo "         Konfiguration wird durch 'backup' / 'restore' verwaltet."
  echo ""
  local repo_script
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  if [ -x "$repo_script" ]; then
    log "Aktualisiere lokales Repository..."
    "$repo_script" update || true
  fi

  echo "Nächster Schritt:          $0 install"
  echo "Später deinstallieren:     $0 uninstall"
}

# ------------------------------------------------------------------------------
# .deb-Pakete: Dovecot Sub-Packages (SQL, LDAP, GSSAPI, Solr, Protokolle)
#
# Jede Komponente bekommt ein eigenes .deb, analog zu Ubuntu:
#   dovecot-custom-mysql, dovecot-custom-pgsql, dovecot-custom-sqlite,
#   dovecot-custom-ldap, dovecot-custom-gssapi, dovecot-custom-solr,
#   dovecot-custom-imapd, dovecot-custom-pop3d, dovecot-custom-lmtpd
#
# Die .so-Dateien wurden bereits aus dem Core-Staging entfernt.
# Hier werden sie aus dem originalen Build-Verzeichnis geholt.
# ------------------------------------------------------------------------------
create_sub_packages() {
  local arch
  arch="$(dpkg --print-architecture)"

  local mod_dir="${STAGE_DOVECOT}/usr/lib/dovecot/modules"
  local lib_dir="${STAGE_DOVECOT}/usr/lib/dovecot"

  local mod_postinst="/tmp/dovecot-sub-postinst.sh"
  local mod_postrm="/tmp/dovecot-sub-postrm.sh"

  cat > "$mod_postinst" <<'SUBPOSTINST'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
SUBPOSTINST
  chmod 755 "$mod_postinst"

  cat > "$mod_postrm" <<'SUBPOSTRM'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
SUBPOSTRM
  chmod 755 "$mod_postrm"

  local pkg_ok=0
  local pkg_fail=0

  for sp in "${DOVECOT_SUBPACKAGES[@]}"; do
    local sofind="${SUB_SOFIND[$sp]}"
    local pkg_name="${SUB_PKGNAME[$sp]}"
    local desc="${SUB_DESC[$sp]}"
    local deps="${SUB_DEPS[$sp]}"
    local conflicts="${SUB_CONFLICTS[$sp]}"

    log "Erstelle Sub-Paket: $pkg_name ($sofind)"

    local sub_stage="/tmp/dovecot-sub-stage-${sp}"
    rm -rf "$sub_stage"
    mkdir -p "$sub_stage"

    local found_any=0

    # SQL-Treiber: 3 .so pro Paket (modules/auth/, modules/dict/, modules/)
    if [ "$sp" = "mysql" ] || [ "$sp" = "pgsql" ] || [ "$sp" = "sqlite" ]; then
      local driver_name
      if [ "$sp" = "mysql" ]; then driver_name="mysql"
      elif [ "$sp" = "pgsql" ]; then driver_name="pgsql"
      else driver_name="sqlite"
      fi

      for subdir in "auth" "dict" ""; do
        local so_path="${mod_dir}/${subdir}/libdriver_${driver_name}.so"
        if [ -f "$so_path" ]; then
          mkdir -p "$sub_stage/usr/lib/dovecot/modules/${subdir}"
          cp "$so_path" "$sub_stage/usr/lib/dovecot/modules/${subdir}/"
          log "  [OK] modules/${subdir}/libdriver_${driver_name}.so"
          found_any=1
        fi
      done
    fi

    # LDAP: libauthdb_ldap.so, libdict_ldap.so, libdovecot-ldap.so
    if [ "$sp" = "ldap" ]; then
      find "$mod_dir" -name "libauthdb_ldap.so" -o -name "libdict_ldap.so" 2>/dev/null | while IFS= read -r f; do
        [ -z "$f" ] && continue
        local rel="${f#"$STAGE_DOVECOT"}"
        mkdir -p "$sub_stage$(dirname "$rel")"
        cp "$f" "$sub_stage$rel"
        log "  [OK] $(basename "$f")"
        found_any=1
      done
      find "$lib_dir" -maxdepth 1 -name "libdovecot-ldap.so*" 2>/dev/null | while IFS= read -r f; do
        [ -z "$f" ] && continue
        local rel="${f#"$STAGE_DOVECOT"}"
        mkdir -p "$sub_stage$(dirname "$rel")"
        cp "$f" "$sub_stage$rel"
        log "  [OK] $(basename "$f")"
        found_any=1
      done
    fi

    # GSSAPI: libmech_gssapi.so
    if [ "$sp" = "gssapi" ]; then
      local gss_so
      gss_so="$(find "$mod_dir" -name "libmech_gssapi.so" 2>/dev/null | head -1)"
      if [ -n "$gss_so" ]; then
        local rel="${gss_so#"$STAGE_DOVECOT"}"
        mkdir -p "$sub_stage$(dirname "$rel")"
        cp "$gss_so" "$sub_stage$rel"
        log "  [OK] libmech_gssapi.so"
        found_any=1
      fi
    fi

    # Solr: lib21_fts_solr_plugin.so
    if [ "$sp" = "solr" ]; then
      local solr_so
      solr_so="$(find "$mod_dir" -name "lib21_fts_solr_plugin.so" 2>/dev/null | head -1)"
      if [ -n "$solr_so" ]; then
        local rel="${solr_so#"$STAGE_DOVECOT"}"
        mkdir -p "$sub_stage$(dirname "$rel")"
        cp "$solr_so" "$sub_stage$rel"
        log "  [OK] lib21_fts_solr_plugin.so"
        found_any=1
      fi
    fi

    # Protocol packages: imapd, pop3d, lmtpd
    if [ "$sp" = "imapd" ]; then
      for b in imap imap-login imap-urlauth imap-urlauth-login imap-urlauth-worker imap-hibernate; do
        local bin="${lib_dir}/$b"
        if [ -f "$bin" ]; then
          mkdir -p "$sub_stage/usr/lib/dovecot"
          cp "$bin" "$sub_stage/usr/lib/dovecot/"
          log "  [OK] $b"
          found_any=1
        fi
      done
      find "$mod_dir" -name "lib02_imap_acl_plugin.so" -o -name "lib11_imap_quota_plugin.so" -o -name "lib30_imap_zlib_plugin.so" 2>/dev/null | while IFS= read -r f; do
        [ -z "$f" ] && continue
        local rel="${f#"$STAGE_DOVECOT"}"
        mkdir -p "$sub_stage$(dirname "$rel")"
        cp "$f" "$sub_stage$rel"
        log "  [OK] $(basename "$f")"
        found_any=1
      done
    elif [ "$sp" = "pop3d" ]; then
      for b in pop3 pop3-login; do
        local bin="${lib_dir}/$b"
        if [ -f "$bin" ]; then
          mkdir -p "$sub_stage/usr/lib/dovecot"
          cp "$bin" "$sub_stage/usr/lib/dovecot/"
          log "  [OK] $b"
          found_any=1
        fi
      done
      find "$mod_dir" -name "libpop3*" 2>/dev/null | while IFS= read -r f; do
        [ -z "$f" ] && continue
        local rel="${f#"$STAGE_DOVECOT"}"
        mkdir -p "$sub_stage$(dirname "$rel")"
        cp "$f" "$sub_stage$rel"
        log "  [OK] $(basename "$f")"
        found_any=1
      done
    elif [ "$sp" = "lmtpd" ]; then
      local lmtp_bin="${lib_dir}/lmtp"
      if [ -f "$lmtp_bin" ]; then
        mkdir -p "$sub_stage/usr/lib/dovecot"
        cp "$lmtp_bin" "$sub_stage/usr/lib/dovecot/"
        log "  [OK] lmtp"
        found_any=1
      fi
      find "$mod_dir" -name "liblmtp*" 2>/dev/null | while IFS= read -r f; do
        [ -z "$f" ] && continue
        local rel="${f#"$STAGE_DOVECOT"}"
        mkdir -p "$sub_stage$(dirname "$rel")"
        cp "$f" "$sub_stage$rel"
        log "  [OK] $(basename "$f")"
        found_any=1
      done
    fi

    if [ "$found_any" -eq 0 ]; then
      log "  [SKIP] $pkg_name – keine Dateien gefunden ($sofind)"
      pkg_fail=$((pkg_fail + 1))
      rm -rf "$sub_stage"
      continue
    fi

    # /usr/share/doc/<pkg> anlegen
    mkdir -p "$sub_stage/usr/share/doc/${pkg_name}"

    local deb_file="$PACKAGE_DIR/${pkg_name}_${DOVECOT_VERSION}_${arch}.deb"

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
      --version      "$DOVECOT_VERSION" \
      --iteration    1 \
      --architecture "$arch" \
      --maintainer   "\"local build <root@localhost>\"" \
      --description  "\"$desc (Dovecot $DOVECOT_VERSION)\"" \
      ${fpm_deps} \
      --conflicts    "$conflicts" \
      --provides     "$conflicts" \
      --replaces     "$conflicts" \
      --deb-no-default-config-files \
      --after-install  "$mod_postinst" \
      --after-remove   "$mod_postrm" \
      --force \
      --package      "$deb_file" \
      --chdir        "$sub_stage" \
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

    rm -rf "$sub_stage"
  done

  log "Sub-Pakete: $pkg_ok erfolgreich, $pkg_fail fehlgeschlagen/uebersprungen"
}

# ------------------------------------------------------------------------------
# Pakete via dpkg installieren
#
# WAS PASSIERT MIT /etc/dovecot:
#   Die .deb-Pakete enthalten /etc/dovecot NICHT (wurde beim Bauen entfernt).
#   dpkg -i schreibt also NICHTS nach /etc/dovecot.
#   Die bestehende Konfiguration (dovecot.conf, dovecot-sql.conf, dh.pem,
#   conf.d/*, usw.) bleibt zu 100% unberührt.
#
# WAS WIRD ÜBERSCHRIEBEN:
#   /usr/sbin/dovecot         – neues Binary
#   /usr/bin/doveadm, doveconf, dsync, ...
#   /usr/lib/dovecot/         – alle Module (.so-Dateien)
#   /usr/lib/libdovecot*.so*  – Shared Libraries
#   /lib/systemd/system/dovecot.service + dovecot.socket
#   /usr/share/dovecot/       – Beispielkonfigurationen (nicht /etc/!)
# ------------------------------------------------------------------------------
install_packages() {
  local deb_core deb_sieve

  deb_core=$(find "$PACKAGE_DIR" -maxdepth 1 -name "dovecot-core-custom_*.deb" 2>/dev/null | sort -V | tail -1 || true)
  deb_sieve=$(find "$PACKAGE_DIR" -maxdepth 1 -name "dovecot-pigeonhole-custom_*.deb" 2>/dev/null | sort -V | tail -1 || true)

  [ -n "$deb_core" ]  || die "Kein dovecot-core-custom.deb in $PACKAGE_DIR – bitte zuerst: $0 package"
  [ -n "$deb_sieve" ] || die "Kein dovecot-pigeonhole-custom.deb in $PACKAGE_DIR – bitte zuerst: $0 package"

  # Sicherheitscheck: /etc/dovecot muss vorhanden und befüllt sein
  if [ ! -f /etc/dovecot/dovecot.conf ]; then
    log "WARNUNG: /etc/dovecot/dovecot.conf nicht gefunden!"
    log "         Konfiguration fehlt – bitte vor dem Install sicherstellen"
    log "         dass /etc/dovecot korrekt befüllt ist."
    read -r -p "Trotzdem fortfahren? (ja/nein): " antwort
    [ "$antwort" = "ja" ] || die "Abgebrochen"
  fi

  # Pakete aus dem Paket extrahieren und prüfen ob /etc drin ist (Sicherheit)
  if dpkg-deb --contents "$deb_core" 2>/dev/null | awk '{print $NF}' | grep -q "^\./etc/dovecot"; then
    die "FEHLER: $deb_core enthält /etc/dovecot – das darf nicht sein! Pakete neu bauen."
  fi

  log "Installiere: $(basename "$deb_core")"
  DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_core"

  log "Installiere: $(basename "$deb_sieve")"
  DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_sieve"

  # Sub-Pakete installieren
  local deb_subs
  deb_subs=$(find "$PACKAGE_DIR" -maxdepth 1 -name "dovecot-custom-*_*.deb" 2>/dev/null | sort || true)
  if [ -n "$deb_subs" ]; then
    log "Installiere Sub-Pakete..."
    for deb_sub in $deb_subs; do
      log "  $(basename "$deb_sub")"
    done
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_subs" 2>&1 | tee -a "$LOG_FILE" || true
  fi

  # Abhängigkeiten nachziehen falls nötig
  apt-get install -f -y || true

  log "Konfiguration in /etc/dovecot: unverändert"
  log "Installierte Dateien: Binaries + Module + Libs + Systemd-Units"
}

# ------------------------------------------------------------------------------
# Dienste neu starten
# ------------------------------------------------------------------------------
restart_services() {
  log "Starte Dovecot neu"
  systemctl daemon-reload
  systemctl daemon-reexec
  systemctl enable dovecot
  systemctl restart dovecot
}

# ------------------------------------------------------------------------------
# Modul-Check: prüft ob alle erwarteten Module nach dem Build vorhanden sind.
# Entspricht dem was apt früher als separate Pakete lieferte:
#   dovecot-core      → Binary + Core-Module
#   dovecot-imapd     → libimap.so
#   dovecot-pop3d     → libpop3.so
#   dovecot-lmtpd     → liblmtp.so  (für Postfix-Integration)
#   dovecot-mysql     → libdriver_mysql.so  (passdb/userdb driver=sql)
#   dovecot-ldap      → libdriver_ldap.so
#   dovecot-sieve     → lib90_sieve_plugin.so o.ä.
#   dovecot-managesieved → managesieve-Binary
#   dovecot-antispam  → nicht im Upstream-Core, separates Plugin (siehe unten)
# ------------------------------------------------------------------------------
verify_modules() {
  local moddir="/usr/lib/dovecot/modules"
  local ok=0
  local warn=0

  check_module() {
    local label="$1"
    local pattern="$2"
    local apt_equiv="$3"
    if find "$moddir" -name "$pattern" 2>/dev/null | grep -q .; then
      printf "  [OK] %-35s (entspricht apt: %s)
" "$label" "$apt_equiv"
      ok=$((ok+1))
    else
      printf "  [!!] %-35s NICHT GEFUNDEN  (entspricht apt: %s)
" "$label" "$apt_equiv"
      warn=$((warn+1))
    fi
  }

  echo ""
  echo "=============================================="
  echo " Modul-Verifikation"
  echo "=============================================="
  echo " Modulpfad: $moddir"
  echo ""

  # Protokoll-Module (früher eigene apt-Pakete)
  check_module "IMAP-Protokoll"        "libimap*.so"            "dovecot-imapd"
  check_module "POP3-Protokoll"        "libpop3*.so"            "dovecot-pop3d"
  check_module "LMTP (Postfix)"        "liblmtp*.so"            "dovecot-lmtpd"

  # IMAP IDLE (Push) – prüfe inotify-Support im Kernel
  echo ""
  echo " IMAP IDLE / Push:"
  if [ -f /proc/sys/fs/inotify/max_user_watches ]; then
    echo "  [OK] inotify verfügbar (IMAP IDLE funktioniert)"
    echo "       max_user_watches: $(cat /proc/sys/fs/inotify/max_user_watches)"
    echo "       Empfehlung: mind. 65536 (sysctl fs.inotify.max_user_watches=65536)"
  else
    echo "  [!!] inotify NICHT verfügbar – IMAP IDLE/Push funktioniert nicht"
  fi

  # Auth-Module
  check_module "MySQL/SQL-Auth"        "libdriver_mysql*.so"    "dovecot-mysql"
  check_module "LDAP-Auth"             "libdriver_ldap*.so"     "dovecot-ldap"
  check_module "PAM-Auth"              "libmech_pam*.so"        "dovecot-pam"

  # Quota
  check_module "Quota-Plugin"          "lib*quota*.so"          "dovecot-core (quota)"

  # Sieve / Pigeonhole
  check_module "Sieve-Plugin"          "lib*sieve*.so"          "dovecot-sieve"
  check_module "ManageSieve"           "lib*managesieve*.so"    "dovecot-managesieved"

  # Kompression
  check_module "zlib-Kompression"      "lib*zlib*.so"           "dovecot-core"
  check_module "lz4-Kompression"       "lib*lz4*.so"            "dovecot-core"
  check_module "zstd-Kompression"      "lib*zstd*.so"           "dovecot-core"

  echo ""
  echo " Binaries:"
  for bin in dovecot doveadm doveconf dsync; do
    if command -v "$bin" >/dev/null 2>&1; then
      printf "  [OK] /usr/bin/%s
" "$bin"
    else
      printf "  [!!] %s  NICHT GEFUNDEN
" "$bin"
      warn=$((warn+1))
    fi
  done

  # ManageSieve-Binary gesondert (in libexec)
  if find /usr/lib/dovecot /usr/libexec/dovecot -name "managesieve*" 2>/dev/null | grep -q .; then
    echo "  [OK] managesieve-login / managesieve"
  else
    echo "  [!!] managesieve-Binary NICHT GEFUNDEN"
    warn=$((warn+1))
  fi

  echo ""
  echo " Hinweis dovecot-antispam:"
  echo "   Das antispam-Plugin ist KEIN Bestandteil des Dovecot-Upstream-Repos."
  echo "   Es muss separat gebaut werden (https://github.com/dovecot-antispam/dovecot-antispam)"
  echo "   oder via apt auf Systemen wo es verfügbar ist."
  echo ""
  echo " Ergebnis: $ok Module OK, $warn Warnungen"
  echo "=============================================="

  if [ "$warn" -gt 0 ]; then
    log "WARNUNG: $warn Module nicht gefunden – siehe Ausgabe oben"
  fi
}

# ------------------------------------------------------------------------------
# Post-Checks nach Installation
# ------------------------------------------------------------------------------
post_checks() {
  log "Prüfe Installation"
  command -v dovecot >/dev/null 2>&1 || die "dovecot-Binary nicht gefunden"
  log "Dovecot Version: $(dovecot --version 2>&1)"

  log "Validiere Konfiguration (dovecot -n)"
  dovecot -n >> "$LOG_FILE" 2>&1     || log "WARNUNG: Konfigurationsfehler – Log prüfen: $LOG_FILE"

  if ! systemctl is-active --quiet dovecot; then
    systemctl status dovecot --no-pager || true
    die "Dovecot läuft nicht"
  fi

  verify_modules

  log "Installation abgeschlossen – Log: $LOG_FILE"
}

# ------------------------------------------------------------------------------
# Restore
# ------------------------------------------------------------------------------
restore_from_backup() {
  local backup_dir="${1:-$LATEST_LINK}"
  [ -L "$backup_dir" ] && backup_dir="$(readlink -f "$backup_dir")"
  [ -d "$backup_dir" ] || die "Backup nicht gefunden: $backup_dir"
  log "Restore aus: $backup_dir"

  systemctl stop dovecot 2>/dev/null || true

  # Custom-Pakete zuerst deinstallieren
  for sp in "${DOVECOT_SUBPACKAGES[@]}"; do
    local pkg="${SUB_PKGNAME[$sp]}"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "Deinstalliere $pkg"
      dpkg -r "$pkg" || true
    fi
  done
  for pkg in dovecot-pigeonhole-custom dovecot-core-custom; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "Deinstalliere $pkg"
      dpkg -r "$pkg" || true
    fi
  done

  # /etc/dovecot
  if [ -d "$backup_dir/etc_dovecot" ]; then
    rm -rf /etc/dovecot
    cp -a "$backup_dir/etc_dovecot" /etc/dovecot
    chmod 750 /etc/dovecot
    chown root:dovecot /etc/dovecot 2>/dev/null || true
  fi

  # SQL-Config + DH
  [ -f "$backup_dir/dovecot-sql.conf" ] && [ ! -f /etc/dovecot/dovecot-sql.conf ] && {
    cp -a "$backup_dir/dovecot-sql.conf" /etc/dovecot/dovecot-sql.conf
    chmod 600 /etc/dovecot/dovecot-sql.conf
  }
  [ -f "$backup_dir/dh.pem" ] && [ ! -f /etc/dovecot/dh.pem ] && \
    cp -a "$backup_dir/dh.pem" /etc/dovecot/dh.pem

  # Binary / Libs
  [ -f "$backup_dir/usr_sbin_dovecot" ] && {
    cp -a "$backup_dir/usr_sbin_dovecot" /usr/sbin/dovecot
    chmod 755 /usr/sbin/dovecot
  }
  [ -d "$backup_dir/usr_lib_dovecot" ] && {
    rm -rf /usr/lib/dovecot
    cp -a "$backup_dir/usr_lib_dovecot" /usr/lib/dovecot
  }

  # Systemd
  [ -f "$backup_dir/dovecot.service" ] && {
    cp -a "$backup_dir/dovecot.service" /lib/systemd/system/dovecot.service
    chmod 644 /lib/systemd/system/dovecot.service
  }
  [ -f "$backup_dir/dovecot.socket" ] && {
    cp -a "$backup_dir/dovecot.socket" /lib/systemd/system/dovecot.socket
    chmod 644 /lib/systemd/system/dovecot.socket
  }
  [ -f "$backup_dir/etc_default_dovecot" ] && {
    cp -a "$backup_dir/etc_default_dovecot" /etc/default/dovecot
    chmod 644 /etc/default/dovecot
  }

  # apt-Pakete (alte Installation aus apt)
  if [ -f "$backup_dir/packages.txt" ] && [ -s "$backup_dir/packages.txt" ]; then
    log "Stelle apt-Pakete wieder her"
    apt-get update -qq || true
    xargs -r apt-get install --reinstall -y < "$backup_dir/packages.txt" || true
  fi

  systemctl daemon-reload
  systemctl daemon-reexec
  systemctl enable dovecot
  systemctl restart dovecot || true

  log "Restore abgeschlossen"
}

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------
status_cmd() {
  echo "=============================================="
  echo " Dovecot Status – $(date)"
  echo "=============================================="

  if command -v dovecot >/dev/null 2>&1; then
    echo "Binary  : $(command -v dovecot)"
    echo "Version : $(dovecot --version 2>/dev/null || echo 'unbekannt')"
  else
    echo "Dovecot-Binary: NICHT GEFUNDEN"
  fi

  echo ""
  echo "--- Installierte Custom-Pakete ---"
  for pkg in dovecot-core-custom dovecot-pigeonhole-custom; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      echo "  [OK] $pkg $(dpkg -s "$pkg" | awk '/^Version:/{print $2}')"
    else
      echo "  [--] $pkg nicht installiert"
    fi
  done

  echo ""
  echo "--- systemctl status dovecot ---"
  systemctl status dovecot --no-pager || true

  echo ""
  echo "--- Installierte Module ---"
  if [ -d /usr/lib/dovecot/modules ]; then
    find /usr/lib/dovecot/modules -name "*.so" | sort | sed 's|.*/||'
  else
    echo "(kein Modul-Verzeichnis)"
  fi

  echo ""
  if [ -L "$LATEST_LINK" ] || [ -d "$LATEST_LINK" ]; then
    echo "Letztes Backup: $(readlink -f "$LATEST_LINK" 2>/dev/null || echo "$LATEST_LINK")"
  else
    echo "Kein Backup vorhanden"
  fi

  echo ""
  echo "--- Verfügbare .deb-Pakete in $PACKAGE_DIR ---"
  if [ -d "$PACKAGE_DIR" ]; then
    ls -lh "$PACKAGE_DIR"/*.deb 2>/dev/null || echo "(keine Pakete erzeugt)"
  else
    echo "(kein Package-Verzeichnis)"
  fi
}

list_backups() {
  echo "Verfügbare Backups in $BACKUP_ROOT:"
  [ -d "$BACKUP_ROOT" ] \
    && find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort \
    || echo "(kein Backup-Verzeichnis)"
}

list_packages() {
  echo "Verfügbare .deb-Pakete in $PACKAGE_DIR:"
  [ -d "$PACKAGE_DIR" ] \
    && ls -lh "$PACKAGE_DIR"/*.deb 2>/dev/null \
    || echo "(keine Pakete erzeugt)"
}

check_config() {
  log "Konfigurationscheck (dovecot -n)"
  dovecot -n || die "Konfigurationsfehler"
}

uninstall_cmd() {
  log "Deinstalliere Custom-Pakete"
  systemctl stop dovecot 2>/dev/null || true
  for sp in "${DOVECOT_SUBPACKAGES[@]}"; do
    local pkg="${SUB_PKGNAME[$sp]}"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      dpkg -r "$pkg" || true
      log "$pkg entfernt"
    fi
  done
  for pkg in dovecot-pigeonhole-custom dovecot-core-custom; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      dpkg -r "$pkg"
      log "$pkg entfernt"
    else
      log "$pkg war nicht installiert"
    fi
  done
  log "Deinstallation abgeschlossen"
}

# ------------------------------------------------------------------------------
# Nur Dovecot-Core bauen + .deb erstellen
# ------------------------------------------------------------------------------
package_dovecot() {
  log "=== Starte Dovecot-Core Paket-Build ==="
  install_build_deps

  # Nur Dovecot-Tarball herunterladen und entpacken
  mkdir -p "$BUILD_ROOT"
  cd "$BUILD_ROOT"
  rm -rf core
  local dc_tar="dovecot-${DOVECOT_VERSION}.tar.gz"
  if [ ! -f "$dc_tar" ]; then
    log "Lade Dovecot $DOVECOT_VERSION Tarball"
    wget -q --show-progress "$DOVECOT_TARBALL" -O "$dc_tar"       || curl -L --progress-bar "$DOVECOT_TARBALL" -o "$dc_tar"       || die "Download fehlgeschlagen"
  else
    log "Dovecot Tarball bereits vorhanden: $dc_tar"
  fi
  tar xzf "$dc_tar"
  mv "dovecot-${DOVECOT_VERSION}" core
  [ -x core/configure ] || die "configure fehlt im Tarball"
  log "Quellen: $BUILD_ROOT/core"

  build_dovecot

  # Nur dovecot-core-custom.deb erstellen
  local arch
  arch="$(dpkg --print-architecture)"
  mkdir -p "$PACKAGE_DIR"

  log "Erzeuge Staging für dovecot-core-custom.deb"
  rm -rf "$STAGE_DOVECOT"
  cd "$BUILD_ROOT/core"
  make install DESTDIR="$STAGE_DOVECOT"
  rm -rf "${STAGE_DOVECOT}/etc/dovecot"

  # Gzip man pages
  find "${STAGE_DOVECOT}/usr/share/man" -type f -name '*.?' ! -name '*.gz' -exec gzip -f {} \; 2>/dev/null || true

  # tmpfiles.d: Runtime-Verzeichnisse bei Bedarf erzeugen (wie offizielle Pakete)
  mkdir -p "${STAGE_DOVECOT}/usr/lib/tmpfiles.d"
  cat > "${STAGE_DOVECOT}/usr/lib/tmpfiles.d/dovecot-custom.conf" <<'TMPEOF'
# Dovecot runtime directories
d /run/dovecot 0755 dovecot dovecot -
d /run/dovecot/login 0755 dovenull dovenull -
d /var/run/dovecot 0755 dovecot dovecot -
d /var/run/dovecot/login 0755 dovenull dovenull -
TMPEOF

  # Systemd-Hardening: Schutzmechanismen wie offizielle Ubuntu-Pakete
  if [ -f "${STAGE_DOVECOT}/lib/systemd/system/dovecot.service" ]; then
    sed -i '/^\[Service\]/a LimitNOFILE=65535\nProtectSystem=full\nPrivateDevices=true\nProtectHome=true' \
      "${STAGE_DOVECOT}/lib/systemd/system/dovecot.service"
    log "Systemd-Hardening angewendet"
  fi

  log "Staging-Inhalt (relevante Dateien):"
  find "$STAGE_DOVECOT" \( -name "dovecot" -o -name "doveadm" -o -name "dovecot-config"     -o -name "*.so" -o -name "dovecot.service" \) | sort | tee -a "$LOG_FILE"

  # postinst/postrm Scripts
  local postinst="/tmp/dovecot-postinst.sh"
  local postrm="/tmp/dovecot-postrm.sh"

  cat > "$postinst" <<'POSTINST'
#!/bin/sh
set -e

if ! id -u dovecot >/dev/null 2>&1; then
  adduser --system --group --home /var/run/dovecot --no-create-home \
    --gecos "Dovecot Mail Server" --shell /usr/sbin/nologin dovecot 2>/dev/null || true
fi
if ! id -u dovenull >/dev/null 2>&1; then
  adduser --system --group --home /var/run/dovecot --no-create-home \
    --gecos "Dovecot Login User" --shell /usr/sbin/nologin dovenull 2>/dev/null || true
fi

# Generate DH parameters if missing
if [ ! -f /etc/dovecot/dh.pem ] && command -v openssl >/dev/null 2>&1; then
  openssl dhparam -out /etc/dovecot/dh.pem 2048 2>/dev/null &
fi

mkdir -p /var/run/dovecot /var/lib/dovecot
chown dovecot:dovecot /var/lib/dovecot 2>/dev/null || true

# Copy default configs on fresh install
if [ ! -f /etc/dovecot/dovecot.conf ]; then
  echo "INFO: Keine dovecot.conf gefunden – installiere Default-Konfiguration"
  if [ -d /usr/share/dovecot ]; then
    cp -a /usr/share/dovecot/dovecot.conf /etc/dovecot/dovecot.conf 2>/dev/null || true
    mkdir -p /etc/dovecot/conf.d
    if [ -d /usr/share/dovecot/conf.d ]; then
      for f in /usr/share/dovecot/conf.d/*.conf; do
        [ -f "$f" ] && cp -a "$f" /etc/dovecot/conf.d/ 2>/dev/null || true
      done
    fi
  fi
  # Generate DH params if missing
  if [ ! -f /etc/dovecot/dh.pem ] && command -v openssl >/dev/null 2>&1; then
    openssl dhparam -out /etc/dovecot/dh.pem 2048 2>/dev/null &
  fi
fi

# Create PAM config for dovecot if missing
if [ ! -f /etc/pam.d/dovecot ]; then
  echo "auth    required        pam_unix.so    nullok" > /etc/pam.d/dovecot
  echo "account required        pam_unix.so" >> /etc/pam.d/dovecot
fi

# Create /etc/default/dovecot if missing
if [ ! -f /etc/default/dovecot ]; then
  echo "# Dovecot startup configuration" > /etc/default/dovecot
  echo "ENABLED=1" >> /etc/default/dovecot
fi

ldconfig
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
command -v apt-mark >/dev/null 2>&1 && apt-mark hold dovecot-core-custom || true
POSTINST
  chmod 755 "$postinst"

  cat > "$postrm" <<'POSTRM'
#!/bin/sh
set -e

command -v apt-mark >/dev/null 2>&1 && apt-mark unhold dovecot-core-custom 2>/dev/null || true
ldconfig
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
POSTRM
  chmod 755 "$postrm"

  local deb_core="$PACKAGE_DIR/dovecot-core-custom_${DOVECOT_VERSION}_${arch}.deb"
  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         dovecot-core-custom \
    --version      "$DOVECOT_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Dovecot IMAP/POP3 $DOVECOT_VERSION – custom build (ISPConfig/MariaDB/Sieve)" \
    --depends      libssl3 \
    --depends      libmariadb3 \
    --depends      libpam0g \
    --depends      libicu74 \
    --depends      libsodium23 \
    --depends      "liblua5.4-0 | liblua5.3-0" \
    --conflicts    dovecot-core \
    --provides     dovecot-core \
    --replaces     dovecot-core \
    --conflicts    dovecot-imapd \
    --conflicts    dovecot-pop3d \
    --conflicts    dovecot-lmtpd \
    --conflicts    dovecot-mysql \
    --conflicts    dovecot-pgsql \
    --conflicts    dovecot-sqlite \
    --conflicts    dovecot-ldap \
    --conflicts    dovecot-dev \
    --provides     dovecot-imapd \
    --provides     dovecot-pop3d \
    --provides     dovecot-lmtpd \
    --provides     dovecot-mysql \
    --provides     dovecot-pgsql \
    --provides     dovecot-sqlite \
    --provides     dovecot-ldap \
    --replaces     dovecot-imapd \
    --replaces     dovecot-pop3d \
    --replaces     dovecot-lmtpd \
    --replaces     dovecot-mysql \
    --replaces     dovecot-pgsql \
    --replaces     dovecot-sqlite \
    --replaces     dovecot-ldap \
    --deb-no-default-config-files \
    --after-install  "$postinst" \
    --after-remove   "$postrm" \
    --force \
    --package      "$deb_core" \
    --chdir        "$STAGE_DOVECOT" \
    .

  log "Erzeugt: $(basename "$deb_core") ($(du -sh "$deb_core" | cut -f1))"
  dpkg-deb --contents "$deb_core" \
    | awk '{print $NF}' \
    | grep -E "(sbin/dovecot$|bin/doveadm|\.so|dovecot\.service|dovecot-config)" \
    | sort | tee -a "$LOG_FILE" || true

  echo ""
  log "=== Dovecot-Core Paket-Build abgeschlossen ==="
  echo "Paket: $deb_core"
  local repo_script
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  if [ -x "$repo_script" ]; then
    log "Aktualisiere lokales Repository..."
    "$repo_script" update || true
  fi

  echo "Nächster Schritt: $0 package-pigeonhole"
}

# ------------------------------------------------------------------------------
# Nur Pigeonhole bauen + .deb erstellen
# Voraussetzung: dovecot-core Tarball/Quellen müssen in $BUILD_ROOT/core
# vorhanden sein (d.h. package-dovecot muss vorher gelaufen sein)
# ------------------------------------------------------------------------------
package_pigeonhole() {
  log "=== Starte Pigeonhole Paket-Build ==="
  install_build_deps

  mkdir -p "$BUILD_ROOT"

  # Pigeonhole-Quellen herunterladen falls nicht vorhanden
  if [ ! -d "$BUILD_ROOT/pigeonhole" ]; then
    local ph_tar
    ph_tar="$BUILD_ROOT/dovecot-pigeonhole-${PIGEONHOLE_VERSION}.tar.gz"
    if [ ! -f "$ph_tar" ]; then
      log "Lade Pigeonhole $PIGEONHOLE_VERSION Tarball nach $ph_tar"
      wget -q --show-progress "$PIGEONHOLE_TARBALL" -O "$ph_tar"         || curl -L --progress-bar "$PIGEONHOLE_TARBALL" -o "$ph_tar"         || die "Download fehlgeschlagen"
    else
      log "Pigeonhole Tarball bereits vorhanden: $ph_tar"
    fi
    cd "$BUILD_ROOT"
    tar xzf "$ph_tar"
    [ -d "dovecot-pigeonhole-${PIGEONHOLE_VERSION}" ]       || die "Tarball entpackt kein Verzeichnis dovecot-pigeonhole-${PIGEONHOLE_VERSION}"
    mv "dovecot-pigeonhole-${PIGEONHOLE_VERSION}" pigeonhole
    [ -x "$BUILD_ROOT/pigeonhole/configure" ]       || die "configure fehlt im Pigeonhole-Tarball – Tarball beschädigt?"
    log "Pigeonhole Quellen: $BUILD_ROOT/pigeonhole"
  else
    log "Pigeonhole-Quellen bereits vorhanden: $BUILD_ROOT/pigeonhole"
    [ -x "$BUILD_ROOT/pigeonhole/configure" ]       || die "configure fehlt in $BUILD_ROOT/pigeonhole – Verzeichnis neu entpacken"
  fi

  # Dovecot-Core muss bereits gebaut + ins Staging installiert sein
  if [ ! -d "$STAGE_DOVECOT" ] || [ ! -f "$STAGE_DOVECOT/usr/lib/dovecot/dovecot-config" ]; then
    log "Dovecot-Staging fehlt oder unvollständig – baue Core ins Staging"
    [ -d "$BUILD_ROOT/core" ]       || die "Dovecot-Quellen fehlen in $BUILD_ROOT/core – bitte zuerst: $0 package-dovecot"
    cd "$BUILD_ROOT/core"
    make install DESTDIR="$STAGE_DOVECOT"
  else
    log "Dovecot-Staging vorhanden: $STAGE_DOVECOT"
  fi

  build_pigeonhole

  # dovecot-pigeonhole-custom.deb erstellen
  local arch
  arch="$(dpkg --print-architecture)"
  mkdir -p "$PACKAGE_DIR"

  log "Prüfe Pigeonhole-Staging"
  [ -d "$STAGE_PIGEONHOLE" ] || die "Pigeonhole-Staging fehlt nach build_pigeonhole"
  rm -rf "${STAGE_PIGEONHOLE:?}/etc"

  log "Pigeonhole Staging-Inhalt:"
  find "$STAGE_PIGEONHOLE" \( -name "*.so" -o -name "*sieve*" -o -name "*managesieve*" \)     | sort | tee -a "$LOG_FILE"

  local postinst="/tmp/dovecot-postinst.sh"
  local postrm="/tmp/dovecot-postrm.sh"
  printf '#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
' > "$postinst"
  printf '#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
' > "$postrm"
  chmod 755 "$postinst" "$postrm"

  local deb_sieve="$PACKAGE_DIR/dovecot-pigeonhole-custom_${PIGEONHOLE_VERSION}_${arch}.deb"
  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         dovecot-pigeonhole-custom \
    --version      "$PIGEONHOLE_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Dovecot Pigeonhole/Sieve $PIGEONHOLE_VERSION – custom build" \
    --depends      dovecot-core-custom \
    --conflicts    dovecot-sieve \
    --conflicts    dovecot-managesieved \
    --provides     dovecot-sieve \
    --provides     dovecot-managesieved \
    --replaces     dovecot-sieve \
    --replaces     dovecot-managesieved \
    --deb-no-default-config-files \
    --after-install  "$postinst" \
    --after-remove   "$postrm" \
    --force \
    --package      "$deb_sieve" \
    --chdir        "$STAGE_PIGEONHOLE" \
    .

  log "Erzeugt: $(basename "$deb_sieve") ($(du -sh "$deb_sieve" | cut -f1))"
  dpkg-deb --contents "$deb_sieve" \
    | awk '{print $NF}' \
    | grep -E "(\.so|sieve|managesieve)" \
    | sort | tee -a "$LOG_FILE" || true

  echo ""
  log "=== Pigeonhole Paket-Build abgeschlossen ==="
  echo "Paket: $deb_sieve"
  local repo_script
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  if [ -x "$repo_script" ]; then
    log "Aktualisiere lokales Repository..."
    "$repo_script" update || true
  fi

  echo "Nächster Schritt: $0 install"
}

# ------------------------------------------------------------------------------
# Kompletter Paket-Build (Schritt 1 – nichts wird installiert)
# ------------------------------------------------------------------------------
package_all() {
  log "=== Starte Paket-Build (Core + Pigeonhole) ==="
  install_build_deps
  prepare_sources
  build_dovecot
  build_pigeonhole
  create_deb_packages
  create_dovecot_dev_package
  create_dovecot_doc_package
  sign_packages
  log "=== Paket-Build abgeschlossen ==="
}

# ------------------------------------------------------------------------------
# .deb-Paket: dovecot-custom-dev (Header-Dateien + dovecot-config)
# ------------------------------------------------------------------------------
create_dovecot_dev_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  local dev_stage="/tmp/dovecot-dev-stage"
  rm -rf "$dev_stage"
  mkdir -p "$dev_stage"

  # Header aus dem Staging kopieren (wurden mit make install installiert)
  local staging_inc="${STAGE_DOVECOT}/usr/include/dovecot"
  if [ -d "$staging_inc" ]; then
    mkdir -p "$dev_stage/usr/include"
    cp -a "$staging_inc" "$dev_stage/usr/include/"
    local hdr_count
    hdr_count=$(find "$dev_stage/usr/include" -name "*.h" | wc -l)
    log "Dovecot dev: $hdr_count Header-Dateien kopiert"
  else
    log "SKIP dovecot-custom-dev – keine Header im Staging"
    rm -rf "$dev_stage"
    return 0
  fi

  # dovecot-config (wird von Pigeonhole und anderen Plugins benötigt)
  local dconfig="${STAGE_DOVECOT}/usr/lib/dovecot/dovecot-config"
  if [ -f "$dconfig" ]; then
    mkdir -p "$dev_stage/usr/lib/dovecot"
    cp "$dconfig" "$dev_stage/usr/lib/dovecot/"
    log "Dovecot dev: dovecot-config kopiert"
  fi

  mkdir -p "$dev_stage/usr/share/doc/dovecot-custom-dev"

  local deb_file="$PACKAGE_DIR/dovecot-custom-dev_${DOVECOT_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         dovecot-custom-dev \
    --version      "$DOVECOT_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Dovecot $DOVECOT_VERSION – development headers and dovecot-config" \
    --depends      dovecot-core-custom \
    --conflicts    dovecot-dev \
    --provides     dovecot-dev \
    --replaces     dovecot-dev \
    --deb-no-default-config-files \
    --force \
    --package      "$deb_file" \
    --chdir        "$dev_stage" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
  rm -rf "$dev_stage"
}

# ------------------------------------------------------------------------------
# .deb-Paket: dovecot-custom-doc (Dokumentation)
# ------------------------------------------------------------------------------
create_dovecot_doc_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  local doc_stage="/tmp/dovecot-doc-stage"
  rm -rf "$doc_stage"
  mkdir -p "$doc_stage"

  local doc_dir="${STAGE_DOVECOT}/usr/share/doc/dovecot"
  local doc_count=0
  if [ -d "$doc_dir" ]; then
    mkdir -p "$doc_stage/usr/share/doc/dovecot"
    cp -a "$doc_dir"/* "$doc_stage/usr/share/doc/dovecot/" 2>/dev/null || true
    doc_count=$(find "$doc_stage" -type f | wc -l)
  fi

  # Man-pages als gz aus dem Staging kopieren
  local man_dir="${STAGE_DOVECOT}/usr/share/man"
  if [ -d "$man_dir" ]; then
    mkdir -p "$doc_stage/usr/share/man"
    cp -a "$man_dir"/* "$doc_stage/usr/share/man/" 2>/dev/null || true
  fi

  # Beispiel-Konfigurationen aus /usr/share/dovecot
  local share_dir="${STAGE_DOVECOT}/usr/share/dovecot"
  if [ -d "$share_dir" ]; then
    mkdir -p "$doc_stage/usr/share/dovecot"
    cp -a "$share_dir"/*.conf "$doc_stage/usr/share/dovecot/" 2>/dev/null || true
    cp -a "$share_dir"/*.ext "$doc_stage/usr/share/dovecot/" 2>/dev/null || true
    if [ -d "$share_dir/conf.d" ]; then
      mkdir -p "$doc_stage/usr/share/dovecot/conf.d"
      cp -a "$share_dir/conf.d"/*.conf "$doc_stage/usr/share/dovecot/conf.d/" 2>/dev/null || true
    fi
    doc_count=$(find "$doc_stage" -type f | wc -l)
  fi

  if [ "$doc_count" -eq 0 ]; then
    log "SKIP dovecot-custom-doc – keine Dokumentation gefunden"
    rm -rf "$doc_stage"
    return 0
  fi

  local deb_file="$PACKAGE_DIR/dovecot-custom-doc_${DOVECOT_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         dovecot-custom-doc \
    --version      "$DOVECOT_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Dovecot $DOVECOT_VERSION – documentation and example configs" \
    --depends      dovecot-core-custom \
    --deb-no-default-config-files \
    --force \
    --package      "$deb_file" \
    --chdir        "$doc_stage" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
  rm -rf "$doc_stage"
}

# ------------------------------------------------------------------------------
# Installation (Schritt 2 – Backup + dpkg -i der Pakete aus package_all)
#
# Ablauf:
#   1. Backup des GESAMTEN Ist-Zustands (Binaries + /etc/dovecot + Libs)
#   2. dpkg -i  → installiert nur Binaries/Module/Libs, NICHT /etc/dovecot
#   3. systemctl restart dovecot
#   4. Modul-Verifikation
#
# /etc/dovecot wird durch diesen Schritt NICHT verändert.
# ------------------------------------------------------------------------------
install_all() {
  log "=== Starte Installation ==="
  log "Schritt 1/4: Backup erstellen"
  create_backup
  log "Schritt 2/4: Pakete installieren (/etc/dovecot bleibt unberührt)"
  install_packages
  log "Schritt 3/4: Dovecot neu starten"
  restart_services
  log "Schritt 4/4: Modul-Verifikation"
  post_checks
  log "=== Installation abgeschlossen ==="
  echo ""
  echo "Zusammenfassung:"
  echo "  Backup:         $LATEST_LINK"
  echo "  Pakete:         $PACKAGE_DIR"
  echo "  Konfiguration:  /etc/dovecot  (UNVERÄNDERT)"
  echo "  Log:            $LOG_FILE"
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
    echo "Starte Skript in Screen Session: dovecot_build ..."
    exec screen -dmS dovecot_build bash "$0" "$@"
  fi

  mkdir -p "$BACKUP_ROOT" "$PACKAGE_DIR"
  touch "$LOG_FILE"

  case "${1:-help}" in
    package)             package_all ;;
    package-dovecot)     package_dovecot ;;
    package-pigeonhole)  package_pigeonhole ;;
    install)             install_all ;;
    build-only)
      install_build_deps
      prepare_sources
      build_dovecot
      build_pigeonhole
      log "Build fertig – keine Pakete erstellt, nichts installiert"
      ;;
    backup)         create_backup ;;
    restore)        restore_from_backup "${2:-$LATEST_LINK}" ;;
    status)         status_cmd ;;
    list-backups)   list_backups ;;
    list-packages)  list_packages ;;
    check-config)   check_config ;;
    uninstall)      uninstall_cmd ;;
    help|-h|--help) usage ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
