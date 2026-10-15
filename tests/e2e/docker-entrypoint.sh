#!/usr/bin/env bash
# Trusts the mounted local CA for Chromium (NSS) and Node (the API calls), then runs.
# Shared by the e2e image and groot-tools (infrastructure/docker/tools): CA_REQUIRED=0 lets a
# tool that never speaks HTTPS (ffmpeg, svgo) run on a machine that has not minted the CA yet.
set -euo pipefail
ca=/certs/local-ca.pem
if [[ ! -r "$ca" ]]; then
  [[ "${CA_REQUIRED:-1}" == 0 ]] && exec "$@"
  echo "[e2e] local CA not mounted at $ca" >&2
  exit 2
fi
mkdir -p "$HOME/.pki/nssdb"
certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password 2>/dev/null || true
certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n track-binocle-local-ca -i "$ca"
export NODE_EXTRA_CA_CERTS="$ca"
exec "$@"
