#!/usr/bin/env bash
set -euo pipefail

# Cleanup on exit
trap 'rm -f /tmp/f2b-$$* 2>/dev/null' EXIT INT TERM

LOG_FILE="${LOG_FILE:-}"
[[ "$LOG_FILE" == "-" ]] && LOG_FILE=""  # "-" wuerde Datei statt stdout erzeugen
log() {
  local line="[$(date '+%F %T')] $*"
  if [[ -n "$LOG_FILE" ]]; then
    echo "$line" | tee -a "$LOG_FILE"
  else
    echo "$line"
  fi
}

log "Starting Fail2Ban test..."
service fail2ban start || { log "WARN: service fail2ban start failed"; true; }
fail2ban-client start || { log "WARN: fail2ban-client start failed"; true; }
fail2ban-client add sshd || { log "WARN: fail2ban-client add sshd failed"; true; }
fail2ban-client set sshd addignoreip 1.2.3.4 || { log "WARN: addignoreip failed"; true; }
log "Fail2Ban test completed"
