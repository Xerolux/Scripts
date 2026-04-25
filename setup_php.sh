#!/usr/bin/env bash
# ==============================================================================
# setup_php.sh – PHP 8.5 Build-from-Source + .deb-Paketerstellung
# Zielumgebung : Ubuntu 24.04 ARM64, ISPConfig, Nginx
#
# PHP wird aus Source kompiliert (cli + fpm + cgi + phpdbg).
# PECL-Extensions werden als SHARED extensions gebaut (phpize) und als
# separate .deb-Pakete verpackt, analog zum Ondrej Surry PPA (ppa:ondrej/php).
#
# Paketstruktur:
#   php8.5-custom_VERSION_arch.deb             – CLI + Common
#   php8.5-fpm-custom_VERSION_arch.deb         – FPM + systemd unit
#   php8.5-opcache_VERSION_arch.deb            – OPcache (zend_extension)
#   php8.5-redis_VERSION_arch.deb              – Redis PECL extension
#   php8.5-imagick_VERSION_arch.deb            – ImageMagick PECL extension
#   ... (siehe PECL_EXTENSIONS unten)
#
# Empfohlener Ablauf:
#   1. setup_php.sh package   → .deb-Pakete erstellen (KEIN install)
#   2. setup_php.sh install   → Backup + dpkg -i
#
# Konfiguration:
#   /etc/php/ wird NICHT in die Pakete gepackt → ISPConfig-Configs bleiben
#
# Deinstallation:
#   setup_php.sh uninstall
# ==============================================================================
set -Eeuo pipefail

if [[ ! -f "setup_php.env" ]]; then
  echo "FEHLER: setup_php.env nicht gefunden. Bitte aus setup_php.env.example erstellen." >&2
  exit 1
fi
source "setup_php.env"

PHP_TARBALL_URL="https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz"
PHP_PREFIX="/usr"
PHP_SYSCONFDIR="/etc/php/${PHP_VER_SHORT}"
PHP_LOCALSTATEDIR="/var"
PHP_LIBDIR="lib/php/${PHP_VER_SHORT}"
PHP_INCDIR="/usr/include/php/${PHP_VER_SHORT}"
PHP_EXTENSION_DIR="/usr/${PHP_LIBDIR}/modules"
PHP_MODS_AVAIL="/usr/share/php/${PHP_VER_SHORT}/mods-available"

# ------------------------------------------------------------------------------
# PECL-Extension-Definitionen (assoziative Arrays)
#
# Jede Extension wird via phpize als SHARED extension gebaut und bekommt
# ein eigenes .deb-Paket: php{VER}-{name}
#
# PECL_GITURL     – Git-Repository oder PECL-URL
# PECL_GITREF     – Branch oder Tag
# PECL_DIRNAME    – Verzeichnisname
# PECL_PKGNAME    – Paketname-Suffix (php8.5-{SUFFIX})
# PECL_DESC       – Kurzbeschreibung
# PECL_CONFIGURE  – Zusaetzliche ./configure Flags
# PECL_ZEND       – "yes" wenn zend_extension statt extension
# PECL_DEPS       – Zusaetzliche Paket-Abhaengigkeiten
# PECL_NEEDS      – Build-Abhaengigkeiten (optional)
# PECL_EXTNAME    – Name der .so Datei (ohne Pfad)
# ------------------------------------------------------------------------------
declare -A PECL_GITURL PECL_GITREF PECL_DIRNAME PECL_PKGNAME PECL_DESC \
           PECL_CONFIGURE PECL_ZEND PECL_DEPS PECL_NEEDS PECL_EXTNAME PECL_SUBDIR PECL_CMAKE PECL_SUBMODULES

# --- 1. OPcache --------------------------------------------------------------
PECL_DIRNAME[opcache]="opcache"
PECL_PKGNAME[opcache]="opcache"
PECL_DESC[opcache]="OPcache bytecode cache (zend_extension)"
PECL_ZEND[opcache]="yes"
PECL_EXTNAME[opcache]="opcache"
PECL_DEPS[opcache]="php${PHP_VER_SHORT}-custom"
PECL_GITURL[opcache]="built-in"
PECL_CONFIGURE[opcache]="--enable-opcache"

# --- 2. APCu -----------------------------------------------------------------
PECL_DIRNAME[apcu]="apcu"
PECL_GITURL[apcu]="https://github.com/krakjoe/apcu.git"
PECL_GITREF[apcu]="v5.1.24"
PECL_PKGNAME[apcu]="apcu"
PECL_DESC[apcu]="APC User Cache"
PECL_EXTNAME[apcu]="apcu"
PECL_ZEND[apcu]="no"
PECL_DEPS[apcu]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[apcu]=""

# --- 3. Redis ----------------------------------------------------------------
PECL_DIRNAME[redis]="phpredis"
PECL_GITURL[redis]="https://github.com/phpredis/phpredis.git"
PECL_GITREF[redis]="6.1.0"
PECL_PKGNAME[redis]="redis"
PECL_DESC[redis]="Redis client (phpredis)"
PECL_EXTNAME[redis]="redis"
PECL_ZEND[redis]="no"
PECL_DEPS[redis]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[redis]=""

# --- 4. Imagick --------------------------------------------------------------
PECL_DIRNAME[imagick]="imagick"
PECL_GITURL[imagick]="https://github.com/Imagick/imagick.git"
PECL_GITREF[imagick]="3.8.0"
PECL_PKGNAME[imagick]="imagick"
PECL_DESC[imagick]="ImageMagick extension"
PECL_EXTNAME[imagick]="imagick"
PECL_ZEND[imagick]="no"
PECL_DEPS[imagick]="php${PHP_VER_SHORT}-custom libmagickwand-6.q16-7"
PECL_CONFIGURE[imagick]=""

# --- 5. Memcached ------------------------------------------------------------
PECL_DIRNAME[memcached]="php-memcached"
PECL_GITURL[memcached]="https://github.com/php-memcached-dev/php-memcached.git"
PECL_GITREF[memcached]="v3.3.0"
PECL_PKGNAME[memcached]="memcached"
PECL_DESC[memcached]="Memcached client (libmemcached)"
PECL_EXTNAME[memcached]="memcached"
PECL_ZEND[memcached]="no"
PECL_DEPS[memcached]="php${PHP_VER_SHORT}-custom libmemcached11"
PECL_CONFIGURE[memcached]="--disable-memcached-sasl"

# --- 6. MongoDB --------------------------------------------------------------
PECL_DIRNAME[mongodb]="php-mongodb-src"
PECL_GITURL[mongodb]="https://github.com/mongodb/mongo-php-driver.git"
PECL_GITREF[mongodb]="1.21.0"
PECL_PKGNAME[mongodb]="mongodb"
PECL_DESC[mongodb]="MongoDB driver"
PECL_EXTNAME[mongodb]="mongodb"
PECL_ZEND[mongodb]="no"
PECL_DEPS[mongodb]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[mongodb]=""
PECL_SUBDIR[mongodb]="pecl-tarball"
PECL_CMAKE[mongodb]="yes"

# --- 7. AMQP -----------------------------------------------------------------
PECL_DIRNAME[amqp]="php-amqp"
PECL_GITURL[amqp]="https://github.com/php-amqp/php-amqp.git"
PECL_GITREF[amqp]="v2.1.2"
PECL_PKGNAME[amqp]="amqp"
PECL_DESC[amqp]="AMQP 0-9-1 messaging (rabbitmq-c)"
PECL_EXTNAME[amqp]="amqp"
PECL_ZEND[amqp]="no"
PECL_DEPS[amqp]="php${PHP_VER_SHORT}-custom librabbitmq4"
PECL_CONFIGURE[amqp]=""

# --- 8. GRPC -----------------------------------------------------------------
PECL_DIRNAME[grpc]="grpc"
PECL_GITURL[grpc]="https://github.com/grpc/grpc.git"
PECL_GITREF[grpc]="v1.71.0"
PECL_PKGNAME[grpc]="grpc"
PECL_DESC[grpc]="gRPC framework"
PECL_EXTNAME[grpc]="grpc"
PECL_ZEND[grpc]="no"
PECL_DEPS[grpc]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[grpc]=""
PECL_SUBDIR[grpc]="pecl-tarball"

# --- 9. YAML -----------------------------------------------------------------
PECL_DIRNAME[yaml]="php-yaml"
PECL_GITURL[yaml]="https://github.com/php/pecl-file_formats-yaml.git"
PECL_GITREF[yaml]="2.3.0"
PECL_PKGNAME[yaml]="yaml"
PECL_DESC[yaml]="YAML parsing (libyaml)"
PECL_EXTNAME[yaml]="yaml"
PECL_ZEND[yaml]="no"
PECL_DEPS[yaml]="php${PHP_VER_SHORT}-custom libyaml-0-2"
PECL_CONFIGURE[yaml]=""

# --- 10. SSH2 ----------------------------------------------------------------
PECL_DIRNAME[ssh2]="php-ssh2"
PECL_GITURL[ssh2]="https://github.com/php/pecl-networking-ssh2.git"
PECL_GITREF[ssh2]="1.4.1"
PECL_PKGNAME[ssh2]="ssh2"
PECL_DESC[ssh2]="SSH2 (libssh2)"
PECL_EXTNAME[ssh2]="ssh2"
PECL_ZEND[ssh2]="no"
PECL_DEPS[ssh2]="php${PHP_VER_SHORT}-custom libssh2-1"
PECL_CONFIGURE[ssh2]=""

# --- 11. Swoole --------------------------------------------------------------
PECL_DIRNAME[swoole]="swoole-src"
PECL_GITURL[swoole]="https://github.com/swoole/swoole-src.git"
PECL_GITREF[swoole]="master"
PECL_PKGNAME[swoole]="swoole"
PECL_DESC[swoole]="Async concurrency framework"
PECL_EXTNAME[swoole]="swoole"
PECL_ZEND[swoole]="no"
PECL_DEPS[swoole]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[swoole]="--enable-openssl --enable-http2 --enable-mysqlnd"

# --- 12. Xdebug --------------------------------------------------------------
PECL_DIRNAME[xdebug]="xdebug"
PECL_GITURL[xdebug]="https://github.com/xdebug/xdebug.git"
PECL_GITREF[xdebug]="3.5.0"
PECL_PKGNAME[xdebug]="xdebug"
PECL_DESC[xdebug]="Xdebug debugger and profiler (zend_extension)"
PECL_EXTNAME[xdebug]="xdebug"
PECL_ZEND[xdebug]="yes"
PECL_DEPS[xdebug]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[xdebug]=""

# --- 13. Protobuf ------------------------------------------------------------
PECL_DIRNAME[protobuf]="protobuf-php"
PECL_GITURL[protobuf]="https://github.com/protocolbuffers/protobuf-php.git"
PECL_GITREF[protobuf]="v4.33.2"
PECL_PKGNAME[protobuf]="protobuf"
PECL_DESC[protobuf]="Protocol Buffers"
PECL_EXTNAME[protobuf]="protobuf"
PECL_ZEND[protobuf]="no"
PECL_DEPS[protobuf]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[protobuf]=""
PECL_SUBDIR[protobuf]="pecl-tarball"

# --- 14. Igbinary ------------------------------------------------------------
PECL_DIRNAME[igbinary]="igbinary"
PECL_GITURL[igbinary]="https://github.com/igbinary/igbinary.git"
PECL_GITREF[igbinary]="3.2.16"
PECL_PKGNAME[igbinary]="igbinary"
PECL_DESC[igbinary]="Binary serialization"
PECL_EXTNAME[igbinary]="igbinary"
PECL_ZEND[igbinary]="no"
PECL_DEPS[igbinary]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[igbinary]=""

# --- 15. Msgpack -------------------------------------------------------------
PECL_DIRNAME[msgpack]="msgpack-php"
PECL_GITURL[msgpack]="https://github.com/msgpack/msgpack-php.git"
PECL_GITREF[msgpack]="v3.0.0"
PECL_PKGNAME[msgpack]="msgpack"
PECL_DESC[msgpack]="MessagePack serialization"
PECL_EXTNAME[msgpack]="msgpack"
PECL_ZEND[msgpack]="no"
PECL_DEPS[msgpack]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[msgpack]=""

# --- 16. Rdkafka -------------------------------------------------------------
PECL_DIRNAME[rdkafka]="php-rdkafka"
PECL_GITURL[rdkafka]="https://github.com/arnaud-lb/php-rdkafka.git"
PECL_GITREF[rdkafka]="6.0.5"
PECL_PKGNAME[rdkafka]="rdkafka"
PECL_DESC[rdkafka]="Apache Kafka client (librdkafka)"
PECL_EXTNAME[rdkafka]="rdkafka"
PECL_ZEND[rdkafka]="no"
PECL_DEPS[rdkafka]="php${PHP_VER_SHORT}-custom librdkafka1"
PECL_CONFIGURE[rdkafka]=""

