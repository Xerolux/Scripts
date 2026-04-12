#!/usr/bin/env bash
# ==============================================================================
# Unban + Whitelist (Fail2Ban & CrowdSec) für IPv4, IPv6 und IPv6-Präfix
# Verbessert: Fix für fehlendes del_ignore, dynamische Allowlist-Namen
# ==============================================================================
set -o errexit -o nounset -o pipefail

if [[ ! -f "unban_ip.env" ]]; then
  echo "FEHLER: unban_ip.env nicht gefunden. Bitte aus unban_ip.env.example erstellen." >&2
  exit 1
fi
source "unban_ip.env"

# Farben
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

mkdir -p "$STATE_DIR" >/dev/null 2>&1 || true

usage() {
  cat <<EOF
Verwendung:
  sudo $0 [--domain DOMAIN] [--prefix-length N] [--test]
  sudo $0 --bans
  sudo $0 --unban <IP|CIDR|Domain>

Optionen:
  --domain <d>         Domain (Default: $DOMAIN_DEFAULT)
  --prefix-length <n>  IPv6-Präfix (Default $IPV6_PREFIX_LENGTH_DEFAULT, 0 = kein Präfix)
  --bans               Nur Bans anzeigen (F2B + CrowdSec)
  --unban <Ziel>       Ziel entbannen & whitelisten (Domain/IP/CIDR)
  --test               Dry-Run (nur anzeigen, keine Änderungen)
  -h, --help           Hilfe
EOF
}

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo -e "${RED}Root nötig.${NC}" >&2; exit 1; fi; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}Fehlt: $1${NC}" >&2; exit 1; }; }
state_file_for(){ echo "${STATE_DIR}/${1}.set"; }

# Generiert den Allowlist-Namen basierend auf der aktuellen Domain
get_cs_allowlist_name() {
  local d="$1"
  echo "dyn-whitelist-${d//[^a-zA-Z0-9_-]/_}"
}

resolve_all_ips() {
  local d="$1"
  echo -e "${BLUE}Auflösen: ${d}${NC}" >&2
  need_cmd dig
  # IPv4: Strikter Regex
  dig +short A "$d"    2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
  # IPv6: Etwas strikterer Regex (Hex und Doppelpunkte, mind. 2 Zeichen)
  dig +short AAAA "$d" 2>/dev/null | grep -Ei '^[0-9a-f:]{2,}$' || true
}

calculate_ipv6_prefix_base() {
  local ipv6="$1" plen="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$ipv6" "$plen" <<'PY'
import ipaddress, sys
try:
  ip=sys.argv[1]; plen=int(sys.argv[2])
  print(ipaddress.IPv6Network(f"{ip}/{plen}", strict=False).network_address)
except Exception:
  pass
PY
  else
    echo -e "${YELLOW}Hinweis: 'python3' fehlt – Präfixberechnung übersprungen.${NC}" >&2
  fi
}

# ---------------- Fail2Ban ----------------

# Cache für Jail-Liste, um Aufrufe zu minimieren
_F2B_JAILS_CACHE=""
get_f2b_jails() {
  if [[ -z "$_F2B_JAILS_CACHE" ]]; then
    if command -v fail2ban-client >/dev/null 2>&1; then
      _F2B_JAILS_CACHE=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p' | tr ',' ' ')
    fi
  fi
  # Ausgabe als Liste für Schleifen
  echo "$_F2B_JAILS_CACHE" | xargs -n1 echo 2>/dev/null || true
}

f2b_is_banned_in_jail() {
  local j="$1" t="$2"
  local lst; lst="$(fail2ban-client status "$j" 2>/dev/null | sed -n 's/.*Banned IP list:\s*//p')"
  [[ -z "${lst:-}" ]] && return 1
  tr ' ' '\n' <<<"$lst" | grep -Fxq -- "$t"
}

f2b_ignore_contains() {
  local j="$1" v="$2"
  local cur; cur="$(fail2ban-client get "$j" ignoreip 2>/dev/null || true)"
  grep -Fqw -- "$v" <<<"$cur"
}

f2b_unban() {
  local t="$1" test="$2"
  command -v fail2ban-client >/dev/null 2>&1 || return 0

  if [[ "$test" == "true" ]]; then
    echo -e "${GREEN}[TEST] F2B: unban '$t'.${NC}" >&2
  else
    local res
    res="$(fail2ban-client unban "$t" 2>/dev/null || echo 0)"
    if [[ "$res" =~ ^[0-9]+$ ]] && [[ "$res" -gt 0 ]]; then
      echo -e "${GREEN}F2B: '$t' aus allen Jails entbannt (Anzahl: $res).${NC}" >&2
    fi
  fi
}

