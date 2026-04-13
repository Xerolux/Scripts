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

POSTFIX_TARBALL="https://ftp.porcupine.org/mirrors/postfix-release/official/postfix-${POSTFIX_VERSION}.tar.gz"
# Spiegel-Fallback
POSTFIX_TARBALL_MIRROR="https://de.postfix.org/ftpmirror/official/postfix-${POSTFIX_VERSION}.tar.gz"

# Installationspfade (passend zu bestehender ISPConfig-Installation)
# Diese werden in der Funktion create_deb_package direkt verwendet
# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
die()  { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausführen."
}

usage() {
  cat <<'EOF'
Verwendung:
  setup_postfix.sh package          – Quellen laden, bauen, .deb erstellen (KEIN install)
  setup_postfix.sh install          – Backup + dpkg -i des erzeugten .deb
  setup_postfix.sh backup           – Nur Backup erstellen
  setup_postfix.sh restore          – Letztes Backup einspielen
  setup_postfix.sh restore /root/postfix-backup/<timestamp>
  setup_postfix.sh status           – Zustand + Module anzeigen
  setup_postfix.sh list-backups     – Verfügbare Backups auflisten
  setup_postfix.sh check-config     – postfix check ausführen
  setup_postfix.sh uninstall        – Custom-Paket via dpkg -r entfernen

Deinstallation manuell:
  dpkg -r postfix-custom
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
    postfix --version > "$backup_dir/postfix-version.txt" 2>&1 || true
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
    build-essential make m4 \
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
    wget -q --show-progress "$POSTFIX_TARBALL" -O "$pf_tar" \
      || curl -L --progress-bar "$POSTFIX_TARBALL" -o "$pf_tar" \
      || wget -q --show-progress "$POSTFIX_TARBALL_MIRROR" -O "$pf_tar" \
      || die "Download fehlgeschlagen"
  else
    log "Postfix Tarball bereits vorhanden: $pf_tar"
  fi

  tar xzf "$pf_tar"
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
  for l in libmariadb libmysqlclient; do
    [ -f "/usr/lib/aarch64-linux-gnu/${l}.so" ] && mysql_lib="${l}" && break
    [ -f "/usr/lib/${l}.so" ]                    && mysql_lib="${l}" && break
  done
  if [ -n "$mysql_inc" ] && [ -n "$mysql_lib" ]; then
    log "  [+] MariaDB/MySQL ($mysql_inc, lib: $mysql_lib)"
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
    CCARGS="$CCARGS -DHAS_PCRE -DHAS_PCRE2 $(pkg-config --cflags libpcre2-8)"
    AUXLIBS_PCRE="$(pkg-config --libs libpcre2-8)"
  elif [ -f /usr/include/pcre.h ]; then
    log "  [+] PCRE (v1)"
    CCARGS="$CCARGS -DHAS_PCRE"
    AUXLIBS_PCRE="-lpcre"
  else
    log "  [-] PCRE nicht gefunden"
  fi

  # --- LMDB – Ersatz für hash/btree (wichtig in Postfix 3.11) ---------------
  if [ -f /usr/include/lmdb.h ]; then
    log "  [+] LMDB"
    CCARGS="$CCARGS -DHAS_LMDB"
    AUXLIBS_LMDB="-llmdb"
  else
    log "  [-] LMDB nicht gefunden (liblmdb-dev prüfen)"
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
    CCARGS="$CCARGS -DUSE_LDAP_SASL $(pkg-config --cflags icu-uc icu-i18n)"
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
  CCARGS="$CCARGS -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
  CCARGS="$CCARGS -Wno-implicit-function-declaration"

  # Ergebnis exportieren
  echo "CCARGS=${CCARGS}"
  echo "AUXLIBS=${AUXLIBS}"
  echo "AUXLIBS_LMDB=${AUXLIBS_LMDB}"
  echo "AUXLIBS_PCRE=${AUXLIBS_PCRE}"
  echo "AUXLIBS_SQLITE=${AUXLIBS_SQLITE}"
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
    default_database_type=lmdb \
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
  [ "$inst_rc" -eq 0 ] || die "postfix-install fehlgeschlagen (Exit $inst_rc)"

  # /etc/postfix aus Staging entfernen – Konfiguration bleibt beim Backup/Restore
  rm -rf "${STAGE_POSTFIX}/etc/postfix"
  log "/etc/postfix aus Staging entfernt (Konfiguration wird nicht verpackt)"

  # Staging-Inhalt prüfen
  log "Staging-Inhalt (relevante Dateien):"
  find "$STAGE_POSTFIX" \( -name "postfix" -o -name "postconf" -o -name "smtpd" \
    -o -name "*.so" -o -name "postfix.service" \) | sort | tee -a "$LOG_FILE"

  # Post-Install / Post-Remove Scripts
  local postinst="/tmp/postfix-postinst.sh"
  local postrm="/tmp/postfix-postrm.sh"
  printf '#!/bin/sh\nset -e\nldconfig\ncommand -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true\n' > "$postinst"
  printf '#!/bin/sh\nset -e\nldconfig\ncommand -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true\n' > "$postrm"
  chmod 755 "$postinst" "$postrm"

  local deb_file="$PACKAGE_DIR/postfix-custom_${POSTFIX_VERSION}_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         postfix-custom \
    --version      "$POSTFIX_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "Postfix MTA $POSTFIX_VERSION – custom build (ISPConfig/MariaDB/SASL/LMDB/TLS)" \
    --depends      libssl3 \
    --depends      libsasl2-2 \
    --depends      libmariadb3 \
    --depends      libldap-2.5-0 \
    --depends      libpcre2-8-0 \
    --depends      liblmdb0 \
    --depends      libsqlite3-0 \
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
    | grep -E "(postfix$|postconf|smtpd|\.so|postfix\.service)" \
    | sort | tee -a "$LOG_FILE" || true

  # Map-Typen prüfen
  log "Verfügbare Map-Typen werden nach Installation sichtbar via: postconf -m"

  echo ""
  log "===== Paket fertig ====="
  find "$deb_file" -maxdepth 0 -printf "%s bytes %p\n" | tee -a "$LOG_FILE"
  echo ""
  echo "HINWEIS: /etc/postfix ist NICHT im Paket."
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
    postfix --version 2>/dev/null || true
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
  dpkg -i "$deb_file"

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
  log "Postfix Version: $(postfix --version 2>&1)"

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
    echo "Version : $(postfix --version 2>/dev/null || echo 'unbekannt')"
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
  log "Deinstalliere postfix-custom"
  systemctl stop postfix 2>/dev/null || true
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

  if ! command -v screen >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y screen
  fi
}

main() {
  check_os_arch

  if [ -z "${STY:-}" ]; then
    echo "Starte Skript im Hintergrund (Screen Session: postfix_build)..."
    exec screen -dmS postfix_build bash "$0" "$@"
    exit 0
  fi

  require_root
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
