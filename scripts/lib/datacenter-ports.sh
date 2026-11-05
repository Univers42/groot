# shellcheck shell=bash
# datacenter-ports.sh — which host ports reach the VM, the proof that they do, and the frontend
# origins the VM has to allow. born2root picks the forwards when it builds the VM, so a port that
# is busy on this host moves, and the frontends move too (scripts/host-ports.sh). Nothing here
# assumes a number: the ports come from born2root's record and .env.ports.
# Sourced by scripts/datacenter.sh, which defines note, die, ALIAS, REPO, CA_CERT, admin_ssh,
# cmd_setting, is_own_vm and require_writes.
#
# Caveat: prove_waf accepts any certificate this CA signed, so two VMs restored from one backup, and
# so sharing a CA, pass for each other (under-reports). The alias check and the pinned host key
# narrow that, and neither sees which forward leads to which guest.
# Caveat: a frontend port is only compared with the VM's own ports, and only with what the record
# says. A VM with no record that forwards more than the WAF can still collide at compose up.
# Caveat: the origin lists only grow. An origin a moved frontend has left stays allowed until it is
# removed by hand from /opt/grobase/.env and .env.local: the lists also hold origins groot did not
# put there, such as the public app's, and cannot tell them apart (2026-10-21, a rebuilt list
# dropped that origin and its sockets got 403).
# Caveat: FRONTEND_PORT_NAMES is written by hand. A new page's port has to be added here, and the
# test that reads the compose files fails until it is named on one side or the other.
# Caveat: born2root's `make grobase` writes the profile's REALTIME_ALLOWED_ORIGINS back over
# .env.local. The next make all reads the running containers, sees the gap and pushes again.

