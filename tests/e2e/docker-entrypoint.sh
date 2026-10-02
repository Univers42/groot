#!/usr/bin/env bash
# Trusts the mounted local CA for Chromium (NSS) and Node (the API calls), then runs.
set -euo pipefail
ca=/certs/local-ca.pem
[[ -r "$ca" ]] || { echo "[e2e] local CA not mounted at $ca" >&2; exit 2; }
mkdir -p "$HOME/.pki/nssdb"
certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password 2>/dev/null || true
certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n track-binocle-local-ca -i "$ca"
export NODE_EXTRA_CA_CERTS="$ca"
exec "$@"
