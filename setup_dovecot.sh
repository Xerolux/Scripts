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
  setup_dovecot.sh package              – Beide Pakete bauen (dovecot-core + pigeonhole)
  setup_dovecot.sh package-dovecot      – Nur dovecot-core bauen + .deb erstellen
  setup_dovecot.sh package-pigeonhole   – Nur pigeonhole bauen + .deb erstellen
                                          (setzt fertigen dovecot-core Tarball voraus)
  setup_dovecot.sh install              – Backup + dpkg -i der erzeugten .deb-Pakete
  setup_dovecot.sh build-only           – Nur kompilieren, kein Paket, kein install
  setup_dovecot.sh backup           – Nur Backup erstellen
  setup_dovecot.sh restore          – Letztes Backup einspielen
  setup_dovecot.sh restore /root/dovecot-backup/<timestamp>
  setup_dovecot.sh status           – Zustand anzeigen
  setup_dovecot.sh list-backups     – Verfügbare Backups auflisten
  setup_dovecot.sh list-packages    – Erzeugte .deb-Pakete auflisten
  setup_dovecot.sh check-config     – dovecot -n ausführen
  setup_dovecot.sh uninstall        – Custom-Pakete via dpkg -r entfernen

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
    libexpat1-dev

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
  ./configure \
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
    --with-systemdsystemunitdir=/lib/systemd/system \
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

  # Aufräumen: ldconfig-Eintrag entfernen, Symlink ersetzen durch echten Link
  rm -f /etc/ld.so.conf.d/dovecot-staging.conf
  rm -f /usr/include/dovecot
  ldconfig

  log "Pigeonhole Build fertig"
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
ldconfig
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
POSTINST
  chmod 755 "$postinst"

  cat > "$postrm" <<'POSTRM'
#!/bin/sh
set -e
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

  # /etc/dovecot NICHT ins Paket – Konfiguration via backup/restore
  rm -rf "${STAGE_DOVECOT}/etc/dovecot"

  # Übersicht was tatsächlich drin ist
  log "Staging-Inhalt (relevante Dateien):"
  find "$STAGE_DOVECOT" \( -name "dovecot" -o -name "doveadm" -o -name "dovecot-config" \
    -o -name "*.so" -o -name "*.so.*" -o -name "dovecot.service" \) \
    | sort | tee -a "$LOG_FILE"

  local deb_core="$PACKAGE_DIR/dovecot-core-custom_${DOVECOT_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_core")"
  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         dovecot-core-custom \
    --version      "$DOVECOT_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Dovecot IMAP/POP3 $DOVECOT_VERSION – custom build (ISPConfig/MySQL/Sieve)" \
    --depends      libssl3 \
    --depends      libmariadb3 \
    --depends      libpam0g \
    --depends      libicu74 \
    --depends      libsodium23 \
    --depends      "liblua5.4-0 | liblua5.3-0" \
    --conflicts    dovecot-core \
    --provides     dovecot-core \
    --replaces     dovecot-core \
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

  # ---- Abschlussmeldung ------------------------------------------------------
  echo ""
  log "===== Fertige Pakete ====="
  find "$PACKAGE_DIR" -maxdepth 1 -name "*.deb" -printf "%s bytes %p\n" | tee -a "$LOG_FILE"
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
# Pakete via dpkg installieren
# ------------------------------------------------------------------------------
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
  dpkg -i "$deb_core"

  log "Installiere: $(basename "$deb_sieve")"
  dpkg -i "$deb_sieve"

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
  if grep -q "inotify" /proc/sys/fs/inotify/max_user_watches 2>/dev/null ||      [ -f /proc/sys/fs/inotify/max_user_watches ]; then
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

  log "Staging-Inhalt (relevante Dateien):"
  find "$STAGE_DOVECOT" \( -name "dovecot" -o -name "doveadm" -o -name "dovecot-config"     -o -name "*.so" -o -name "dovecot.service" \) | sort | tee -a "$LOG_FILE"

  # postinst/postrm Scripts
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

  local deb_core="$PACKAGE_DIR/dovecot-core-custom_${DOVECOT_VERSION}_${arch}.deb"
  fpm     --input-type   dir     --output-type  deb     --name         dovecot-core-custom     --version      "$DOVECOT_VERSION"     --iteration    1     --architecture "$arch"     --maintainer   "local build <root@localhost>"     --description  "Dovecot IMAP/POP3 $DOVECOT_VERSION – custom build (ISPConfig/MariaDB/Sieve)"     --depends      libssl3     --depends      libmariadb3     --depends      libpam0g     --depends      libicu74     --depends      libsodium23     --depends      "liblua5.4-0 | liblua5.3-0"     --conflicts    dovecot-core     --provides     dovecot-core     --replaces     dovecot-core     --deb-no-default-config-files     --after-install  "$postinst"     --after-remove   "$postrm"     --force     --package      "$deb_core"     --chdir        "$STAGE_DOVECOT"     .

  log "Erzeugt: $(basename "$deb_core") ($(du -sh "$deb_core" | cut -f1))"
  dpkg-deb --contents "$deb_core" | awk '{print $NF}'     | grep -E "(sbin/dovecot$|bin/doveadm|\.so|dovecot\.service|dovecot-config)"     | sort | tee -a "$LOG_FILE" || true

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
  fpm     --input-type   dir     --output-type  deb     --name         dovecot-pigeonhole-custom     --version      "$PIGEONHOLE_VERSION"     --iteration    1     --architecture "$arch"     --maintainer   "local build <root@localhost>"     --description  "Dovecot Pigeonhole/Sieve $PIGEONHOLE_VERSION – custom build"     --depends      dovecot-core-custom     --conflicts    dovecot-sieve     --conflicts    dovecot-managesieved     --provides     dovecot-sieve     --provides     dovecot-managesieved     --replaces     dovecot-sieve     --replaces     dovecot-managesieved     --deb-no-default-config-files     --after-install  "$postinst"     --after-remove   "$postrm"     --force     --package      "$deb_sieve"     --chdir        "$STAGE_PIGEONHOLE"     .

  log "Erzeugt: $(basename "$deb_sieve") ($(du -sh "$deb_sieve" | cut -f1))"
  dpkg-deb --contents "$deb_sieve" | awk '{print $NF}'     | grep -E "(\.so|sieve|managesieve)" | sort | tee -a "$LOG_FILE" || true

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
  log "=== Paket-Build abgeschlossen ==="
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

  if ! command -v screen >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y screen
  fi
}

main() {
  check_os_arch

  if [ -z "${STY:-}" ]; then
    echo "Starte Skript im Hintergrund (Screen Session: dovecot_build)..."
    exec screen -dmS dovecot_build bash "$0" "$@"
    exit 0
  fi

  require_root
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