# --- 17. UUID ----------------------------------------------------------------
PECL_DIRNAME[uuid]="php-uuid"
PECL_GITURL[uuid]="https://github.com/php/pecl-networking-uuid.git"
PECL_GITREF[uuid]="1.3.0"
PECL_PKGNAME[uuid]="uuid"
PECL_DESC[uuid]="UUID generation (libuuid)"
PECL_EXTNAME[uuid]="uuid"
PECL_ZEND[uuid]="no"
PECL_DEPS[uuid]="php${PHP_VER_SHORT}-custom libuuid1"
PECL_CONFIGURE[uuid]=""

# --- 18. Zstd ----------------------------------------------------------------
PECL_DIRNAME[zstd]="php-zstd"
PECL_GITURL[zstd]="https://github.com/kjdev/php-ext-zstd.git"
PECL_GITREF[zstd]="0.15.2"
PECL_PKGNAME[zstd]="zstd"
PECL_DESC[zstd]="Zstandard compression"
PECL_EXTNAME[zstd]="zstd"
PECL_ZEND[zstd]="no"
PECL_DEPS[zstd]="php${PHP_VER_SHORT}-custom libzstd1"
PECL_CONFIGURE[zstd]=""

# --- 19. Lz4 -----------------------------------------------------------------
PECL_DIRNAME[lz4]="php-lz4"
PECL_GITURL[lz4]="https://github.com/kjdev/php-ext-lz4.git"
PECL_GITREF[lz4]="0.6.0"
PECL_PKGNAME[lz4]="lz4"
PECL_DESC[lz4]="LZ4 compression"
PECL_EXTNAME[lz4]="lz4"
PECL_ZEND[lz4]="no"
PECL_DEPS[lz4]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[lz4]=""

# --- 20. Ast -----------------------------------------------------------------
PECL_DIRNAME[ast]="php-ast"
PECL_GITURL[ast]="https://github.com/nikic/php-ast.git"
PECL_GITREF[ast]="v1.1.3"
PECL_PKGNAME[ast]="ast"
PECL_DESC[ast]="Abstract syntax tree"
PECL_EXTNAME[ast]="ast"
PECL_ZEND[ast]="no"
PECL_DEPS[ast]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[ast]=""

# --- 21. Ds ------------------------------------------------------------------
PECL_DIRNAME[ds]="php-ds"
PECL_GITURL[ds]="https://github.com/php-ds/ext-ds.git"
PECL_GITREF[ds]="v1.6.0"
PECL_PKGNAME[ds]="ds"
PECL_DESC[ds]="Data Structures"
PECL_EXTNAME[ds]="ds"
PECL_ZEND[ds]="no"
PECL_DEPS[ds]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[ds]=""

# --- 22. Decimal -------------------------------------------------------------
PECL_DIRNAME[decimal]="php-decimal"
PECL_GITURL[decimal]="https://github.com/php-decimal/ext-decimal.git"
PECL_GITREF[decimal]="v1.5.0"
PECL_PKGNAME[decimal]="decimal"
PECL_DESC[decimal]="Arbitrary precision decimal (libmpdec)"
PECL_EXTNAME[decimal]="decimal"
PECL_ZEND[decimal]="no"
PECL_DEPS[decimal]="php${PHP_VER_SHORT}-custom libmpdec3"
PECL_CONFIGURE[decimal]=""

# --- 23. Excimer -------------------------------------------------------------
PECL_DIRNAME[excimer]="php-excimer"
PECL_GITURL[excimer]="https://github.com/wikimedia/php-excimer.git"
PECL_GITREF[excimer]="1.2.5"
PECL_PKGNAME[excimer]="excimer"
PECL_DESC[excimer]="Interrupting timer (profiling)"
PECL_EXTNAME[excimer]="excimer"
PECL_ZEND[excimer]="no"
PECL_DEPS[excimer]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[excimer]=""

# --- 24. Gearman -------------------------------------------------------------
PECL_DIRNAME[gearman]="php-gearman"
PECL_GITURL[gearman]="https://github.com/php/pecl-job-queue-gearman.git"
PECL_GITREF[gearman]="v2.1.4"
PECL_PKGNAME[gearman]="gearman"
PECL_DESC[gearman]="Gearman job server client"
PECL_EXTNAME[gearman]="gearman"
PECL_ZEND[gearman]="no"
PECL_DEPS[gearman]="php${PHP_VER_SHORT}-custom libgearman8"
PECL_CONFIGURE[gearman]=""

# --- 25. GeoIP ---------------------------------------------------------------
PECL_DIRNAME[geoip]="php-geoip"
PECL_GITURL[geoip]="https://github.com/php/pecl-networking-geoip.git"
PECL_GITREF[geoip]="1.1.1"
PECL_PKGNAME[geoip]="geoip"
PECL_DESC[geoip]="GeoIP lookup (legacy)"
PECL_EXTNAME[geoip]="geoip"
PECL_ZEND[geoip]="no"
PECL_DEPS[geoip]="php${PHP_VER_SHORT}-custom libgeoip1"
PECL_CONFIGURE[geoip]=""

# --- 26. MaxMindDB -----------------------------------------------------------
PECL_DIRNAME[maxminddb]="php-maxminddb"
PECL_GITURL[maxminddb]="https://github.com/maxmind/MaxMind-DB-Reader-php.git"
PECL_GITREF[maxminddb]="v1.13.1"
PECL_PKGNAME[maxminddb]="maxminddb"
PECL_DESC[maxminddb]="MaxMind DB Reader (libmaxminddb)"
PECL_EXTNAME[maxminddb]="maxminddb"
PECL_ZEND[maxminddb]="no"
PECL_DEPS[maxminddb]="php${PHP_VER_SHORT}-custom libmaxminddb0"
PECL_CONFIGURE[maxminddb]=""
PECL_SUBDIR[maxminddb]="ext"

# --- 27. Mcrypt --------------------------------------------------------------
PECL_DIRNAME[mcrypt]="php-mcrypt"
PECL_GITURL[mcrypt]="https://github.com/php/pecl-encryption-mcrypt.git"
PECL_GITREF[mcrypt]="1.0.9"
PECL_PKGNAME[mcrypt]="mcrypt"
PECL_DESC[mcrypt]="MCrypt encryption (libmcrypt)"
PECL_EXTNAME[mcrypt]="mcrypt"
PECL_ZEND[mcrypt]="no"
PECL_DEPS[mcrypt]="php${PHP_VER_SHORT}-custom libmcrypt4"
PECL_CONFIGURE[mcrypt]=""

# --- 28. Inotify -------------------------------------------------------------
PECL_DIRNAME[inotify]="php-inotify"
PECL_GITURL[inotify]="https://github.com/php/pecl-file_formats-inotify.git"
PECL_GITREF[inotify]="3.0.1"
PECL_PKGNAME[inotify]="inotify"
PECL_DESC[inotify]="File system notifications (inotify)"
PECL_EXTNAME[inotify]="inotify"
PECL_ZEND[inotify]="no"
PECL_DEPS[inotify]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[inotify]=""

# --- 30. Gnupg ---------------------------------------------------------------
PECL_DIRNAME[gnupg]="php-gnupg"
PECL_GITURL[gnupg]="https://github.com/php/pecl-encryption-gnupg.git"
PECL_GITREF[gnupg]="1.5.4"
PECL_PKGNAME[gnupg]="gnupg"
PECL_DESC[gnupg]="GnuPG encryption/signatures"
PECL_EXTNAME[gnupg]="gnupg"
PECL_ZEND[gnupg]="no"
PECL_DEPS[gnupg]="php${PHP_VER_SHORT}-custom libgpgme11"
PECL_CONFIGURE[gnupg]=""

# --- 31. Mailparse -----------------------------------------------------------
PECL_DIRNAME[mailparse]="php-mailparse"
PECL_GITURL[mailparse]="https://github.com/php/pecl-mail-mailparse.git"
PECL_GITREF[mailparse]="3.1.9"
PECL_PKGNAME[mailparse]="mailparse"
PECL_DESC[mailparse]="Email parsing"
PECL_EXTNAME[mailparse]="mailparse"
PECL_ZEND[mailparse]="no"
PECL_DEPS[mailparse]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[mailparse]=""

# --- 32. OAuth ---------------------------------------------------------------
PECL_DIRNAME[oauth]="php-oauth"
PECL_GITURL[oauth]="https://github.com/php/pecl-authentication-oauth.git"
PECL_GITREF[oauth]="2.0.10"
PECL_PKGNAME[oauth]="oauth"
PECL_DESC[oauth]="OAuth 1.0 consumer"
PECL_EXTNAME[oauth]="oauth"
PECL_ZEND[oauth]="no"
PECL_DEPS[oauth]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[oauth]=""

# --- 33. PCov ----------------------------------------------------------------
PECL_DIRNAME[pcov]="php-pcov"
PECL_GITURL[pcov]="https://github.com/krakjoe/pcov.git"
PECL_GITREF[pcov]="v1.0.12"
PECL_PKGNAME[pcov]="pcov"
PECL_DESC[pcov]="Code coverage driver"
PECL_EXTNAME[pcov]="pcov"
PECL_ZEND[pcov]="no"
PECL_DEPS[pcov]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[pcov]=""

# --- 34. PSR -----------------------------------------------------------------
PECL_DIRNAME[psr]="php-psr"
PECL_GITURL[psr]="https://github.com/jbboehr/php-psr.git"
PECL_GITREF[psr]="v1.2.0"
PECL_PKGNAME[psr]="psr"
PECL_DESC[psr]="PSR-3/7/17/18 interfaces"
PECL_EXTNAME[psr]="psr"
PECL_ZEND[psr]="no"
PECL_DEPS[psr]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[psr]=""

# --- 35. Solr ----------------------------------------------------------------
PECL_DIRNAME[solr]="php-solr"
PECL_GITURL[solr]="https://github.com/php/pecl-search_engine-solr.git"
PECL_GITREF[solr]="2.9.1"
PECL_PKGNAME[solr]="solr"
PECL_DESC[solr]="Apache Solr client"
PECL_EXTNAME[solr]="solr"
PECL_ZEND[solr]="no"
PECL_DEPS[solr]="php${PHP_VER_SHORT}-custom libxml2"
PECL_CONFIGURE[solr]=""

# --- 36. Stomp ---------------------------------------------------------------
PECL_DIRNAME[stomp]="php-stomp"
PECL_GITURL[stomp]="https://github.com/php/pecl-protocols-stomp.git"
PECL_GITREF[stomp]="2.0.3"
PECL_PKGNAME[stomp]="stomp"
PECL_DESC[stomp]="STOMP protocol client"
PECL_EXTNAME[stomp]="stomp"
PECL_ZEND[stomp]="no"
PECL_DEPS[stomp]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[stomp]=""

# --- 37. Uploadprogress ------------------------------------------------------
PECL_DIRNAME[uploadprogress]="php-uploadprogress"
PECL_GITURL[uploadprogress]="https://github.com/php/pecl-file_formats-uploadprogress.git"
PECL_GITREF[uploadprogress]="2.0.2"
PECL_PKGNAME[uploadprogress]="uploadprogress"
PECL_DESC[uploadprogress]="File upload progress tracking"
PECL_EXTNAME[uploadprogress]="uploadprogress"
PECL_ZEND[uploadprogress]="no"
PECL_DEPS[uploadprogress]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[uploadprogress]=""

# --- 38. Vips ----------------------------------------------------------------
PECL_DIRNAME[vips]="php-vips"
PECL_GITURL[vips]="https://github.com/php-vips/php-vips.git"
PECL_GITREF[vips]="1.0.13"
PECL_PKGNAME[vips]="vips"
PECL_DESC[vips]="Image processing (libvips)"
PECL_EXTNAME[vips]="vips"
PECL_ZEND[vips]="no"
PECL_DEPS[vips]="php${PHP_VER_SHORT}-custom libvips42"
PECL_CONFIGURE[vips]=""

# --- 39. Xhprof --------------------------------------------------------------
PECL_DIRNAME[xhprof]="xhprof"
PECL_GITURL[xhprof]="https://github.com/longxinH/xhprof.git"
PECL_GITREF[xhprof]="2.3.10"
PECL_PKGNAME[xhprof]="xhprof"
PECL_DESC[xhprof]="Hierarchical profiler"
PECL_EXTNAME[xhprof]="xhprof"
PECL_ZEND[xhprof]="no"
PECL_DEPS[xhprof]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[xhprof]=""
PECL_SUBDIR[xhprof]="extension"

