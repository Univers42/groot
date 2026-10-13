#!/usr/bin/env bash
# grobase-link.sh — let the root frontends reach grobase wherever it runs, by the names they already use.
# Modes: local (this daemon), ssh (ControlMaster -> unix sockets in LINK_DIR -> the grobase-link relay) and
# direct (a Kong URL; Redis and Mailpit stood in here); GROBASE_TARGET picks it (wiki/runbooks/grobase-link.md).
# Ponytail: in ssh mode a remote service without a published port is forwarded to its
# container IP, which changes when that container is recreated; the forward then connects
# to nothing until the next `up` re-points it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"
CONF="${GROBASE_LINK_CONF:-$REPO/.env.grobase-link}" # this machine's settings; git-ignored
# One setting: the environment (make's command line) wins, then $CONF, then the default.
# An empty environment value counts as unset: that is how make hands over an unset variable.
setting() {
  local v=${!1:-}
  [ -n "$v" ] || v=$(get_env "$CONF" "$1" || true)
  printf '%s\n' "${v:-$2}"
}
LINK_DIR="${GROBASE_LINK_DIR:-${XDG_RUNTIME_DIR:-/tmp}/track-binocle-link}"
TARGET=$(setting GROBASE_TARGET auto)
HOST_PORT=$(setting GROBASE_LINK_HOST_PORT 28000) # loopback copy of Kong for host tools; 0 disables
REMOTE_DIR=$(setting GROBASE_REMOTE_DIR /opt/grobase)
API_URL=$(setting GROBASE_API_URL "") # the WAF clients call; empty = derived from TARGET
CA_FILE=$(setting GROBASE_CA_FILE "") # direct targets only: the CA signing that Kong's certificate
REMOTE_ENV="${GROBASE_REMOTE_ENV:-$REPO/.env.grobase-remote}"
CTL="$LINK_DIR/ssh.ctl"
STATE="$LINK_DIR/state"
ROUTES="$LINK_DIR/routes"
FORWARDS="$LINK_DIR/forwards"
SOCAT_IMG=alpine/socat:1.8.0.1
# <relay port> <grobase service> <container port> <name the frontends use> <probe kind>;
# docker-compose.grobase-link.yml answers to the names, grobase-link-verify.sh sends the probes.
SERVICES="8000 kong 8000 mini-baas-kong http
6379 redis 6379 mini-baas-redis redis
8025 mailpit 8025 mini-baas-mailpit http
1025 mailpit 1025 mailpit smtp
4000 realtime 4000 mini-baas-realtime http"

note() { printf '[grobase-link] %s\n' "$*" >&2; }
die() {
  note "$*"
  exit 1
}
state_get() { get_env "$STATE" "$1"; }
state_set() { printf 'mode=%s\ntarget=%s\n' "$1" "$2" >"$STATE"; }
mux() { ssh -F /dev/null -S "$CTL" -o BatchMode=yes -o LogLevel=ERROR "$@"; }
# shellcheck source=scripts/lib/grobase-link-target.sh
. "$REPO/scripts/lib/grobase-link-target.sh"
# shellcheck source=scripts/lib/grobase-link-verify.sh
. "$REPO/scripts/lib/grobase-link-verify.sh"
# shellcheck source=scripts/lib/grobase-link-ide.sh
. "$REPO/scripts/lib/grobase-link-ide.sh"

# "<service> <container port> <ip:port reachable from the remote's sshd>" per tcp port of
# every mini-baas-* container; a published port (0.0.0.0/:: -> 127.0.0.1) beats the
# container IP on its first network.
# The host group has no empty alternative: with `(...|)?`, mawk 1.3.4 20260129 (Ubuntu 26.04)
# drops the ^ anchor and rewrote 127.0.0.1:8000 as 127.0.0.1127.0.0.1:8000, so every
# loopback-published port forwarded to nothing (2026-10-12, relay unhealthy 5/5 checks).
remote_endpoints() {
  mux x 'sh -s' <<'EOF' | awk '
    $1 == "N" && !($2 in ip) { ip[$2] = $3 }
    $1 == "P" && $3 ~ /\/tcp$/ {
      sub(/\/tcp$/, "", $3); ep = $4
      if (ep == "-") ep = ip[$2] ":" $3; else sub(/^(0\.0\.0\.0|::|\[::\])?:/, "127.0.0.1:", ep)
      name = $2; sub(/^\/?mini-baas-/, "", name); print name, $3, ep }'
docker ps --filter name=^mini-baas- --format '{{.Names}}' | xargs -r docker inspect -f '{{$n := .Name}}{{range .NetworkSettings.Networks}}N {{$n}} {{.IPAddress}}
{{end}}{{range $p, $b := .NetworkSettings.Ports}}P {{$n}} {{$p}} {{if $b}}{{(index $b 0).HostIp}}:{{(index $b 0).HostPort}}{{else}}-{{end}}
{{end}}'
EOF
}