f2b_add_ignore() {
  local v="$1" test="$2"
  command -v fail2ban-client >/dev/null 2>&1 || return 0

  while IFS= read -r j; do
    [[ -z "$j" ]] && continue
    if f2b_ignore_contains "$j" "$v"; then
      # echo -e "${YELLOW}F2B: ignoreip enthält '$v' in '$j' bereits.${NC}" >&2
      continue
    fi

    if [[ "$test" == "true" ]]; then
      echo -e "${GREEN}[TEST] F2B: add ignoreip '$v' -> '$j'.${NC}" >&2
      continue
    fi

    if fail2ban-client set "$j" addignoreip "$v" >/dev/null 2>&1; then
      echo -e "${GREEN}F2B: ignoreip '$v' in '$j' gesetzt.${NC}" >&2
    else
      echo -e "${RED}F2B: addignoreip fehlgeschlagen ($v/$j).${NC}" >&2
    fi
  done < <(get_f2b_jails)
}

# !!! NEU HINZUGEFÜGT: Funktion zum Entfernen aus ignoreip !!!
f2b_del_ignore() {
  local v="$1" test="$2"
  command -v fail2ban-client >/dev/null 2>&1 || return 0

  while IFS= read -r j; do
    [[ -z "$j" ]] && continue
    if ! f2b_ignore_contains "$j" "$v"; then
      continue # Ist gar nicht drin, also nichts tun
    fi

    if [[ "$test" == "true" ]]; then
      echo -e "${GREEN}[TEST] F2B: del ignoreip '$v' -> '$j'.${NC}" >&2
      continue
    fi

    if fail2ban-client set "$j" delignoreip "$v" >/dev/null 2>&1; then
      echo -e "${GREEN}F2B: ignoreip '$v' aus '$j' entfernt.${NC}" >&2
    else
      echo -e "${RED}F2B: delignoreip fehlgeschlagen ($v/$j).${NC}" >&2
    fi
  done < <(get_f2b_jails)
}

# ---------------- CrowdSec (allowlists) ----------------
# Hilfsfunktionen benötigen den Namen der Allowlist als Argument oder nutzen globale Var

cs_allowlist_exists() {
  local name="$1"
  cscli allowlists list -o raw 2>/dev/null | awk -F',' '{print $1}' | grep -Fxq -- "$name"
}
cs_allowlist_create() {
  local name="$1" domain="$2"
  cs_allowlist_exists "$name" && return 0
  cscli allowlists create "$name" -d "dyn allowlist for ${domain}" >/dev/null 2>&1 || true
}
cs_allowlist_values() {
  local name="$1"
  cscli allowlists inspect "$name" -o raw 2>/dev/null | awk -F',' '{print $1}' || true
}
cs_allowlist_add_value() { 
  local name="$1" val="$2"
  cscli allowlists add "$name" "$val" -d "dynamic" >/dev/null 2>&1 || true; 
}
cs_allowlist_remove_value() { 
  local name="$1" val="$2"
  cscli allowlists remove "$name" "$val" >/dev/null 2>&1 || true; 
}