# --- 40. Xlswriter -----------------------------------------------------------
PECL_DIRNAME[xlswriter]="php-xlswriter"
PECL_GITURL[xlswriter]="https://github.com/viest/php-ext-xlswriter.git"
PECL_GITREF[xlswriter]="1.5.8"
PECL_PKGNAME[xlswriter]="xlswriter"
PECL_DESC[xlswriter]="Excel (XLSX) writer/reader"
PECL_EXTNAME[xlswriter]="xlswriter"
PECL_ZEND[xlswriter]="no"
PECL_DEPS[xlswriter]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[xlswriter]=""
PECL_SUBMODULES[xlswriter]="yes"

# --- 41. XMLRPC --------------------------------------------------------------
PECL_DIRNAME[xmlrpc]="php-xmlrpc"
PECL_GITURL[xmlrpc]="https://github.com/php/pecl-networking-xmlrpc.git"
PECL_GITREF[xmlrpc]="1.0.0RC3"
PECL_PKGNAME[xmlrpc]="xmlrpc"
PECL_DESC[xmlrpc]="XML-RPC (removed from core in 8.0)"
PECL_EXTNAME[xmlrpc]="xmlrpc"
PECL_ZEND[xmlrpc]="no"
PECL_DEPS[xmlrpc]="php${PHP_VER_SHORT}-custom libxml2"
PECL_CONFIGURE[xmlrpc]=""

# --- 42. Yac -----------------------------------------------------------------
PECL_DIRNAME[yac]="php-yac"
PECL_GITURL[yac]="https://github.com/laruence/yac.git"
PECL_GITREF[yac]="2.3.1"
PECL_PKGNAME[yac]="yac"
PECL_DESC[yac]="Lockless user data cache"
PECL_EXTNAME[yac]="yac"
PECL_ZEND[yac]="no"
PECL_DEPS[yac]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[yac]=""

# --- 43. ZMQ -----------------------------------------------------------------
PECL_DIRNAME[zmq]="php-zmq"
PECL_GITURL[zmq]="https://github.com/zeromq/php-zmq.git"
PECL_GITREF[zmq]="master"
PECL_PKGNAME[zmq]="zmq"
PECL_DESC[zmq]="ZeroMQ messaging"
PECL_EXTNAME[zmq]="zmq"
PECL_ZEND[zmq]="no"
PECL_DEPS[zmq]="php${PHP_VER_SHORT}-custom libzmq5"
PECL_CONFIGURE[zmq]=""

# --- 44. OpenTelemetry -------------------------------------------------------
PECL_DIRNAME[opentelemetry]="php-opentelemetry"
PECL_GITURL[opentelemetry]="https://github.com/open-telemetry/opentelemetry-php-instrumentation.git"
PECL_GITREF[opentelemetry]="1.2.1"
PECL_PKGNAME[opentelemetry]="opentelemetry"
PECL_DESC[opentelemetry]="OpenTelemetry instrumentation"
PECL_EXTNAME[opentelemetry]="opentelemetry"
PECL_ZEND[opentelemetry]="no"
PECL_DEPS[opentelemetry]="php${PHP_VER_SHORT}-custom"
PECL_CONFIGURE[opentelemetry]=""
PECL_SUBDIR[opentelemetry]="ext"

# --- 45. IMAP ----------------------------------------------------------------
PECL_DIRNAME[imap]="php-imap"
PECL_GITURL[imap]="https://github.com/php/pecl-mail-imap.git"
PECL_GITREF[imap]="1.0.3"
PECL_PKGNAME[imap]="imap"
PECL_DESC[imap]="IMAP client (libc-client)"
PECL_EXTNAME[imap]="imap"
PECL_ZEND[imap]="no"
PECL_DEPS[imap]="php${PHP_VER_SHORT}-custom libc-client2007e"
PECL_CONFIGURE[imap]="--with-kerberos --with-imap-ssl"

# --- 46. SNMP ----------------------------------------------------------------
PECL_DIRNAME[snmp]="snmp"
PECL_GITURL[snmp]="built-in"
PECL_GITREF[snmp]="built-in"
PECL_PKGNAME[snmp]="snmp"
PECL_DESC[snmp]="SNMP (shared extension)"
PECL_EXTNAME[snmp]="snmp"
PECL_ZEND[snmp]="no"
PECL_DEPS[snmp]="php${PHP_VER_SHORT}-custom libsnmp40"
PECL_CONFIGURE[snmp]=""

# --- 47. Tidy ----------------------------------------------------------------
PECL_DIRNAME[tidy]="tidy"
PECL_GITURL[tidy]="built-in"
PECL_GITREF[tidy]="built-in"
PECL_PKGNAME[tidy]="tidy"
PECL_DESC[tidy]="Tidy HTML clean/repair (shared extension)"
PECL_EXTNAME[tidy]="tidy"
PECL_ZEND[tidy]="no"
PECL_DEPS[tidy]="php${PHP_VER_SHORT}-custom libtidy5deb1"
PECL_CONFIGURE[tidy]=""

PECL_EXTENSIONS=(
  opcache
  apcu
  redis
  imagick
  memcached
  mongodb
  amqp
  grpc
  yaml
  ssh2
  swoole
  xdebug
  protobuf
  igbinary
  msgpack
  rdkafka
  uuid
  zstd
  lz4
  ast
  ds
  decimal
  excimer
  gearman
  geoip
  maxminddb
  mcrypt
  inotify
  gnupg
  mailparse
  oauth
  pcov
  psr
  solr
  stomp
  uploadprogress
  vips
  xhprof
  xlswriter
  xmlrpc
  yac
  zmq
  opentelemetry
  imap
  snmp
  tidy
)

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
die()  { log "FEHLER: $*"; exit 1; }

require_root() {
  [ "$EUID" -eq 0 ] || die "Bitte als root ausfuehren."
}

resolve_staged_php_tool() {
  local tool="$1"
  local suffixed="$STAGE_PHP$PHP_PREFIX/bin/${tool}${PHP_VER_SHORT}"
  local plain="$STAGE_PHP$PHP_PREFIX/bin/${tool}"

  if [ -x "$suffixed" ]; then
    printf '%s' "$suffixed"
    return 0
  fi
  if [ -x "$plain" ]; then
    printf '%s' "$plain"
    return 0
  fi

  return 1
}