cancel_forwards() {
  local f
  [ -f "$FORWARDS" ] || return 0
  while read -r f; do [ -z "$f" ] || mux -O cancel -L "$f" x 2>/dev/null || true; done <"$FORWARDS"
  rm -f "$FORWARDS" "$LINK_DIR"/*.sock "$LINK_DIR"/ide/*.sock
}
# Reuses a live master only when it goes to the same host: the control socket has one
# path, so a new target would otherwise silently keep talking to the previous machine.
# shellcheck disable=SC2046 # see ssh_args
open_master() {
  local prev
  prev=$(state_get target 2>/dev/null || true)
  if mux -O check x 2>/dev/null; then
    [ "$(ssh_args "$prev")" != "$(ssh_args "$1")" ] || return 0
    note "closing the master to $prev"
    cmd_down_ssh
  fi
  ssh -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=yes -o ClearAllForwardings=yes \
    -o StreamLocalBindUnlink=yes -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 -o LogLevel=ERROR -N -f $(ssh_args "$1") ||
    die "ssh cannot open a master to $1 (key in ssh-agent or passwordless? try: ssh $(ssh_args "$1"))"
}
forward() { # <listen> <ip:port>; records it so a later up or down can cancel it
  mux -O forward -L "$1:$2" x || die "ssh refused the forward $1 -> $2"
  printf '%s:%s\n' "$1" "$2" >>"$FORWARDS"
}
# Kong copy on the host loopback for curl and the healthcheck; prints the suffix for the note.
forward_host_port() {
  [ "$HOST_PORT" != 0 ] || return 0
  if mux -O forward -L "127.0.0.1:$HOST_PORT:$1" x 2>/dev/null; then
    printf '127.0.0.1:%s:%s\n' "$HOST_PORT" "$1" >>"$FORWARDS"
    printf ', and on 127.0.0.1:%s for host tools' "$HOST_PORT"
  else
    note "127.0.0.1:$HOST_PORT is taken; host tools get no Kong port (GROBASE_LINK_HOST_PORT=<free port>)"
  fi
}

# tenant-control 3022 also gets a socket, in no route: host scripts only (link-live-data-ensure).
up_ssh() {
  local endpoints relay svc cport ep sock kong=""
  open_master "$1"
  endpoints=$(remote_endpoints)
  [ -n "$endpoints" ] || die "no mini-baas-* container is running on $1"
  cancel_forwards
  : >"$ROUTES.tmp"
  while read -r relay svc cport _; do
    ep=$(awk -v s="$svc" -v p="$cport" '$1 == s && $2 == p { print $3; exit }' <<<"$endpoints")
    [ -n "$ep" ] || {
      note "$svc:$cport is not running on $1; its name will refuse connections"
      continue
    }
    sock="$LINK_DIR/$svc-$cport.sock"
    forward "$sock" "$ep"
    printf '%s UNIX-CONNECT:/link/%s\n' "$relay" "${sock##*/}" >>"$ROUTES.tmp"
    [ "$svc:$cport" = kong:8000 ] && kong=$ep
  done <<<"$SERVICES"
  [ -n "$kong" ] || die "Kong is not running on $1; nothing to link"
  ep=$(awk '$1 == "tenant-control" && $2 == 3022 { print $3; exit }' <<<"$endpoints")
  [ -z "$ep" ] || forward "$LINK_DIR/tenant-control-3022.sock" "$ep"
  mv "$ROUTES.tmp" "$ROUTES"
  link_ide_plane
  note "ssh link to $1: $(wc -l <"$ROUTES") ports relayed, Kong at $kong$(forward_host_port "$kong")"
}

up_direct() {
  local cafile
  url_reachable "$1" || die "$1 does not answer from a container of this daemon"
  cmd_down_ssh # only once the URL answers: a dead target must not cost the link that works
  if [ -n "$CA_FILE" ]; then
    [ -r "$CA_FILE" ] || die "GROBASE_CA_FILE=$CA_FILE is not a readable file"
    install -m 644 "$CA_FILE" "$LINK_DIR/ca.pem" # that is /link/ca.pem in the relay
    cafile=/link/ca.pem
  else
    rm -f "$LINK_DIR/ca.pem" # a copy from an earlier target would keep a CA we dropped
    cafile=/etc/ssl/certs/ca-certificates.crt
  fi
  direct_routes "$1" "$cafile" >"$ROUTES"
  note "direct link to $1: Kong over the URL, bridge publishes through its service_role-only route;"
  note "Redis and Mailpit are local stand-ins (sessions and captured mail stay on this machine)."
}

