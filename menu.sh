#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SETTINGS_FILE="$HOME/.build_settings.env"
SCREEN_MAP=("php_build:setup_php.sh" "nginx_build:setup_nginx.sh" "dovecot_build:setup_dovecot.sh" "postfix_build:setup_postfix.sh")
SCRIPT_FILES=(setup_dovecot.sh setup_postfix.sh setup_php.sh setup_nginx.sh setup-zpush.sh setup_local_repo.sh setup_backup_restore.sh unban_ip.sh f2b_test.sh)

# ===================== COLORS =====================
R=196 G=82 Y=220 B=69 C=51 P=183 GR=242 W=255 O=215

# ===================== HELPERS =====================

get_env_var() {
  local envfile="$SCRIPT_DIR/$1" var="$2"
  [ -f "$envfile" ] && grep "^${var}=" "$envfile" | head -1 | sed "s/^${var}=[\"']\?//;s/[\"']\?$//"
}

screen_cache="" screen_cache_ts=0
screen_list_cached() {
  local now; now="$(date +%s)"
  if [ $((now - screen_cache_ts)) -gt 2 ]; then
    screen_cache="$(screen -list 2>/dev/null)"
    screen_cache_ts="$now"
  fi
  printf '%s' "$screen_cache"
}

screen_active()  { screen_list_cached | grep -qE "\.$1\b"; }
screen_pid()     { local l; l="$(screen_list_cached | grep -E "\.$1\b")" && echo "${l%%.*}"; }
screen_uptime()  { local p; p="$(screen_pid "$1")" && [ -n "$p" ] && ps -o etimes= -p "$p" 2>/dev/null | awk '{printf "%dh%dm",$1/3600,($1%3600)/60}'; }
screen_state()   { screen_list_cached | grep -E "\.$1\b" | grep -q 'Detached' && echo "Detached" || echo "Attached"; }

screen_count() {
  local c=0 sn
  for entry in "${SCREEN_MAP[@]}"; do
    IFS=: read -r sn _ <<< "$entry"
    screen_active "$sn" && c=$((c + 1))
  done
  echo "$c"
}

get_log_for_screen() {
  local sname="$1" script=""
  for entry in "${SCREEN_MAP[@]}"; do
    local sn sc; IFS=: read -r sn sc <<< "$entry"
    [ "$sn" = "$sname" ] && script="$sc" && break
  done
  [ -n "$script" ] && get_env_var "${script%.sh}.env" LOG_FILE
}

load_settings() {
  [ -f "$SETTINGS_FILE" ] && source "$SETTINGS_FILE"
  : "${FORCE_REBUILD:=no}"
  : "${USE_PGO:=yes}"
  : "${USE_LTO:=yes}"
}

save_settings() {
  cat > "$SETTINGS_FILE" <<EOF
FORCE_REBUILD="$FORCE_REBUILD"
USE_PGO="$USE_PGO"
USE_LTO="$USE_LTO"
EOF
}

opt_args() {
  local -n _oa_arr="$1"; shift
  local v; for v in "$@"; do [ -n "$v" ] && _oa_arr+=("$v"); done
}

