#!/usr/bin/env bash
# ide-plane.sh — operator tools for the IDE plane's docker-ide daemon (devil S6: A10 kill switch,
# A11 removal). Nothing here deploys; both commands act on the daemon DOCKER_HOST names and refuse
# to run without it, so a stray shell never reaches the host's main daemon.
#
#   DOCKER_HOST=unix:///run/docker-ide.sock scripts/ide-plane.sh off
#       Stops every running osio.ide.managed container and prints "stopped <n>". Setting the
#       plane's access mode to off is a separate step, printed first: while the ide-server is
#       still on `allowlist`/`approved`, a reconnecting terminal re-provisions the box.
#   DOCKER_HOST=unix:///run/docker-ide.sock scripts/ide-plane.sh remove-user <uid|home-digest> --yes
#       Removes that user's containers, their volumes and their ledger line. <uid> is the number in
#       the ledger (20000..59999); <home-digest> is the 32 hex of osio-ide-home-<digest>. Refuses
#       without --yes. The ledger lives in the socket proxy's container on the MAIN daemon:
#       OSIONOS_IDE_LEDGER_DOCKER_HOST (default unix:///var/run/docker.sock) and
#       OSIONOS_IDE_PROXY_CONTAINER (default osionos-ide-socket-proxy).
#
# Caveat: the user's boxes are found by their osio.ide.owner label, so a workspace volume whose
# container was already removed is not found and stays (list `osio-ide-vol-*` and compare by hand).
# The ledger edit rewrites the file inside the proxy container and restarts the proxy so its
# in-memory copy cannot write the line back; a uid allocation landing between the edit and the
# restart (milliseconds) resurrects it, and the restart drops in-flight creates for a moment.
# Freeing the highest uid lets the next user receive it: the volumes are removed first for that.
# Exit: 0 done; 1 a step failed (nothing later ran); 2 usage or missing --yes.
set -euo pipefail

