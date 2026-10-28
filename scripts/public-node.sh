#!/usr/bin/env bash
# public-node.sh — run the second Tailscale node (default name osionos-apps) that serves the Mail
# and Calendar static previews through its own Funnel, beside the main node. The main node keeps
# 443/8443/10000 for the website, the osionos app and the bridge; a node has one 443 and one 8443,
# so the apps live on a second one (docs/adr/0020-*.md).
#   start    userspace tailscaled with its own socket, state and --port; joins the tailnet only when
#            it is not logged in, reading the auth key from stdin
#   stop     reset the node's Funnel, then stop that tailscaled: the serve config persists in the
#            state dir, so a stop without the reset would re-serve the apps on the next start
#   status   the node's DNS name and its open Funnel ports
#   autostart      install osionos-apps-node.service (systemd user unit): the node starts at boot
#                  (with linger) and after a crash, its Funnel with it; a daemon already running
#                  outside the unit is handed over to it
#   autostart-off  stop and remove that unit; the Funnel config stays in the state dir
# Settings (environment): PUBLIC_APPS_NODE (osionos-apps), PUBLIC_APPS_PORT (0 = pick one),
# TAILSCALE_APPS_SOCKET, TAILSCALED_BIN, TAILSCALE_BIN, XDG_STATE_HOME, PUBLIC_APPS_LOG (1 = keep the
# daemon's output in <state dir>/tailscaled.log; default /dev/null).
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
# A start that fails (no key, a node stuck in Starting) stops its daemon WITHOUT the Funnel reset:
# the unit's first start after a boot can be slow, and a reset there unpublished the apps for good.
# Only `stop`, an operator's decision, closes the Funnel.
#
# Caveat: "already running" is judged by the socket answering; a daemon wedged without answering
# is not seen, and `start` then fails when it cannot bind. `stop` trusts the pidfile and checks
# that the process is a tailscaled started with this node's --socket; a stale pidfile whose PID
# was reused by another tailscaled therefore stops nothing. The default keeps no daemon log (the
# file grew ~140 KB/h under a 4.7 GB $HOME quota), so a daemon that dies at boot leaves no trace
# until `start` is re-run with PUBLIC_APPS_LOG=1. A node that stays NoState or Starting for 10 s
# is stopped and reported, though it may only have been slow.
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
  if [[ -t 0 ]]; then
    read -rsp "auth key (single-use, tagged, pre-approved, not ephemeral): " key >&2 && echo >&2
  else IFS= read -r key || true; fi
  [[ -n "$key" ]] || return 1
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

# Where the daemon's output goes: nowhere unless PUBLIC_APPS_LOG=1.
daemon_log() {
  if [[ "${PUBLIC_APPS_LOG:-}" = 1 ]]; then printf '%s/tailscaled.log' "$1"; else printf /dev/null; fi
}

# Waits (50 x 0.2 s) for a BackendState other than NoState/Starting/unreadable and prints it; a
# logged-in node reports those while it loads its state, and must not be asked for a key then.
settle_backend_state() {
  local state=""
  for _ in $(seq 1 50); do
    state=$(backend_state)
    case "$state" in
      NoState | Starting | "") sleep 0.2 ;;
      *)
        printf '%s' "$state"
        return 0
        ;;
    esac
  done
  printf '%s' "${state:-unreadable}"
  return 1
}

# Joins only a node that says it needs a login; any other state is not ours to fix with a key.
ensure_logged_in() {
  local state
  state=$(settle_backend_state) || {
    stop_daemon || true
    die "node still '$state' after 10 s: the daemon was stopped"
  }
  case "$state" in
    Running) ;;
    NeedsLogin)
      join_tailnet || {
        stop_daemon || true
        die "could not join the tailnet: key missing on stdin, or refused; the daemon was stopped"
      }
      ;;
    *)
      stop_daemon || true
      die "node is in state '$state', neither Running nor NeedsLogin: the daemon was stopped"
      ;;
  esac
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
    --statedir="$dir/var" --socket="$sock" --port="${PUBLIC_APPS_PORT:-0}" >"$(daemon_log "$dir")" 2>&1 &
  echo $! >"$pidfile"
  wait_until_answering || {
    stop_daemon || true
    die "tailscaled did not open $sock: re-run with PUBLIC_APPS_LOG=1 to keep its output in $dir/tailscaled.log"
  }
  ensure_logged_in
  note "node $(apps_node_name) is up: $(node_dns tsa || true)"
}

