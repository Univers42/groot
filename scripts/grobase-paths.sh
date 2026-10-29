#!/usr/bin/env bash
# grobase-paths.sh — which ways THIS device reaches the grobase data center: each WAF URL
# (TLS verified, never -k) and each ssh target (grobase's Kong running there). A target on the
# tailnet is first checked there (this device connected, the peer online), so a stopped
# Tailscale or an offline machine is named as such instead of "no answer". A new device
# runs it first; the per-path recipes are in wiki/runbooks/grobase-link.md.
#
# Ponytail: a PASS proves the edge answered or that ssh+docker work, NOT that a login or a
# groot link will succeed (`grobase doctor` / `make link-verify` prove those); an ssh PASS
# needs a key loaded (BatchMode never prompts for a password).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
note() { printf '%s\n' "$*" >&2; }
die() {
  note "$*"
  exit 2
}
# shellcheck source=scripts/lib/grobase-link-target.sh
. "$REPO/scripts/lib/grobase-link-target.sh"

usage() {
  cat <<'USAGE'
usage: grobase-paths.sh [--ca FILE] [TARGET...]
  --ca FILE  the CA that signs the WAF certificate (default: GROBASE_CA_FILE, then
             ./.env.grobase-link, then the system store)
  TARGET     https://host[:port] or http://… (a WAF URL), or ssh://[user@]host[:port],
             user@host, an ssh alias. None: GROBASE_API_URL and GROBASE_TARGET from the config
Exit codes: 0 every path works, 1 one fails, 2 usage or config error.
USAGE
}

conf() { bash "$REPO/scripts/grobase-link.sh" conf "$1" 2>/dev/null || true; }
row() { printf '%-6s %-7s %-50s %s\n' "$@"; }

configured_targets() {
  local api target
  api=$(conf GROBASE_API_URL)
  target=$(conf GROBASE_TARGET)
  [ -z "$api" ] || printf '%s\n' "$api"
  case "$target" in auto | local | "" | "$api") ;; *) printf '%s\n' "$target" ;; esac
}

probe_url() { # URL CA
  local url=${1%/} code verify detail=""
  read -r code verify < <(curl -s -o /dev/null -m 8 -w '%{http_code} %{ssl_verify_result}' \
    ${2:+--cacert "$2"} "$url/auth/v1/health")
  if [ "${verify:-0}" != 0 ]; then
    row FAIL url "$url" "TLS verify failed (code $verify): wrong CA or a name the certificate does not carry"
    return 1
  fi
  [ "${code:-000}" != 000 ] || { row FAIL url "$url" "no answer" && return 1; }
  case "$url" in http://*) detail=plaintext ;; esac
  row PASS url "$url" "$detail"
}

# ssh_failure STDERR — why ssh failed, from OpenSSH's own message. A changed or unknown host
# key used to read "refused or timed out" and sent people debugging the network instead.
ssh_failure() {
  case "$1" in
  *"REMOTE HOST IDENTIFICATION HAS CHANGED"* | *"Host key verification failed"*)
    echo "host key unknown or changed: check known_hosts (ssh-keygen -R HOST), never just accept it" ;;
  *"Permission denied"*) echo "no key accepted (BatchMode never prompts: ssh-add one)" ;;
  *"Connection refused"*) echo "ssh refused" ;;
  *"timed out"* | *"No route to host"*) echo "ssh timed out" ;;
  "") echo "ssh refused or timed out" ;;
  *) echo "ssh failed: $(tail -n1 <<<"$1")" ;;
  esac
}

probe_ssh() { # TARGET
  local names err
  err=$(mktemp) || die "mktemp failed"
  # shellcheck disable=SC2046 # ssh_args prints a dest and an optional -p port, never spaces
  if ! names=$(ssh_once $(ssh_args "$1") "docker ps --format '{{.Names}}'" 2>"$err"); then
    row FAIL ssh "$1" "$(ssh_failure "$(cat "$err")")"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  grep -qx mini-baas-kong <<<"$names" || { row FAIL ssh "$1" "no mini-baas-kong running there" && return 1; }
  row PASS ssh "$1" ""
}

