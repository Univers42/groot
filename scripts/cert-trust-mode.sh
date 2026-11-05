#!/usr/bin/env bash
# cert-trust-mode.sh [MODE] — the CA trust mode `make all` uses. An explicit system, user or skip
# stands. auto never prompts: on a 42 seat nobody holds sudo, the sudo this stack needs is the VM's
# and born2root drives it, and a make all that stops at a password is not unattended. So auto takes
# the system store only when sudo answers without a password, and the browser stores otherwise.
#
# Caveat: someone with password sudo gets browser trust only, so curl and Electron outside the
# containers do not trust the local CA (under-reports). CERT_TRUST_MODE=system asks once.
set -u

case "${1:-auto}" in
system | user | skip)
  printf '%s\n' "$1"
  exit 0
  ;;
esac

if sudo -n true 2>/dev/null; then
  echo system
else
  echo user
fi