cs_unban_any() {
  local t="$1" test="${2:-false}"
  if [[ "$test" == "true" ]]; then
    echo -e "${GREEN}[TEST] CS: decisions delete '$t'${NC}" >&2
    return 0
  fi
  # CrowdSec unban ist global, keine Allowlist nötig
  if [[ "$t" == */* ]]; then
    cscli decisions delete --range "$t" >/dev/null 2>&1 || true
  else
    cscli decisions delete --ip "$t"    >/dev/null 2>&1 || true
  fi
}

# ---------------- Anzeige ----------------
show_bans() {
  echo -e "${YELLOW}=== Fail2Ban Status ===${NC}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    local tot=0
    while IFS= read -r j; do
      [[ -z "$j" ]] && continue
      echo -e "${BLUE}Jail: $j${NC}"
      local lst; lst="$(fail2ban-client status "$j" | sed -n 's/.*Banned IP list:\s*//p')"
      if [[ -n "$lst" ]]; then
        local -a ips_arr
        read -r -a ips_arr <<< "$lst"
        printf "  - %s\n" "${ips_arr[@]}"
        tot=$((tot + ${#ips_arr[@]}))
      else
        echo "  (leer)"
      fi
    done < <(get_f2b_jails)
    echo -e "${YELLOW}Gesamt Fail2Ban Bans: $tot${NC}"
  else
    echo "Fail2Ban nicht installiert/gefunden."
  fi

  echo -e "\n${YELLOW}=== CrowdSec Status ===${NC}"
  if command -v cscli >/dev/null 2>&1; then
    local raw n; raw="$(cscli decisions list -o raw 2>/dev/null || true)"
    n=0
    if [[ -n "$raw" ]]; then
      # Header überspringen falls vorhanden, ansonsten zählen
      # cscli raw output ist oft: id,source,ip_text,...
      # wir filtern auf einfache IP Liste
      local ips; ips="$(echo "$raw" | awk -F',' 'NR>1 {print $3}')"
      if [[ -n "$ips" ]]; then
         while IFS= read -r line; do
           echo "  - $line"
         done <<< "$ips"
         n="$(echo "$ips" | grep -c . || true)"
      else
         echo "  (leer)"
      fi
    else
      echo "  (leer)"
    fi
    echo -e "${YELLOW}Gesamt CrowdSec Bans: ${n}${NC}"
  else
    echo "CrowdSec nicht installiert/gefunden."
  fi
}

# ---------------- State & Logic ----------------
load_prev_set() {
  if [[ -f "$1" ]]; then
    grep -Ev '^[[:space:]]*$' -- "$1" || true
  fi
}
save_curr_set() { local f="$1"; shift; printf '%s\n' "$@" | grep -Ev '^[[:space:]]*$' | sort -u > "${f}.tmp"; mv "${f}.tmp" "$f"; }

apply_targets() {
  local test="$1" allowlist_name="$2"; shift 2
  local t

  local existing_allowlist=""
  if [[ "$test" != "true" ]]; then
    existing_allowlist="$(cs_allowlist_values "$allowlist_name")"
  fi

  for t in "$@"; do
    [[ -z "$t" ]] && continue
    
    # 1. Unban (F2B + CS)
    f2b_unban "$t" "$test"
    cs_unban_any "$t" "$test"
    
    # 2. Whitelist Add
    f2b_add_ignore "$t" "$test"
    
    if [[ "$test" == "true" ]]; then
      echo -e "${GREEN}[TEST] CS: allowlists add '$t' -> '$allowlist_name'${NC}" >&2
    else
      # nur hinzufügen, wenn noch nicht drin (API calls sparen)
      if ! grep -Fqw -- "$t" <<< "$existing_allowlist"; then
        cs_allowlist_add_value "$allowlist_name" "$t"
        echo -e "${GREEN}CS: Allowlist '$allowlist_name' erweitert um: $t${NC}" >&2
      fi
    fi
  done
}

cleanup_old_targets() {
  local test="$1" allowlist_name="$2"; shift 2
  local t
  for t in "$@"; do
    [[ -z "$t" ]] && continue
    # 1. Whitelist Remove
    f2b_del_ignore "$t" "$test"
    
    if [[ "$test" == "true" ]]; then
      echo -e "${GREEN}[TEST] CS: allowlists remove '$t' aus '$allowlist_name'${NC}" >&2
    else
      cs_allowlist_remove_value "$allowlist_name" "$t"
      echo -e "${YELLOW}CS: Aus Allowlist '$allowlist_name' entfernt: $t${NC}" >&2
    fi

    # 2. Sicherstellen: nicht gebannt (falls währenddessen gebannt wurde)
    f2b_unban "$t" "$test"
    cs_unban_any "$t" "$test"
  done
}

build_targets_for_domain() {
  local domain="$1" v6_plen="$2"
  local ips=()
  while IFS= read -r ip; do [[ -n "$ip" ]] && ips+=("$ip"); done < <(resolve_all_ips "$domain")
  
  [[ "${#ips[@]}" -eq 0 ]] && return 0
  
  local out=()
  local first_v6=""
  local i
  for i in "${ips[@]}"; do
    out+=("$i")
    [[ "$i" == *:* && -z "$first_v6" ]] && first_v6="$i"
  done
  
  if [[ "$v6_plen" -gt 0 && -n "$first_v6" ]]; then
    local base; base="$(calculate_ipv6_prefix_base "$first_v6" "$v6_plen" || true)"
    [[ -n "$base" ]] && out+=("${base}/${v6_plen}")
  fi
  printf '%s\n' "${out[@]}"
}

# ---------------- Main ----------------
main() {
  require_root
  local MODE="auto" DOMAIN="$DOMAIN_DEFAULT" UNBAN_ARG="" V6_PLEN="$IPV6_PREFIX_LENGTH_DEFAULT" TEST_MODE="false"

  while (("$#")); do
    case "$1" in
      --bans) MODE="bans"; shift;;
      --unban) MODE="unban"; UNBAN_ARG="${2:-}"; [[ -z "$UNBAN_ARG" ]] && { echo -e "${RED}--unban braucht Argument.${NC}" >&2; exit 1; }; shift 2;;
      --domain) DOMAIN="${2:-}"; [[ -z "$DOMAIN" ]] && { echo -e "${RED}--domain braucht Wert.${NC}" >&2; exit 1; }; shift 2;;
      --prefix-length) V6_PLEN="${2:-}"; [[ "$V6_PLEN" =~ ^[0-9]+$ ]] || { echo -e "${RED}--prefix-length Zahl erwartet.${NC}" >&2; exit 1; }; shift 2;;
      --test) TEST_MODE="true"; shift;;
      -h|--help) usage; exit 0;;
      *) echo -e "${RED}Unbekannte Option: $1${NC}" >&2; usage; exit 1;;
    esac
  done

  # Generiere Namen dynamisch basierend auf der Domain
  local CS_LIST_NAME
  CS_LIST_NAME="$(get_cs_allowlist_name "$DOMAIN")"

  case "$MODE" in
    bans)
      show_bans
      ;;
    unban)
      # Fallunterscheidung: Ist es eine IP oder eine Domain?
      if [[ ! "$UNBAN_ARG" =~ :|^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|/ ]]; then
         # Sieht aus wie eine Domain -> Auflösen
         mapfile -t targets < <(build_targets_for_domain "$UNBAN_ARG" "$V6_PLEN")
         # Wenn man explizit --unban domain.com macht, sollte man vielleicht 
         # auch den Allowlist-Namen anpassen? Hier lassen wir es bei der Hauptdomain, 
         # oder man müsste --domain passend setzen.
      else
        targets=( "$UNBAN_ARG" )
      fi
      
      if [[ "${#targets[@]}" -eq 0 ]]; then
        echo -e "${YELLOW}Keine Targets gefunden.${NC}" >&2
        exit 0
      fi
      echo -e "${BLUE}Targets: ${targets[*]}${NC}" >&2
      
      # CrowdSec Liste erstellen, falls nicht da
      if [[ "$TEST_MODE" != "true" ]]; then
        cs_allowlist_create "$CS_LIST_NAME" "$DOMAIN"
      fi

      apply_targets "$TEST_MODE" "$CS_LIST_NAME" "${targets[@]}"
      ;;
    auto)
      echo -e "${BLUE}=== Automatik für '${DOMAIN}' ===${NC}" >&2
      echo -e "${BLUE}CS Allowlist Name: '${CS_LIST_NAME}'${NC}" >&2
      
      mapfile -t targets < <(build_targets_for_domain "$DOMAIN" "$V6_PLEN")
      
      if [[ "${#targets[@]}" -eq 0 ]]; then
        echo -e "${RED}Fehler: Konnte keine IPs für $DOMAIN auflösen.${NC}" >&2
        # Vorsicht: Wenn DNS ausfällt, wollen wir nicht alle alten löschen? 
        # Hier brechen wir lieber ab, um Sicherheit zu wahren.
        exit 1
      fi
      echo -e "${BLUE}Aktuelle DNS-Targets: ${targets[*]}${NC}" >&2

      # CrowdSec Liste sicherstellen
      if [[ "$TEST_MODE" != "true" ]]; then
        cs_allowlist_create "$CS_LIST_NAME" "$DOMAIN"
      fi

      # Vorherige Targets laden
      local sf; sf="$(state_file_for "$DOMAIN")"
      mapfile -t prev < <(load_prev_set "$sf" || true)

      # 1. Neue anwenden
      apply_targets "$TEST_MODE" "$CS_LIST_NAME" "${targets[@]}"

      # 2. Alte entfernen (= prev - current)
      if [[ "${#prev[@]}" -gt 0 ]]; then
        local tfA tfB
        tfA="$(mktemp)"; tfB="$(mktemp)"
        printf '%s\n' "${prev[@]}"    | grep -Ev '^[[:space:]]*$' | sort -u > "$tfA"
        printf '%s\n' "${targets[@]}" | grep -Ev '^[[:space:]]*$' | sort -u > "$tfB"
        
        # Zeilen, die in A sind, aber nicht in B
        mapfile -t old_only < <(grep -Fvx -f "$tfB" "$tfA" || true)
        rm -f "$tfA" "$tfB"
        
        if [[ "${#old_only[@]}" -gt 0 ]]; then
          echo -e "${YELLOW}Entferne veraltete Targets: ${old_only[*]}${NC}" >&2
          cleanup_old_targets "$TEST_MODE" "$CS_LIST_NAME" "${old_only[@]}"
        fi
      fi

      save_curr_set "$sf" "${targets[@]}"
      echo -e "${GREEN}=== Fertig ===${NC}" >&2
      ;;
  esac
}

main "$@"