# own_link_dir — LINK_DIR, made by and private to this user. A reboot empties XDG_RUNTIME_DIR,
# and dockerd, restarting the relay, re-creates the relay's bind source as root (2026-10-11:
# `make link` then died on chmod). An empty dir in a parent this user owns is ours to remove.
own_link_dir() {
  if [ -d "$LINK_DIR" ] && [ ! -O "$LINK_DIR" ]; then
    rmdir "$LINK_DIR" 2>/dev/null || die "$LINK_DIR belongs to $(stat -c %U "$LINK_DIR") and is not empty; remove it, then make link"
  fi
  mkdir -p "$LINK_DIR" && chmod 700 "$LINK_DIR"
}

cmd_up() {
  local mode target
  own_link_dir
  [ -n "${GROBASE_TARGET:-}" ] || ! get_env "$CONF" GROBASE_TARGET >/dev/null || note "target $TARGET, from ${CONF#"$REPO"/}"
  read -r mode target < <(resolve)
  case "$mode" in
  ssh) up_ssh "$target" ;;
  direct) up_direct "$target" ;;
  local)
    # An explicit kind is taken as given, but a monolithic host still has to HAVE grobase:
    # with none, the frontends would start and every call to mini-baas-kong would fail DNS.
    local_has_grobase || die "local: no mini-baas-kong on this daemon; make backend-up first, or set GROBASE_TARGET to the machine that runs grobase"
    cmd_down_ssh && rm -f "$ROUTES"
    note "local: grobase runs on this daemon; the frontends reach it by name, no relay needed"
    ;;
  esac
  state_set "$mode" "$target"
}

