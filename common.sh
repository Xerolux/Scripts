#!/usr/bin/env bash
# ==============================================================================
# common.sh – Shared Functions Library for Xerolux Build Scripts
#
# Usage (at top of each script, AFTER sourcing .env):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/common.sh"
#
# Provides:
#   log(), die(), require_root()
#   check_os_arch()
#   generate_checksums()
#   sign_packages()
#   update_local_repo_if_configured()
#   install_signing_tool()
#   ensure_ccache()
# ==============================================================================
# Do NOT source this directly without setting LOG_FILE first.

# --- Logging ---

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
die()  { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausfuehren."
}

# --- OS / Architecture Check ---

check_os_arch() {
  local os_id="" os_version_id="" os_major_version arch

  [ -f /etc/os-release ] && . /etc/os-release
  os_id="${ID:-}"
  os_version_id="${VERSION_ID:-}"
  os_major_version=$(echo "$os_version_id" | cut -d. -f1)
  arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")

  if [ "$os_id" != "ubuntu" ] || [ -z "$os_major_version" ] || [ "$os_major_version" -lt 24 ]; then
    echo "FEHLER: Nur Ubuntu 24.04+ unterstuetzt (aktuell: ${os_id:-?} ${os_version_id:-?})." >&2
    exit 1
  fi
  if [ "$arch" != "arm64" ]; then
    echo "WARNUNG: Skript ist fuer arm64 optimiert. Architektur: $arch." >&2
  fi
}

# --- SHA256 Checksums ---