ensure_deps() {
  local need=()
  command -v gum  >/dev/null 2>&1 || need+=(gum)
  command -v fzf  >/dev/null 2>&1 || need+=(fzf)
  command -v curl >/dev/null 2>&1 || need+=(curl)
  (( ${#need[@]} == 0 )) && return
  command -v gum >/dev/null 2>&1 && gum style --bold --foreground "$R" -- "Installiere: ${need[*]}" || echo "Installiere: ${need[*]}"
  if ! command -v gum >/dev/null 2>&1; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
  fi
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y gum fzf curl 2>/dev/null
  command -v gum >/dev/null 2>&1 || { echo "gum fehlgeschlagen"; exit 1; }
}

ensure_root() {
  [ "$(id -u)" -eq 0 ] && return
  command -v sudo >/dev/null 2>&1 && exec sudo -E bash "$0" "$@"
  echo "Root erforderlich." >&2; exit 1
}

ensure_scripts() {
  for f in "${SCRIPT_FILES[@]}"; do
    [ -f "$SCRIPT_DIR/$f" ] && chmod 755 "$SCRIPT_DIR/$f" 2>/dev/null || true
  done
}

ensure_env_files() {
  for ex in "$SCRIPT_DIR"/*.env.example; do
    [ -f "$ex" ] || continue
    local t="${ex%.example}"
    [ -f "$t" ] || cp -n "$ex" "$t" 2>/dev/null || true
  done
}

# ===================== UI =====================

_ok()   { gum style --foreground "$G"  -- "$1"; }
_warn() { gum style --foreground "$Y" -- "$1"; }
_fail() { gum style --foreground "$R"    -- "$1"; }
_dim()  { gum style --foreground "$GR"   -- "$1"; }
_bold() { gum style --bold --foreground "$W" -- "$1"; }
_col()  { local c="$1"; shift; gum style --foreground "$c" -- "$@"; }

badge() {
  local label="$1" val="$2"
  if [ "$val" = "yes" ]; then
    gum style --foreground "$G" --bold -- "● $label"
  else
    gum style --foreground "$GR" -- "○ $label"
  fi
}

SYS_LINE=""
cache_sys_info() {
  [ -n "$SYS_LINE" ] && return
  local h c m a
  h="$(hostname -s 2>/dev/null || echo '?')"
  c="$(nproc 2>/dev/null || echo '?')"
  m="$(awk '/MemTotal/{printf "%.0fG",$2/1048576}' /proc/meminfo 2>/dev/null || echo '?')"
  a="$(uname -m 2>/dev/null || echo '?')"
  SYS_LINE="$h  │  ${c} Cores  │  ${m} RAM  │  $a"
}

draw_header() {
  local title="${1:-}" extras="${2:-}"
  cache_sys_info

  local nl=$'\n'
  local hdr=""
  if [ -n "$title" ]; then
    hdr+="$(gum style --bold --foreground "$C" -- "$title")${nl}"
  fi
  hdr+="$(gum style --foreground "$W" -- "$SYS_LINE")${nl}"
  hdr+="$(badge PGO "$USE_PGO") $(badge LTO "$USE_LTO") $(badge Force "$FORCE_REBUILD")"

  local sc; sc="$(screen_count)"
  [ "$sc" -gt 0 ] && hdr+="${nl}$(gum style --foreground "$Y" -- "⚡ $sc Session(s)")"
  [ -n "$extras" ] && hdr+="${nl}$extras"

  gum style --border double --padding "0 3" --align center --foreground "$C" -- "$hdr"
}

draw_box() {
  local title="$1" color="${2:-$C}"; shift 2
  local nl=$'\n'
  local body
  body="$(printf '%s\n' "$@")"
  gum style --border rounded --padding "0 1" --foreground "$color" -- \
    "$(gum style --bold --foreground "$color" -- " $title ")${nl}${body}"
}

choose() {
  local hdr="${1:-}"; shift
  printf '%s\n' "$@" | gum choose --header="$hdr" \
    --cursor=" ❯ " --cursor.foreground="$C" --selected.foreground="$G" --height=30
}

choose_or_back() { choose "$@" "$(_dim "← Zurueck")" || echo "Zurueck"; }

ask_path()    { gum input --placeholder="Pfad (leer = latest)" 3>/dev/null || echo ""; }
ask_confirm() { local msg="$1"; shift; gum confirm "$msg" "$@" 2>/dev/null; }
ask_screen()  {
  gum confirm "▶ Im Hintergrund starten? (Screen)" --affirmative="Screen" --negative="Vordergrund" 2>/dev/null
}

# ===================== RUNNERS =====================

run_script() {
  local script="$1"; shift
  local path="$SCRIPT_DIR/$script"
  [ -f "$path" ] || { _fail "Nicht gefunden: $path"; read -r -p " Enter..."; return 1; }
  chmod 755 "$path" 2>/dev/null || true

  echo
  draw_box "$script $*" "$C" "$(_dim "PGO=$USE_PGO  LTO=$USE_LTO  Force=$FORCE_REBUILD")"
  echo

  FORCE_REBUILD="$FORCE_REBUILD" USE_PGO="$USE_PGO" USE_LTO="$USE_LTO" bash "$path" "$@"
  local rc=$?
  echo
  if [ "$rc" -eq 0 ]; then
    draw_box "Fertig" "$G" "$(_ok "✔") Build erfolgreich"
  else
    draw_box "Fehler" "$R" "$(_fail "✘") Exit-Code: $rc"
  fi
  read -r -p " Enter fuer Menue..." _
  return $rc
}

run_in_screen() {
  local script="$1"; shift
  local sname="$1"; shift
  local path="$SCRIPT_DIR/$script"
  [ -f "$path" ] || { _fail "Nicht gefunden: $path"; return 1; }
  chmod 755 "$path" 2>/dev/null || true

  if ! command -v screen >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y screen
  fi

  if screen_active "$sname"; then
    local st; st="$(screen_state "$sname")"
    local up; up="$(screen_uptime "$sname")"
    echo
    draw_box "Session laeuft" "$Y" \
      "Name:   $sname ($st)" \
      "Uptime: ${up:---}" \
      "" \
      "$(_dim "screen -r $sname")  zum Anhaengen"
    echo
    ask_confirm "Anhaengen?" && screen -r "$sname"
    return 0
  fi

  local logfile; logfile="$(get_log_for_screen "$sname")"
  local log_redirect=""
  [ -n "$logfile" ] && log_redirect="2>&1 | tee '$logfile'"

  local args_str="" a
  for a in "$@"; do args_str+=" '${a//\'/\'\\\'\'}'"; done
  screen -dmS "$sname" bash -c "
    export FORCE_REBUILD='${FORCE_REBUILD}' USE_PGO='${USE_PGO}' USE_LTO='${USE_LTO}'
    bash '${path}'${args_str} ${log_redirect}
    echo ''; echo '=== Fertig ==='; echo 'Strg+A D = Trennen'; read -r _
  "

  sleep 0.3
  if screen_active "$sname"; then
    echo
    local nl=$'\n'
    local info="Session  $(_col "$G" "$sname")  gestartet"
    [ -n "$logfile" ] && info+="${nl}Log      $(_dim "$logfile")"
    info+="${nl}${nl}  $(_dim "screen -r $sname")   Anhaengen"
    info+="${nl}  $(_dim "Strg+A D")           Trennen"
    draw_box "Screen gestartet" "$G" "$info"
    echo
  else
    _fail "Session '$sname' konnte nicht gestartet werden."
  fi
  read -r -p " Enter..." _
}

run_build() {
  local script="$1"; shift
  local sname="$1"; shift
  if ask_screen; then
    run_in_screen "$script" "$sname" "$@"
  else
    run_script "$script" "$@"
  fi
}

do_restore() {
  local script="$1" sname="$2"; shift 2
  local p; p="$(ask_path)"
  local -a args=(); opt_args args "$p"
  if [ "$sname" = "-" ]; then
    run_script "$script" "$@" "${args[@]}"
  else
    run_build "$script" "$sname" "$@" "${args[@]}"
  fi
}

do_custom_args() {
  local script="$1"
  local a; a="$(gum input --placeholder='Args...')"
  [ -n "$a" ] && run_script "$script" $a
}

# ===================== SCREEN MENU =====================

menu_screens() {
  while true; do
    clear; draw_header "Screen Sessions"; echo

    local items=() snames=() log_items=()
    for entry in "${SCREEN_MAP[@]}"; do
      IFS=: read -r sn sc <<< "$entry"
      local label="${sn%_build}" line
      if screen_active "$sn"; then
        local pid up st st_c
        pid="$(screen_pid "$sn")"
        up="$(screen_uptime "$sn")"
        st="$(screen_state "$sn")"
        [ "$st" = "Detached" ] && st_c="$Y" || st_c="$G"
        printf -v line "$(_ok "●")  %-10s  PID %s  %s  %s" "$label" "${pid:----}" "${up:----}" "$(_col "$st_c" "$st")"
      else
        printf -v line "$(_dim "○")  %-10s  $(_dim "---")" "$label"
      fi
      items+=("$line")
      snames+=("$sn")
    done

    for entry in "${SCREEN_MAP[@]}"; do
      IFS=: read -r sn sc <<< "$entry"
      local logpath; logpath="$(get_log_for_screen "$sn")"
      [ -n "$logpath" ] && [ -f "$logpath" ] && log_items+=("${sn%_build}: $(du -h "$logpath" 2>/dev/null | cut -f1) $logpath")
    done

    local choice
    choice=$(choose_or_back "" \
      "${items[@]}" \
      "$(_dim "─── Aktionen ───")" \
      "Alle Sessions beenden" \
      "Logs anzeigen...") || return

    case "$choice" in
      "Zurueck") return ;;
      "Alle"*)
        ask_confirm "Wirklich alle beenden?" || continue
        for entry in "${SCREEN_MAP[@]}"; do
          IFS=: read -r sn _ <<< "$entry"
          screen_active "$sn" && screen -X -S "$sn" quit 2>/dev/null
        done
        _ok "Alle beendet."; read -r -p " Enter..." _ ;;
      "Logs"*)
        [ ${#log_items[@]} -eq 0 ] && { _dim "Keine Logs."; read -r -p " Enter..." _; continue; }
        local lc; lc=$(choose "Log:" "${log_items[@]}") || continue
        local lname="${lc%%:*}" sn_found=""
        for entry in "${SCREEN_MAP[@]}"; do
          IFS=: read -r sn _ <<< "$entry"
          [ "${sn%_build}" = "$lname" ] && sn_found="$sn" && break
        done
        if [ -n "$sn_found" ]; then
          local lp; lp="$(get_log_for_screen "$sn_found")"
          clear; _dim "=== $lp === (Strg+C = zurueck)"; tail -f "$lp"
        fi ;;
      *"Aktionen"*) continue ;;
      *$(_ok "●")*)
        local i=0 found=""
        for item in "${items[@]}"; do
          [ "$item" = "$choice" ] && found="${snames[$i]}" && break
          i=$((i + 1))
        done
        [ -n "$found" ] && screen_active "$found" && ask_confirm "'$found' anhaengen?" && screen -r "$found" ;;
      *$(_dim "○")*)
        local i=0 found=""
        for item in "${items[@]}"; do
          [ "$item" = "$choice" ] && found="${snames[$i]}" && break
          i=$((i + 1))
        done
        if [ -n "$found" ]; then
          _dim "'${found%_build}' nicht aktiv."
          ask_confirm "Starten?" || continue
          local sc=""
          for entry in "${SCREEN_MAP[@]}"; do
            IFS=: read -r sn s <<< "$entry"
            [ "$sn" = "$found" ] && sc="$s" && break
          done
          [ -n "$sc" ] && run_build "$sc" "$found" package
        fi ;;
    esac
  done
}

# ===================== PECL SELECTOR =====================

menu_php_ext_select() {
  source "$SCRIPT_DIR/setup_php.env" 2>/dev/null || true
  local pkg_dir="${PACKAGE_DIR:-/root/php-packages}"
  local ver="${PHP_VER_SHORT:-8.5}"

  local -a ext_names=()
  eval "$(awk '/^PECL_EXTENSIONS=\(/,/\)/' "$SCRIPT_DIR/setup_php.sh" 2>/dev/null | head -60)"
  for e in "${PECL_EXTENSIONS[@]:-}"; do ext_names+=("$e"); done

  if [ ${#ext_names[@]} -eq 0 ]; then
    ext_names=()
    while IFS= read -r line; do
      local name="$(echo "$line" | xargs)"
      [ -n "$name" ] && ext_names+=("$name")
    done < <(awk '/^PECL_EXTENSIONS=\(/,/\)/' "$SCRIPT_DIR/setup_php.sh" | grep -oP '^\s+\K[a-z][a-z0-9_]*')
  fi

  [ ${#ext_names[@]} -eq 0 ] && { _fail "Keine Extensions gefunden."; return; }

  local items=() missing=0 total=0
  local ext desc pkg_name line
  for ext in "${ext_names[@]}"; do
    total=$((total + 1))
    desc="$(grep -oP "PECL_DESC\\[$ext\\]=\"\\K[^\"]+" "$SCRIPT_DIR/setup_php.sh" 2>/dev/null || echo "$ext")"
    pkg_name="$(grep -oP "PECL_PKGNAME\\[$ext\\]=\"\\K[^\"]+" "$SCRIPT_DIR/setup_php.sh" 2>/dev/null || echo "$ext")"
    if compgen -G "${pkg_dir}/php${ver}-${pkg_name}_*_*.deb" >/dev/null 2>&1; then
      printf -v line "%-18s $(_ok "[OK]")    %s" "$ext" "$desc"
    else
      printf -v line "%-18s $(_fail "[ -- ]") %s" "$ext" "$desc"
      missing=$((missing + 1))
    fi
    items+=("$line")
  done

  clear
  draw_header "PECL Extensions" "$(_ok "$((total - missing))") OK  $(_fail "$missing") fehlen  von $total"
  echo

  local choices
  choices=$(printf '%s\n' "${items[@]}" | fzf --multi \
    --header="Tab = auswaehlen | Enter = starten | ESC = abbrechen" \
    --height=~25 --layout=reverse-list --no-sort --ansi \
    --marker=" ❯ " --pointer=" ❯ " \
    --color="fg:#aaaaaa,fg+:#ffffff,bg+:#1a1a2e,hl:#51afef,hl+:#51afef,marker:#51afef,pointer:#51afef,header:#87af87,gutter:#444444,border:#444444" \
    --bind 'tab:toggle' --delimiter=' ' --nth=1) || return 0

  [ -z "$choices" ] && { _dim "Nichts ausgewaehlt."; return; }

  local ext_list=()
  while IFS= read -r line; do
    ext_list+=("$(echo "$line" | awk '{print $1}')")
  done <<< "$choices"

  echo
  draw_box "PECL Build" "$C" "$(_bold "${#ext_list[@]} Extension(s):")  ${ext_list[*]}"
  ask_confirm "Starten? (PGO=$USE_PGO  LTO=$USE_LTO)" || return 0

  run_build "setup_php.sh" "php_build" pecl-only "${ext_list[@]}"
}

# ===================== SUB-MENUS =====================

menu_php() {
  local ver pkg_count=0
  ver="$(get_env_var setup_php.env PHP_VER_SHORT)"
  source "$SCRIPT_DIR/setup_php.env" 2>/dev/null || true
  [ -d "${PACKAGE_DIR:-/root/php-packages}" ] && pkg_count="$(ls "${PACKAGE_DIR:-/root/php-packages}"/*.deb 2>/dev/null | wc -l)"

  while true; do
    clear; draw_header "PHP ${ver:-}" "$(_col "$P" "$pkg_count") Pakete"; echo
    local choice
    choice=$(choose_or_back "" \
      "$(_bold "▶ Komplett-Build")" \
      "$(_warn "⚠ Force-Rebuild")" \
      "Einzelne Extension(en)..." \
      "$(_dim "─ Verwaltung ─")" \
      "Installieren" \
      "Status" \
      "Pakete auflisten" \
      "Extensions auflisten" \
      "Konfiguration pruefen" \
      "Verifikation" \
      "$(_dim "─ Backup ─")" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Backups auflisten" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Komplett"*)   run_build "setup_php.sh" "php_build" package ;;
      "Force"*)      FORCE_REBUILD=yes run_build "setup_php.sh" "php_build" package ;;
      "Einzelne"*)   menu_php_ext_select ;;
      *"Verwaltung"*) continue ;;
      "Installieren"*) run_script "setup_php.sh" install ;;
      "Status"*)     run_script "setup_php.sh" status ;;
      "Pakete"*)     run_script "setup_php.sh" list-packages ;;
      "Extensions"*) run_script "setup_php.sh" list-extensions ;;
      "Konfiguration"*) run_script "setup_php.sh" check-config ;;
      "Verifikation"*) run_script "setup_php.sh" verify ;;
      *"Backup"*) continue ;;
      "Backup erstellen"*) run_script "setup_php.sh" backup ;;
      "wiederher"*)  do_restore "setup_php.sh" "php_build" restore ;;
      "Backups"*)    run_script "setup_php.sh" list-backups ;;
      "Deinstall"*)  run_script "setup_php.sh" uninstall ;;
      "Eigene"*)     do_custom_args "setup_php.sh" ;;
      *)             return ;;
    esac
  done
}

menu_nginx() {
  local ver; ver="$(get_env_var setup_nginx.env NGINX_VERSION)"
  while true; do
    clear; draw_header "Nginx ${ver:-}"; echo
    local choice
    choice=$(choose_or_back "" \
      "$(_bold "▶ Pakete bauen")" \
      "Installieren" \
      "Status" \
      "$(_dim "─ Details ─")" \
      "Module auflisten" \
      "Backups auflisten" \
      "Nach Updates suchen" \
      "Konfiguration pruefen" \
      "Verifikation" \
      "$(_dim "─ Backup ─")" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Pakete"*)      run_build "setup_nginx.sh" "nginx_build" package ;;
      "Installieren"*) run_script "setup_nginx.sh" install ;;
      "Status"*)      run_script "setup_nginx.sh" status ;;
      *"Details"*) continue ;;
      "Module"*)      run_script "setup_nginx.sh" list-modules ;;
      "Backups"*)     run_script "setup_nginx.sh" list-backups ;;
      "Updates"*)     run_script "setup_nginx.sh" check-updates ;;
      "Konfiguration"*) run_script "setup_nginx.sh" check-config ;;
      "Verifikation"*) run_script "setup_nginx.sh" verify ;;
      *"Backup"*) continue ;;
      "Backup erstellen"*) run_script "setup_nginx.sh" backup ;;
      "wiederher"*)   do_restore "setup_nginx.sh" "nginx_build" restore ;;
      "Deinstall"*)   run_script "setup_nginx.sh" uninstall ;;
      "Eigene"*)      do_custom_args "setup_nginx.sh" ;;
      *)              return ;;
    esac
  done
}

menu_dovecot() {
  while true; do
    clear; draw_header "Dovecot"; echo
    local choice
    choice=$(choose_or_back "" \
      "$(_bold "▶ Komplett-Build")" \
      "Nur Dovecot-Core" \
      "Nur Pigeonhole" \
      "Nur kompilieren" \
      "$(_dim "─ Verwaltung ─")" \
      "Installieren" \
      "Status" \
      "Backups auflisten" \
      "Pakete auflisten" \
      "Nach Updates suchen" \
      "Konfiguration pruefen" \
      "$(_dim "─ Backup ─")" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Komplett"*)    run_build "setup_dovecot.sh" "dovecot_build" package ;;
      "Nur Dovecot"*) run_build "setup_dovecot.sh" "dovecot_build" package-dovecot ;;
      "Nur Pig"*)     run_build "setup_dovecot.sh" "dovecot_build" package-pigeonhole ;;
      "Nur komp"*)    run_build "setup_dovecot.sh" "dovecot_build" build-only ;;
      *"Verwaltung"*) continue ;;
      "Installieren"*) run_script "setup_dovecot.sh" install ;;
      "Status"*)      run_script "setup_dovecot.sh" status ;;
      "Backups"*)     run_script "setup_dovecot.sh" list-backups ;;
      "Pakete"*)      run_script "setup_dovecot.sh" list-packages ;;
      "Updates"*)     run_script "setup_dovecot.sh" check-updates ;;
      "Konfiguration"*) run_script "setup_dovecot.sh" check-config ;;
      *"Backup"*) continue ;;
      "Backup erstellen"*) run_script "setup_dovecot.sh" backup ;;
      "wiederher"*)   do_restore "setup_dovecot.sh" "dovecot_build" restore ;;
      "Deinstall"*)   run_script "setup_dovecot.sh" uninstall ;;
      "Eigene"*)      do_custom_args "setup_dovecot.sh" ;;
      *)              return ;;
    esac
  done
}

menu_postfix() {
  local ver; ver="$(get_env_var setup_postfix.env POSTFIX_VERSION)"
  while true; do
    clear; draw_header "Postfix ${ver:-}"; echo
    local choice
    choice=$(choose_or_back "" \
      "$(_bold "▶ Pakete bauen")" \
      "Installieren" \
      "Status" \
      "$(_dim "─ Details ─")" \
      "Backups auflisten" \
      "Nach Updates suchen" \
      "Konfiguration pruefen" \
      "Verifikation" \
      "$(_dim "─ Backup ─")" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Pakete"*)      run_build "setup_postfix.sh" "postfix_build" package ;;
      "Installieren"*) run_script "setup_postfix.sh" install ;;
      "Status"*)      run_script "setup_postfix.sh" status ;;
      *"Details"*) continue ;;
      "Backups"*)     run_script "setup_postfix.sh" list-backups ;;
      "Updates"*)     run_script "setup_postfix.sh" check-updates ;;
      "Konfiguration"*) run_script "setup_postfix.sh" check-config ;;
      "Verifikation"*) run_script "setup_postfix.sh" verify ;;
      *"Backup"*) continue ;;
      "Backup erstellen"*) run_script "setup_postfix.sh" backup ;;
      "wiederher"*)   do_restore "setup_postfix.sh" "postfix_build" restore ;;
      "Deinstall"*)   run_script "setup_postfix.sh" uninstall ;;
      "Eigene"*)      do_custom_args "setup_postfix.sh" ;;
      *)              return ;;
    esac
  done
}

menu_zpush() {
  clear; draw_header "Z-Push"; echo
  local choice
  choice=$(choose_or_back "" "Setup ausfuehren" "Eigene Argumente...")
  case "$choice" in
    "Setup"*)  run_script "setup-zpush.sh" ;;
    "Eigene"*) do_custom_args "setup-zpush.sh" ;;
  esac
}

# ===================== LOCAL REPO =====================

repo_info() {
  local envf="$SCRIPT_DIR/setup_local_repo.env" repo_dir=""
  [ -f "$envf" ] && source "$envf"
  repo_dir="${REPO_DIR:-/var/local/custom-repo}"

  local deb_count=0 disk="" signed="nein" apt_ok="--" gpg_s="--"
  if [ -d "$repo_dir" ]; then
    deb_count="$(find "$repo_dir" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)"
    disk="$(du -sh "$repo_dir" 2>/dev/null | cut -f1)"
    [ -f "$repo_dir/InRelease" ] && signed="ja"
  fi
  [ -f /etc/apt/sources.list.d/local-mail-repo.list ] && apt_ok="$(grep -c '^deb ' /etc/apt/sources.list.d/local-mail-repo.list 2>/dev/null || echo 0)" && apt_ok="$((apt_ok > 0))"
  [ -f /etc/apt/keyrings/custom-repo.gpg ] && gpg_s="ja"

  local s_c a_c g_c
  [ "$signed" = "ja" ] && s_c="$G" || s_c="$GR"
  [ "$apt_ok" = "1" ] && a_c="$G" || a_c="$GR"
  [ "$gpg_s" = "ja" ] && g_c="$G" || g_c="$GR"

  echo "$(_col "$P" "$deb_count") Pakete  $(_dim "|")  ${disk:---}  $(_dim "|")  Signiert: $(_col "$s_c" "$signed")  $(_dim "|")  GPG: $(_col "$g_c" "$gpg_s")  $(_dim "|")  apt: $(_col "$a_c" "${apt_ok:-0}")"
}

repo_browse() {
  local envf="$SCRIPT_DIR/setup_local_repo.env" repo_dir=""
  [ -f "$envf" ] && source "$envf"
  repo_dir="${REPO_DIR:-/var/local/custom-repo}"

  if [ ! -d "$repo_dir" ] || ! ls "$repo_dir"/*.deb >/dev/null 2>&1; then
    _dim "Keine Pakete im Repository."; read -r -p " Enter..." _; return
  fi

  local -a items=()
  local deb pkg_size inst_ver="" inst_state
  for deb in "$repo_dir"/*.deb; do
    [ -f "$deb" ] || continue
    pkg_size="$(du -h "$deb" | cut -f1)"
    local pkg_name="" pkg_ver=""
    pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null)"
    pkg_ver="$(dpkg-deb -f "$deb" Version 2>/dev/null)"
    inst_ver="$(dpkg-query -W -f '${Version}' "$pkg_name" 2>/dev/null || true)"
    if [ -n "$inst_ver" ]; then
      if [ "$inst_ver" = "$pkg_ver" ]; then
        inst_state="$(_ok "✔")"
      else
        inst_state="$(_warn "↑${inst_ver}")"
      fi
    else
      inst_state="$(_dim "○")"
    fi
    items+=("${pkg_name:-$(basename "$deb")}  ${pkg_ver:---}  ${pkg_size}  ${inst_state}")
  done

  clear; draw_header "Repo: Pakete durchsuchen"; echo
  local sel
  sel=$(printf '%s\n' "${items[@]}" | fzf \
    --header="Paket                Version       Size   Status" \
    --height=~30 --layout=reverse-list --no-sort --ansi \
    --color="fg:#aaaaaa,fg+:#ffffff,bg+:#1a1a2e,hl:#51afef,hl+:#51afef,header:#87af87,border:#444444") || return

  [ -z "$sel" ] && return
  local pkg="${sel%% *}"

  clear; draw_header "Paket: $pkg"; echo
  local deb_path; deb_path="$(find "$repo_dir" -maxdepth 1 -name "${pkg}_*.deb" | head -1)"
  if [ -n "$deb_path" ]; then
    draw_box "Metadaten" "$C" "$(dpkg-deb -I "$deb_path" 2>/dev/null)"
    echo
    draw_box "Dateien" "$C" "$(dpkg-deb -c "$deb_path" 2>/dev/null | head -40)"
    echo
  fi
  read -r -p " Enter..." _
}

repo_install_select() {
  local envf="$SCRIPT_DIR/setup_local_repo.env" repo_dir=""
  [ -f "$envf" ] && source "$envf"
  repo_dir="${REPO_DIR:-/var/local/custom-repo}"

  if [ ! -d "$repo_dir" ] || ! ls "$repo_dir"/*.deb >/dev/null 2>&1; then
    _dim "Keine Pakete."; read -r -p " Enter..." _; return
  fi

  local -a items=()
  local deb pkg_name inst_ver
  for deb in "$repo_dir"/*.deb; do
    [ -f "$deb" ] || continue
    pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || basename "$deb")"
    inst_ver="$(dpkg-query -W -f '${Version}' "$pkg_name" 2>/dev/null || true)"
    if [ -n "$inst_ver" ]; then
      items+=("$(_ok "✔") $pkg_name ($inst_ver)")
    else
      items+=("$(_dim "○") $pkg_name")
    fi
  done

  clear; draw_header "Pakete installieren"; echo
  local choices
  choices=$(printf '%s\n' "${items[@]}" | fzf --multi \
    --header="Tab = auswaehlen | Enter = installieren | ESC = abbrechen" \
    --height=~25 --layout=reverse-list --no-sort --ansi \
    --color="fg:#aaaaaa,fg+:#ffffff,bg+:#1a1a2e,hl:#51afef,hl+:#51afef,marker:#51afef,pointer:#51afef,header:#87af87,border:#444444") || return

  [ -z "$choices" ] && { _dim "Nichts ausgewaehlt."; return; }

  local -a to_install=()
  while IFS= read -r line; do
    local p="$(echo "$line" | awk '{print $2}')"
    to_install+=("$p")
  done <<< "$choices"

  echo
  draw_box "apt install" "$B" "$(_bold "${#to_install[@]} Paket(e):")  ${to_install[*]}"
  ask_confirm "Installieren?" || return

  DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}"
  echo; _ok "Fertig."; read -r -p " Enter..." _
}

repo_sync() {
  local envf="$SCRIPT_DIR/setup_local_repo.env"
  [ -f "$envf" ] && source "$envf"
  local repo_dir="${REPO_DIR:-/var/local/custom-repo}"
  local -a pkg_dirs=()
  local d
  for d in "${DOVECOT_PKG_DIR:-}" "${POSTFIX_PKG_DIR:-}" "${NGINX_PKG_DIR:-}" "${PHP_PKG_DIR:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && pkg_dirs+=("$d")
  done

  [ ${#pkg_dirs[@]} -eq 0 ] && { _dim "Keine Quellen."; read -r -p " Enter..." _; return; }

  echo
  local total_new=0 nl=$'\n' lines=""
  for d in "${pkg_dirs[@]}"; do
    local label="$(basename "$d")"
    if ! ls "$d"/*.deb >/dev/null 2>&1; then
      lines+="$(_dim "○ $label: leer")${nl}"; continue
    fi
    local new=0
    for deb in "$d"/*.deb; do
      [ -f "$deb" ] && [ ! -f "$repo_dir/$(basename "$deb")" ] && new=$((new + 1))
    done
    if [ "$new" -gt 0 ]; then
      lines+="$(_ok "✔ $label: $new neu")${nl}"
      total_new=$((total_new + new))
    else
      lines+="$(_dim "○ $label: aktuell")${nl}"
    fi
  done

  if [ "$total_new" -eq 0 ]; then
    draw_box "Sync" "$GR" "$lines" "$(_dim "Alles aktuell")"
    read -r -p " Enter..." _; return
  fi

  draw_box "Sync: $total_new neu" "$Y" "$lines"
  ask_confirm "Synchronisieren + Index aktualisieren?" || return
  run_script "setup_local_repo.sh" update
}

menu_localrepo() {
  while true; do
    clear; draw_header "Lokales APT-Repository" "$(repo_info)"; echo
    local choice
    choice=$(choose_or_back "" \
      "$(_bold "Repo einrichten")" \
      "$(_ok "Pakete synchronisieren")" \
      "$(_col "$C" "Pakete durchsuchen")" \
      "$(_col "$B" "Pakete installieren")" \
      "$(_dim "─ Verwaltung ─")" \
      "Status (Detail)" \
      "GPG Schluessel erzeugen" \
      "Public Key exportieren" \
      "Release neu signieren" \
      "Alle DEBs signieren" \
      "$(_fail "Repo entfernen")" \
      "Eigene Argumente...")
    case "$choice" in
      "einrichten"*)       run_script "setup_local_repo.sh" install ;;
      "synchronisieren"*)  repo_sync ;;
      "durchsuchen"*)      repo_browse ;;
      "installieren"*)     repo_install_select ;;
      *"Verwaltung"*) continue ;;
      "Status"*)           run_script "setup_local_repo.sh" status ;;
      "GPG"*)              run_script "setup_local_repo.sh" init-gpg ;;
      "Public"*)           run_script "setup_local_repo.sh" export-key ;;
      "Release"*)          run_script "setup_local_repo.sh" sign-repo ;;
      "DEBs"*)             run_script "setup_local_repo.sh" sign-debs ;;
      "entfernen"*)        ask_confirm "Repository wirklich entfernen?" && run_script "setup_local_repo.sh" uninstall ;;
      "Eigene"*)           do_custom_args "setup_local_repo.sh" ;;
      *)                   return ;;
    esac
  done
}

# ===================== MORE MENUS =====================

menu_backuprestore() {
  while true; do
    clear; draw_header "Backup / Restore"; echo
    local choice
    choice=$(choose_or_back "" \
      "$(_bold "▲ Full Backup")" \
      "Nur Postfix" \
      "Nur Dovecot" \
      "Nur Nginx" \
      "$(_dim "─ Restore ─")" \
      "Full Restore" \
      "Postfix Restore" \
      "Dovecot Restore" \
      "Nginx Restore" \
      "$(_dim "─ Aktionen ─")" \
      "Backups auflisten" \
      "Backup verifizieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Full B"*)   run_script "setup_backup_restore.sh" backup ;;
      "Nur Post"*) run_script "setup_backup_restore.sh" backup-postfix ;;
      "Nur Dove"*) run_script "setup_backup_restore.sh" backup-dovecot ;;
      "Nur Ngin"*) run_script "setup_backup_restore.sh" backup-nginx ;;
      *"Restore"*) continue ;;
      "Full R"*)   do_restore "setup_backup_restore.sh" "-" restore ;;
      "Postfix R"*) do_restore "setup_backup_restore.sh" "-" restore-postfix ;;
      "Dovecot R"*) do_restore "setup_backup_restore.sh" "-" restore-dovecot ;;
      "Nginx R"*)  do_restore "setup_backup_restore.sh" "-" restore-nginx ;;
      *"Aktionen"*) continue ;;
      "auflisten"*) run_script "setup_backup_restore.sh" list ;;
      "verifizieren"*) do_restore "setup_backup_restore.sh" "-" verify ;;
      "Eigene"*)   do_custom_args "setup_backup_restore.sh" ;;
      *)           return ;;
    esac
  done
}

menu_unbanip() {
  while true; do
    clear; draw_header "IP Unban"; echo
    local choice
    choice=$(choose_or_back "" "Automatikmodus" "Bans anzeigen" "Gezieltes Unban" "Eigene Argumente...")
    case "$choice" in
      "Automatik"*)
        local domain prefix; local -a args=()
        domain="$(gum input --placeholder='Domain (leer = default)')" || continue
        prefix="$(gum input --placeholder='IPv6 Prefix (leer = default)')" || continue
        [ -n "${domain// }" ] && args+=(--domain "$domain")
        [ -n "${prefix// }" ] && args+=(--prefix-length "$prefix")
        ask_confirm "Dry-Run?" && args+=(--test)
        run_script "unban_ip.sh" "${args[@]}" ;;
      "Bans"*)  run_script "unban_ip.sh" --bans ;;
      "Geziel"*)
        local t; t="$(gum input --placeholder='IP / CIDR / Domain')" || continue
        [ -z "${t// }" ] && { _fail "Kein Target."; continue; }
        run_script "unban_ip.sh" --unban "$t" ;;
      "Eigene"*) do_custom_args "unban_ip.sh" ;;
      *)        return ;;
    esac
  done
}

menu_f2btest() {
  clear; draw_header "Fail2Ban Test"; echo
  local choice
  choice=$(choose_or_back "" "Test ausfuehren" "Eigene Argumente...")
  case "$choice" in
    "Test"*)  run_script "f2b_test.sh" ;;
    "Eigene"*) do_custom_args "f2b_test.sh" ;;
  esac
}

# ===================== SYSTEM MENUS =====================

menu_clean() {
  while true; do
    clear; draw_header "Build-Artefakte loeschen"; echo
    local choice
    choice=$(choose_or_back "" \
      "$(_col "$P" "PHP:") Staging" \
      "$(_col "$P" "PHP:") Build-Dir" \
      "$(_col "$P" "PHP:") PECL-Quellen" \
      "$(_col "$P" "PHP:") PGO-Profile" \
      "$(_col "$P" "PHP:") Pakete (.deb)" \
      "$(_fail "PHP: ALLES")" \
      "$(_dim "─ Weitere ─")" \
      "$(_col "$G" "Nginx:") Staging" \
      "$(_col "$Y" "Dovecot:") Staging" \
      "$(_col "$B" "Postfix:") Staging" \
      "Alle Staging" \
      "$(_fail "ALLE Artefakte")")

    [ "$choice" = "Zurueck" ] && return
    ask_confirm "$(_dim "$choice")  wirklich loeschen?" || continue

    local PE="setup_php.env" NE="setup_nginx.env" DE="setup_dovecot.env" FE="setup_postfix.env"

    case "$choice" in
      "PHP: S"*)  rm -rf "$(get_env_var "$PE" STAGE_PHP)" ;;
      "PHP: B"*)  rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-$(get_env_var "$PE" PHP_VERSION)" ;;
      "PHP: P"*)  rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-pecl" ;;
      "PHP: G"*)  rm -rf /tmp/php-pgo-stage ;;
      "PHP: Pak"*) rm -f "$(get_env_var "$PE" PACKAGE_DIR)"/*.deb 2>/dev/null ;;
      "PHP: A"*)
        rm -rf "$(get_env_var "$PE" STAGE_PHP)"
        rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-$(get_env_var "$PE" PHP_VERSION)"
        rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-pecl"
        rm -rf /tmp/php-pgo-stage
        rm -f "$(get_env_var "$PE" PACKAGE_DIR)"/*.deb 2>/dev/null ;;
      "Nginx"*)   rm -rf "$(get_env_var "$NE" STAGE_NGINX)" ;;
      "Dovecot"*) rm -rf "$(get_env_var "$DE" STAGE_DOVECOT)" ;;
      "Postfix"*) rm -rf "$(get_env_var "$FE" STAGE_POSTFIX)" ;;
      "Alle S"*)
        rm -rf "$(get_env_var "$PE" STAGE_PHP)"
        rm -rf "$(get_env_var "$NE" STAGE_NGINX)"
        rm -rf "$(get_env_var "$DE" STAGE_DOVECOT)"
        rm -rf "$(get_env_var "$FE" STAGE_POSTFIX)" ;;
      "ALLE"*)
        rm -rf "$(get_env_var "$PE" STAGE_PHP)"
        rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-$(get_env_var "$PE" PHP_VERSION)"
        rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-pecl" /tmp/php-pgo-stage
        rm -f "$(get_env_var "$PE" PACKAGE_DIR)"/*.deb 2>/dev/null
        rm -rf "$(get_env_var "$NE" STAGE_NGINX)" "$(get_env_var "$NE" BUILD_ROOT)/nginx-$(get_env_var "$NE" NGINX_VERSION)"
        rm -rf "$(get_env_var "$DE" STAGE_DOVECOT)" "$(get_env_var "$FE" STAGE_POSTFIX)" ;;
    esac
    _ok "✔ Bereinigt."; read -r -p " Enter..." _
  done
}

menu_settings() {
  while true; do
    clear; draw_header "Build-Einstellungen"; echo

    local pgo_s lto_s force_s
    [ "$USE_PGO" = "yes" ]       && pgo_s="$(_ok "AN")"   || pgo_s="$(_dim "AUS")"
    [ "$USE_LTO" = "yes" ]       && lto_s="$(_ok "AN")"   || lto_s="$(_dim "AUS")"
    [ "$FORCE_REBUILD" = "yes" ]  && force_s="$(_warn "AN")"  || force_s="$(_dim "AUS")"

    draw_box "Aktuelle Einstellungen" "$C" \
      "$(printf '  %-16s %s   %s\n' "PGO" "$pgo_s" "$(_dim "Profile-Guided Optimization")")" \
      "$(printf '  %-16s %s   %s\n' "LTO" "$lto_s" "$(_dim "Link-Time Optimization")")" \
      "$(printf '  %-16s %s   %s\n' "Force-Rebuild" "$force_s" "$(_dim "Alle Pakete neu bauen")")" \
      "$(_dim "  Screen wird pro Build abgefragt")"
    echo

    local choice
    choice=$(choose_or_back "" "PGO umschalten" "LTO umschalten" "Force-Rebuild umschalten" "Auf Defaults zuruecksetzen")
    case "$choice" in
      "PGO"*)    [ "$USE_PGO" = "yes" ] && USE_PGO="no" || USE_PGO="yes"; save_settings ;;
      "LTO"*)    [ "$USE_LTO" = "yes" ] && USE_LTO="no" || USE_LTO="yes"; save_settings ;;
      "Force"*)  [ "$FORCE_REBUILD" = "yes" ] && FORCE_REBUILD="no" || FORCE_REBUILD="yes"; save_settings ;;
      "Defaults"*) FORCE_REBUILD="no" USE_PGO="yes" USE_LTO="yes"; save_settings; _ok "Reset."; read -r -p " Enter..." _ ;;
      *)         return ;;
    esac
  done
}

menu_sysinfo() {
  clear; draw_header "System-Info"; echo

  local cpu ram disk kernel uptime
  cpu="$(lscpu 2>/dev/null | grep -E '^(Architecture|CPU\(s\)|Model name|Thread|Core|Socket|CPU max)' | sed 's/^/  /')"
  ram="$(free -h 2>/dev/null | head -3 | sed 's/^/  /')"
  disk="$(df -h / 2>/dev/null | head -2 | sed 's/^/  /')"
  kernel="$(uname -a 2>/dev/null | sed 's/^/  /')"
  uptime="$(uptime 2>/dev/null | sed 's/^/  /')"

  local nl=$'\n'
  local sections=()
  sections+=("$(gum style --border rounded --padding "0 1" --foreground "$C" -- "$(gum style --bold --foreground "$C" -- " CPU ")${nl}$cpu")")
  sections+=("$(gum style --border rounded --padding "0 1" --foreground "$G" -- "$(gum style --bold --foreground "$G" -- " RAM ")${nl}$ram")")
  sections+=("$(gum style --border rounded --padding "0 1" --foreground "$Y" -- "$(gum style --bold --foreground "$Y" -- " Disk ")${nl}$disk")")

  gum join --align left --vertical "${sections[@]}"
  echo

  gum style --border rounded --padding "0 1" --foreground "$P" -- "$(gum style --bold --foreground "$P" -- " Kernel ")${nl}$kernel"
  echo
  gum style --border rounded --padding "0 1" --foreground "$B" -- "$(gum style --bold --foreground "$B" -- " Uptime ")${nl}$uptime"
  echo
  read -r -p " Enter fuer Menue..." _
}

check_all_updates() {
  clear; draw_header "Update-Check"; echo
  _bold "Pruefe alle Updates..."; echo

  draw_box "Nginx" "$G" "$(bash "$SCRIPT_DIR/setup_nginx.sh" check-updates 2>&1 || true)"
  echo
  draw_box "Dovecot" "$Y" "$(bash "$SCRIPT_DIR/setup_dovecot.sh" check-updates 2>&1 || true)"
  echo
  draw_box "Postfix" "$B" "$(bash "$SCRIPT_DIR/setup_postfix.sh" check-updates 2>&1 || true)"
  echo
  _ok "✔ Fertig."; read -r -p " Enter fuer Menue..." _
}

git_update() {
  [ -d "$SCRIPT_DIR/.git" ] || return
  local output
  output="$(git -C "$SCRIPT_DIR" pull 2>&1)" || { _fail "git pull fehlgeschlagen"; return; }
  echo "$output" | grep -qi "already up.to.date\|current" && return
  local nl=$'\n'
  draw_box "Scripts aktualisiert" "$Y" "$output" "${nl}Neustart in 2s..."
  sleep 2
  exec bash "$0" "$@"
}

# ===================== MAIN =====================

main_menu() {
  local php_ver nginx_ver postfix_ver
  php_ver="$(get_env_var setup_php.env PHP_VER_SHORT)"
  nginx_ver="$(get_env_var setup_nginx.env NGINX_VERSION)"
  postfix_ver="$(get_env_var setup_postfix.env POSTFIX_VERSION)"

  while true; do
    clear; draw_header "SERVER MANAGEMENT"; echo

    local sc; sc="$(screen_count)"
    local screen_label="Screens"
    [ "$sc" -gt 0 ] && screen_label="Screens ($(_warn "$sc aktiv"))"

    local choice
    choice=$(choose "" \
      "$(_col "$P" "●") PHP ${php_ver:-}" \
      "$(_col "$G" "●") Nginx ${nginx_ver:-}" \
      "$(_col "$Y" "●") Dovecot" \
      "$(_col "$B" "●") Postfix ${postfix_ver:-}" \
      "$(_dim "─── Dienste ─────────")" \
      "Z-Push ActiveSync" \
      "Backup / Restore" \
      "Lokales Repository" \
      "$(_dim "─── Tools ──────────")" \
      "IP Unban" \
      "Fail2Ban Test" \
      "$screen_label" \
      "$(_dim "─── System ─────────")" \
      "Clean" \
      "Settings" \
      "System-Info" \
      "Updates pruefen" \
      "$(_fail "Beenden")") || break

    case "$choice" in
      PHP*)       menu_php ;;
      Nginx*)     menu_nginx ;;
      Dovecot*)   menu_dovecot ;;
      Postfix*)   menu_postfix ;;
      *"Dienste"*) continue ;;
      Z-Push*)    menu_zpush ;;
      Backup*)    menu_backuprestore ;;
      Lokales*)   menu_localrepo ;;
      *"Tools"*) continue ;;
      IP*)        menu_unbanip ;;
      Fail2Ban*)  menu_f2btest ;;
      Screen*|"Screens"*) menu_screens ;;
      *"System"*) continue ;;
      Clean*)     menu_clean ;;
      Settings*)  menu_settings ;;
      System*)    menu_sysinfo ;;
      Updates*)   check_all_updates ;;
      Beenden*)   break ;;
    esac
  done
}

load_settings
ensure_root "$@"
ensure_deps
git_update "$@"
ensure_scripts
ensure_env_files
main_menu
clear
