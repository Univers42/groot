#!/usr/bin/env bash
# grobase-link-set.sh — write where grobase is into the file `make link` reads, after checking each
# value's shape, then prove the result with grobase-paths.sh. The user names the address; this
# script only refuses a malformed one and offers what it can detect (this daemon's Kong, ssh
# aliases, born2root VMs) as choices. The file is GROBASE_LINK_CONF, else ./.env.grobase-link,
# so it is the one grobase-link.sh reads on this machine (a vault42 host exports the .local name).
#
# Caveat: the checks are shape-only (scheme, host[:port], alias charset, readable PEM); a
# well-formed address of the wrong machine passes them, and only the closing probe catches it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"
CONF="${GROBASE_LINK_CONF:-$REPO/.env.grobase-link}"
KEYS="GROBASE_TARGET GROBASE_API_URL GROBASE_CA_FILE GROBASE_REMOTE_DIR GROBASE_LINK_HOST_PORT GROBASE_IDE_SSH GROBASE_ADMIN_SSH GROBASE_CONNECT_IP"

note() { printf '[link-set] %s\n' "$*" >&2; }
die() {
  note "$*"
  exit 1
}
current() { get_env "$CONF" "$1" 2>/dev/null || true; }

is_alias() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._@:-]*$ ]]; }
is_url() { [[ $1 =~ ^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/.*)?$ ]]; }
is_ssh_url() { [[ $1 =~ ^ssh://([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+(:[0-9]{1,5})?$ ]]; }
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# check KEY VALUE — exit 1 with the reason when VALUE cannot mean KEY. Empty clears a key.
check() {
  [ -n "$2" ] || return 0
  case "$1" in
  GROBASE_TARGET) [[ $2 == auto || $2 == local ]] || is_ssh_url "$2" || is_url "$2" || is_alias "$2" ||
    die "GROBASE_TARGET=$2: want auto, local, ssh://[user@]host[:port], http(s)://host[:port] or an ssh alias" ;;
  GROBASE_API_URL) [[ $2 == https://* ]] && is_url "$2" || die "GROBASE_API_URL=$2: want https://host[:port], the WAF clients call" ;;
  GROBASE_CA_FILE) [ -r "$2" ] && grep -q 'BEGIN CERTIFICATE' "$2" || die "GROBASE_CA_FILE=$2: not a readable PEM certificate" ;;
  GROBASE_REMOTE_DIR) [[ $2 == /* ]] || die "GROBASE_REMOTE_DIR=$2: want an absolute path on that machine" ;;
  GROBASE_LINK_HOST_PORT) [[ $2 =~ ^[0-9]{1,5}$ ]] && [ "$2" -le 65535 ] || die "GROBASE_LINK_HOST_PORT=$2: want 0-65535" ;;
  GROBASE_IDE_SSH | GROBASE_ADMIN_SSH) is_alias "$2" || die "$1=$2: want an ssh alias or user@host, not starting with -" ;;
  GROBASE_CONNECT_IP) is_ipv4 "$2" || die "GROBASE_CONNECT_IP=$2: want an IPv4 address" ;;
  *) die "$1 is not a link setting; known: $KEYS" ;;
  esac
}

# The same ssh candidates `auto` probes, plus this daemon's grobase, as numbered choices.
detected() {
  # shellcheck source=scripts/lib/grobase-link-target.sh
  . "$REPO/scripts/lib/grobase-link-target.sh"
  ! local_has_grobase || printf 'local\n'
  ssh_candidates | sed '/^ssh:\/\//!s|^|ssh://|' | awk '!seen[$0]++'
}

# ask KEY HINT — prompt on the terminal with the current value as the default.
ask() {
  local v
  read -r -p "$1 ($2) [$(current "$1")]: " v </dev/tty || v=
  printf '%s\n' "${v:-$(current "$1")}"
}

# "KEY hint" for each key a kind of target uses; the others are left as they are.
keys_for() {
  case "$1" in
  local) ;;
  http://* | https://*) printf '%s\n' \
    'GROBASE_CA_FILE PEM CA signing that Kong, empty = public CA' \
    'GROBASE_CONNECT_IP IPv4 the relay dials, empty = the URL host' \
    'GROBASE_IDE_SSH ssh alias of the IDE machine, empty = none' \
    'GROBASE_ADMIN_SSH ssh alias for bring-up, empty = none' ;;
  *) printf '%s\n' \
    'GROBASE_API_URL https://<vm>.<tailnet>.ts.net:8443, the WAF clients call; needed' \
    'GROBASE_REMOTE_DIR its grobase checkout, empty = asked of it' ;;
  esac
}

interactive() {
  local -a found
  local t k hint
  mapfile -t found < <(detected 2>/dev/null || true)
  note "where is grobase? detected here: ${found[*]:-nothing}"
  for k in "${!found[@]}"; do printf '  %d) %s\n' "$((k + 1))" "${found[$k]}" >&2; done
  t=$(ask GROBASE_TARGET "a number above, or auto|local|ssh://…|https://…|alias")
  [[ ! $t =~ ^[0-9]+$ ]] || [ -z "${found[$((t - 1))]:-}" ] || t=${found[$((t - 1))]}
  printf 'GROBASE_TARGET=%s\n' "$t"
  while read -r k hint; do printf '%s=%s\n' "$k" "$(ask "$k" "$hint")"; done < <(keys_for "$t")
}

show() {
  local k
  note "settings in $CONF (unset = the default in .env.grobase-link.example):"
  for k in $KEYS; do printf '%s=%s\n' "$k" "$(current "$k")"; done
}

write_all() { # KEY=value lines on stdin
  local kv
  [ -f "$CONF" ] || [ ! -f "$REPO/.env.grobase-link.example" ] ||
    (umask 077 && grep '^#' "$REPO/.env.grobase-link.example" >"$CONF")
  while IFS= read -r kv; do put_env "$CONF" "${kv%%=*}" "${kv#*=}" || die "cannot write $CONF"; done
  note "wrote $CONF"
}

main() {
  local -a pairs=()
  local kv
  case "${1:-}" in -h | --help)
    printf 'usage: grobase-link-set.sh [KEY=value...]   keys: %s\n  none on a terminal: asks, offering what it detects; none elsewhere: prints the settings\n' "$KEYS"
    return 0 ;;
  esac
  if [ $# -gt 0 ]; then pairs=("$@")
  elif [ -t 0 ] && [ -r /dev/tty ]; then mapfile -t pairs < <(interactive)
  else show && return 0; fi
  for kv in "${pairs[@]}"; do [[ $kv == *=* ]] || die "$kv: want KEY=value"; check "${kv%%=*}" "${kv#*=}"; done
  printf '%s\n' "${pairs[@]}" | write_all
  [ "${LINK_SET_PROBE:-1}" = 0 ] && return 0
  GROBASE_LINK_CONF="$CONF" bash "$REPO/scripts/grobase-paths.sh" ||
    die "saved, but not every path answers yet: fix the address or bring that grobase up, then make link-paths"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
main "$@"
