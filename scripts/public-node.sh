#!/usr/bin/env bash
# public-node.sh — run the second Tailscale node (default name osionos-apps) that serves the Mail
# and Calendar static previews through its own Funnel, beside the main node. The main node keeps
# 443/8443/10000 for the website, the osionos app and the bridge; a node has one 443 and one 8443,
# so the apps live on a second one (docs/adr/0020-*.md).
#   start    userspace tailscaled with its own socket, state and --port; joins the tailnet only when
#            it is not logged in, reading the auth key from stdin
#   stop     stop that tailscaled (the Funnel config dies with the node's serving)
#   status   the node's DNS name and its open Funnel ports
# Settings (environment): PUBLIC_APPS_NODE (osionos-apps), PUBLIC_APPS_PORT (0 = pick one),
# TAILSCALE_APPS_SOCKET, TAILSCALED_BIN, TAILSCALE_BIN, XDG_STATE_HOME.
#
# The auth key is read from stdin only, never from argv, a file or the environment, and is not
# echoed:   pbpaste | scripts/public-node.sh start      or type it at the silent prompt.
# Mint it in the Tailscale admin console as: single-use, tagged, pre-approved, NOT ephemeral
# (an ephemeral node is deleted when it goes offline, and its DNS name with it). The tag's ACL
# needs the funnel nodeAttr, else the Funnel on this node cannot open. Once the node is logged
# in, its state in the state dir is enough and `start` needs no key.
#
# Unlike the born2root seat, this daemon has NO --socks5-server and NO --outbound-http-proxy-listen:
# nothing on this host can use it as a proxy into the tailnet.
#
# Caveat: "already running" is judged by the socket answering; a daemon wedged without answering
# is not seen, and `start` then fails when it cannot bind. `stop` trusts the pidfile and checks
# only that the process is a tailscaled.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/public-tailnet.sh
. "$SELF/lib/public-tailnet.sh"
TAILSCALED_BIN="${TAILSCALED_BIN:-$HOME/.local/bin/tailscaled}"

note() { printf '[public-node] %s\n' "$*" >&2; }
die() {
  note "$*"
  exit 1
}

is_running() { tsa status --json >/dev/null 2>&1; }
backend_state() { tsa status --json 2>/dev/null | jq -r '.BackendState // empty' || true; }

read_key() {
  local key
  if [ -t 0 ]; then
    read -rsp "auth key (single-use, tagged, pre-approved, not ephemeral): " key >&2 && echo >&2
  else IFS= read -r key || true; fi
  [ -n "$key" ] || return 1
  printf '%s' "$key"
}

wait_until_answering() {
  for _ in $(seq 1 50); do
    is_running && return 0
    sleep 0.2
  done
  return 1
}

join_tailnet() {
  local key
  key=$(read_key) || return 1
  printf '%s\n' "$key" | tsa up --auth-key=file:/dev/stdin --hostname="$(apps_node_name)" --timeout=60s >/dev/null
}

cmd_start() {
  local dir sock pidfile
  [[ "$(apps_node_name)" =~ ^[a-z0-9-]+$ ]] || die "PUBLIC_APPS_NODE must match [a-z0-9-]+"
  dir=$(apps_node_dir)
  sock=$(apps_node_socket)
  pidfile="$dir/tailscaled.pid"
  if is_running; then die "a tailscaled already answers on $sock: refusing to start a second"; fi
  install -d -m 700 "$dir" "$dir/var"
  nohup "$TAILSCALED_BIN" --tun=userspace-networking --state="$dir/tailscaled.state" \
    --statedir="$dir/var" --socket="$sock" --port="${PUBLIC_APPS_PORT:-0}" >"$dir/tailscaled.log" 2>&1 &
  echo $! >"$pidfile"
  wait_until_answering || {
    cmd_stop || true
    die "tailscaled did not open $sock (see $dir/tailscaled.log)"
  }
  if [ "$(backend_state)" != Running ]; then
    join_tailnet || {
      cmd_stop || true
      die "could not join the tailnet: key missing on stdin, or refused; the daemon was stopped"
    }
  fi
  note "node $(apps_node_name) is up: $(tsa status --json | jq -r '.Self.DNSName // "unnamed"')"
}

cmd_stop() {
  local pidfile pid
  pidfile="$(apps_node_dir)/tailscaled.pid"
  [ -f "$pidfile" ] || die "no pidfile $pidfile: nothing of ours to stop"
  pid=$(cat "$pidfile")
  if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" = tailscaled ]; then
    kill "$pid"
    note "stopped tailscaled $pid"
  else note "pid $pid is not a running tailscaled"; fi
  rm -f "$pidfile"
}

cmd_status() {
  if ! is_running; then
    printf 'node:  %s (not running)\n' "$(apps_node_name)"
    return 0
  fi
  printf 'node:  %s\n' "$(tsa status --json | jq -r '.Self.DNSName // "unreadable"')"
  printf 'ports: %s\n' "$(funnel_ports tsa || echo unreadable)"
}

main() {
  local cmd=${1:-}
  command -v jq >/dev/null || die "jq is required"
  case "$cmd" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    *) die "usage: public-node.sh start | stop | status" ;;
  esac
}
main "$@"
