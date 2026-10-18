#!/usr/bin/env bash
# public-funnel.sh — open and close the Tailscale Funnel in front of the three public frontends,
# and prove the stack behind it is the public build before anything is exposed.
#   up [443|all]       verify --pre, then open 443 (website) alone, or 443 + 8443 (osionos app)
#                      + 10000 (bridge). Nothing else is ever exposed.
#   up apps            verify --pre, then open 443 -> 3102 (Mail) and 8443 -> 3103 (Calendar) on the
#                      second node (scripts/public-node.sh start first)
#   down               funnel reset on BOTH nodes; the containers keep running on localhost
#   status             both nodes: name and open Funnel ports
#   verify [--pre] [443|all|apps]   PASS/FAIL/SKIP per check, exit 1 on any FAIL (lib/public-verify.sh)
#   env                create ./.env.public from the example, mint AUTH_LINK_SIGNING_KEY (mode 600)
# Settings (environment): TAILSCALE_BIN, TAILSCALE_SOCKET, PUBLIC_ENV_FILE, PUBLIC_PROJECT,
# PUBLIC_EDGE_BASE, PUBLIC_APP_IMAGE, PUBLIC_WEB_IMAGE, PUBLIC_TS_PROXY. wiki/runbooks/public-funnel.md.
#
# Caveat: Funnel needs tailscaled to have a state dir for its certificate (--statedir); the
# born2root seat starts it --state=mem:, which serves a TLS alert to every visitor (verify's tls
# check FAILs on it). A daemon whose state is in memory also loses the node name and the Funnel
# config on restart; `verify` then fails on the name and `up` has to be run again.
# With PUBLIC_MAIL_ORIGIN and PUBLIC_CALENDAR_ORIGIN set, the apps checks need the apps node
# serving: run `up apps` FIRST. `up 443` or `up all` before it FAILs its post-open verify and
# resets BOTH nodes. `up apps` dies before opening anything when the origins are unset.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${PUBLIC_REPO:-$(cd "$SELF/.." && pwd)}"
GIT_REPO="$REPO"
# shellcheck source=scripts/lib/envfile.sh
. "$SELF/lib/envfile.sh"
# shellcheck source=scripts/lib/public-verify.sh
. "$SELF/lib/public-verify.sh"

# Exported only so the checks sourced above read them as configuration: paths and image names.
ENV_FILE="${PUBLIC_ENV_FILE:-$REPO/.env.public}"
LOCAL_ENV="$REPO/.env.local"
REMOTE_ENV="$REPO/.env.grobase-remote"
APP_IMAGE="${PUBLIC_APP_IMAGE:-track-binocle/osionos-web:public}"
WEB_IMAGE="${PUBLIC_WEB_IMAGE:-track-binocle/opposite-osiris-web:public}"
export GIT_REPO ENV_FILE LOCAL_ENV REMOTE_ENV APP_IMAGE WEB_IMAGE
PROJECT="${PUBLIC_PROJECT:-track-binocle}"
TAILSCALE_BIN="${TAILSCALE_BIN:-$HOME/.local/bin/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-$HOME/.local/state/tailscale/tailscaled.sock}"
# public port:local loopback port (the local-https-proxy listeners); the apps node's map is
# APPS_FUNNEL_MAP in lib/public-tailnet.sh
FUNNEL_MAP="443:4322 8443:3001 10000:4000"
# The userspace tailscaled's outbound proxy, through which verify reaches the node's own cert.
TS_PROXY="${PUBLIC_TS_PROXY:-socks5h://localhost:1055}"

note() { printf '[public-funnel] %s\n' "$*" >&2; }
die() {
  note "$*"
  exit 1
}
ts() { "$TAILSCALE_BIN" --socket "$TAILSCALE_SOCKET" "$@"; }
penv() { get_env "$ENV_FILE" "$1"; }
svc_container() {
  docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" | head -n1
}

# Ports to open for a scope, as "public:local" pairs.
scope_pairs() {
  local pair
  for pair in $FUNNEL_MAP; do
    if [ "$1" = all ] || [ "${pair%%:*}" = 443 ]; then printf '%s\n' "$pair"; fi
  done
}

# Both resets are attempted, and a node whose state is on disk but whose socket is silent counts
# as a failed reset: its persisted serve config may still be exposing. CLOSED lists what was reset.
reset_both() {
  local rc=0
  CLOSED=""
  if ts funnel reset; then CLOSED="main"; else rc=1; fi
  if tsa status --json >/dev/null 2>&1; then
    if tsa funnel reset; then CLOSED+="${CLOSED:+, }apps"; else rc=1; fi
  elif [ -e "$(apps_node_dir)" ]; then
    note "apps node has state in $(apps_node_dir) but nothing answers on $(apps_node_socket): its Funnel could not be reset"
    rc=1
  fi
  return $rc
}

