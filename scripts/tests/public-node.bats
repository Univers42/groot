#!/usr/bin/env bats
# scripts/public-node.sh: the second tailscaled that serves the Mail and Calendar previews. The
# properties under test are the ones the verdict (MC11) names: its own state and socket at mode
# 700, no proxy listener, no second daemon on a socket that answers, a key read from stdin only
# and never echoed or put in argv. tailscaled and tailscale are stubs keeping state under $T.
# Caveat: the stubs do not test that real tailscaled accepts these flags or that the key is valid;
# that first start is run by the user (wiki/runbooks/public-funnel.md).
# `has`/`lacks`, never `! cmd`: a negation that is not the last line never fails a bats test.

bats_require_minimum_version 1.5.0

NODE="$BATS_TEST_DIRNAME/../public-node.sh"
KEY="tskey-auth-SECRETVALUE-123456"

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "$*" >>"$T/tsd.log"\ntouch "$T/node-running"\ntrap '"'"'kill $s; rm -f "$T/node-running"; exit 0'"'"' TERM\nsleep 31 &\ns=$!\nwait\n' >"$T/bin/tailscaled"
  printf '#!/bin/sh\nshift 2\necho "$*" >>"$T/ts.log"\ncase "$1" in\nstatus) [ -f "$T/node-running" ] || exit 1\n  st=NeedsLogin; [ -f "$T/loggedin" ] && st=Running\n  printf "{\\"BackendState\\":\\"%%s\\",\\"Self\\":{\\"DNSName\\":\\"osionos-apps.tail10f2ea.ts.net.\\"}}\\n" "$st" ;;\nup) cat >"$T/stdin-seen"; [ "${UP_RC:-0}" = 0 ] && touch "$T/loggedin"; exit "${UP_RC:-0}" ;;\nfunnel) printf "{\\"AllowFunnel\\":{\\"osionos-apps.tail10f2ea.ts.net:443\\":true,\\"osionos-apps.tail10f2ea.ts.net:8443\\":true}}\\n" ;;\nesac\n' >"$T/bin/tailscale"
  chmod +x "$T/bin/tailscaled" "$T/bin/tailscale"
  export T XDG_STATE_HOME="$T/state" TAILSCALED_BIN="$T/bin/tailscaled" TAILSCALE_BIN="$T/bin/tailscale"
  DIR="$T/state/tailscale-osionos-apps"
  : >"$T/ts.log"
}

teardown() { [ ! -f "$DIR/tailscaled.pid" ] || kill "$(cat "$DIR/tailscaled.pid")" 2>/dev/null || true; }

run_node() { run bash -c "printf '%s\n' \"\${STDIN_KEY-}\" | \"$NODE\" \"\$@\"" _ "$@"; out="$output"; }
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
lacks() {
  if printf '%s\n' "$out" | grep -qF -- "$1"; then
    echo "unexpected in output: $1" >&2
    return 1
  fi
}

@test "start gives the daemon its own state, statedir, socket and port at mode 700, and no proxy listener" {
  STDIN_KEY="$KEY" run_node start
  [ "$status" -eq 0 ]
  grep -qF -- "--tun=userspace-networking" "$T/tsd.log"
  grep -qF -- "--state=$DIR/tailscaled.state" "$T/tsd.log"
  grep -qF -- "--statedir=$DIR/var" "$T/tsd.log"
  grep -qF -- "--socket=$DIR/tailscaled.sock" "$T/tsd.log"
  grep -qF -- "--port=0" "$T/tsd.log"
  [ "$(grep -c -e socks5-server -e outbound-http-proxy-listen "$T/tsd.log" || true)" -eq 0 ]
  [ "$(stat -c %a "$DIR")" = 700 ]
  [ "$(stat -c %a "$DIR/var")" = 700 ]
}

@test "start joins with the key from stdin only: never in argv, a log or the output" {
  STDIN_KEY="$KEY" run_node start
  [ "$status" -eq 0 ]
  grep -qF -- "up --auth-key=file:/dev/stdin --hostname=osionos-apps" "$T/ts.log"
  [ "$(cat "$T/stdin-seen")" = "$KEY" ]
  lacks "$KEY"
  [ "$(cat "$T/ts.log" "$T/tsd.log" | grep -cF -- "$KEY" || true)" -eq 0 ]
  has "node osionos-apps is up: osionos-apps.tail10f2ea.ts.net."
}

@test "start on a node already logged in joins nothing and needs no key" {
  mkdir -p "$DIR"
  touch "$T/loggedin"
  run_node start
  [ "$status" -eq 0 ]
  [ "$(grep -c '^up ' "$T/ts.log" || true)" -eq 0 ]
}

@test "start refuses when a tailscaled already answers on the socket" {
  touch "$T/node-running"
  STDIN_KEY="$KEY" run_node start
  [ "$status" -ne 0 ]
  has "already answers"
  [ ! -e "$T/tsd.log" ]
}

@test "start without a key stops the daemon it started and fails" {
  STDIN_KEY="" run_node start
  [ "$status" -ne 0 ]
  has "could not join the tailnet"
  sleep 0.5
  [ ! -f "$T/node-running" ]
}

@test "start with a refused key stops the daemon it started and never prints the key" {
  UP_RC=1 STDIN_KEY="$KEY" run_node start
  [ "$status" -ne 0 ]
  lacks "$KEY"
  sleep 0.5
  [ ! -f "$T/node-running" ]
}

@test "stop ends the daemon of ours; stop without a pidfile refuses" {
  STDIN_KEY="$KEY" run_node start
  run_node stop
  [ "$status" -eq 0 ]
  has "stopped tailscaled"
  sleep 0.5
  [ ! -f "$T/node-running" ]
  run_node stop
  [ "$status" -ne 0 ]
  has "nothing of ours to stop"
}

@test "status prints the DNS name and the Funnel ports, or says the node is not running" {
  run_node status
  [ "$status" -eq 0 ]
  has "(not running)"
  STDIN_KEY="$KEY" run_node start
  run_node status
  has "node:  osionos-apps.tail10f2ea.ts.net."
  has "ports: 443,8443"
}

@test "a node name outside [a-z0-9-] is refused, and PUBLIC_APPS_NODE moves the state dir" {
  PUBLIC_APPS_NODE='Bad;name' run_node start
  [ "$status" -ne 0 ]
  has "must match"
  PUBLIC_APPS_NODE=other-apps STDIN_KEY="$KEY" run_node start
  [ "$status" -eq 0 ]
  [ -d "$T/state/tailscale-other-apps/var" ]
  PUBLIC_APPS_NODE=other-apps run_node stop
}