# True when $1 is a tailscaled started with this node's --socket (not, say, the main node's).
is_our_daemon() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  [[ "$(cat "/proc/$1/comm" 2>/dev/null || true)" = tailscaled ]] || return 1
  tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | grep -qxF -- "--socket=$(apps_node_socket)"
}

# The serve config lives in the state dir: reset it while the daemon still answers.
reset_funnel_before_stop() {
  is_running || return 0
  tsa funnel reset >/dev/null && return 0
  note "funnel reset failed: the serve config stays in $(apps_node_dir) and the next start re-serves it until 'public-funnel.sh down'"
  return 1
}

# stop_daemon [reset]: end the daemon named by the pidfile when it is ours; with `reset`, close its
# Funnel first. 1 when there is no pidfile or the reset failed.
stop_daemon() {
  local pidfile pid rc=0
  pidfile="$(apps_node_dir)/tailscaled.pid"
  [[ -f "$pidfile" ]] || return 1
  pid=$(cat "$pidfile")
  if is_our_daemon "$pid"; then
    if [[ "${1:-}" = reset ]]; then reset_funnel_before_stop || rc=1; fi
    kill "$pid"
    note "stopped tailscaled $pid"
  else note "pid $pid is not a running tailscaled of ours (socket $(apps_node_socket))"; fi
  rm -f "$pidfile"
  return $rc
}

cmd_stop() {
  [[ -f "$(apps_node_dir)/tailscaled.pid" ]] || die "no pidfile $(apps_node_dir)/tailscaled.pid: nothing of ours to stop"
  stop_daemon reset
}

UNIT=osionos-apps-node.service
unit_dir() { printf '%s/systemd/user' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# The unit runs `start` with this clone's paths and binaries, resolved now. A running daemon of ours
# gets SIGTERM (its serve config stays), so the unit's own start does not refuse a second one.
cmd_autostart() {
  local groot
  groot=$(cd "$SELF/.." && pwd)
  [[ -x "$TAILSCALED_BIN" ]] || die "no tailscaled at $TAILSCALED_BIN: set TAILSCALED_BIN"
  [[ -x "${TAILSCALE_BIN:-$HOME/.local/bin/tailscale}" ]] || die "no tailscale at ${TAILSCALE_BIN:-$HOME/.local/bin/tailscale}: set TAILSCALE_BIN"
  install -d "$(unit_dir)"
  sed -e "s|@GROOT@|$groot|g" -e "s|@NODE@|$(apps_node_name)|g" -e "s|@STATE_DIR@|$(apps_node_dir)|g" \
    -e "s|@TAILSCALED_BIN@|$TAILSCALED_BIN|g" -e "s|@TAILSCALE_BIN@|${TAILSCALE_BIN:-$HOME/.local/bin/tailscale}|g" \
    "$groot/infrastructure/systemd/user/$UNIT.in" >"$(unit_dir)/$UNIT"
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT"
  if ! systemctl --user -q is-active "$UNIT"; then
    if stop_daemon; then
      for _ in $(seq 1 50); do
        is_running || break
        sleep 0.2
      done
    fi
    systemctl --user start "$UNIT" || die "$UNIT did not start: journalctl --user -u $UNIT"
  fi
  [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" = yes ]] ||
    note "linger is off: the node starts at login, not at boot (loginctl enable-linger $(id -un))"
  note "$UNIT installed and running"
}

cmd_autostart_off() {
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$(unit_dir)/$UNIT"
  systemctl --user daemon-reload
  note "$UNIT removed; the node is stopped, its Funnel config kept (start brings it back)"
}

cmd_status() {
  if ! is_running; then
    printf 'node:  %s (not running)\n' "$(apps_node_name)"
    return 0
  fi
  local dns
  dns=$(node_dns tsa || true)
  printf 'node:  %s\n' "${dns:-unreadable}"
  printf 'ports: %s\n' "$(funnel_ports tsa || echo unreadable)"
}

main() {
  local cmd=${1:-}
  command -v jq >/dev/null || die "jq is required"
  case "$cmd" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    autostart) cmd_autostart ;;
    autostart-off) cmd_autostart_off ;;
    *) die "usage: public-node.sh start | stop | status | autostart | autostart-off" ;;
  esac
}
main "$@"
