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
    screen_cache="$(screen -list 2>/dev/null || echo "")"
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
    mkdir -p /etc/apt/keyrings || { echo "Fehler: Kann /etc/apt/keyrings nicht erstellen" >&2; exit 1; }
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null || { echo "Fehler: Charm GPG key download fehlgeschlagen" >&2; exit 1; }
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list || { echo "Fehler: Kann sources.list.d nicht schreiben" >&2; exit 1; }
  fi
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y gum fzf curl 2>/dev/null || { echo "apt-get install fehlgeschlagen" >&2; exit 1; }
  command -v gum >/dev/null 2>&1 || { echo "gum fehlgeschlagen"; exit 1; }
}

ensure_root() {
  [ "$(id -u)" -eq 0 ] && return
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  echo "Root erforderlich." >&2
  exit 1
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
  if [ -f /proc/meminfo ]; then
    m="$(awk '/MemTotal/{printf "%.0fG",$2/1048576}' /proc/meminfo)" || m="?"
  else
    m="?"
  fi
  a="$(uname -m 2>/dev/null || echo '?')"
  SYS_LINE="$h  │  ${c}C  │  ${m}  │  $a"
}

draw_header() {
  local title="${1:-}" extras="${2:-}"
  cache_sys_info
  local nl=$'\n'

  local sc; sc="$(screen_count)"

  local title_block=""
  if [ -n "$title" ]; then
    title_block="$(gum style --bold --foreground "$C" -- "$title")${nl}"
  fi

  local badge_line
  badge_line="$(badge PGO "$USE_PGO")  $(badge LTO "$USE_LTO")  $(badge Force "$FORCE_REBUILD")"

  local info_line=""
  [ "$sc" -gt 0 ] && info_line="${nl}$(gum style --foreground "$Y" -- "⚡ $sc Session(s)")"
  [ -n "$extras" ] && info_line+="${nl}$extras"

  local top="$title_block$(gum style --foreground 254 -- "$SYS_LINE")${nl}${badge_line}${info_line}"
  gum style --border double --padding "0 3" --align center --foreground "$C" -- "$top"
}

draw_banner() {
  local nl=$'\n'
  local sc; sc="$(screen_count)"
  cache_sys_info

  local uptime_s; uptime_s="$(cat /proc/uptime 2>/dev/null | awk '{printf "%.0f", $1}' || echo 0)"
  local uptime_display=""
  if [ "$uptime_s" -ge 86400 ]; then
    uptime_display="$(printf '%dd%dh' $((uptime_s/86400)) $((uptime_s%86400/3600)))"
  elif [ "$uptime_s" -ge 3600 ]; then
    uptime_display="$(printf '%dh%dm' $((uptime_s/3600)) $((uptime_s%3600/60)))"
  else
    uptime_display="$(printf '%dm' $((uptime_s/60)))"
  fi

  local load; load="$(awk '{printf "%.1f %.1f %.1f", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "- - -")"

  local logo
  logo="$(gum style --bold --foreground "$C" -- '  ╔═══════════════════════════════╗')
$(gum style --bold --foreground "$C" -- '  ║     SERVER  MANAGEMENT       ║')
$(gum style --bold --foreground "$C" -- '  ╚═══════════════════════════════╝')"

  local info_bar
  info_bar="$(gum style --foreground 254 -- "$SYS_LINE")"

  local badge_line
  badge_line="$(badge PGO "$USE_PGO")  $(badge LTO "$USE_LTO")  $(badge Force "$FORCE_REBUILD")"

  local screen_line=""
  [ "$sc" -gt 0 ] && screen_line="${nl}$(gum style --foreground "$Y" -- "⚡ $sc Session(s)")"

  local stats_line
  stats_line="$(gum style --foreground "$GR" -- "  Up: $uptime_display  │  Load: $load")"

  local footer
  footer="$(gum style --foreground "$GR" -- '  ↑↓ Navigate  │  Enter Select  │  ESC Back')"

  local full="${logo}${nl}${nl}${info_bar}${nl}${stats_line}${nl}${badge_line}${screen_line}${nl}${nl}${footer}"
  gum style --padding "1 2" -- "$full"
}

draw_box() {
  local title="$1" color="${2:-$C}"; shift 2
  local nl=$'\n'
  local body
  body="$(printf '%s\n' "$@")"
  gum style --border rounded --padding "0 1" --foreground "$color" -- \
    "$(gum style --bold --foreground "$color" -- " $title ")${nl}${body}"
}

sep() { echo "────────────────────────────────"; }

choose() {
  local hdr="${1:-}"; shift
  printf '%s\n' "$@" | gum choose --header="$hdr" \
    --cursor=" ❯ " --cursor.foreground="$C" --selected.foreground="$G" --height=30
}

choose_or_back() { choose "$@" "Zurück" || echo "Zurück"; }

ask_path()    { gum input --placeholder="Pfad (leer = latest)" 3>/dev/null || echo ""; }
ask_confirm() { local msg="$1"; shift; gum confirm "$msg" "$@" 2>/dev/null; }
ask_screen()  {
  gum confirm "Build im Screen starten?" --affirmative="Screen (Hintergrund)" --negative="Vordergrund (direkt)"
}

