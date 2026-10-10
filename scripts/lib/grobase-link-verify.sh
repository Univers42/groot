#!/usr/bin/env bash
# grobase-link-verify.sh — the connectivity test behind `make link-verify`, run at the end
# of every `make link` and `make link-frontends-up`: from inside each frontend container
# that shares grobase's network, one request to every grobase name the link serves, then
# the browser's path through the TLS edge, then the browser's trust in that edge's CA. Each
# probe must be answered by the real service,
# because a listening relay proves nothing: socat accepts first and fails behind. Sourced
# by scripts/grobase-link.sh, which defines note, die, SOCAT_IMG, SERVICES, ROUTES and
# state_get before sourcing; define-only, sets no shell option. The pure parts (the specs,
# the consumer filter, the probe script's verdicts, the exit codes) are tested by
# scripts/tests/grobase-link.bats with a stub docker and a stub socat.
#
# Ponytail: a frontend that is not running is not probed, so a green verify right after
# `make link` on a fresh machine says nothing about the frontends; it runs again at the end
# of link-frontends-up. And the probe sends its own request, not the frontend's: a service
# configured with another host name passes here and fails for real. The 5 s budgets are
# generous for an idle host, not for a busy one: with browsers starting and containers being
# recreated at the same time, 3 of 5 names timed out from every frontend (2026-10-08 23:30,
# green again 2 min later), so a FAIL during heavy load is re-run before it is believed.

