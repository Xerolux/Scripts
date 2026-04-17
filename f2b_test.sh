#!/usr/bin/env bash
set -euo pipefail

service fail2ban start || true
fail2ban-client start || true
fail2ban-client add sshd || true
fail2ban-client set sshd addignoreip 1.2.3.4 || true