# ===================== RUNNERS =====================

is_build_script() {
  case "$1" in
    setup_php.sh|setup_nginx.sh|setup_dovecot.sh|setup_postfix.sh) return 0 ;;
    *) return 1 ;;
  esac
}

auto_repo_sync() {
  local envf="$SCRIPT_DIR/setup_local_repo.env"
  [ -f "$envf" ] || return 0
  source "$envf"
  [ -d "${REPO_DIR:-}" ] || return 0
  [ -f "$SCRIPT_DIR/setup_local_repo.sh" ] || return 0

  echo
  if ask_confirm "Pakete ins Repo synchronisieren?"; then
    bash "$SCRIPT_DIR/setup_local_repo.sh" update 2>&1 | tail -5
  fi
}

run_script() {
  local script="$1"; shift
  local path="$SCRIPT_DIR/$script"
  [ -f "$path" ] || { echo "Nicht gefunden: $path"; read -r -p " Enter..."; return 1; }
  chmod 755 "$path" 2>/dev/null || true

  local start_s="$SECONDS"
  echo
  FORCE_REBUILD="$FORCE_REBUILD" USE_PGO="$USE_PGO" USE_LTO="$USE_LTO" bash "$path" "$@"
  local rc=$?
  local duration=$((SECONDS - start_s))
  local dur_str=""
  if [ "$duration" -ge 3600 ]; then
    dur_str="$(printf '%dh%dm%ds' $((duration/3600)) $((duration%3600/60)) $((duration%60)))"
  elif [ "$duration" -ge 60 ]; then
    dur_str="$(printf '%dm%ds' $((duration/60)) $((duration%60)))"
  else
    dur_str="${duration}s"
  fi
  echo
  if [ "$rc" -eq 0 ]; then
    _ok "✔ Fertig (OK)  ${dur_str}"
    is_build_script "$script" && auto_repo_sync
  else
    _fail "✘ Fertig (Exit: $rc)  ${dur_str}"
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
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y screen >/dev/null 2>&1 || { _fail "screen-Installation fehlgeschlagen"; return 1; }
  fi

  if screen_active "$sname"; then
    echo
    draw_box "Session laeuft bereits" "$Y" \
      "Name:   $sname" \
      "Status: $(screen_state "$sname")" \
      "Uptime: $(screen_uptime "$sname")"
    echo
    if ask_confirm "Anhaengen? (Strg+A D zum Trennen)"; then
      clear
      screen -r "$sname"
      clear
    fi
    return 0
  fi

  local logfile; logfile="$(get_log_for_screen "$sname")"
  local log_redirect=""
  [ -n "$logfile" ] && log_redirect="2>&1 | tee '$logfile'"

  local args_str="" a
  for a in "$@"; do args_str+=" '${a//\'/\'\\\'\'}'"; done
  local sync_cmd=""
  is_build_script "$script" && sync_cmd="echo ''; echo 'Repo-Sync: $SCRIPT_DIR/setup_local_repo.sh update'; echo ''"
  screen -dmS "$sname" bash -c "
    set -o pipefail
    export FORCE_REBUILD='${FORCE_REBUILD}' USE_PGO='${USE_PGO}' USE_LTO='${USE_LTO}'
    bash '${path}'${args_str} ${log_redirect}
    _rc=\$?
    echo ''; echo '=== Fertig (rc='\$_rc') ==='; echo 'Strg+A D = Trennen'; echo ''
    ${sync_cmd}
    if [ \$_rc -eq 0 ]; then echo '✔ Build erfolgreich - Session schliesst in 30s'; else echo '✘ Build fehlgeschlagen (rc='\$_rc') - Session bleibt offen'; read -r _; fi
    sleep 30
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
  [ -n "$a" ] && run_script "$script" "$a"
}

# ===================== SCREEN MENU =====================

