#!/usr/bin/env bash
# edge-conf-revert.sh <container> <conf> <path-in-container> — put an nginx conf on a running edge in
# place (no container restart). Used both to deploy a new conf and to put a saved one back. Before a
# change, save the live file:
#   docker cp <container>:<path> <saved-conf>
# Both edges bind-mount their conf read-only (production: groot-wt/deploy/tls/nginx.conf ->
# /etc/nginx/nginx.conf; beta: osionos-beta/edge.conf -> /etc/nginx/conf.d/default.conf), so writing
# inside the container fails with "Read-only file system" (2026-11-22). When <path-in-container> is a
# bind mount, the host source is rewritten in place (`cat >`, same inode, so the single-file mount sees
# it); otherwise the file is written through `docker exec tee`.
# `nginx -t` runs on the new file first; if it fails the previous file is put back and the reload is
# not sent, so a bad conf cannot take the edge down.
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 <container> <conf> <path-in-container>" >&2; exit 2; }
container=$1 conf=$2 target=$3
[[ -s "$conf" ]] || { echo "$conf is missing or empty" >&2; exit 2; }

mount_source=$(docker inspect "$container" \
  --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' |
  awk -F'|' -v t="$target" '$1 == t { print $2 }')

keep=$(mktemp)
trap 'rm -f "$keep"' EXIT
put() {
  if [[ -n "$mount_source" ]]; then
    cat "$1" >"$mount_source"
  else
    docker exec -i "$container" tee "$target" <"$1" >/dev/null
  fi
}
docker cp "$container:$target" "$keep"
put "$conf"
if ! docker exec "$container" nginx -t; then
  put "$keep"
  echo "nginx -t failed on $conf: the file in use was put back, nothing reloaded" >&2
  exit 1
fi
docker exec "$container" nginx -s reload
echo "reloaded $container from $conf${mount_source:+ (via bind mount $mount_source)}"