cmd_down_ssh() {
  cancel_forwards
  [ ! -S "$CTL" ] || mux -O exit x 2>/dev/null || true
  rm -f "$CTL" "$LINK_DIR"/*.sock
}

cmd_down() {
  [ -d "$LINK_DIR" ] || return 0
  cmd_down_ssh
  rm -f "$ROUTES" "$ROUTES.tmp" "$STATE"
  note "link closed; the frontends now resolve grobase on this daemon only (make backend-up)"
}

cmd_status() {
  local mode target code
  mode=$(state_get mode) || true
  [ -n "$mode" ] || die "no link; open one with: make link"
  target=$(state_get target)
  case "$mode" in
  local)
    local_has_grobase || die "local: mini-baas-kong is not running on this daemon (make backend-up)"
    note "local: mini-baas-kong runs on this daemon"
    ;;
  ssh)
    mux -O check x 2>/dev/null || die "ssh: master to $target is gone; re-run make link"
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --unix-socket "$LINK_DIR/kong-8000.sock" http://kong/ || true)
    note "ssh: master to $target up; Kong through $LINK_DIR/kong-8000.sock answers HTTP $code"
    [ "$code" != 000 ]
    ;;
  direct)
    url_reachable "$target" || die "direct: $target no longer answers from a container"
    note "direct: $target answers from a container"
    ;;
  esac
}

cmd_env() {
  local mode src sync=""
  mode=$(state_get mode) || true
  [ -n "$mode" ] || die "no link yet; run up first so env knows where grobase's .env is"
  case "$mode" in
  ssh)
    umask 077
    mux x "cat '$REMOTE_DIR/.env'" >"$REMOTE_ENV.tmp" || {
      rm -f "$REMOTE_ENV.tmp"
      die "cannot read $REMOTE_DIR/.env on $(state_get target) (GROBASE_REMOTE_DIR=<its grobase dir>)"
    }
    grep -q '^JWT_SECRET=.' "$REMOTE_ENV.tmp" || die "$REMOTE_DIR/.env on the remote has no JWT_SECRET"
    mv "$REMOTE_ENV.tmp" "$REMOTE_ENV"
    src=$REMOTE_ENV
    ;;
  direct)
    for src in "$REMOTE_ENV" "$REPO/apps/grobase/.env"; do [ -f "$src" ] && break; done
    [ -f "$src" ] || die "direct mode cannot fetch secrets; put that grobase's .env at $REMOTE_ENV"
    ;;
  local) src="$REPO/apps/grobase/.env" ;;
  esac
  [ ! -f "$REPO/.env.local" ] || sync=--sync
  GRO_ENV="$src" bash "$REPO/scripts/gen-local-env.sh" ${sync:+"$sync"}
  publish_env "$mode" "$REPO/.env.local" && { [ "$mode" = local ] || rt_token_ensure "$REPO/.env.local" "$src"; }
}

# The settings as `up` will use them, so make and the user read one resolution, not the file.
cmd_conf() {
  case "${1:-}" in
  "") printf 'GROBASE_TARGET=%s\nGROBASE_LINK_HOST_PORT=%s\nGROBASE_REMOTE_DIR=%s\nGROBASE_API_URL=%s\nGROBASE_CA_FILE=%s\n' "$TARGET" "$HOST_PORT" "$REMOTE_DIR" "$API_URL" "$CA_FILE" ;;
  GROBASE_TARGET) printf '%s\n' "$TARGET" ;;
  GROBASE_LINK_HOST_PORT) printf '%s\n' "$HOST_PORT" ;;
  GROBASE_REMOTE_DIR) printf '%s\n' "$REMOTE_DIR" ;;
  GROBASE_API_URL) printf '%s\n' "$API_URL" ;;
  GROBASE_CA_FILE) printf '%s\n' "$CA_FILE" ;;
  *) die "conf: no setting named $1 (GROBASE_TARGET, GROBASE_LINK_HOST_PORT, GROBASE_REMOTE_DIR, GROBASE_API_URL, GROBASE_CA_FILE)" ;;
  esac
}

# DOCKER_HOST for the daemon that runs the linked grobase, so `make models-migrate` (docker
# exec into mini-baas-postgres) reaches ITS postgres: empty in local mode (this daemon), the
# ssh target in ssh mode (docker's own ssh transport takes an alias or user@host:port alike),
# refused in direct mode (a Kong URL gives no daemon and no database).
cmd_docker_host() {
  local mode target
  mode=$(state_get mode) || die "no link; open one with: make link"
  target=$(state_get target)
  case "$mode" in
  local) printf '\n' ;;
  ssh) case "$target" in ssh://*) printf '%s\n' "$target" ;; *) printf 'ssh://%s\n' "$target" ;; esac ;;
  *) die "direct mode reaches Kong only: no daemon, no postgres; run make models-migrate where grobase runs" ;;
  esac
}

usage() {
  cat <<'USAGE'
usage: grobase-link.sh up|down|status|env|verify|mode|conf [KEY]|api-url|docker-host    (wiki/runbooks/grobase-link.md)
  up      resolve GROBASE_TARGET, open the path to grobase and write LINK_DIR/routes
  down    close it (ssh master, forwards, sockets, routes, state)
  status  exit 0 when the link is open and Kong answers through it
  env     copy the remote grobase .env (ssh mode) and derive ./.env.local from it
  verify  one request per grobase name from inside every frontend on grobase's network, then the browser's TLS edge; exit 1 on any FAIL
  mode    print the active mode: local, ssh or direct
  conf    print the effective settings, one (KEY) or all (KEY=value lines)
  docker-host  DOCKER_HOST of the daemon running the linked grobase ("" = this one; direct: exit 1)
  api-url  print the HTTPS URL of the grobase API (the WAF) for clients
Settings: the environment (make link KEY=value) wins, then ./.env.grobase-link (KEY=value, git-ignored; .env.grobase-link.example documents it), then the default.
  GROBASE_TARGET          auto | local | ssh://[user@]host[:port] | <ssh alias|user@host|host> | http(s)://host[:port]  -- the scheme is the kind of connection
  GROBASE_LINK_HOST_PORT  28000 (0 = none)        GROBASE_REMOTE_DIR  /opt/grobase
  GROBASE_API_URL         the WAF URL clients call, https://<vm>.<tailnet>.ts.net:8443; ssh/auto need it
  GROBASE_CA_FILE         direct targets only: the PEM CA signing that Kong's certificate; empty = the relay's system store
Environment only: GROBASE_LINK_DIR (XDG_RUNTIME_DIR/track-binocle-link), GROBASE_LINK_CONF (another settings file), GROBASE_REMOTE_ENV, B2B_DIR.
Exit codes: 0 success, 1 failure or misuse.
USAGE
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0 # sourced by scripts/tests/grobase-link.bats: define only
case "${1:-}" in
up | down | status | env | verify) "cmd_$1" ;;
conf) cmd_conf "${2:-}" ;;
mode) state_get mode | grep . || die "no link" ;;
docker-host) cmd_docker_host ;;
api-url) api_url "$TARGET" "$API_URL" || die "no API URL for target $TARGET; set GROBASE_API_URL to the WAF URL, e.g. https://<vm>.<tailnet>.ts.net:8443" ;;
ide-linked) ide_linked ;;
-h | --help) usage ;;
*) usage >&2 && exit 1 ;;
esac