menu_screens() {
  while true; do
    clear; draw_header "Screen Sessions"; echo

    local -a items=() snames=() states=() log_items=()
    for entry in "${SCREEN_MAP[@]}"; do
      IFS=: read -r sn sc <<< "$entry"
      local label="${sn%_build}" line
      if screen_active "$sn"; then
        local pid up st
        pid="$(screen_pid "$sn")"
        up="$(screen_uptime "$sn")"
        st="$(screen_state "$sn")"
        if [ "$st" = "Detached" ]; then
          line="$(_ok "●") $label  PID:${pid:--}  ${up:--}  $st"
        else
          line="$(_ok "●") $label  PID:${pid:--}  ${up:--}  $(_warn "$st")"
        fi
        states+=("active")
      else
        line="$(_dim "○") $label  ---"
        states+=("inactive")
      fi
      items+=("$line")
      snames+=("$sn")
    done

    for entry in "${SCREEN_MAP[@]}"; do
      IFS=: read -r sn sc <<< "$entry"
      local logpath; logpath="$(get_log_for_screen "$sn")"
      if [ -n "$logpath" ] && [ -f "$logpath" ]; then
        local logsize; logsize="$(stat -c%s "$logpath" 2>/dev/null | awk '{if ($1<1024) print $1"B"; else if ($1<1048576) printf "%.1fK\n",$1/1024; else printf "%.1fM\n",$1/1048576}')"
        log_items+=("${sn%_build}: $logsize $logpath")
      fi
    done

    local choice
    choice=$(choose_or_back "" \
      "${items[@]}" \
      "$(sep)" \
      "Alle Sessions beenden" \
      "Logs anzeigen...") || return

    case "$choice" in
      "Zurück") return ;;
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
      *"──"*) continue ;;
      *)
        local match_idx=-1
        local i=0
        for item in "${items[@]}"; do
          if [ "$item" = "$choice" ]; then
            match_idx=$i
            break
          fi
          i=$((i + 1))
        done
        [ "$match_idx" -lt 0 ] && continue

        local found_sn="${snames[$match_idx]}"
        local found_state="${states[$match_idx]}"
        local found_label="${found_sn%_build}"

        if [ "$found_state" = "active" ]; then
          echo
          draw_box "Session: $found_sn" "$G" \
            "Status:  $(screen_state "$found_sn")" \
            "Uptime:  $(screen_uptime "$found_sn")" \
            "PID:     $(screen_pid "$found_sn")"
          echo
          local action
          action=$(choose "" "Anhaengen (screen -r)" "Beenden (screen -X quit)" "Abbrechen") || continue
          case "$action" in
            "Anhaengen"*)
              clear
              screen -r "$found_sn"
              clear ;;
            "Beenden"*)
              ask_confirm "'$found_sn' beenden?" || continue
              screen -X -S "$found_sn" quit 2>/dev/null
              _ok "$found_label beendet."
              read -r -p " Enter..." _ ;;
          esac
        else
          echo
          draw_box "$found_label" "$GR" "Session nicht aktiv"
          echo
          local action
          action=$(choose "" "Starten (Build)" "Abbrechen") || continue
          case "$action" in
            "Starten"*)
              local sc=""
              for entry in "${SCREEN_MAP[@]}"; do
                IFS=: read -r sn s <<< "$entry"
                [ "$sn" = "$found_sn" ] && sc="$s" && break
              done
              [ -n "$sc" ] && run_build "$sc" "$found_sn" package ;;
          esac
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
  while IFS= read -r ext; do
    [ -n "$ext" ] && ext_names+=("$ext")
  done < <(sed -n '/^PECL_EXTENSIONS=(/,/^)/p' "$SCRIPT_DIR/setup_php.sh" 2>/dev/null \
    | grep -oE '^[[:space:]]+[a-z][a-z0-9_-]*' | sed 's/^[[:space:]]*//')

  if [ ${#ext_names[@]} -eq 0 ]; then
    _fail "Keine Extensions in setup_php.sh gefunden."
    read -r -p " Enter..." _
    return
  fi

  local items=() missing=0 total=0
  local ext desc pkg_name line
  for ext in "${ext_names[@]}"; do
    total=$((total + 1))
    desc="$(grep -oP "PECL_DESC\\[$ext\\]=\"\\K[^\"]+" "$SCRIPT_DIR/setup_php.sh" 2>/dev/null || echo "$ext")"
    pkg_name="$(grep -oP "PECL_PKGNAME\\[$ext\\]=\"\\K[^\"]+" "$SCRIPT_DIR/setup_php.sh" 2>/dev/null || echo "$ext")"
    if compgen -G "${pkg_dir}/php${ver}-${pkg_name}_*_*.deb" >/dev/null 2>&1; then
      printf -v line "%-20s [OK]    %s" "$ext" "$desc"
    else
      printf -v line "%-20s [ -- ]  %s" "$ext" "$desc"
      missing=$((missing + 1))
    fi
    items+=("$line")
  done

  clear
  local ok_n=$((total - missing))
  draw_header "PECL Extensions" "$ok_n OK  |  $missing fehlen  |  $total gesamt"
  echo

  local choices
  choices=$(printf '%s\n' "${items[@]}" | fzf --multi \
    --header="Tab = auswaehlen | Enter = starten | ESC = abbrechen" \
    --height=~25 --layout=reverse-list --no-sort \
    --marker=">" --pointer=">" \
    --color="fg:#aaaaaa,fg+:#ffffff,bg+:#1a1a2e,hl:#51afef,hl+:#51afef,marker:#51afef,pointer:#51afef,header:#87af87,gutter:#444444,border:#444444" \
    --bind 'tab:toggle' --delimiter=' ' --nth=1) || return 0

  if [ -z "$choices" ]; then
    _dim "Nichts ausgewaehlt."
    return
  fi

  local ext_list=()
  while IFS= read -r line; do
    ext_list+=("${line%% *}")
  done <<< "$choices"

  echo
  _bold "${#ext_list[@]} Extension(s): ${ext_list[*]}"
  echo
  ask_confirm "Starten? (PGO=$USE_PGO  LTO=$USE_LTO)" || return 0

  run_build "setup_php.sh" "php_build" pecl-only "${ext_list[@]}"
}

# ===================== SUB-MENUS =====================