PROXY_CONTAINER=${OSIONOS_IDE_PROXY_CONTAINER:-osionos-ide-socket-proxy}
LEDGER_HOST=${OSIONOS_IDE_LEDGER_DOCKER_HOST:-unix:///var/run/docker.sock}
LEDGER_FILE=/ledger/uid-ledger.jsonl
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
VOLUME_RE='^osio-ide-(vol|home)-[0-9a-f]{32}$'

die() { printf '[ide-plane] %s\n' "$1" >&2; exit "${2:-1}"; }

require_plane_host() {
  [[ -n "${DOCKER_HOST:-}" ]] || die "DOCKER_HOST is unset: name the docker-ide daemon explicitly (unix:///run/docker-ide.sock)" 2
}

ledger_docker() { DOCKER_HOST=$LEDGER_HOST docker "$@"; }

home_digest() { printf '%s' "$1" | sha256sum | cut -c1-32; }

cmd_off() {
  require_plane_host
  printf '[ide-plane] first set OSIONOS_IDE_ACCESS=off for the bridge and the ide-server and recreate them (README "Access and capacity"); otherwise a terminal reconnect starts its box again\n' >&2
  local ids
  ids=$(docker ps -q --filter label=osio.ide.managed=1) || die "cannot list boxes on $DOCKER_HOST"
  if [[ -z "$ids" ]]; then echo "stopped 0"; return 0; fi
  # One `docker stop` stops them in parallel: 5 s grace, not 5 s per box.
  # shellcheck disable=SC2086 # ids is a newline list of hex ids, one word each
  docker stop -t 5 $ids >/dev/null || die "docker stop failed on $DOCKER_HOST"
  echo "stopped $(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
}

# Prints "<owner> <uid>" for the ledger line matching the argument, or nothing.
resolve_owner() {
  local arg=$1 ledger=$2 owner uid
  while read -r owner uid; do
    [[ "$owner" =~ $UUID_RE ]] || continue
    if [[ "$arg" =~ ^[0-9]{5}$ && "$uid" == "$arg" ]] || [[ "$arg" =~ ^[0-9a-f]{32}$ && "$(home_digest "$owner")" == "$arg" ]]; then
      echo "$owner $uid"
      return 0
    fi
  done < <(printf '%s\n' "$ledger" | sed -n 's/.*"owner":"\([^"]*\)","uid":\([0-9]*\).*/\1 \2/p')
}

# Container ids whose owner label is `owner`, from `docker ps` lines "<id> <owner>" on stdin.
ids_of_owner() {
  local owner=$1 id label
  while read -r id label; do
    [[ "$label" == "$owner" ]] && echo "$id"
  done
}

# The plane's own volume names among the mount names on stdin (anything else a box mounts is left alone).
managed_volumes() {
  local name
  while read -r name; do
    [[ "$name" =~ $VOLUME_RE ]] && echo "$name"
  done
}

drop_ledger_line() {
  local owner=$1 ledger=$2 kept
  kept=$(printf '%s\n' "$ledger" | grep -vF "\"owner\":\"$owner\"" || true)
  [[ -z "$kept" ]] || kept+=$'\n'
  printf '%s' "$kept" | ledger_docker exec -i "$PROXY_CONTAINER" sh -c "cat > $LEDGER_FILE.rm && mv $LEDGER_FILE.rm $LEDGER_FILE" \
    || die "cannot rewrite the ledger in $PROXY_CONTAINER"
  ledger_docker restart "$PROXY_CONTAINER" >/dev/null || die "ledger rewritten but $PROXY_CONTAINER did not restart: restart it by hand or it writes the line back"
}

cmd_remove_user() {
  require_plane_host
  local arg=${1:-} confirmed=${2:-}
  [[ "$arg" =~ ^[0-9]{5}$ || "$arg" =~ ^[0-9a-f]{32}$ ]] || die "usage: ide-plane.sh remove-user <uid|home-digest> --yes" 2
  [[ "$confirmed" == "--yes" ]] || die "refusing to delete a user's data without --yes" 2

  local ledger match owner uid
  ledger=$(ledger_docker exec "$PROXY_CONTAINER" cat "$LEDGER_FILE") || die "cannot read the ledger in $PROXY_CONTAINER on $LEDGER_HOST"
  match=$(resolve_owner "$arg" "$ledger")
  [[ -n "$match" ]] || die "no ledger line for $arg: nothing removed"
  read -r owner uid <<<"$match"

  local listing mounts id name removed=0 ids=() volumes=()
  listing=$(docker ps -a --filter label=osio.ide.managed=1 --format '{{.ID}} {{.Label "osio.ide.owner"}}') || die "cannot list containers on $DOCKER_HOST: nothing removed"
  mapfile -t ids < <(ids_of_owner "$owner" <<<"$listing")
  for id in ${ids[@]+"${ids[@]}"}; do
    mounts=$(docker inspect --format '{{range .Mounts}}{{.Name}}{{"\n"}}{{end}}' "$id") || die "cannot inspect container $id: ledger line kept"
    mapfile -t -O "${#volumes[@]}" volumes < <(managed_volumes <<<"$mounts")
    docker rm -f "$id" >/dev/null || die "cannot remove container $id: ledger line kept"
  done
  volumes+=("osio-ide-home-$(home_digest "$owner")")
  for name in $(printf '%s\n' "${volumes[@]}" | sort -u); do
    docker volume inspect "$name" >/dev/null 2>&1 || continue
    docker volume rm "$name" >/dev/null || die "cannot remove volume $name (a box still mounts it?): ledger line kept"
    removed=$((removed + 1))
  done
  drop_ledger_line "$owner" "$ledger"
  echo "removed containers=${#ids[@]} volumes=$removed ledger=1 uid=$uid"
}

case "${1:-}" in
  off) cmd_off ;;
  remove-user) shift; cmd_remove_user "$@" ;;
  *) die "usage: ide-plane.sh off | remove-user <uid|home-digest> --yes" 2 ;;
esac