# Any failure after something was opened closes both nodes: the verify judges the whole exposure.
fail_closed() {
  reset_both || note "reset incomplete (closed: ${CLOSED:-none}): check both nodes with 'status'"
  die "$1"
}

# Opens the apps node's Funnel; the checks already passed in pre mode.
open_apps() {
  local pair
  for pair in $APPS_FUNNEL_MAP; do
    tsa funnel --bg "--https=${pair%%:*}" "https+insecure://127.0.0.1:${pair##*:}" || fail_closed "apps funnel on ${pair%%:*} failed: both nodes reset"
  done
  run_verify full apps || fail_closed "post-open verify failed: both nodes reset"
  note "apps public on $(penv PUBLIC_MAIL_ORIGIN || true) and $(penv PUBLIC_CALENDAR_ORIGIN || true)"
}

cmd_up() {
  local scope=${1:-443} pair
  case "$scope" in 443 | all | apps) ;; *) die "usage: up [443|all|apps]" ;; esac
  if [ "$scope" = all ] && [ -z "$(penv AUTH_TRUSTED_PROXY_HOPS || true)" ]; then
    die "refusing 'up all': AUTH_TRUSTED_PROXY_HOPS is unset in $ENV_FILE (measure it on 443 first)"
  fi
  if [ "$scope" = apps ] && ! apps_configured; then
    die "refusing 'up apps': set PUBLIC_MAIL_ORIGIN and PUBLIC_CALENDAR_ORIGIN in $ENV_FILE (the apps checks need the origins)"
  fi
  run_verify pre || die "verify --pre failed: the Funnel stays closed"
  if [ "$scope" = apps ]; then
    open_apps
    return
  fi
  for pair in $(scope_pairs "$scope"); do
    ts funnel --bg "--https=${pair%%:*}" "https+insecure://127.0.0.1:${pair##*:}" || fail_closed "funnel on ${pair%%:*} failed: both nodes reset"
  done
  run_verify full "$scope" || fail_closed "post-open verify failed: both nodes reset"
  note "public on $(penv PUBLIC_ORIGIN) (scope $scope)"
}

cmd_down() {
  reset_both || die "a funnel reset failed (closed: ${CLOSED:-none}): check both nodes with 'status'"
  note "Funnel closed on: $CLOSED; the containers keep running on localhost"
}

# $1 line label, $2 CLI function, $3 what to print when the daemon does not answer
node_line() {
  local dns
  if dns=$(node_dns "$2"); then printf '%s  %s\n' "$1" "${dns:-unreadable}"; else printf '%s  %s\n' "$1" "$3"; fi
}

cmd_status() {
  node_line "node:" ts unreadable
  printf 'ports: %s\n' "$(funnel_ports ts || echo unreadable)"
  node_line "apps node:" tsa "not running"
  printf 'apps ports: %s\n' "$(funnel_ports tsa || echo unreadable)"
}

cmd_verify() {
  local mode=full scope=""
  for a in "$@"; do
    case "$a" in --pre) mode=pre ;; 443 | all | apps) scope=$a ;; *) die "usage: verify [--pre] [443|all|apps]" ;; esac
  done
  run_verify "$mode" "$scope"
}

# Creates the file from the example and mints the signing key; never prints a value.
# The key comes from od, not openssl: without openssl a failed $(…) is not caught by set -e and
# the file got an empty key (CI's bats image, run 39148082034); od is in busybox and coreutils.
cmd_env() {
  local key
  [ -f "$ENV_FILE" ] || (umask 077 && cp "$REPO/.env.public.example" "$ENV_FILE")
  chmod 600 "$ENV_FILE"
  if [ -z "$(penv AUTH_LINK_SIGNING_KEY || true)" ]; then
    key="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
    [ "${#key}" -eq 64 ] || die "could not mint AUTH_LINK_SIGNING_KEY from /dev/urandom; $ENV_FILE left without it"
    put_env "$ENV_FILE" AUTH_LINK_SIGNING_KEY "$key"
    note "minted AUTH_LINK_SIGNING_KEY in $ENV_FILE"
  fi
  for k in OSIONOS_ADMIN_EMAILS AUTH_TRUSTED_PROXY_HOPS; do
    [ -n "$(penv "$k" || true)" ] || note "decide $k in $ENV_FILE"
  done
}

main() {
  local cmd=${1:-}
  [ $# -eq 0 ] || shift
  command -v jq >/dev/null || die "jq is required"
  case "$cmd" in
    up) cmd_up "$@" ;;
    down) cmd_down ;;
    status) cmd_status ;;
    verify) cmd_verify "$@" ;;
    env) cmd_env ;;
    *) die "usage: public-funnel.sh up [443|all|apps] | down | status | verify [--pre] [443|all|apps] | env" ;;
  esac
}
main "$@"