menu_php() {
  local ver pkg_count=0
  ver="$(get_env_var setup_php.env PHP_VER_SHORT)"
  source "$SCRIPT_DIR/setup_php.env" 2>/dev/null || true
  [ -d "${PACKAGE_DIR:-/root/php-packages}" ] && pkg_count="$(find "${PACKAGE_DIR:-/root/php-packages}" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | wc -l)"

  while true; do
    clear; draw_header "PHP ${ver:-}" "$(_col "$P" "$pkg_count") Pakete"; echo
    local choice
    choice=$(choose_or_back "" \
      "Komplett-Build" \
      "Force-Rebuild (alles neu)" \
      "Einzelne Extension(en)..." \
      "$(sep)" \
      "Installieren" \
      "Status" \
      "Pakete auflisten" \
      "Extensions auflisten" \
      "Konfiguration pruefen" \
      "Verifikation" \
      "$(sep)" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Backups auflisten" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Komplett"*)   run_build "setup_php.sh" "php_build" package ;;
      "Force"*)      FORCE_REBUILD=yes run_build "setup_php.sh" "php_build" package ;;
      "Einzelne"*)   menu_php_ext_select ;;
      *"──"*)        continue ;;
      "Installieren"*) run_script "setup_php.sh" install ;;
      "Status"*)     run_script "setup_php.sh" status ;;
      "Pakete"*)     run_script "setup_php.sh" list-packages ;;
      "Extensions"*) run_script "setup_php.sh" list-extensions ;;
      "Konfiguration"*) run_script "setup_php.sh" check-config ;;
      "Verifikation"*) run_script "setup_php.sh" verify ;;
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
      "Pakete bauen" \
      "Installieren" \
      "Status" \
      "$(sep)" \
      "Module auflisten" \
      "Backups auflisten" \
      "Nach Updates suchen" \
      "Konfiguration pruefen" \
      "Verifikation" \
      "$(sep)" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Pakete"*)      run_build "setup_nginx.sh" "nginx_build" package ;;
      "Installieren"*) run_script "setup_nginx.sh" install ;;
      "Status"*)      run_script "setup_nginx.sh" status ;;
      *"──"*)         continue ;;
      "Module"*)      run_script "setup_nginx.sh" list-modules ;;
      "Backups"*)     run_script "setup_nginx.sh" list-backups ;;
      "Updates"*)     run_script "setup_nginx.sh" check-updates ;;
      "Konfiguration"*) run_script "setup_nginx.sh" check-config ;;
      "Verifikation"*) run_script "setup_nginx.sh" verify ;;
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
      "Komplett-Build" \
      "Nur Dovecot-Core" \
      "Nur Pigeonhole" \
      "Nur kompilieren" \
      "$(sep)" \
      "Installieren" \
      "Status" \
      "Backups auflisten" \
      "Pakete auflisten" \
      "Nach Updates suchen" \
      "Konfiguration pruefen" \
      "$(sep)" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Komplett"*)    run_build "setup_dovecot.sh" "dovecot_build" package ;;
      "Nur Dovecot"*) run_build "setup_dovecot.sh" "dovecot_build" package-dovecot ;;
      "Nur Pig"*)     run_build "setup_dovecot.sh" "dovecot_build" package-pigeonhole ;;
      "Nur komp"*)    run_build "setup_dovecot.sh" "dovecot_build" build-only ;;
      *"──"*)         continue ;;
      "Installieren"*) run_script "setup_dovecot.sh" install ;;
      "Status"*)      run_script "setup_dovecot.sh" status ;;
      "Backups"*)     run_script "setup_dovecot.sh" list-backups ;;
      "Pakete"*)      run_script "setup_dovecot.sh" list-packages ;;
      "Updates"*)     run_script "setup_dovecot.sh" check-updates ;;
      "Konfiguration"*) run_script "setup_dovecot.sh" check-config ;;
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
      "Pakete bauen" \
      "Installieren" \
      "Status" \
      "$(sep)" \
      "Backups auflisten" \
      "Nach Updates suchen" \
      "Konfiguration pruefen" \
      "Verifikation" \
      "$(sep)" \
      "Backup erstellen" \
      "Backup wiederherstellen" \
      "Deinstallieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Pakete"*)      run_build "setup_postfix.sh" "postfix_build" package ;;
      "Installieren"*) run_script "setup_postfix.sh" install ;;
      "Status"*)      run_script "setup_postfix.sh" status ;;
      *"──"*)         continue ;;
      "Backups"*)     run_script "setup_postfix.sh" list-backups ;;
      "Updates"*)     run_script "setup_postfix.sh" check-updates ;;
      "Konfiguration"*) run_script "setup_postfix.sh" check-config ;;
      "Verifikation"*) run_script "setup_postfix.sh" verify ;;
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

  local t_dir="$repo_dir/testing" s_dir="$repo_dir/stable"
  local t_count=0 s_count=0 disk="" t_signed="nein" s_signed="nein" apt_ok="--" gpg_s="--"
  if [ -d "$t_dir" ]; then
    t_count="$(find "$t_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | wc -l)"
    [ -f "$t_dir/InRelease" ] && t_signed="ja"
  fi
  if [ -d "$s_dir" ]; then
    s_count="$(find "$s_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | wc -l)"
    [ -f "$s_dir/InRelease" ] && s_signed="ja"
  fi
  [ -d "$repo_dir" ] && disk="$(du -sh "$repo_dir" 2>/dev/null | cut -f1)"
  [ -f /etc/apt/sources.list.d/xerolux-repo.list ] && apt_ok="1" || apt_ok="0"
  [ -f /etc/apt/keyrings/xerolux-repo.gpg ] && gpg_s="ja"

  local t_c s_c a_c g_c
  [ "$t_signed" = "ja" ] && t_c="$G" || t_c="$GR"
  [ "$s_signed" = "ja" ] && s_c="$G" || s_c="$GR"
  [ "$apt_ok" = "1" ] && a_c="$G" || a_c="$GR"
  [ "$gpg_s" = "ja" ] && g_c="$G" || g_c="$GR"

  echo "$(_col "$P" "$s_count") stable  $(_col "$Y" "$t_count") testing  $(_dim "|")  ${disk:---}  $(_dim "|")  GPG: $(_col "$g_c" "$gpg_s")  $(_dim "|")  apt: $(_col "$a_c" "${apt_ok:-0}")"
}