generate_checksums() {
  local pkg_dir="${1:-$PACKAGE_DIR}"
  if [ -d "$pkg_dir" ] && find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
    log "Erstelle SHA256SUMS fuer Pakete..."
    cd "$pkg_dir"
    sha256sum ./*.deb > SHA256SUMS
    log "SHA256SUMS erstellt: $(wc -l < SHA256SUMS) Pakete"
    tee -a "$LOG_FILE" < SHA256SUMS
  fi
}

# --- Signing Tool Installation ---

install_signing_tool() {
  if command -v dpkg-sig >/dev/null 2>&1 || command -v debsigs >/dev/null 2>&1; then
    return 0
  fi
  if apt-cache show dpkg-sig >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-sig || true
  elif apt-cache show debsigs >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y debsigs || true
  else
    log "Kein Paketsignierungs-Tool verfuegbar – Signierung wird uebersprungen"
  fi
}

# --- Package Signing ---

sign_packages() {
  local pkg_dir="${1:-$PACKAGE_DIR}"
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

  log "Signiere .deb-Pakete mit $sign_tool (GPG: $gpg_key_id)..."
  local sign_count=0 sign_fail=0
  for deb in "$pkg_dir"/*.deb; do
    [ -f "$deb" ] || continue
    if [ "$sign_tool" = "dpkg-sig" ]; then
      dpkg-sig --verify "$deb" 2>/dev/null | grep -q "GOODSIG" && continue
      dpkg-sig -k "$gpg_key_id" --sign builder "$deb" >/dev/null 2>&1 && sign_count=$((sign_count + 1)) || sign_fail=$((sign_fail + 1))
    else
      debsigs --sign=origin --default-key="$gpg_key_id" "$deb" >/dev/null 2>&1 && sign_count=$((sign_count + 1)) || sign_fail=$((sign_fail + 1))
    fi
  done
  log "$sign_count Pakete signiert, $sign_fail fehlgeschlagen"
}

# --- Local Repository Auto-Update ---

update_local_repo_if_configured() {
  local caller_dir repo_script repo_env repo_env_example repo_dir=""

  caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
  repo_script="$caller_dir/setup_local_repo.sh"
  repo_env="$caller_dir/setup_local_repo.env"
  repo_env_example="$caller_dir/setup_local_repo.env.example"

  [ -x "$repo_script" ] || return 0

  if [ ! -f "$repo_env" ] && [ -f "$repo_env_example" ]; then
    cp -n "$repo_env_example" "$repo_env" 2>/dev/null || true
    log "Lokales Repo-Env erstellt: $(basename "$repo_env")"
  fi
  [ -f "$repo_env" ] || return 0

  repo_dir="$(
    (set +u; source "$repo_env" 2>/dev/null || true; printf '%s' "${REPO_DIR:-}")
  )"
  [ -n "$repo_dir" ] || return 0
  [ -d "$repo_dir" ] || return 0

  log "Aktualisiere lokales Repository..."
  "$repo_script" update || true
}

# --- ccache Support ---

ensure_ccache() {
  if ! command -v ccache >/dev/null 2>&1; then
    log "Installiere ccache..."
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ccache 2>/dev/null || { log "ccache nicht verfuegbar – ueberspringe"; return 0; }
  fi
  log "ccache: $(ccache --version 2>/dev/null | head -1)"
  log "ccache dir: ${CCACHE_DIR:-/root/.ccache}"
  mkdir -p "${CCACHE_DIR:-/root/.ccache}" 2>/dev/null || true
}

setup_ccache_env() {
  export CCACHE_DIR="${CCACHE_DIR:-/root/.ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
  export CCACHE_COMPRESS="${CCACHE_COMPRESS:-1}"
  export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-6}"
  mkdir -p "$CCACHE_DIR" 2>/dev/null || true
}

ccache_stats() {
  if command -v ccache >/dev/null 2>&1; then
    log "ccache Statistik:"
    ccache --show-stats 2>/dev/null | sed 's/^/  /' | tee -a "$LOG_FILE" || true
  fi
}

# --- Build Duration Tracker ---

BUILD_START_SECS="${BUILD_START_SECS:-0}"

start_build_timer() {
  BUILD_START_SECS="$SECONDS"
}

elapsed_build_time() {
  local s=$((SECONDS - BUILD_START_SECS))
  if [ "$s" -ge 3600 ]; then
    printf '%dh%dm%ds' $((s/3600)) $((s%3600/60)) $((s%60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm%ds' $((s/60)) $((s%60))
  else
    printf '%ds' "$s"
  fi
}

log_build_summary() {
  local label="${1:-Build}"
  local pkg_dir="${2:-$PACKAGE_DIR}"
  local duration
  duration="$(elapsed_build_time)"
  log "=== $label abgeschlossen in $duration ==="
  if [ -d "$pkg_dir" ]; then
    local cnt
    cnt="$(find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | wc -l)"
    log "Pakete: $cnt in $pkg_dir"
  fi
  ccache_stats
}

# --- OpenSSL Build ---

prepare_openssl() {
  local ssl_dir="$BUILD_ROOT/openssl-${OPENSSL_VERSION}"
  local ssl_build_dir="$BUILD_ROOT/openssl-build-${OPENSSL_VERSION}"
  local ssl_tar="$BUILD_ROOT/openssl-${OPENSSL_VERSION}.tar.gz"
  local ssl_install="$BUILD_ROOT/openssl-install-${OPENSSL_VERSION}"

  # Check if OpenSSL is already built
  if [ -d "$ssl_install" ] && [ -f "$ssl_install/lib/libssl.so" ]; then
    log "OpenSSL $OPENSSL_VERSION bereits gebaut: $ssl_install"
    return 0
  fi

  # Download tarball if needed
  if [ ! -f "$ssl_tar" ]; then
    log "Lade OpenSSL $OPENSSL_VERSION Tarball herunter..."
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar \
      "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" -o "$ssl_tar" \
      || die "OpenSSL Download fehlgeschlagen"
  else
    log "OpenSSL Tarball bereits vorhanden: $ssl_tar"
  fi

  # Extract to clean source directory for Nginx (if needed)
  if [ ! -d "$ssl_dir" ]; then
    log "Entpacke OpenSSL Quellen..."
    tar xzf "$ssl_tar" -C "$BUILD_ROOT" || die "Entpacken fehlgeschlagen"
    [ -d "$ssl_dir" ] || die "Tarball entpackt kein Verzeichnis openssl-${OPENSSL_VERSION}"
  fi

  # Build in separate build directory (keeps sources clean for Nginx)
  mkdir -p "$ssl_build_dir" || die "Kann $ssl_build_dir nicht erstellen"
  mkdir -p "$ssl_install" || die "Kann $ssl_install nicht erstellen"

  log "Baue OpenSSL $OPENSSL_VERSION (Quellen: $ssl_dir, Build: $ssl_build_dir)..."
  cd "$ssl_build_dir" || die "Kann nicht zu $ssl_build_dir wechseln"

  # Configure for shared library build with PIC for ARM64
  "$ssl_dir/Configure" \
    linux-aarch64 \
    --prefix="$ssl_install" \
    --libdir=lib \
    shared \
    no-tests \
    -fPIC \
    || die "OpenSSL Configure fehlgeschlagen"

  # Build
  make -j "$(nproc)" || die "OpenSSL Kompilierung fehlgeschlagen"

  # Install
  make install || die "OpenSSL Installation fehlgeschlagen"

  [ -f "$ssl_install/lib/libssl.so" ] || die "OpenSSL libssl.so nicht gefunden nach Build"
  log "OpenSSL erfolgreich gebaut und installiert: $ssl_install"
}