# TARGET -> the host it names: a URL, ssh://[user@]host[:port], user@host or an alias.
target_host() {
  local host=${1#*://}
  host=${host##*@}
  host=${host%%/*}
  printf '%s\n' "${host%%:*}"
}

# Caveat: a tailnet host is a literal *.ts.net name or a 100.64.0.0/10 address; an ssh alias
# whose HostName is on the tailnet, or a tailnet IPv6 address, skips this layer and fails
# only as "no answer" / "ssh timed out" at the probe below.
is_tailnet_host() {
  local second
  case "$1" in
  *.ts.net) return 0 ;;
  100.*.*.*)
    second=${1#100.}
    second=${second%%.*}
    [ "$second" -ge 64 ] 2>/dev/null && [ "$second" -le 127 ]
    ;;
  *) return 1 ;;
  esac
}

# HOST: this device on the tailnet, and HOST a peer it can see online. Each FAIL names the repair.
probe_tailnet() {
  local status state peer
  command -v tailscale >/dev/null ||
    { row FAIL tailnet "$1" "tailscale is not installed here: https://tailscale.com/download, then tailscale up" && return 1; }
  status=$(tailscale status --json 2>/dev/null) ||
    { row FAIL tailnet "$1" "tailscaled is not running here: start it, then tailscale up" && return 1; }
  state=$(jq -r '.BackendState // "unknown"' <<<"$status")
  case "$state" in
  Running) ;;
  NeedsLogin) row FAIL tailnet "$1" "this device is logged out of the tailnet: tailscale up" && return 1 ;;
  *) row FAIL tailnet "$1" "tailscale is $state here: tailscale up" && return 1 ;;
  esac
  peer=$(jq -r --arg h "$1" '[.Peer // {} | .[]
    | select((.DNSName | rtrimstr(".")) == $h or ((.TailscaleIPs // []) | index($h)))]
    | first // empty | "\(.Online // false) \(.LastSeen // "")"' <<<"$status")
  case "$peer" in
  "") row FAIL tailnet "$1" "not a peer of this tailnet: a wrong name, or another tailnet (tailscale status lists them)" ;;
  true*) row PASS tailnet "$1" "peer online" && return 0 ;;
  *) row FAIL tailnet "$1" "peer offline (last seen ${peer#* }): start that machine, or set GROBASE_TARGET to one online" ;;
  esac
  return 1
}

main() {
  local ca="" targets=() t pass=0
  while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help) usage && exit 0 ;;
    --ca) [ $# -ge 2 ] || die "--ca needs a FILE" && ca=$2 && shift ;;
    -*) usage >&2 && exit 2 ;;
    *) targets+=("$1") ;;
    esac
    shift
  done
  [ -n "$ca" ] || ca=${GROBASE_CA_FILE:-$(conf GROBASE_CA_FILE)}
  [ -z "$ca" ] || [ -r "$ca" ] || die "CA file not readable: $ca"
  [ ${#targets[@]} -gt 0 ] || mapfile -t targets < <(configured_targets)
  [ ${#targets[@]} -gt 0 ] || die "no targets: set GROBASE_TARGET and/or GROBASE_API_URL in ./.env.grobase-link, or pass them"
  row RESULT KIND TARGET DETAIL
  for t in "${targets[@]}"; do
    ! is_tailnet_host "$(target_host "$t")" || probe_tailnet "$(target_host "$t")" || continue
    case "$t" in http://* | https://*) probe_url "$t" "$ca" ;; *) probe_ssh "$t" ;; esac && pass=$((pass + 1))
  done
  printf '%d/%d paths work\n' "$pass" "${#targets[@]}"
  [ "$pass" -eq "${#targets[@]}" ]
}

main "$@"