repo_browse() {
  local envf="$SCRIPT_DIR/setup_local_repo.env" repo_dir=""
  [ -f "$envf" ] && source "$envf"
  repo_dir="${REPO_DIR:-/var/local/custom-repo}"

  local suite_sel
  suite_sel=$(choose "Kanal:" "stable" "testing") || return
  local browse_dir="$repo_dir/$suite_sel"

  if [ ! -d "$browse_dir" ] || ! find "$browse_dir" -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
    _dim "Keine Pakete in $suite_sel."; read -r -p " Enter..." _; return
  fi

  local -a items=()
  while IFS= read -r deb; do
    local pkg_size pkg_name pkg_ver inst_ver inst_state
    [ -f "$deb" ] || continue
    pkg_size="$(stat -c%s "$deb" 2>/dev/null | awk '{if ($1<1024) print $1"B"; else if ($1<1048576) printf "%.1fK\n",$1/1024; else printf "%.1fM\n",$1/1048576}')"
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
  done < <(find "$browse_dir" -maxdepth 1 -name '*.deb' -type f)

  clear; draw_header "Repo: $suite_sel durchsuchen"; echo
  local sel
  sel=$(printf '%s\n' "${items[@]}" | fzf \
    --header="Paket                Version       Size   Status" \
    --height=~30 --layout=reverse-list --no-sort --ansi \
    --color="fg:#aaaaaa,fg+:#ffffff,bg+:#1a1a2e,hl:#51afef,hl+:#51afef,header:#87af87,border:#444444") || return

  if [ -z "$sel" ]; then
    return
  fi
  local pkg="${sel%% *}"

  clear; draw_header "Paket: $pkg ($suite_sel)"; echo
  local deb_path; deb_path="$(find "$browse_dir" -maxdepth 1 -name "${pkg}_*.deb" | head -1)"
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
  local install_dir="$repo_dir/stable"

  if [ ! -d "$install_dir" ] || ! find "$install_dir" -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
    _dim "Keine Pakete in stable/."; read -r -p " Enter..." _; return
  fi

  local -a items=()
  while IFS= read -r deb; do
    local pkg_name inst_ver
    [ -f "$deb" ] || continue
    pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || basename "$deb")"
    inst_ver="$(dpkg-query -W -f '${Version}' "$pkg_name" 2>/dev/null || true)"
    if [ -n "$inst_ver" ]; then
      items+=("$(_ok "✔") $pkg_name ($inst_ver)")
    else
      items+=("$(_dim "○") $pkg_name")
    fi
  done < <(find "$install_dir" -maxdepth 1 -name '*.deb' -type f)

  clear; draw_header "Pakete installieren (stable)"; echo
  local choices
  choices=$(printf '%s\n' "${items[@]}" | fzf --multi \
    --header="Tab = auswaehlen | Enter = installieren | ESC = abbrechen" \
    --height=~25 --layout=reverse-list --no-sort --ansi \
    --color="fg:#aaaaaa,fg+:#ffffff,bg+:#1a1a2e,hl:#51afef,hl+:#51afef,marker:#51afef,pointer:#51afef,header:#87af87,border:#444444") || return

  if [ -z "$choices" ]; then
    _dim "Nichts ausgewaehlt."
    return
  fi

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
  local testing_dir="$repo_dir/testing"
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
    if ! find "$d" -maxdepth 1 -name '*.deb' -type f -print -quit | grep -q .; then
      lines+="$(_dim "○ $label: leer")${nl}"; continue
    fi
    local new=0
    while IFS= read -r deb; do
      [ -f "$deb" ] || continue
      local bn; bn="$(basename "$deb")"
      [ -f "$testing_dir/$bn" ] || [ -f "$repo_dir/stable/$bn" ] || new=$((new + 1))
    done < <(find "$d" -maxdepth 1 -name '*.deb' -type f)
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

  draw_box "Sync: $total_new neu → testing/" "$Y" "$lines"
  ask_confirm "Synchronisieren + Index aktualisieren?" || return
  run_script "setup_local_repo.sh" update
}