LINK_NET=mini-baas_mini-baas
EDGE_SERVICE=local-https-proxy # the TLS edge the browser talks to; its 8444 is Kong by name
EDGE_CPORT=8444
# The CA the edge serves: common.mk's LOCAL_CA_CERT (make passes it), else grobase's default.
LINK_CA=${LOCAL_CA_CERT:-apps/grobase/certs/track-binocle-local-ca.pem}
case $LINK_CA in /*) ;; *) LINK_CA="$REPO/$LINK_CA" ;; esac

# Runs inside the probe container (alpine sh, socat on PATH): "$@" are name:port:kind, one
# "ok|FAIL name:port <first line>" per spec, exit 1 when any failed. http: Kong's own `/`
# 404 is a complete answer (runbook, "What it gets wrong"); redis: PING answers +PONG, or
# -NOAUTH when a password is set, both from the server; smtp: the 220 banner arrives unasked,
# so nothing is sent. The sender sleeps 1 s after the request so socat does not half-close
# at once: realtime's server drops a half-closed request unanswered (2026-10-08: 0 bytes in
# 12/12 probes, 200 with the socket kept open) and the smtp banner raced the close (1/12).
# shellcheck disable=SC2016 # expanded by the probe container's sh, not here
PROBE_SH='rc=0
for spec in "$@"; do
  host=${spec%%:*}; rest=${spec#*:}; port=${rest%%:*}; kind=${rest#*:}
  case $kind in
  http) req="GET / HTTP/1.0\r\n\r\n"; pat="HTTP/*" ;;
  redis) req="PING\r\n"; pat="[+-]*" ;;
  smtp) req=""; pat="220*" ;;
  *) req=""; pat="?*" ;;
  esac
  out=$({ printf "$req"; sleep 1; } | socat -T5 -t1 - "TCP:$host:$port,connect-timeout=5" 2>/dev/null | head -c 120 | tr -d "\r")
  first=$(printf "%s\n" "$out" | head -n1 | cut -c1-48)
  case $out in
  $pat) printf "ok   %s:%s  %s\n" "$host" "$port" "$first" ;;
  *) printf "FAIL %s:%s  %s\n" "$host" "$port" "${first:-no answer}"; rc=1 ;;
  esac
done
exit $rc'

# "<name>:<port>:<kind>" for every grobase name the link serves: all of SERVICES in local
# mode (the names are grobase's own containers there), else the ones ROUTES relays (direct
# mode relays Kong alone).
verify_specs() {
  local mode relay cport name kind
  mode=$(state_get mode) || mode=
  while read -r relay _ cport name kind; do
    [ "$mode" = local ] || grep -q "^$relay " "$ROUTES" 2>/dev/null || continue
    printf '%s:%s:%s\n' "$name" "$cport" "$kind"
  done <<<"$SERVICES"
}

# The frontends: every container on grobase's network that is neither one of grobase's
# own (mini-baas-*) nor the relay.
link_consumers() {
  docker network inspect "$LINK_NET" -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null |
    grep -vE '^mini-baas-|(^|-)grobase-link-[0-9]+$' | sort || true
}

# One probe container inside CONTAINER's network namespace: its DNS, its network, its view
# of the names, whatever that frontend's image ships.
probe_from() { # <container> <spec>...
  local c=$1
  shift
  docker run --rm --network "container:$c" --entrypoint sh "$SOCAT_IMG" -c "$PROBE_SH" probe "$@" 2>&1
}

# The browser's path: this host, the TLS edge (nginx), then Kong by name through the link.
# Kong without an apikey answers 401 on a route, which is still Kong. Skipped with a note
# while the edge is not running (before frontends-up). The edge's certificate is the local
# CA's; it is checked when the CA file is there, else the probe is about reachability only.
probe_edge() {
  local id port code trust=(-k)
  id=$(docker ps -q --filter "label=com.docker.compose.service=$EDGE_SERVICE" | head -n1)
  if [ -z "$id" ]; then
    note "verify: $EDGE_SERVICE is not running; the browser path is probed after link-frontends-up"
    return 0
  fi
  port=$(docker port "$id" "$EDGE_CPORT/tcp" 2>/dev/null | head -n1 | sed 's/.*://')
  if [ -z "$port" ]; then
    printf 'FAIL edge  %s publishes no %s/tcp\n' "$EDGE_SERVICE" "$EDGE_CPORT"
    return 1
  fi
  [ ! -f "$LINK_CA" ] || trust=(--cacert "$LINK_CA")
  # Ponytail: -m 10, and the host part of `docker port` is dropped (0.0.0.0 and 127.0.0.1 are
  # both reached on 127.0.0.1, the only values detect-bind-addr.sh emits): a VM answering
  # slower under load, or an edge bound to one LAN address, reads as FAIL.
  code=$(curl -s "${trust[@]}" -o /dev/null -m 10 -w '%{http_code}' "https://127.0.0.1:$port/auth/v1/health" || true)
  case "$code" in
  200 | 401) printf 'ok   edge  https://127.0.0.1:%s/auth/v1/health  Kong HTTP %s\n' "$port" "$code" ;;
  *)
    printf 'FAIL edge  https://127.0.0.1:%s/auth/v1/health  HTTP %s\n' "$port" "${code:-000}"
    return 1
    ;;
  esac
}

# The browser's trust: the CA the edge serves must be the one in this user's browser stores
# (scripts/certs-trust-user.sh --check): a copy from an older tree is the usual cause of a
# red padlock on a stack curl is happy with. Skipped with a note before `make certs`.
probe_trust() {
  if [ ! -f "$LINK_CA" ]; then
    note "verify: no CA at $LINK_CA yet; browser trust is checked once make certs has run"
    return 0
  fi
  bash "$REPO/scripts/certs-trust-user.sh" --check "$LINK_CA"
}

# A store behind the CA fails link-verify and the verify that ends link-frontends-up, which
# runs after certs-trust-user. `make link` runs before that import, so there it is a note
# (LINK_VERIFY_TRUST=note): failing it would stop the pipeline that repairs the store.
trust_failed() {
  if [ "${LINK_VERIFY_TRUST:-fail}" = note ]; then
    note "verify: a browser store is behind the CA (above): link-frontends-up imports it, or: make certs-trust-user"
  else
    fails=$((fails + 1))
  fi
}

verify_summary() { # <frontends probed> <failures>
  [ "$2" -eq 0 ] || die "verify: $2 FAIL above; the frontends do not all reach grobase through this link"
  if [ "$1" -eq 0 ]; then
    note "verify: no frontend is on $LINK_NET yet; it runs again at the end of make link-frontends-up"
  else
    note "verify: $1 frontends reach grobase through the $(state_get mode) link to $(state_get target)"
  fi
}

# Every frontend at once (one probe container each; ~5 s in all, not 5 s per frontend):
# DIR/<container>.out holds its lines, DIR/<container>.rc exists when its probe failed.
probe_all() { # <dir> <consumers, one per line> <spec>...
  local dir=$1 consumers=$2 c
  shift 2
  while read -r c; do
    [ -n "$c" ] || continue
    { probe_from "$c" "$@" >"$dir/$c.out" 2>&1 || : >"$dir/$c.rc"; } &
  done <<<"$consumers"
  wait
}

# The matrix: every frontend x every served name, then the edge. Exit 1 on any FAIL.
cmd_verify() {
  local specs consumers c fails=0 n=0
  state_get mode >/dev/null 2>&1 || die "no link; open one with: make link"
  specs=$(verify_specs)
  [ -n "$specs" ] || die "verify: the link serves no grobase name (no routes); re-run make link"
  consumers=$(link_consumers)
  VERIFY_DIR=$(mktemp -d "$LINK_DIR/verify.XXXXXX") # global: the EXIT trap outlives this scope
  trap 'rm -rf "$VERIFY_DIR"' EXIT
  # shellcheck disable=SC2086 # specs are name:port:kind words, by construction
  probe_all "$VERIFY_DIR" "$consumers" $specs
  while read -r c; do
    [ -n "$c" ] || continue
    n=$((n + 1))
    [ ! -e "$VERIFY_DIR/$c.rc" ] || fails=$((fails + 1))
    awk -v c="$c" '{ printf "  %-38s %s\n", c, $0 }' "$VERIFY_DIR/$c.out"
  done <<<"$consumers"
  probe_edge | sed 's/^/  /' || fails=$((fails + 1))
  probe_trust | sed 's/^/  /' || trust_failed
  verify_summary "$n" "$fails"
}