# Only for a VM built before born2root recorded its ports. prove_waf proves it before anything
# uses it; it is never taken on trust.
UNRECORDED_WAF_PORT=8443
# The ports a browser loads a page from, so the origins grobase sees. The bridges, the TLS doors to
# grobase, LiveKit and the IDE are called from those pages or from a server, and are no origin here.
FRONTEND_PORT_NAMES="OSIONOS_APP_HOST_PORT OPPOSITE_OSIRIS_HOST_PORT MAIL_HOST_PORT CALENDAR_HOST_PORT DRAWNOSAURUS_HOST_PORT AUTH_GATEWAY_HOST_PORT"
ORIGIN_CONTAINERS="mini-baas-kong mini-baas-realtime mini-baas-gotrue"
# "<variable> <suffix on each origin>". All three are read at container start, and an existing
# grobase already takes them from .env, so a moved frontend needs no change in grobase.
ORIGIN_LISTS="KONG_CORS_ORIGIN_DEV_LIST
REALTIME_ALLOWED_ORIGINS
GOTRUE_URI_ALLOW_LIST /**"

vm_ports_file() { printf '%s/.config/born2root/%s-ports.env\n' "$HOME" "$1"; }

# vm_recorded_port ALIAS NAME — the port, or nothing when there is no record. A record that holds
# no port stops: falling back would hide a broken one behind the old default.
vm_recorded_port() {
  local file value
  file=$(vm_ports_file "$1")
  value=$(get_env "$file" "$2") || return 0
  if [[ ! $value =~ ^[1-9][0-9]{0,4}$ ]] || [ "$value" -gt 65535 ]; then
    die "$file holds $2=$value, which is no port. Build the record again from born2root"
  fi
  printf '%s\n' "$value"
}

waf_port() {
  local port
  port=$(vm_recorded_port "$1" WAF_HOST_PORT) || exit 1
  printf '%s\n' "${port:-$UNRECORDED_WAF_PORT}"
}

# An alias left on an older port can answer from something else, so it is compared before anything
# it says is believed.
require_alias_on_record() {
  local recorded port
  recorded=$(vm_recorded_port "$1" SSH_HOST_PORT) || exit 1
  [ -n "$recorded" ] || return 0
  port=$(ssh -G "$1" | awk '$1 == "port" { print $2; exit }')
  [ "$port" = "$recorded" ] || die "the ssh alias $1 uses port $port, and born2root recorded $recorded in $(vm_ports_file "$1"). Point the alias at the VM again from born2root, then make all"
}

# prove_waf ALIAS — the service on the WAF port presents a certificate this VM's CA signed. The CA
# came from the VM over the pinned ssh path, which is what makes this a statement about this VM. A
# status from behind the WAF proves as much as a 200, so only curl's own failure counts.
prove_waf() {
  local port url origin rc
  port=$(waf_port "$1") || exit 1
  url="https://localhost:$port/"
  origin="the port recorded in $(vm_ports_file "$1")"
  [ -n "$(vm_recorded_port "$1" WAF_HOST_PORT)" ] ||
    origin="the old default: there is no $(vm_ports_file "$1"), so write WAF_HOST_PORT=<n> there if this VM forwards another port"
  curl --noproxy '*' --cacert "$CA_CERT" -s -o /dev/null -m 10 -w '%{http_code}' "$url" >/dev/null
  rc=$?
  case "$rc" in
  0) return 0 ;;
  7 | 28) die "nothing answers on $url, $origin" ;;
  60) die "$CA_CERT does not verify $url, $origin. Another service holds that port, or the CA here is stale: rm -r apps/grobase/certs, then VAULT42_REFRESH=1 make all" ;;
  *) die "$url is not this VM's WAF (curl exit $rc), $origin" ;;
  esac
}

# .env.ports is resolved when make starts, and datacenter-vm can start the VM after that, so a port
# that looked free can be a forward by now. A second make all resolves with the forward in place.
require_ports_apart() {
  local waf ssh_port held
  waf=$(waf_port "$1") || exit 1
  ssh_port=$(vm_recorded_port "$1" SSH_HOST_PORT) || exit 1
  held=$(grep -E "^[A-Z0-9_]+=($waf${ssh_port:+|$ssh_port})\$" "$REPO/.env.ports" 2>/dev/null | head -n 1)
  [ -z "$held" ] || die "$held in .env.ports is a port the VM forwards: it started after the ports were chosen. Run make all again, which chooses around it"
}

cmd_chain() {
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center"
  require_alias_on_record "$ALIAS"
  admin_ssh true || die "the ssh alias $ALIAS does not reach the VM with its pinned host key; make datacenter-configure pins it again"
  prove_waf "$ALIAS"
  require_ports_apart "$ALIAS"
  note "$ALIAS answers on its pinned key, its WAF on https://localhost:$(waf_port "$ALIAS")"
}

# frontend_origins — one origin per page, from the record of what this host publishes.
frontend_origins() {
  local name port
  for name in $FRONTEND_PORT_NAMES; do
    port=$(get_env "$REPO/.env.ports" "$name") || die "no $name in .env.ports: make all resolves it, so run this through make"
    printf 'https://localhost:%s\n' "$port"
  done
}

# with_origins LIST SUFFIX ORIGIN... — LIST with each ORIGIN+SUFFIX added once, nothing removed.
with_origins() {
  local list=$1 suffix=$2 origin
  shift 2
  for origin; do
    case ",$list," in
    *",$origin$suffix,"*) ;;
    *) list="${list:+$list,}$origin$suffix" ;;
    esac
  done
  printf '%s\n' "$list"
}

# origin_changes RUNNING ORIGIN... — one KEY=VALUE per list that lacks an origin. RUNNING is what the
# containers run with, the only state that says an origin is in effect: a file can be ahead of them
# or, after a restore, behind. An empty realtime list checks nothing, so every origin already passes
# and a list would only narrow it.
origin_changes() {
  local running=$1 key suffix current wanted
  shift
  while read -r key suffix; do
    current=$(sed -n "s/^$key=//p" <<<"$running")
    [ "$key" != REALTIME_ALLOWED_ORIGINS ] || [ -n "$current" ] || continue
    wanted=$(with_origins "$current" "$suffix" "$@")
    [ "$wanted" = "$current" ] || printf '%s=%s\n' "$key" "$wanted"
  done <<<"$ORIGIN_LISTS"
}

running_origin_env() {
  admin_ssh "docker inspect -f \"{{range .Config.Env}}{{println .}}{{end}}\" $ORIGIN_CONTAINERS"
}

# Through stdin, not the command line: the guest's login shell would glob the /** of GoTrue's list.
push_origins() {
  {
    cat "$REPO/scripts/lib/envfile.sh"
    printf 'set --'
    printf ' %q' "$@"
    printf '\n'
    cat "$REPO/scripts/lib/datacenter-origins-guest.sh"
  } | admin_ssh 'bash -s'
}

# Read first, so a run with nothing to change writes nothing and restarts nothing. The verdict is
# read back from the containers, not from the push's exit status.
cmd_origins() {
  local origins running changes pairs
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center"
  [ -f "$REPO/.env.ports" ] || die "no .env.ports: make all resolves it, so run this through make"
  origins=$(frontend_origins) || exit 1
  mapfile -t origins <<<"$origins"
  running=$(running_origin_env) || die "cannot read the origin lists from the VM ($ALIAS): are $ORIGIN_CONTAINERS running?"
  changes=$(origin_changes "$running" "${origins[@]}")
  if [ -z "$changes" ]; then
    note "the VM already allows the frontends' origins"
    return 0
  fi
  if ! is_own_vm; then
    note "$ALIAS is not this user's own VM, so nothing was written. Refused until its grobase allows: ${origins[*]}"
    return 0
  fi
  require_writes "allowing the frontends' origins"
  mapfile -t pairs <<<"$changes"
  note "allowing the frontends' origins in the VM: ${pairs[*]%%=*}"
  push_origins "${pairs[@]}" || die "the VM's grobase config holds the origins, but its containers were not recreated. make all tries again"
  running=$(running_origin_env) || die "cannot read the origin lists back from the VM ($ALIAS)"
  changes=$(origin_changes "$running" "${origins[@]}")
  [ -z "$changes" ] || die "the VM's containers still lack the frontends' origins in ${changes%%=*}: the setting did not reach them"
}