menu_localrepo() {
  while true; do
    clear; draw_header "Lokales APT-Repository" "$(repo_info)"; echo
    local choice
    choice=$(choose_or_back "" \
      "Repo einrichten" \
      "Pakete synchronisieren" \
      "Pakete durchsuchen" \
      "Pakete installieren" \
      "$(sep)" \
      "testing→stable promote" \
      "Alle testing→stable erzwingen" \
      "Auto-promote (Cron)" \
      "Rollback (stable→testing)" \
      "Diff testing vs stable" \
      "$(sep)" \
      "Status (Detail)" \
      "Verifikation" \
      "Health-Check" \
      "Download-Statistiken" \
      "Cleanup alte Versionen" \
      "$(sep)" \
      "apt Pinning einrichten" \
      "Migration (flat→testing/stable)" \
      "GPG Schluessel erzeugen" \
      "Public Key exportieren" \
      "Release neu signieren" \
      "Alle DEBs signieren" \
      "Repo entfernen" \
      "Eigene Argumente...")
    case "$choice" in
      "einrichten"*)       run_script "setup_local_repo.sh" install ;;
      "synchronisieren"*)  repo_sync ;;
      "durchsuchen"*)      repo_browse ;;
      "installieren"*)     repo_install_select ;;
      *"──"*)              continue ;;
      "testing"*)          run_script "setup_local_repo.sh" promote ;;
      "Alle testing"*)     ask_confirm "Alle testing→stable erzwingen?" && run_script "setup_local_repo.sh" promote-all ;;
      "Auto-promote"*)     run_script "setup_local_repo.sh" auto-promote ;;
      "Rollback"*)         local pat; pat="$(gum input --placeholder='Paket-Filter (leer=alle)')" || continue; run_script "setup_local_repo.sh" demote "$pat" ;;
      "Diff"*)             run_script "setup_local_repo.sh" diff ;;
      "Status"*)           run_script "setup_local_repo.sh" status ;;
      "Verifikation"*)     run_script "setup_local_repo.sh" verify ;;
      "Health"*)           run_script "setup_local_repo.sh" health-check ;;
      "Download"*)         run_script "setup_local_repo.sh" stats ;;
      "Cleanup"*)          ask_confirm "Alte Versionen entfernen?" && run_script "setup_local_repo.sh" cleanup ;;
      "Pinning"*)          run_script "setup_local_repo.sh" setup-pinning ;;
      "Migration"*)        ask_confirm "Flat-Repo nach testing/stable migrieren?" && run_script "setup_local_repo.sh" migrate ;;
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
      "Full Backup" \
      "Nur Postfix" \
      "Nur Dovecot" \
      "Nur Nginx" \
      "$(sep)" \
      "Full Restore" \
      "Postfix Restore" \
      "Dovecot Restore" \
      "Nginx Restore" \
      "$(sep)" \
      "Backups auflisten" \
      "Backup verifizieren" \
      "Eigene Argumente...")
    case "$choice" in
      "Full B"*)   run_script "setup_backup_restore.sh" backup ;;
      "Nur Post"*) run_script "setup_backup_restore.sh" backup-postfix ;;
      "Nur Dove"*) run_script "setup_backup_restore.sh" backup-dovecot ;;
      "Nur Ngin"*) run_script "setup_backup_restore.sh" backup-nginx ;;
      *"──"*)      continue ;;
      "Full R"*)   do_restore "setup_backup_restore.sh" "-" restore ;;
      "Postfix R"*) do_restore "setup_backup_restore.sh" "-" restore-postfix ;;
      "Dovecot R"*) do_restore "setup_backup_restore.sh" "-" restore-dovecot ;;
      "Nginx R"*)  do_restore "setup_backup_restore.sh" "-" restore-nginx ;;
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
    choice=$(choose_or_back "" \
      "Automatikmodus" \
      "Bans anzeigen" \
      "Gezieltes Unban" \
      "$(sep)" \
      "Service installieren" \
      "Service-Status" \
      "Service deinstallieren" \
      "Interval aktualisieren" \
      "$(sep)" \
      "Eigene Argumente...")
    case "$choice" in
      "Automatik"*)
        local -a args=()
        ask_confirm "Dry-Run (Test-Modus)?" && args+=(--test)
        run_script "unban_ip.sh" "${args[@]}" ;;
      "Bans"*)  run_script "unban_ip.sh" --bans ;;
      "Geziel"*)
        local t; t="$(gum input --placeholder='IP / CIDR / Domain')" || continue
        [ -z "${t// }" ] && { _fail "Kein Target."; continue; }
        run_script "unban_ip.sh" --unban "$t" ;;
      *"──"*)   continue ;;
      "Service installieren"*)
        ask_confirm "Service installieren? (systemd Timer alle 30min)" && \
        run_script "unban-ip-installer.sh" install ;;
      "Service-Status"*)
        clear; run_script "unban-ip-installer.sh" status; read -r -p " Enter..." _ ;;
      "Service deinstallieren"*)
        ask_confirm "Service deinstallieren?" && \
        run_script "unban-ip-installer.sh" uninstall ;;
      "Interval"*)
        local interval; interval="$(gum input --placeholder='Minuten (Standard: 30)')" || continue
        [ -z "${interval// }" ] && interval="30"
        run_script "unban-ip-installer.sh" update "$interval" ;;
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

