#!/usr/bin/env bash
# edge-conf-revert.sh <container> <saved-conf> <path-in-container> — put a saved nginx conf back on a
# running edge, in place (no container restart). Before the change, save the live file:
#   docker cp <container>:<path> <saved-conf>
# The file is written through `tee`, not `docker cp`: compose bind-mounts the conf as a single file, and
# docker cp cannot replace a mounted file (rehearsal: "device or resource busy"). `tee` keeps the inode,
# so on a bind mount the host file changes too.
# `nginx -t` runs on the restored file first; if it fails the previous (new) file is put back and the
# reload is not sent, so a bad revert cannot take the edge down.
# Used for the production edge (infrastructure/tls/nginx.conf, /etc/nginx/nginx.conf) and the beta
# edge (infrastructure/beta/edge.conf, /etc/nginx/conf.d/default.conf).
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 <container> <saved-conf> <path-in-container>" >&2; exit 2; }
container=$1 saved=$2 target=$3
[[ -s "$saved" ]] || { echo "$saved is missing or empty" >&2; exit 2; }

keep=$(mktemp)
trap 'rm -f "$keep"' EXIT
put() { docker exec -i "$container" tee "$target" <"$1" >/dev/null; }
docker cp "$container:$target" "$keep"
put "$saved"
if ! docker exec "$container" nginx -t; then
  put "$keep"
  echo "nginx -t failed on $saved: the file in use was put back, nothing reloaded" >&2
  exit 1
fi
docker exec "$container" nginx -s reload
echo "reloaded $container from $saved"