usage() {
  cat <<EOF
Verwendung:
  setup_php.sh [--screen] <Befehl>

Optionen:
  --screen         Skript in einer GNU Screen Session ausfuehren (optional)

Befehle:
  package          – Quellen laden, bauen, .deb-Pakete erstellen (KEIN install)
  install          – Backup + dpkg -i aller erzeugten .deb-Pakete
  backup           – Nur Backup erstellen
  restore          – Letztes Backup einspielen
  restore /root/php-backup/<timestamp>
  status           – Zustand + installierte Pakete anzeigen
  list-backups     – Verfuegbare Backups auflisten
  list-extensions  – PECL-Extensions auflisten
  check-config     – php -m + php-fpm -t ausfuehren
  uninstall        – Alle Custom-Pakete via dpkg -r entfernen
  verify           – Modul-Verifikation (nach Installation)

Deinstallation manuell:
  dpkg -r php${PHP_VER_SHORT}-redis php${PHP_VER_SHORT}-imagick ... php${PHP_VER_SHORT}-fpm-custom php${PHP_VER_SHORT}-custom

Modul aktivieren (Beispiel):
  In /etc/php/${PHP_VER_SHORT}/fpm/php.ini oder /etc/php/${PHP_VER_SHORT}/mods-available/redis.ini:
    extension=redis.so
  Fuer zend_extensions (opcache, xdebug):
    zend_extension=opcache.so
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

  systemctl stop "php${PHP_VER_SHORT}-fpm" 2>/dev/null || true

  [ -d "/etc/php/${PHP_VER_SHORT}" ] && cp -a "/etc/php/${PHP_VER_SHORT}" "$backup_dir/etc_php"
  [ -f "/usr/sbin/php-fpm${PHP_VER_SHORT}" ] && cp -a "/usr/sbin/php-fpm${PHP_VER_SHORT}" "$backup_dir/usr_sbin_phpfpm"
  [ -d "/usr/${PHP_LIBDIR}" ] && cp -a "/usr/${PHP_LIBDIR}" "$backup_dir/usr_lib_php"
  [ -f "/lib/systemd/system/php${PHP_VER_SHORT}-fpm.service" ] && cp -a "/lib/systemd/system/php${PHP_VER_SHORT}-fpm.service" "$backup_dir/phpfpm.service"

  dpkg -l 2>/dev/null | awk '/^ii/ && /php/ {print $2}' > "$backup_dir/packages.txt" || true

  if [ -f "/usr/bin/php${PHP_VER_SHORT}" ]; then
    "/usr/bin/php${PHP_VER_SHORT}" -v > "$backup_dir/php-version.txt" 2>&1 || true
    "/usr/bin/php${PHP_VER_SHORT}" -m > "$backup_dir/php-modules.txt" 2>&1 || true
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
    build-essential make m4 pkg-config autoconf automake libtool bison re2c cmake \
    libssl-dev \
    libpcre2-dev \
    zlib1g-dev \
    libbz2-dev \
    libzip-dev \
    libcurl4-openssl-dev \
    libxml2-dev \
    libxslt1-dev \
    libgd-dev libfreetype-dev libjpeg-dev libpng-dev libwebp-dev libxpm-dev \
    libgmp-dev \
    libldap2-dev \
    libpq-dev \
    libmariadb-dev \
    libsqlite3-dev \
    libreadline-dev \
    libedit-dev \
    libtidy-dev \
    libenchant-2-dev \
    libsodium-dev \
    libargon2-dev \
    libffi-dev \
    libicu-dev \
    libonig-dev \
    libsasl2-dev \
    libmagic-dev \
    libgpgme-dev \
    libmagickwand-dev \
    libmemcached-dev \
    librabbitmq-dev \
    libyaml-dev \
    libssh2-1-dev \
    librdkafka-dev \
    libuuid1 uuid-dev \
    libzstd-dev \
    libmaxminddb-dev \
    libgeoip-dev \
    libmcrypt-dev libmcrypt4 \
    libc-client2007e-dev \
    libsnmp-dev \
    libvips-dev \
    libkrb5-dev \
    libgearman-dev \
    libmpdec-dev \
    libsystemd-dev \
    libre2-dev \
    libutf8proc-dev \
    libc-ares-dev \
    libgoogle-perftools-dev \
    libbz2-dev \
    liblz4-dev \
    libzmq3-dev \
    libabsl-dev \
    libxlsxwriter-dev \
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
# Quellen herunterladen
# ------------------------------------------------------------------------------
prepare_sources() {
  mkdir -p "$BUILD_ROOT"
  cd "$BUILD_ROOT"
  rm -rf "php-${PHP_VERSION}"

  local php_tar="$BUILD_ROOT/php-${PHP_VERSION}.tar.gz"

  if [ ! -f "$php_tar" ]; then
    log "Lade PHP $PHP_VERSION Tarball"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar \
      "$PHP_TARBALL_URL" -o "$php_tar" \
      || die "Download PHP Tarball fehlgeschlagen"
  else
    log "PHP Tarball bereits vorhanden: $php_tar"
  fi

  tar xzf "$php_tar"
  [ -d "$BUILD_ROOT/php-${PHP_VERSION}" ] \
    || die "Tarball entpackt kein Verzeichnis php-${PHP_VERSION}"
  log "Quellen: $BUILD_ROOT/php-${PHP_VERSION}"
}

# ------------------------------------------------------------------------------
# PECL-Extension-Quellen herunterladen
# ------------------------------------------------------------------------------
download_pecl_sources() {
  local pecl_dir="$BUILD_ROOT/php-pecl"
  mkdir -p "$pecl_dir"

  for ext in "${PECL_EXTENSIONS[@]}"; do
    local url="${PECL_GITURL[$ext]:-}"
    local ref="${PECL_GITREF[$ext]:-master}"
    local dir="${PECL_DIRNAME[$ext]:-$ext}"
    local pkg_name="${PECL_PKGNAME[$ext]:-$ext}"
    local target="$pecl_dir/$dir"

    if [ "$url" = "built-in" ]; then
      continue
    fi

    local subdir="${PECL_SUBDIR[$ext]:-}"

    if [ "$subdir" = "pecl-tarball" ]; then
      if [ -d "$target" ]; then
        log "  [OK] $dir bereits vorhanden"
        continue
      fi
      local pecl_ref="$ref"
      if [[ "$pecl_ref" =~ ^v ]]; then
        pecl_ref="${pecl_ref#v}"
      fi
      local pecl_tgz_url="https://pecl.php.net/get/${pkg_name}-${pecl_ref}.tgz"
      local pecl_tgz_file="/tmp/pecl-${pkg_name}-${pecl_ref}.tgz"
      log "Lade $dir via PECL-Tarball ($pecl_tgz_url)"
      mkdir -p "$target"
      if curl -fL --retry 2 --retry-delay 1 --connect-timeout 15 --progress-bar \
        "$pecl_tgz_url" -o "$pecl_tgz_file" \
        && tar xzf "$pecl_tgz_file" -C "$target" --strip-components=1; then
        rm -f "$pecl_tgz_file" 2>/dev/null || true
        log "  [OK] $dir via PECL-Tarball geladen"
      else
        rm -rf "$target" "$pecl_tgz_file" 2>/dev/null || true
        log "  [WARN] $dir konnte nicht via PECL-Tarball geladen werden – ueberspringe $ext"
      fi
      continue
    fi

    if [ -z "$url" ]; then
      log "  [WARN] $ext: keine PECL_GITURL gesetzt – ueberspringe"
      continue
    fi

    if [ -d "$target" ]; then
      if [ "${PECL_SUBMODULES[$ext]:-}" = "yes" ] && [ -d "$target/.git" ]; then
        local _sm_check="$target/library/libxlsxwriter/third_party/md5/md5.c"
        if [ ! -f "$_sm_check" ] || [ ! -d "$target/library/libxlsxwriter/third_party" ]; then
          log "  Initialisiere fehlende Submodules fuer $dir"
          git -C "$target" submodule update --init --recursive --depth 1 2>&1 || {
            log "  [WARN] Submodule-Init fuer $dir fehlgeschlagen – Build evtl. unvollstaendig"
          }
        fi
      fi
      log "  [OK] $dir bereits vorhanden"
      continue
    fi

    log "Lade $dir ($ref)"
    local clone_ok=0
    if [ "$ref" = "master" ]; then
      GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone --depth 1 "$url" "$target" && clone_ok=1
    else
      GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone --depth 1 --branch "$ref" "$url" "$target" && clone_ok=1
      if [ "$clone_ok" -eq 0 ]; then
        local alt_ref=""
        if [[ "$ref" =~ ^v ]]; then
          alt_ref="${ref#v}"
        else
          alt_ref="v$ref"
        fi
        GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone --depth 1 --branch "$alt_ref" "$url" "$target" && clone_ok=1
      fi
      if [ "$clone_ok" -eq 0 ]; then
        GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone --depth 1 "$url" "$target" && clone_ok=1
      fi
    fi

    if [ "$clone_ok" -eq 0 ]; then
      # Fallback: PECL Tarball (z.B. https://pecl.php.net/get/lz4-0.6.0.tgz)
      local pecl_ref="$ref"
      if [[ "$pecl_ref" =~ ^v ]]; then
        pecl_ref="${pecl_ref#v}"
      fi
      local pecl_tgz_url="https://pecl.php.net/get/${pkg_name}-${pecl_ref}.tgz"
      local pecl_tgz_file="/tmp/pecl-${pkg_name}-${pecl_ref}.tgz"

      log "  [WARN] Git-Clone fehlgeschlagen, versuche PECL-Tarball: $pecl_tgz_url"
      rm -rf "$target"
      mkdir -p "$target"
      if curl -fL --retry 2 --retry-delay 1 --connect-timeout 15 --progress-bar \
        "$pecl_tgz_url" -o "$pecl_tgz_file" \
        && tar xzf "$pecl_tgz_file" -C "$target" --strip-components=1; then
        clone_ok=1
      fi
      rm -f "$pecl_tgz_file" 2>/dev/null || true
    fi

    if [ "$clone_ok" -eq 0 ]; then
      log "  [WARN] $dir konnte weder via Git noch via PECL-Tarball geladen werden – ueberspringe $ext"
      rm -rf "$target"
      continue
    fi

    if [ "${PECL_SUBMODULES[$ext]:-}" = "yes" ] && [ -d "$target/.git" ]; then
      log "  Initialisiere Submodules fuer $dir"
      git -C "$target" submodule update --init --recursive --depth 1 2>&1 || {
        log "  [WARN] Submodule-Init fuer $dir fehlgeschlagen – Build evtl. unvollstaendig"
      }
    fi

    log "  [OK] $dir geklont"
  done
}

# ------------------------------------------------------------------------------
# PHP configure + make
# ------------------------------------------------------------------------------
build_php() {
  cd "$BUILD_ROOT/php-${PHP_VERSION}"
  log "Konfiguriere PHP $PHP_VERSION"

  local CONF_ARGS=""
  CONF_ARGS="$CONF_ARGS --prefix=$PHP_PREFIX"
  CONF_ARGS="$CONF_ARGS --program-suffix=${PHP_VER_SHORT}"
  CONF_ARGS="$CONF_ARGS --exec-prefix=$PHP_PREFIX"
  CONF_ARGS="$CONF_ARGS --with-config-file-path=$PHP_SYSCONFDIR"
  CONF_ARGS="$CONF_ARGS --with-config-file-scan-dir=$PHP_SYSCONFDIR/mods-available"
  CONF_ARGS="$CONF_ARGS --enable-phpdbg"
  CONF_ARGS="$CONF_ARGS --enable-fpm"
  CONF_ARGS="$CONF_ARGS --with-fpm-user=$PHP_USER"
  CONF_ARGS="$CONF_ARGS --with-fpm-group=$PHP_GROUP"
  CONF_ARGS="$CONF_ARGS --with-fpm-systemd"
  CONF_ARGS="$CONF_ARGS --enable-cli"
  CONF_ARGS="$CONF_ARGS --enable-cgi"
  CONF_ARGS="$CONF_ARGS --disable-rpath"
  CONF_ARGS="$CONF_ARGS --enable-shared"

  CONF_ARGS="$CONF_ARGS --enable-bcmath"
  CONF_ARGS="$CONF_ARGS --with-curl"
  CONF_ARGS="$CONF_ARGS --with-openssl"
  CONF_ARGS="$CONF_ARGS --with-openssl-dir=/usr"
  CONF_ARGS="$CONF_ARGS --with-zlib"
  CONF_ARGS="$CONF_ARGS --with-zlib-dir=/usr"
  CONF_ARGS="$CONF_ARGS --with-bz2"
  CONF_ARGS="$CONF_ARGS --with-zip"
  CONF_ARGS="$CONF_ARGS --enable-gd"
  CONF_ARGS="$CONF_ARGS --with-freetype"
  CONF_ARGS="$CONF_ARGS --with-jpeg"
  CONF_ARGS="$CONF_ARGS --with-webp"
  CONF_ARGS="$CONF_ARGS --with-xpm"
  CONF_ARGS="$CONF_ARGS --enable-gd-jis-conv"
  CONF_ARGS="$CONF_ARGS --with-gettext"
  CONF_ARGS="$CONF_ARGS --with-gmp"
  CONF_ARGS="$CONF_ARGS --with-mhash"
  CONF_ARGS="$CONF_ARGS --enable-intl"
  CONF_ARGS="$CONF_ARGS --enable-mbstring"
  CONF_ARGS="$CONF_ARGS --with-onig"
  CONF_ARGS="$CONF_ARGS --with-mysqli=mysqlnd"
  CONF_ARGS="$CONF_ARGS --with-pdo-mysql=mysqlnd"
  CONF_ARGS="$CONF_ARGS --with-pdo-pgsql=/usr"
  CONF_ARGS="$CONF_ARGS --with-pdo-sqlite=/usr"
  CONF_ARGS="$CONF_ARGS --with-pgsql=/usr"
  CONF_ARGS="$CONF_ARGS --enable-soap"
  CONF_ARGS="$CONF_ARGS --enable-sockets"
  CONF_ARGS="$CONF_ARGS --with-sodium"
  CONF_ARGS="$CONF_ARGS --with-sqlite3=/usr"
  CONF_ARGS="$CONF_ARGS --with-tidy"
  CONF_ARGS="$CONF_ARGS --with-xsl"
  CONF_ARGS="$CONF_ARGS --enable-libxml"
  CONF_ARGS="$CONF_ARGS --with-libxml"
  CONF_ARGS="$CONF_ARGS --enable-simplexml"
  CONF_ARGS="$CONF_ARGS --enable-xml"
  CONF_ARGS="$CONF_ARGS --enable-xmlreader"
  CONF_ARGS="$CONF_ARGS --enable-xmlwriter"
  CONF_ARGS="$CONF_ARGS --with-pear"
  CONF_ARGS="$CONF_ARGS --enable-fileinfo"
  CONF_ARGS="$CONF_ARGS --enable-filter"
  CONF_ARGS="$CONF_ARGS --enable-ftp"
  CONF_ARGS="$CONF_ARGS --with-readline"
  CONF_ARGS="$CONF_ARGS --with-libedit"
  CONF_ARGS="$CONF_ARGS --enable-session"
  CONF_ARGS="$CONF_ARGS --enable-shmop"
  CONF_ARGS="$CONF_ARGS --enable-sysvmsg"
  CONF_ARGS="$CONF_ARGS --enable-sysvsem"
  CONF_ARGS="$CONF_ARGS --enable-sysvshm"
  CONF_ARGS="$CONF_ARGS --enable-tokenizer"
  CONF_ARGS="$CONF_ARGS --enable-pcntl"
  CONF_ARGS="$CONF_ARGS --with-enchant"
  CONF_ARGS="$CONF_ARGS --with-ffi"
  CONF_ARGS="$CONF_ARGS --enable-opcache"
  CONF_ARGS="$CONF_ARGS --with-password-argon2"
  CONF_ARGS="$CONF_ARGS --enable-phar"
  CONF_ARGS="$CONF_ARGS --enable-posix"
  CONF_ARGS="$CONF_ARGS --with-ldap"
  CONF_ARGS="$CONF_ARGS --with-ldap-sasl"
  CONF_ARGS="$CONF_ARGS --with-kerberos"
  CONF_ARGS="$CONF_ARGS --enable-exif"
  CONF_ARGS="$CONF_ARGS --enable-dba"
  CONF_ARGS="$CONF_ARGS --with-snmp=shared"
  CONF_ARGS="$CONF_ARGS --enable-ctype"
  CONF_ARGS="$CONF_ARGS --enable-dom"
  CONF_ARGS="$CONF_ARGS --with-imap=shared"
  CONF_ARGS="$CONF_ARGS --with-imap-ssl"
  CONF_ARGS="$CONF_ARGS --enable-calendar"
  local -a conf_args_array=()
  read -r -a conf_args_array <<< "$CONF_ARGS"

  CC_OPT="-fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2"

  log "Fuehre ./configure aus"
  set +e
  ./configure \
    --with-cc-opt="$CC_OPT" \
    "${conf_args_array[@]}" \
    2>&1 | tee -a "$LOG_FILE"
  local conf_rc=${PIPESTATUS[0]}
  set -e
  [ "$conf_rc" -eq 0 ] || die "./configure fehlgeschlagen (Exit $conf_rc)"

  log "Kompiliere PHP (make -j$(nproc))"
  set +e
  make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
  local build_rc=${PIPESTATUS[0]}
  set -e
  [ "$build_rc" -eq 0 ] || die "PHP make fehlgeschlagen (Exit $build_rc)"

  log "PHP Build fertig"
}

# ------------------------------------------------------------------------------
# Staging: make install
# ------------------------------------------------------------------------------
stage_install() {
  cd "$BUILD_ROOT/php-${PHP_VERSION}"

  log "Installiere PHP ins Staging: $STAGE_PHP"
  rm -rf "$STAGE_PHP"
  mkdir -p "$STAGE_PHP"

  set +e
  make INSTALL_ROOT="$STAGE_PHP" install 2>&1 | tee -a "$LOG_FILE"
  local inst_rc=${PIPESTATUS[0]}
  set -e
  [ "$inst_rc" -eq 0 ] || die "make install fehlgeschlagen (Exit $inst_rc)"

  rm -rf "${STAGE_PHP}${PHP_SYSCONFDIR}"
  log "/etc/php aus Staging entfernt"

  log "Staging-Inhalt:"
  find "$STAGE_PHP/usr" -type f \( -name "php*" -o -name "*.so" \) | sort | head -50 | tee -a "$LOG_FILE" || true
}

# ------------------------------------------------------------------------------
# PECL-Extensions bauen (phpize + make)
# ------------------------------------------------------------------------------
build_pecl_extensions() {
  local php_config
  local phpize
  php_config="$(resolve_staged_php_tool "php-config" || true)"
  phpize="$(resolve_staged_php_tool "phpize" || true)"
  local ext_dir

  [ -x "$php_config" ] || die "php-config nicht gefunden: $php_config"
  [ -x "$phpize" ] || die "phpize nicht gefunden: $phpize"

  local build_link="$PHP_PREFIX/lib/php/build"
  local build_target="$STAGE_PHP$PHP_PREFIX/lib/php/build"
  if [ -d "$build_target" ]; then
    [ -L "$build_link" ] && ! [ -e "$build_link" ] && rm -f "$build_link"
    [ -e "$build_link" ] || ln -s "$build_target" "$build_link"
  fi

  local inc_link="$PHP_PREFIX/include/php"
  local inc_target="$STAGE_PHP$PHP_PREFIX/include/php"
  if [ -d "$inc_target" ]; then
    if [ -L "$inc_link" ]; then
      rm -f "$inc_link"
      ln -s "$inc_target" "$inc_link"
    elif [ -d "$inc_link" ]; then
      cp -af "$inc_target/." "$inc_link/"
    else
      ln -s "$inc_target" "$inc_link"
    fi
  fi
  ext_dir="$($php_config --extension-dir 2>/dev/null || echo "$STAGE_PHP$PHP_EXTENSION_DIR")"

  local pecl_dir="$BUILD_ROOT/php-pecl"
  local src_dir="$BUILD_ROOT/php-${PHP_VERSION}"
  local pecl_log_dir="/tmp/pecl-build-logs"
  rm -rf "$pecl_log_dir"
  mkdir -p "$pecl_log_dir"

  local std_dir="$src_dir/ext/standard"
  [ -d "$std_dir" ] || mkdir -p "$std_dir"

  sed -i '/typedef.*smart_string/d' "$src_dir/Zend/zend_smart_str.h" 2>/dev/null || true
  grep -rl 'typedef.*smart_string' "$src_dir/Zend/" "$src_dir/main/" 2>/dev/null | while read -r _f; do
    sed -i '/typedef.*smart_string/d' "$_f"
  done || true

  cat > "$std_dir/php_smart_string.h" <<'SMART_STRING_SHIM'
#ifndef PHP_SMART_STRING_H
#define PHP_SMART_STRING_H

#include <string.h>
#include <Zend/zend.h>

typedef struct {
    char *c;
    size_t len;
    size_t a;
} smart_string;

#define SMART_STRING_OVERHEAD 128

static zend_always_inline size_t smart_string_chunksz(smart_string *str, size_t len) {
    return str->a ? str->a + (str->a >> 2) : len + SMART_STRING_OVERHEAD;
}

static zend_always_inline void smart_string_alloc(smart_string *str, size_t len, zend_bool pre) {
    if (!pre && str->c && str->len + len < str->a) {
        return;
    }
    str->a = smart_string_chunksz(str, len);
    str->c = pre ? perealloc(str->c, str->a, pre) : erealloc(str->c, str->a);
}

static zend_always_inline void smart_string_extend(smart_string *str, size_t len, zend_bool pre) {
    smart_string_alloc(str, len, pre);
}

static zend_always_inline void smart_string_appendc(smart_string *str, char c) {
    smart_string_alloc(str, 1, 0);
    str->c[str->len++] = c;
}

static zend_always_inline void smart_string_appendl(smart_string *str, const char *buf, size_t len) {
    smart_string_alloc(str, len, 0);
    memcpy(str->c + str->len, buf, len);
    str->len += len;
}

static zend_always_inline void smart_string_append(smart_string *str, const char *buf) {
    smart_string_appendl(str, buf, strlen(buf));
}

static zend_always_inline void smart_string_append_long(smart_string *str, zend_long val) {
    char buf[32];
    size_t len = snprintf(buf, sizeof(buf), ZEND_LONG_FMT, val);
    smart_string_appendl(str, buf, len);
}

static zend_always_inline void smart_string_append_unsigned(smart_string *str, zend_ulong val) {
    char buf[32];
    size_t len = snprintf(buf, sizeof(buf), ZEND_ULONG_FMT, val);
    smart_string_appendl(str, buf, len);
}

#define smart_string_append_int(s, v) smart_string_append_long((s), (v))

static zend_always_inline void smart_string_reset(smart_string *str) {
    if (str->c) {
        str->len = 0;
    }
}

static zend_always_inline void smart_string_free(smart_string *str) {
    if (str->c) {
        efree(str->c);
        str->c = NULL;
    }
    str->len = 0;
    str->a = 0;
}

#define smart_string_0(s) smart_string_appendc((s), '\0')

#endif
SMART_STRING_SHIM
  log "  Shim: php_smart_string.h erzwungen"

  if [ ! -f "$std_dir/php_smart_str.h" ]; then
    cat > "$std_dir/php_smart_str.h" <<'SMART_STR_SHIM'
#ifndef PHP_SMART_STR_H
#define PHP_SMART_STR_H
#include "Zend/zend_smart_str.h"
#endif
SMART_STR_SHIM
    log "  Shim: php_smart_str.h erstellt"
  fi

  if [ ! -f "$std_dir/php_smart_str_public.h" ]; then
    cat > "$std_dir/php_smart_str_public.h" <<'SMART_STR_PUBLIC_SHIM'
#ifndef PHP_SMART_STR_PUBLIC_H
#define PHP_SMART_STR_PUBLIC_H
#include "Zend/zend_smart_str.h"
#endif
SMART_STR_PUBLIC_SHIM
    log "  Shim: php_smart_str_public.h erstellt"
  fi

  if [ ! -f "$std_dir/php_rand.h" ]; then
    cat > "$std_dir/php_rand.h" <<'RAND_SHIM'
#ifndef PHP_RAND_H
#define PHP_RAND_H
#include "ext/random/php_random.h"
#endif
RAND_SHIM
    log "  Shim: php_rand.h erstellt"
  fi

  if [ ! -f "$std_dir/datetime.h" ]; then
    cat > "$std_dir/datetime.h" <<'DATETIME_SHIM'
#ifndef PHP_DATETIME_STANDARD_H
#define PHP_DATETIME_STANDARD_H
#include "ext/date/php_date.h"
#endif
DATETIME_SHIM
    log "  Shim: datetime.h erstellt"
  fi

  for ext in "${PECL_EXTENSIONS[@]}"; do
    local url="${PECL_GITURL[$ext]}"
    local ext_dir_src="${PECL_DIRNAME[$ext]}"
    local conf="${PECL_CONFIGURE[$ext]}"
    local target

    local _pkg_name="${PECL_PKGNAME[$ext]}"
    local _deb_pattern="php${PHP_VER_SHORT}-${_pkg_name}_*_*.deb"
    if [ "${FORCE_REBUILD:-no}" != "yes" ] && [ -d "$PACKAGE_DIR" ] && compgen -G "$PACKAGE_DIR/$_deb_pattern" >/dev/null 2>&1; then
      log "  [OK] $ext – .deb bereits vorhanden, ueberspringe Build"
      continue
    fi

    if [ "$url" = "built-in" ]; then
      local built_in_dir="$src_dir/ext/${ext_dir_src}"

      if [ -d "$built_in_dir" ] && [ -f "$built_in_dir/config.m4" ]; then
        target="$built_in_dir"
      else
        log "  [SKIP] $ext – built-in Quelle nicht gefunden"
        continue
      fi
    else
      target="$pecl_dir/$ext_dir_src"
      local subdir="${PECL_SUBDIR[$ext]:-}"
      if [ -n "$subdir" ] && [ "$subdir" != "pecl-tarball" ]; then
        target="$target/$subdir"
      fi
      if [ ! -d "$target" ]; then
        log "  [SKIP] $ext – Quellen nicht gefunden ($target)"
        continue
      fi
      if [ ! -f "$target/config.m4" ] && [ "${PECL_CMAKE[$ext]:-}" != "yes" ]; then
        log "  [SKIP] $ext – config.m4 nicht gefunden in $target"
        continue
      fi
    fi

    log "Baue PECL: $ext ($ext_dir_src)"

    local src_inc="-I$src_dir"
    local ext_log="$pecl_log_dir/${ext}.log"

    if [ "${PECL_CMAKE[$ext]:-}" = "yes" ]; then
      (
        cd "$target"
        mkdir -p build
        log "  cmake fuer $ext"
        set +e
        cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DPHP_CONFIG="$php_config" \
          -DCMAKE_C_FLAGS="$src_inc" \
          -S . -B build 2>&1 | tee "$ext_log"
        local cmakerc=${PIPESTATUS[0]}
        set -e
        [ "$cmakerc" -eq 0 ] || { log "  [FAIL] cmake fuer $ext fehlgeschlagen (Log: $ext_log)"; exit 0; }

        set +e
        cmake --build build -j"$(nproc)" 2>&1 | tee -a "$ext_log"
        local mkrc=${PIPESTATUS[0]}
        set -e
        [ "$mkrc" -eq 0 ] || { log "  [FAIL] cmake build fuer $ext fehlgeschlagen (Log: $ext_log)"; exit 0; }

        cmake --install build --prefix /usr DESTDIR="$STAGE_PHP" 2>&1 | tee -a "$ext_log"
        log "  [OK] $ext gebaut und installiert (cmake)"
      ) || true
      continue
    fi

    (
      cd "$target"
      log "  phpize fuer $ext"
      PHP_CONFIG="$php_config" "$phpize" --clean 2>/dev/null || true
      "$phpize" --clean 2>/dev/null || true

      set +e
      "$phpize" 2>&1 | tee "$ext_log"
      local phprc=${PIPESTATUS[0]}
      set -e
      [ "$phprc" -eq 0 ] || { log "  [FAIL] phpize fuer $ext fehlgeschlagen (Log: $ext_log)"; exit 0; }

      set +e
      if [ -n "$conf" ]; then
        local -a ext_conf_args=()
        read -r -a ext_conf_args <<< "$conf"
        ./configure --with-php-config="$php_config" EXTRA_CFLAGS="$src_inc" "${ext_conf_args[@]}" 2>&1 | tee -a "$ext_log"
      else
        ./configure --with-php-config="$php_config" EXTRA_CFLAGS="$src_inc" 2>&1 | tee -a "$ext_log"
      fi
      local confrc=${PIPESTATUS[0]}
      set -e
      [ "$confrc" -eq 0 ] || { log "  [FAIL] configure fuer $ext fehlgeschlagen (Log: $ext_log)"; exit 0; }

      set +e
      make -j"$(nproc)" EXTRA_CFLAGS="$src_inc" 2>&1 | tee -a "$ext_log"
      local mkrc=${PIPESTATUS[0]}
      set -e
      [ "$mkrc" -eq 0 ] || { log "  [FAIL] make fuer $ext fehlgeschlagen (Log: $ext_log)"; exit 0; }

      make install INSTALL_ROOT="$STAGE_PHP" 2>&1 | tee -a "$ext_log"
      log "  [OK] $ext gebaut und installiert"
    ) || true
  done

  log "PECL-Extension-Build abgeschlossen"
}

# ------------------------------------------------------------------------------
# Maintainer-Scripts fuer fpm
# ------------------------------------------------------------------------------
create_maintainer_scripts() {
  local postinst="/tmp/php-core-postinst.sh"
  local postrm="/tmp/php-core-postrm.sh"

  cat > "$postinst" <<POSTINST
#!/bin/sh
set -e
update-alternatives --install /usr/bin/php php /usr/bin/php${PHP_VER_SHORT} 85 \
  --slave /usr/bin/phar phar /usr/bin/phar${PHP_VER_SHORT} \
  --slave /usr/bin/phar.phar phar.phar /usr/bin/phar.phar${PHP_VER_SHORT} \
  --slave /usr/bin/php-cgi php-cgi /usr/bin/php-cgi${PHP_VER_SHORT} 2>/dev/null || true
if [ -f /usr/bin/phpdbg${PHP_VER_SHORT} ]; then
  update-alternatives --install /usr/bin/phpdbg phpdbg /usr/bin/phpdbg${PHP_VER_SHORT} 85 2>/dev/null || true
fi
mkdir -p /etc/php/${PHP_VER_SHORT}/fpm/conf.d
mkdir -p /etc/php/${PHP_VER_SHORT}/fpm/pool.d
mkdir -p /etc/php/${PHP_VER_SHORT}/cli/conf.d
mkdir -p /etc/php/${PHP_VER_SHORT}/mods-available
mkdir -p $PHP_MODS_AVAIL

# Copy default php.ini on fresh install
if [ ! -f "/etc/php/${PHP_VER_SHORT}/cli/php.ini" ] && [ -f "/usr/share/php/${PHP_VER_SHORT}/custom-defaults/php.ini" ]; then
  echo "INFO: Keine php.ini gefunden – installiere Production-Defaults"
  cp "/usr/share/php/${PHP_VER_SHORT}/custom-defaults/php.ini" "/etc/php/${PHP_VER_SHORT}/cli/php.ini"
fi
if [ ! -f "/etc/php/${PHP_VER_SHORT}/fpm/php.ini" ] && [ -f "/usr/share/php/${PHP_VER_SHORT}/custom-defaults/php.ini" ]; then
  cp "/usr/share/php/${PHP_VER_SHORT}/custom-defaults/php.ini" "/etc/php/${PHP_VER_SHORT}/fpm/php.ini"
fi

ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
command -v apt-mark >/dev/null 2>&1 && apt-mark hold php${PHP_VER_SHORT}-custom || true
POSTINST
  chmod 755 "$postinst"

  cat > "$postrm" <<POSTRM
#!/bin/sh
set -e
update-alternatives --remove php /usr/bin/php${PHP_VER_SHORT} 2>/dev/null || true
command -v apt-mark >/dev/null 2>&1 && apt-mark unhold php${PHP_VER_SHORT}-custom 2>/dev/null || true
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
POSTRM
  chmod 755 "$postrm"

  local fpm_postinst="/tmp/php-fpm-postinst.sh"
  local fpm_postrm="/tmp/php-fpm-postrm.sh"

  cat > "$fpm_postinst" <<FPMPINST
#!/bin/sh
set -e
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
command -v systemctl >/dev/null 2>&1 && systemctl enable php${PHP_VER_SHORT}-fpm 2>/dev/null || true

# Copy default FPM configs on fresh install
FPM_SHARE="/usr/share/php/${PHP_VER_SHORT}/custom-defaults/fpm"
FPM_ETC="/etc/php/${PHP_VER_SHORT}/fpm"
if [ ! -f "\${FPM_ETC}/php-fpm.conf" ] && [ -d "\$FPM_SHARE" ]; then
  echo "INFO: Keine FPM-Konfiguration gefunden – installiere Defaults"
  cp "\$FPM_SHARE/php-fpm.conf" "\${FPM_ETC}/php-fpm.conf"
  cp "\$FPM_SHARE/pool.d/www.conf" "\${FPM_ETC}/pool.d/www.conf"
fi
FPMPINST
  chmod 755 "$fpm_postinst"

  cat > "$fpm_postrm" <<FPMPOSTRM
#!/bin/sh
set -e
command -v systemctl >/dev/null 2>&1 && systemctl stop php${PHP_VER_SHORT}-fpm 2>/dev/null || true
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
FPMPOSTRM
  chmod 755 "$fpm_postrm"
}

create_ext_maintainer_scripts() {
  local ext_postinst="/tmp/php-ext-postinst.sh"
  local ext_postrm="/tmp/php-ext-postrm.sh"

  cat > "$ext_postinst" <<'EXTPOSTINST'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
EXTPOSTINST
  chmod 755 "$ext_postinst"

  cat > "$ext_postrm" <<'EXTPOSTRM'
#!/bin/sh
set -e
ldconfig
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
EXTPOSTRM
  chmod 755 "$ext_postrm"
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
# .deb-Paket: php8.5-custom (CLI + Common)
# ------------------------------------------------------------------------------
create_core_package() {
  local arch
  arch="$(dpkg --print-architecture)"
  mkdir -p "$PACKAGE_DIR"

  create_maintainer_scripts

  local deb_file="$PACKAGE_DIR/php${PHP_VER_SHORT}-custom_${PHP_VERSION}-1_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  # Copy php.ini reference files
  if [ -f "$BUILD_ROOT/php-${PHP_VERSION}/php.ini-development" ]; then
    mkdir -p "${STAGE_PHP}/usr/share/php/${PHP_VER_SHORT}"
    cp "$BUILD_ROOT/php-${PHP_VERSION}/php.ini-development" "${STAGE_PHP}/usr/share/php/${PHP_VER_SHORT}/php.ini-development"
    cp "$BUILD_ROOT/php-${PHP_VERSION}/php.ini-production" "${STAGE_PHP}/usr/share/php/${PHP_VER_SHORT}/php.ini-production"
  fi

  mkdir -p "${STAGE_PHP}/usr/share/php/${PHP_VER_SHORT}/custom-defaults"

  if [ -f "$BUILD_ROOT/php-${PHP_VERSION}/php.ini-production" ]; then
    cp "$BUILD_ROOT/php-${PHP_VERSION}/php.ini-production" \
      "${STAGE_PHP}/usr/share/php/${PHP_VER_SHORT}/custom-defaults/php.ini"
  fi

  # Create php-enmod / php-dismod helper scripts
  mkdir -p "${STAGE_PHP}/usr/sbin"
  cat > "${STAGE_PHP}/usr/sbin/php${PHP_VER_SHORT}-enmod" <<'ENMOD'
#!/bin/sh
set -e
MODNAME="$1"
VER="PHP_VER_PLACEHOLDER"
MODSAVAIL="/usr/share/php/${VER}/mods-available"
if [ -z "$MODNAME" ]; then
  echo "Usage: php${VER}-enmod <module>" >&2
  exit 1
fi
if [ ! -f "${MODSAVAIL}/${MODNAME}.ini" ]; then
  echo "WARNING: Module ${MODNAME} not found in ${MODSAVAIL}" >&2
  exit 0
fi
for sapi in fpm cli; do
  CONFD="/etc/php/${VER}/${sapi}/conf.d"
  mkdir -p "$CONFD"
  PRIORITY=$(echo "${MODNAME}" | tr '[:upper:]' '[:lower:]' | cksum | cut -d' ' -f1 | tail -c 3)
  ln -sf "${MODSAVAIL}/${MODNAME}.ini" "${CONFD}/$(printf '%02d' $((10#$PRIORITY)))-${MODNAME}.ini" 2>/dev/null || true
done
ENMOD
  sed -i "s/PHP_VER_PLACEHOLDER/${PHP_VER_SHORT}/g" "${STAGE_PHP}/usr/sbin/php${PHP_VER_SHORT}-enmod"
  chmod 755 "${STAGE_PHP}/usr/sbin/php${PHP_VER_SHORT}-enmod"

  cat > "${STAGE_PHP}/usr/sbin/php${PHP_VER_SHORT}-dismod" <<'DISMOD'
#!/bin/sh
set -e
MODNAME="$1"
VER="PHP_VER_PLACEHOLDER"
if [ -z "$MODNAME" ]; then
  echo "Usage: php${VER}-dismod <module>" >&2
  exit 1
fi
for sapi in fpm cli; do
  CONFD="/etc/php/${VER}/${sapi}/conf.d"
  rm -f "${CONFD}/"*"-${MODNAME}.ini" 2>/dev/null || true
done
DISMOD
  sed -i "s/PHP_VER_PLACEHOLDER/${PHP_VER_SHORT}/g" "${STAGE_PHP}/usr/sbin/php${PHP_VER_SHORT}-dismod"
  chmod 755 "${STAGE_PHP}/usr/sbin/php${PHP_VER_SHORT}-dismod"

  # Ensure man pages are included
  mkdir -p "${STAGE_PHP}/usr/share/man/man1"
  for manfile in "${STAGE_PHP}/usr/share/man/man1"/*.1; do
    if [ -f "$manfile" ]; then gzip -f "$manfile" 2>/dev/null || true; fi
  done

  # If no man pages were installed, copy from source
  if [ -z "$(find "${STAGE_PHP}/usr/share/man/man1" -name '*.gz' 2>/dev/null)" ]; then
    for man_src in "$BUILD_ROOT/php-${PHP_VERSION}/sapi/cli/php.1" \
                    "$BUILD_ROOT/php-${PHP_VERSION}/sapi/cli/php.1.in" \
                    "$BUILD_ROOT/php-${PHP_VERSION}/php.1"; do
      if [ -f "$man_src" ]; then
        cp "$man_src" "${STAGE_PHP}/usr/share/man/man1/php${PHP_VER_SHORT}.1"
        gzip -f "${STAGE_PHP}/usr/share/man/man1/php${PHP_VER_SHORT}.1" 2>/dev/null || true
        break
      fi
    done
  fi

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         "php${PHP_VER_SHORT}-custom" \
    --version      "$PHP_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "PHP $PHP_VERSION CLI + common (custom build)" \
    --depends      libssl3 \
    --depends      libpcre2-8-0 \
    --depends      zlib1g \
    --depends      libcurl4 \
    --depends      libxml2 \
    --depends      libgd3 \
    --depends      libzip4 \
    --depends      libsodium23 \
    --depends      libicu74 \
    --depends      libonig5 \
    --depends      libffi8 \
    --depends      libpq5 \
    --depends      libmariadb3 \
    --depends      libsqlite3-0 \
    --depends      libgmp10 \
    --depends      libldap-2.5-0 \
    --depends      libxslt1.1 \
    --depends      libenchant-2-2 \
    --depends      libtidy5deb1 \
    --depends      libedit2 \
    --depends      libsasl2-2 \
    --conflicts    "php${PHP_VER_SHORT}" \
    --conflicts    "php${PHP_VER_SHORT}-cli" \
    --conflicts    "php${PHP_VER_SHORT}-common" \
    --replaces     "php${PHP_VER_SHORT}" \
    --replaces     "php${PHP_VER_SHORT}-cli" \
    --replaces     "php${PHP_VER_SHORT}-common" \
    --provides     "php${PHP_VER_SHORT}" \
    --provides     "php${PHP_VER_SHORT}-cli" \
    --provides     "php${PHP_VER_SHORT}-common" \
    --provides     "php${PHP_VER_SHORT}-json" \
    --provides     "php${PHP_VER_SHORT}-mbstring" \
    --provides     "php${PHP_VER_SHORT}-xml" \
    --provides     "php${PHP_VER_SHORT}-curl" \
    --provides     "php${PHP_VER_SHORT}-gd" \
    --provides     "php${PHP_VER_SHORT}-mysql" \
    --provides     "php${PHP_VER_SHORT}-pgsql" \
    --provides     "php${PHP_VER_SHORT}-intl" \
    --provides     "php${PHP_VER_SHORT}-soap" \
    --provides     "php${PHP_VER_SHORT}-bcmath" \
    --provides     "php${PHP_VER_SHORT}-zip" \
    --deb-no-default-config-files \
    --after-install  "/tmp/php-core-postinst.sh" \
    --after-remove   "/tmp/php-core-postrm.sh" \
    --force \
    --package      "$deb_file" \
    --chdir        "$STAGE_PHP" \
    --exclude      "sbin/php-fpm" \
    --exclude      "lib/systemd/system/php*fpm*" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
}

# ------------------------------------------------------------------------------
# .deb-Paket: php8.5-fpm-custom (FPM binary + systemd unit)
# ------------------------------------------------------------------------------
create_fpm_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  local fpm_stage="/tmp/php-fpm-stage"
  rm -rf "$fpm_stage"
  mkdir -p "$fpm_stage/usr/sbin"
  mkdir -p "$fpm_stage/lib/systemd/system"
  mkdir -p "$fpm_stage/usr/share/php/${PHP_VER_SHORT}/fpm"

  local fpm_src=""
  for candidate in "$STAGE_PHP/usr/sbin/php-fpm${PHP_VER_SHORT}" "$STAGE_PHP/usr/sbin/php-fpm"; do
    if [ -f "$candidate" ]; then
      fpm_src="$candidate"
      break
    fi
  done
  [ -n "$fpm_src" ] || die "php-fpm Binary nicht gefunden in $STAGE_PHP/usr/sbin/"
  cp "$fpm_src" "$fpm_stage/usr/sbin/php-fpm${PHP_VER_SHORT}"
  chmod 755 "$fpm_stage/usr/sbin/php-fpm${PHP_VER_SHORT}"

  cat > "$fpm_stage/lib/systemd/system/php${PHP_VER_SHORT}-fpm.service" <<FPMUNIT
[Unit]
Description=The PHP ${PHP_VER_SHORT} FastCGI Process Manager
After=network.target

[Service]
Type=notify
ExecStart=/usr/sbin/php-fpm${PHP_VER_SHORT} --nodaemonize --fpm-config /etc/php/${PHP_VER_SHORT}/fpm/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
PrivateTmp=true
LimitNOFILE=65535
ProtectSystem=full
PrivateDevices=true
ProtectHome=true
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
FPMUNIT

  cat > "$fpm_stage/usr/share/php/${PHP_VER_SHORT}/fpm/pool.d.example.conf" <<'FPMPOOL'
; Example FPM pool configuration
; Copy to /etc/php/8.5/fpm/pool.d/www.conf
[www]
user = www-data
group = www-data
listen = /run/php/php8.5-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 10
pm.max_requests = 1000
FPMPOOL

  mkdir -p "$fpm_stage/usr/lib/tmpfiles.d"
  cat > "$fpm_stage/usr/lib/tmpfiles.d/php${PHP_VER_SHORT}-fpm.conf" <<EOF
# PHP ${PHP_VER_SHORT} FPM runtime
d /run/php 0755 ${PHP_USER} ${PHP_GROUP} -
EOF

  mkdir -p "$fpm_stage/etc/logrotate.d"
  cat > "$fpm_stage/etc/logrotate.d/php${PHP_VER_SHORT}-fpm-custom" <<EOF
/var/log/php${PHP_VER_SHORT}-fpm.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${PHP_USER} adm
    sharedscripts
    postrotate
        [ -f /var/run/php${PHP_VER_SHORT}-fpm.pid ] && kill -USR1 \$(cat /var/run/php${PHP_VER_SHORT}-fpm.pid) || true
    endspost
}
EOF

  mkdir -p "$fpm_stage/usr/share/php/${PHP_VER_SHORT}/custom-defaults/fpm"
  mkdir -p "$fpm_stage/usr/share/php/${PHP_VER_SHORT}/custom-defaults/fpm/pool.d"

  cat > "$fpm_stage/usr/share/php/${PHP_VER_SHORT}/custom-defaults/fpm/php-fpm.conf" <<'FPMCONF'
;;;;;;;;;;;;;;;;;;;;;
; FPM Configuration ;
;;;;;;;;;;;;;;;;;;;;;

[global]
pid = /run/php/php8.5-fpm.pid
error_log = /var/log/php8.5-fpm.log
include=/etc/php/8.5/fpm/pool.d/*.conf
FPMCONF

  cat > "$fpm_stage/usr/share/php/${PHP_VER_SHORT}/custom-defaults/fpm/pool.d/www.conf" <<'POOLCONF'
[www]
user = www-data
group = www-data
listen = /run/php/php8.5-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 10
pm.max_requests = 1000
POOLCONF

  # Install php-fpm man page
  mkdir -p "$fpm_stage/usr/share/man/man8"
  cat > "$fpm_stage/usr/share/man/man8/php-fpm${PHP_VER_SHORT}.8" <<'FPM_MAN'
.TH PHP-FPM 8 "PHP" "PHP-FPM"
.SH NAME
php-fpm \- PHP FastCGI Process Manager
.SH SYNOPSIS
.B php-fpm
.RI [ options ]
.SH DESCRIPTION
.PP
php-fpm is the FastCGI Process Manager for PHP.
It is used to serve PHP applications via FastCGI with web servers like nginx.
.SH OPTIONS
.TP
.BR \-y " " file
Specify the php-fpm configuration file.
.TP
.BR \-t " " " "
Test the php-fpm configuration.
.TP
.BR \-\-nodaemonize
Run in foreground.
.SH "SEE ALSO"
.BR php (1),
.BR nginx (8).
FPM_MAN
  gzip -f "$fpm_stage/usr/share/man/man8/php-fpm${PHP_VER_SHORT}.8" 2>/dev/null || true

  local deb_file="$PACKAGE_DIR/php${PHP_VER_SHORT}-fpm-custom_${PHP_VERSION}-1_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         "php${PHP_VER_SHORT}-fpm-custom" \
    --version      "$PHP_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "PHP $PHP_VERSION FPM (custom build)" \
    --depends      "php${PHP_VER_SHORT}-custom" \
    --conflicts    "php${PHP_VER_SHORT}-fpm" \
    --replaces     "php${PHP_VER_SHORT}-fpm" \
    --provides     "php${PHP_VER_SHORT}-fpm" \
    --deb-no-default-config-files \
    --after-install  "/tmp/php-fpm-postinst.sh" \
    --after-remove   "/tmp/php-fpm-postrm.sh" \
    --force \
    --package      "$deb_file" \
    --chdir        "$fpm_stage" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
  rm -rf "$fpm_stage"
}

# ------------------------------------------------------------------------------
# .deb-Pakete: PECL-Extensions (einzeln)
# ------------------------------------------------------------------------------
create_extension_packages() {
  local arch
  arch="$(dpkg --print-architecture)"

  local php_config
  php_config="$(resolve_staged_php_tool "php-config" || true)"
  [ -x "$php_config" ] || die "php-config nicht gefunden: $php_config"
  local ext_install_dir
  ext_install_dir="$($php_config --extension-dir 2>/dev/null || echo "$PHP_EXTENSION_DIR")"
  ext_install_dir="${ext_install_dir#"$STAGE_PHP"}"

  create_ext_maintainer_scripts

  local pkg_ok=0
  local pkg_fail=0

  for ext in "${PECL_EXTENSIONS[@]}"; do
    local pkg_name="${PECL_PKGNAME[$ext]}"
    local desc="${PECL_DESC[$ext]}"
    local extname="${PECL_EXTNAME[$ext]}"
    local deps="${PECL_DEPS[$ext]}"
    local is_zend="${PECL_ZEND[$ext]}"

    local _deb_pattern="php${PHP_VER_SHORT}-${pkg_name}_*_*.deb"
    if [ "${FORCE_REBUILD:-no}" != "yes" ] && compgen -G "$PACKAGE_DIR/$_deb_pattern" >/dev/null 2>&1; then
      pkg_ok=$((pkg_ok + 1))
      continue
    fi

    local so_file="$STAGE_PHP${ext_install_dir}/${extname}.so"
    if [ ! -f "$so_file" ]; then
      so_file="$STAGE_PHP$PHP_EXTENSION_DIR/${extname}.so"
    fi

    if [ ! -f "$so_file" ]; then
      log "  [SKIP] $pkg_name – ${extname}.so nicht gefunden"
      pkg_fail=$((pkg_fail + 1))
      continue
    fi

    local ext_stage="/tmp/php-ext-stage-${ext}"
    rm -rf "$ext_stage"
    mkdir -p "$ext_stage${ext_install_dir}"
    mkdir -p "$ext_stage$PHP_MODS_AVAIL"

    cp "$so_file" "$ext_stage${ext_install_dir}/"

    if [ "$is_zend" = "yes" ]; then
      echo "zend_extension=${extname}.so" > "$ext_stage$PHP_MODS_AVAIL/${extname}.ini"
    else
      echo "extension=${extname}.so" > "$ext_stage$PHP_MODS_AVAIL/${extname}.ini"
    fi

    local deb_file="$PACKAGE_DIR/php${PHP_VER_SHORT}-${pkg_name}_${PHP_VERSION}-1_${arch}.deb"
    log "Erstelle $(basename "$deb_file")"

    local fpm_deps=""
    local dep
    for dep in $deps; do
      fpm_deps="$fpm_deps --depends $dep"
    done

    local fpm_conflicts=""
    fpm_conflicts="--conflicts php${PHP_VER_SHORT}-${pkg_name} --replaces php${PHP_VER_SHORT}-${pkg_name}"

    set +e
    eval fpm \
      --input-type   dir \
      --output-type  deb \
      --name         "php${PHP_VER_SHORT}-${pkg_name}" \
      --version      "$PHP_VERSION" \
      --iteration    1 \
      --architecture "$arch" \
      --maintainer   "\"local build <root@localhost>\"" \
      --description  "\"$desc (PHP $PHP_VERSION)\"" \
      ${fpm_deps} \
      ${fpm_conflicts} \
      --deb-no-default-config-files \
      --after-install  "/tmp/php-ext-postinst.sh" \
      --after-remove   "/tmp/php-ext-postrm.sh" \
      --force \
      --package      "$deb_file" \
      --chdir        "$ext_stage" \
      . 2>&1 | tee -a "$LOG_FILE"
    local fpm_rc=${PIPESTATUS[0]}
    set -e

    if [ "$fpm_rc" -eq 0 ]; then
      log "  [OK] $(basename "$deb_file")"
      pkg_ok=$((pkg_ok + 1))
    else
      log "  [FAIL] fpm fuer $pkg_name (Exit $fpm_rc)"
      pkg_fail=$((pkg_fail + 1))
    fi

    rm -rf "$ext_stage"
  done

  log "PECL-Pakete: $pkg_ok erfolgreich, $pkg_fail fehlgeschlagen/uebersprungen"
}

# ------------------------------------------------------------------------------
# Alle Pakete erstellen
# ------------------------------------------------------------------------------
create_all_packages() {
  stage_install
  build_pecl_extensions
  create_core_package
  create_fpm_package
  create_extension_packages

  echo ""
  log "===== Alle PHP-Pakete fertig ====="
  echo ""
  echo "Erzeugte Pakete:"
  find "$PACKAGE_DIR" -maxdepth 1 -name "*.deb" -printf "  %s bytes %p\n" 2>/dev/null \
    | sort -t/ -k6 | tee -a "$LOG_FILE"

  generate_checksums

  echo ""
  echo "HINWEIS: /etc/php ist NICHT in den Paketen."
  echo "         Konfiguration wird durch 'backup' / 'restore' verwaltet."
  echo ""
  local repo_script
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  if [ -x "$repo_script" ]; then
    log "Aktualisiere lokales Repository..."
    "$repo_script" update || true
  fi

  echo "Naechster Schritt: $0 install"
}

# ------------------------------------------------------------------------------
# Verifikation
# ------------------------------------------------------------------------------
verify_build() {
  echo ""
  echo "=============================================="
  echo " PHP ${PHP_VER_SHORT} Verifikation"
  echo "=============================================="

  if [ -f "/usr/bin/php${PHP_VER_SHORT}" ]; then
    echo ""
    echo "--- Version ---"
    "/usr/bin/php${PHP_VER_SHORT}" -v

    echo ""
    echo "--- Geladene Module ---"
    "/usr/bin/php${PHP_VER_SHORT}" -m | sort

    echo ""
    echo "--- FPM ---"
    if [ -f "/usr/sbin/php-fpm${PHP_VER_SHORT}" ]; then
      "/usr/sbin/php-fpm${PHP_VER_SHORT}" -v 2>&1 || true
      systemctl status "php${PHP_VER_SHORT}-fpm" --no-pager || true
    else
      echo "php-fpm${PHP_VER_SHORT} nicht installiert"
    fi

    echo ""
    echo "--- Verfuegbare Extensions (.so) ---"
    if [ -d "$PHP_EXTENSION_DIR" ]; then
      find "$PHP_EXTENSION_DIR" -name "*.so" | sort
    fi

    echo ""
    echo "--- Extension INIs ---"
    if [ -d "$PHP_MODS_AVAIL" ]; then
      ls -1 "$PHP_MODS_AVAIL"/*.ini 2>/dev/null || echo "(keine)"
    fi
  else
    echo "php${PHP_VER_SHORT} nicht installiert"
  fi
  echo "=============================================="
}

# ------------------------------------------------------------------------------
# Pakete installieren
# ------------------------------------------------------------------------------
install_packages() {
  local deb_core deb_fpm
  deb_core=$(find "$PACKAGE_DIR" -maxdepth 1 -name "php${PHP_VER_SHORT}-custom_*.deb" 2>/dev/null | sort -V | tail -1 || true)
  deb_fpm=$(find "$PACKAGE_DIR" -maxdepth 1 -name "php${PHP_VER_SHORT}-fpm-custom_*.deb" 2>/dev/null | sort -V | tail -1 || true)

  [ -n "$deb_core" ] || die "Kein php${PHP_VER_SHORT}-custom.deb – zuerst: $0 package"

  if [ ! -d "/etc/php/${PHP_VER_SHORT}" ]; then
    log "WARNUNG: /etc/php/${PHP_VER_SHORT} nicht gefunden!"
    read -r -p "Trotzdem fortfahren? (ja/nein): " antwort
    [ "$antwort" = "ja" ] || die "Abgebrochen"
  fi

  log "Installiere Core: $(basename "$deb_core")"
  DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_core"

  if [ -n "$deb_fpm" ]; then
    log "Installiere FPM: $(basename "$deb_fpm")"
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_fpm"
  fi

  local deb_exts
  deb_exts=$(find "$PACKAGE_DIR" -maxdepth 1 -name "php${PHP_VER_SHORT}-*_*.deb" 2>/dev/null \
    | grep -v "custom" | grep -v "fpm-custom" | sort || true)
  if [ -n "$deb_exts" ]; then
    log "Installiere Extension-Pakete..."
    for deb_ext in $deb_exts; do
      log "  $(basename "$deb_ext")"
    done
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef -i "$deb_exts" 2>&1 | tee -a "$LOG_FILE" || true
  fi

  apt-get install -f -y || true
  log "Konfiguration in /etc/php/${PHP_VER_SHORT}: unveraendert"
}

# ------------------------------------------------------------------------------
# Dienst neu starten
# ------------------------------------------------------------------------------
restart_service() {
  log "Starte PHP ${PHP_VER_SHORT}-FPM neu"
  systemctl daemon-reload
  systemctl enable "php${PHP_VER_SHORT}-fpm"
  systemctl restart "php${PHP_VER_SHORT}-fpm"
}

# ------------------------------------------------------------------------------
# Post-Install Checks
# ------------------------------------------------------------------------------
post_checks() {
  log "Pruefe Installation"
  [ -f "/usr/bin/php${PHP_VER_SHORT}" ] || die "php${PHP_VER_SHORT} Binary nicht gefunden"
  log "PHP Version: $("/usr/bin/php${PHP_VER_SHORT}" -r 'echo PHP_VERSION;' 2>&1)"

  if [ -f "/usr/sbin/php-fpm${PHP_VER_SHORT}" ]; then
    log "FPM Konfigurationscheck"
    { "/usr/sbin/php-fpm${PHP_VER_SHORT}" -t >> "$LOG_FILE"; } 2>&1 \
      || log "WARNUNG: FPM Konfigurationsfehler – Log: $LOG_FILE"

    if ! systemctl is-active --quiet "php${PHP_VER_SHORT}-fpm"; then
      systemctl status "php${PHP_VER_SHORT}-fpm" --no-pager || true
      die "PHP ${PHP_VER_SHORT}-FPM laeuft nicht"
    fi
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

  systemctl stop "php${PHP_VER_SHORT}-fpm" 2>/dev/null || true

  for pkg in $(for ext in "${PECL_EXTENSIONS[@]}"; do echo "php${PHP_VER_SHORT}-${PECL_PKGNAME[$ext]}"; done) \
    "php${PHP_VER_SHORT}-fpm-custom" "php${PHP_VER_SHORT}-custom"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "Deinstalliere $pkg"
      dpkg -r "$pkg" || true
    fi
  done

  if [ -d "$backup_dir/etc_php" ]; then
    rm -rf "/etc/php/${PHP_VER_SHORT}"
    cp -a "$backup_dir/etc_php" "/etc/php/${PHP_VER_SHORT}"
    chmod 755 "/etc/php/${PHP_VER_SHORT}"
    log "/etc/php/${PHP_VER_SHORT} wiederhergestellt"
  fi

  [ -f "$backup_dir/usr_sbin_phpfpm" ] && {
    cp -a "$backup_dir/usr_sbin_phpfpm" "/usr/sbin/php-fpm${PHP_VER_SHORT}"
    chmod 755 "/usr/sbin/php-fpm${PHP_VER_SHORT}"
  }

  if [ -f "$backup_dir/packages.txt" ] && [ -s "$backup_dir/packages.txt" ]; then
    log "Stelle apt-Pakete wieder her"
    apt-get update -qq || true
    xargs -r apt-get install --reinstall -y < "$backup_dir/packages.txt" || true
  fi

  systemctl daemon-reload
  systemctl enable "php${PHP_VER_SHORT}-fpm"
  systemctl restart "php${PHP_VER_SHORT}-fpm" || true

  log "Restore abgeschlossen"
}

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------
status_cmd() {
  echo "=============================================="
  echo " PHP ${PHP_VER_SHORT} Status – $(date)"
  echo "=============================================="

  if [ -f "/usr/bin/php${PHP_VER_SHORT}" ]; then
    echo "Binary  : /usr/bin/php${PHP_VER_SHORT}"
    echo "Version : $("/usr/bin/php${PHP_VER_SHORT}" -r 'echo PHP_VERSION;' 2>&1)"
  else
    echo "php${PHP_VER_SHORT}: NICHT GEFUNDEN"
  fi

  echo ""
  echo "--- Installierte Custom-Pakete ---"
  local found=0
  for pkg in "php${PHP_VER_SHORT}-custom" "php${PHP_VER_SHORT}-fpm-custom" \
    $(for ext in "${PECL_EXTENSIONS[@]}"; do echo "php${PHP_VER_SHORT}-${PECL_PKGNAME[$ext]}"; done); do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      printf "  [OK] %-50s %s\n" "$pkg" "$(dpkg -s "$pkg" | awk '/^Version:/{print $2}')"
      found=$((found + 1))
    fi
  done
  [ "$found" -eq 0 ] && echo "  (keine Custom-Pakete installiert)"

  echo ""
  echo "--- FPM Status ---"
  systemctl status "php${PHP_VER_SHORT}-fpm" --no-pager 2>/dev/null || echo "FPM nicht aktiv"

  echo ""
  if [ -L "$LATEST_LINK" ] || [ -d "$LATEST_LINK" ]; then
    echo "Letztes Backup: $(readlink -f "$LATEST_LINK" 2>/dev/null || echo "$LATEST_LINK")"
  else
    echo "Kein Backup vorhanden"
  fi

  echo ""
  echo "--- Verfuegbare .deb-Pakete ---"
  if [ -d "$PACKAGE_DIR" ]; then
    find "$PACKAGE_DIR" -maxdepth 1 -name "*.deb" -printf "%s bytes %p\n" 2>/dev/null || echo "(keine)"
  fi
}

list_backups() {
  echo "Verfuegbare Backups in $BACKUP_ROOT:"
  [ -d "$BACKUP_ROOT" ] \
    && find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort \
    || echo "(kein Backup-Verzeichnis)"
}

list_extensions_cmd() {
  echo "=============================================="
  echo " Verfuegbare PECL-Extensions (${#PECL_EXTENSIONS[@]})"
  echo "=============================================="
  printf "%-20s %-30s %s\n" "PAKETNAME" "EXTENSION" "BESCHREIBUNG"
  printf "%-20s %-30s %s\n" "--------------------" "------------------------------" "--------------------"
  for ext in "${PECL_EXTENSIONS[@]}"; do
    printf "%-20s %-30s %s\n" "php${PHP_VER_SHORT}-${PECL_PKGNAME[$ext]}" "${PECL_EXTNAME[$ext]}" "${PECL_DESC[$ext]}"
  done
  echo "=============================================="
}

check_config() {
  log "PHP Module-Check"
  if [ -f "/usr/bin/php${PHP_VER_SHORT}" ]; then "/usr/bin/php${PHP_VER_SHORT}" -m || true; fi
  log "FPM Konfigurationscheck"
  if [ -f "/usr/sbin/php-fpm${PHP_VER_SHORT}" ]; then "/usr/sbin/php-fpm${PHP_VER_SHORT}" -t || true; fi
}

uninstall_cmd() {
  log "Deinstalliere alle PHP ${PHP_VER_SHORT} Custom-Pakete"
  systemctl stop "php${PHP_VER_SHORT}-fpm" 2>/dev/null || true

  for ext in "${PECL_EXTENSIONS[@]}"; do
    local pkg="php${PHP_VER_SHORT}-${PECL_PKGNAME[$ext]}"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "  Entferne $pkg"
      dpkg -r "$pkg" || true
    fi
  done

  for pkg in "php${PHP_VER_SHORT}-custom-dev" "php${PHP_VER_SHORT}-fpm-custom" "php${PHP_VER_SHORT}-custom"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "  Entferne $pkg"
      dpkg -r "$pkg" || true
    fi
  done

  log "Deinstallation abgeschlossen"
}

# ------------------------------------------------------------------------------
# Vollstaendiger Paket-Build
# ------------------------------------------------------------------------------
package_all() {
  log "=== Starte PHP ${PHP_VER_SHORT} Paket-Build ==="
  log "PECL-Extensions: ${#PECL_EXTENSIONS[@]}"
  install_build_deps
  prepare_sources
  download_pecl_sources
  build_php
  create_all_packages
  create_php_dev_package
  sign_packages
  log "=== Paket-Build abgeschlossen ==="
  echo ""
  local repo_script
  repo_script="$(dirname "$0")/setup_local_repo.sh"
  if [ -x "$repo_script" ]; then
    log "Aktualisiere lokales Repository..."
    "$repo_script" update || true
  fi

  echo "Naechster Schritt: $0 install"
}

# ------------------------------------------------------------------------------
# .deb-Paket: php8.5-custom-dev (phpize, php-config, Header)
# ------------------------------------------------------------------------------
create_php_dev_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  local dev_stage="/tmp/php-dev-stage"
  rm -rf "$dev_stage"
  mkdir -p "$dev_stage"

  local php_bin="$STAGE_PHP$PHP_PREFIX/bin"

  # phpize, php-config
  mkdir -p "$dev_stage/usr/bin"
  for tool in phpize php-config; do
    local bin="${php_bin}/${tool}${PHP_VER_SHORT}"
    if [ -f "$bin" ]; then
      cp "$bin" "$dev_stage/usr/bin/"
      log "PHP dev: ${tool}${PHP_VER_SHORT} kopiert"
    fi
  done

  # Header-Dateien
  local inc_src="${STAGE_PHP}${PHP_INCDIR}"
  if [ -d "$inc_src" ]; then
    mkdir -p "$dev_stage${PHP_INCDIR}"
    cp -a "$inc_src"/* "$dev_stage${PHP_INCDIR}/"
    local hdr_count
    hdr_count=$(find "$dev_stage${PHP_INCDIR}" -name "*.h" | wc -l)
    log "PHP dev: $hdr_count Header-Dateien kopiert"
  fi

  local file_count
  file_count=$(find "$dev_stage" -type f | wc -l)
  if [ "$file_count" -eq 0 ]; then
    log "SKIP php${PHP_VER_SHORT}-custom-dev – keine Dateien gefunden"
    rm -rf "$dev_stage"
    return 0
  fi

  mkdir -p "$dev_stage/usr/share/doc/php${PHP_VER_SHORT}-custom-dev"

  local deb_file="$PACKAGE_DIR/php${PHP_VER_SHORT}-custom-dev_${PHP_VERSION}-1_${arch}.deb"
  log "Erstelle $(basename "$deb_file")"

  fpm \
    --input-type   dir \
    --output-type  deb \
    --name         "php${PHP_VER_SHORT}-custom-dev" \
    --version      "$PHP_VERSION" \
    --iteration    1 \
    --architecture "$arch" \
    --maintainer   "local build <root@localhost>" \
    --description  "PHP $PHP_VERSION – development files (phpize, php-config, headers)" \
    --depends      "php${PHP_VER_SHORT}-custom" \
    --conflicts    "php${PHP_VER_SHORT}-dev" \
    --provides     "php${PHP_VER_SHORT}-dev" \
    --replaces     "php${PHP_VER_SHORT}-dev" \
    --deb-no-default-config-files \
    --force \
    --package      "$deb_file" \
    --chdir        "$dev_stage" \
    .

  log "Erzeugt: $(basename "$deb_file") ($(du -sh "$deb_file" | cut -f1))"
  rm -rf "$dev_stage"
}

# ------------------------------------------------------------------------------
# Installation
# ------------------------------------------------------------------------------
install_all() {
  log "=== Starte Installation ==="
  log "Schritt 1/4: Backup"
  create_backup
  log "Schritt 2/4: Pakete installieren (/etc/php bleibt unberuehrt)"
  install_packages
  log "Schritt 3/4: FPM neu starten"
  restart_service
  log "Schritt 4/4: Verifikation"
  post_checks
  log "=== Installation abgeschlossen ==="
  echo ""
  echo "Zusammenfassung:"
  echo "  Backup:         $LATEST_LINK"
  echo "  Pakete:         $PACKAGE_DIR"
  echo "  Konfiguration:  /etc/php/${PHP_VER_SHORT}  (UNVERAENDERT)"
  echo "  FPM Socket:     ${PHP_FPM_SOCKET}"
  echo "  Log:            $LOG_FILE"
}

# ------------------------------------------------------------------------------
# OS/Arch Pruefung
# ------------------------------------------------------------------------------
check_os_arch() {
  local os_id os_version_id os_major_version arch

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
    echo "Starte Skript in Screen Session: php_build ..."
    exec screen -dmS php_build bash "$0" "$@"
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
    list-extensions) list_extensions_cmd ;;
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