clean_php_all() {
  local PE="setup_php.env"
  rm -rf "$(get_env_var "$PE" STAGE_PHP)" 2>/dev/null || true
  rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-$(get_env_var "$PE" PHP_VERSION)" 2>/dev/null || true
  rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-pecl" 2>/dev/null || true
  rm -rf /tmp/php-pgo-stage 2>/dev/null || true
  rm -f "$(get_env_var "$PE" PACKAGE_DIR)"/*.deb 2>/dev/null || true
}

menu_clean() {
  while true; do
    clear; draw_header "Build-Artefakte loeschen"; echo
    local choice
    choice=$(choose_or_back "" \
      "PHP: Staging" \
      "PHP: Build-Dir" \
      "PHP: PECL-Quellen" \
      "PHP: PGO-Profile" \
      "PHP: Pakete (.deb)" \
      "PHP: ALLES" \
      "$(sep)" \
      "Nginx: Staging" \
      "Dovecot: Staging" \
      "Postfix: Staging" \
      "Alle Staging" \
      "ALLE Artefakte")

    [ "$choice" = "Zurück" ] && return
    ask_confirm "$choice  wirklich loeschen?" || continue

    local PE="setup_php.env" NE="setup_nginx.env" DE="setup_dovecot.env" FE="setup_postfix.env"

    case "$choice" in
      "PHP: S"*)  rm -rf "$(get_env_var "$PE" STAGE_PHP)" 2>/dev/null || true ;;
      "PHP: B"*)  rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-$(get_env_var "$PE" PHP_VERSION)" 2>/dev/null || true ;;
      "PHP: P"*)  rm -rf "$(get_env_var "$PE" BUILD_ROOT)/php-pecl" 2>/dev/null || true ;;
      "PHP: G"*)  rm -rf /tmp/php-pgo-stage 2>/dev/null || true ;;
      "PHP: Pak"*) rm -f "$(get_env_var "$PE" PACKAGE_DIR)"/*.deb 2>/dev/null || true ;;
      "PHP: A"*)  clean_php_all ;;
      "Nginx"*)   rm -rf "$(get_env_var "$NE" STAGE_NGINX)" 2>/dev/null || true ;;
      "Dovecot"*) rm -rf "$(get_env_var "$DE" STAGE_DOVECOT)" 2>/dev/null || true ;;
      "Postfix"*) rm -rf "$(get_env_var "$FE" STAGE_POSTFIX)" 2>/dev/null || true ;;
      "Alle S"*)
        rm -rf "$(get_env_var "$PE" STAGE_PHP)" 2>/dev/null || true
        rm -rf "$(get_env_var "$NE" STAGE_NGINX)" 2>/dev/null || true
        rm -rf "$(get_env_var "$DE" STAGE_DOVECOT)" 2>/dev/null || true
        rm -rf "$(get_env_var "$FE" STAGE_POSTFIX)" 2>/dev/null || true ;;
      "ALLE"*)
        clean_php_all
        rm -rf "$(get_env_var "$NE" STAGE_NGINX)" 2>/dev/null || true
        rm -rf "$(get_env_var "$NE" BUILD_ROOT)/nginx-$(get_env_var "$NE" NGINX_VERSION)" 2>/dev/null || true
        rm -rf "$(get_env_var "$DE" STAGE_DOVECOT)" 2>/dev/null || true
        rm -rf "$(get_env_var "$FE" STAGE_POSTFIX)" 2>/dev/null || true ;;
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

compare_versions() {
  local current="$1" available="$2"
  # Simple version comparison: split by dots and compare numerically
  local IFS=. current_arr=($current) available_arr=($available)
  for ((i=0; i<${#available_arr[@]}; i++)); do
    local c=${current_arr[$i]:-0} a=${available_arr[$i]:-0}
    [ "$a" -gt "$c" ] && return 0  # Update available
    [ "$a" -lt "$c" ] && return 1  # Downgrade - no update
  done
  return 1  # Same version
}

auto_update_component() {
  local script="$1" env_var="$2" current="$3" available="$4"

  # Avoid downgrades
  if ! compare_versions "$current" "$available"; then
    [ "$available" != "$current" ] && _warn "  [SKIP] $script: $current → $available (Downgrade)" || true
    return 1
  fi

  # Update .env file
  local env_file="$SCRIPT_DIR/${script%.sh}.env"
  if sed -i "s/^${env_var}=.*/\${env_var}=\"${available}\"/" "$env_file" 2>/dev/null; then
    _ok "  [UPDATE] $script: $current → $available"
    return 0
  fi
  return 1
}

check_all_updates() {
  clear; draw_header "Update-Check"; echo
  _bold "Aktualisiere Scripts und Config..."; echo

  # Update scripts from git
  git_update "$@"

  # Recreate .env files from .example (ensures latest versions)
  _bold "Aktualisiere .env Dateien..."; echo
  local env_count=0
  for f in "$SCRIPT_DIR"/setup_*.env.example; do
    [ -f "$f" ] || continue
    local env_file="${f%.example}"
    if cp "$f" "$env_file" 2>/dev/null; then
      env_count=$((env_count + 1))
    fi
  done
  [ "$env_count" -gt 0 ] && _ok "  ✔ $env_count .env Dateien aktualisiert" || _warn "  (keine .env Dateien gefunden)"
  echo

  _bold "Pruefe und installiere Updates..."; echo

  # Check and auto-update each component
  local updates_found=0

  # Nginx
  local nginx_out="$(bash "$SCRIPT_DIR/setup_nginx.sh" check-updates 2>&1 || true)"
  local nginx_current="$(echo "$nginx_out" | grep "^│ Nginx" | awk '{print $4}')"
  local nginx_available="$(echo "$nginx_out" | grep "^│ Nginx" | awk '{print $6}')"
  if [ -n "$nginx_current" ] && [ -n "$nginx_available" ] && [ "$nginx_current" != "$nginx_available" ]; then
    auto_update_component "setup_nginx.sh" "NGINX_VERSION" "$nginx_current" "$nginx_available" && updates_found=$((updates_found + 1))
  fi

  # Dovecot
  local dovecot_out="$(bash "$SCRIPT_DIR/setup_dovecot.sh" check-updates 2>&1 || true)"
  local dovecot_current="$(echo "$dovecot_out" | grep "^│ *Dovecot" | head -1 | awk '{print $4}')"
  local dovecot_available="$(echo "$dovecot_out" | grep "^│ *Dovecot" | head -1 | awk '{print $6}')"
  if [ -n "$dovecot_current" ] && [ -n "$dovecot_available" ] && [ "$dovecot_current" != "$dovecot_available" ]; then
    auto_update_component "setup_dovecot.sh" "DOVECOT_VERSION" "$dovecot_current" "$dovecot_available" && updates_found=$((updates_found + 1))
  fi

  # Postfix (skip downgrades like 3.11.1 -> 3.1.1)
  local postfix_out="$(bash "$SCRIPT_DIR/setup_postfix.sh" check-updates 2>&1 || true)"
  local postfix_current="$(echo "$postfix_out" | grep "^│ Postfix" | awk '{print $4}')"
  local postfix_available="$(echo "$postfix_out" | grep "^│ Postfix" | awk '{print $6}')"
  if [ -n "$postfix_current" ] && [ -n "$postfix_available" ] && [ "$postfix_current" != "$postfix_available" ]; then
    auto_update_component "setup_postfix.sh" "POSTFIX_VERSION" "$postfix_current" "$postfix_available" && updates_found=$((updates_found + 1))
  fi

  echo
  if [ "$updates_found" -gt 0 ]; then
    _ok "✔ $updates_found Komponente(n) aktualisiert - bereit zum Bauen!"
  else
    _ok "✔ Alles aktuell"
  fi

  read -r -p " Enter fuer Menue..." _
}

git_update() {
  [ -d "$SCRIPT_DIR/.git" ] || return
  command -v git >/dev/null 2>&1 || return

  local output current_branch
  current_branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

  [[ "$current_branch" != "main" ]] && git -C "$SCRIPT_DIR" checkout main >/dev/null 2>&1 || true

  git -C "$SCRIPT_DIR" fetch origin >/dev/null 2>&1 || return

  # Check if local changes exist (stash if needed)
  local has_local_changes=0
  if ! git -C "$SCRIPT_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
    has_local_changes=1
    git -C "$SCRIPT_DIR" stash >/dev/null 2>&1
  fi

  # Hard reset to origin/main to avoid merge conflicts
  output="$(git -C "$SCRIPT_DIR" reset --hard origin/main 2>&1)" || {
    _fail "git reset fehlgeschlagen: $output"
    return
  }

  echo "$output" | grep -qi "already up.to.date\|current\|HEAD is now" && {
    [ "$has_local_changes" = "1" ] && git -C "$SCRIPT_DIR" stash pop >/dev/null 2>&1
    return
  }

  local nl=$'\n'
  local msg="Scripts aktualisiert${nl}${output}${nl}${nl}Neustart in 2s..."
  [ "$has_local_changes" = "1" ] && msg="${msg}${nl}(lokale Änderungen wurden stashed)"

  draw_box "Scripts aktualisiert" "$Y" "$msg"
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
    clear; draw_banner; echo

    local sc; sc="$(screen_count)"
    local screen_label="Screens"
    [ "$sc" -gt 0 ] && screen_label="Screens ($sc aktiv)"

    local choice
    choice=$(choose "" \
      "PHP ${php_ver:-}" \
      "Nginx ${nginx_ver:-}" \
      "Dovecot" \
      "Postfix ${postfix_ver:-}" \
      "$(sep)" \
      "Z-Push ActiveSync" \
      "Backup / Restore" \
      "Lokales Repository" \
      "$(sep)" \
      "IP Unban" \
      "Fail2Ban Test" \
      "$screen_label" \
      "$(sep)" \
      "Clean" \
      "Settings" \
      "System-Info" \
      "Updates pruefen" \
      "Beenden") || break

    case "$choice" in
      PHP*)       menu_php ;;
      Nginx*)     menu_nginx ;;
      Dovecot*)   menu_dovecot ;;
      Postfix*)   menu_postfix ;;
      *"──"*)     continue ;;
      Z-Push*)    menu_zpush ;;
      Backup*)    menu_backuprestore ;;
      Lokales*)   menu_localrepo ;;
      IP*)        menu_unbanip ;;
      Fail2Ban*)  menu_f2btest ;;
      Screen*|"Screens"*) menu_screens ;;
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
