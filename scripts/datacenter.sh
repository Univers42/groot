#!/usr/bin/env bash
# datacenter.sh — what `make all` does on a machine with vault42 credentials: deploy the frontends
# here against the grobase in the VM on this host, over TLS, never starting grobase on the host
# (ADR 0047). utils/mk/datacenter.mk strings these steps together.
#
#   gate          prove the vault can be read, or stop naming what to set
#   setting       print the data center's ssh alias; nothing means this machine has none
#   vault-needed  exit 0 when the vault's tree must be pulled
#   vm            build a VM that does not exist, wait for it, have born2root start grobase, seed
#   configure     pin the VM's host key, write the link's settings
#   certs         copy the CA certificate and the WAF's leaf from the VM, never the CA key
#   certs-verify  exit 0 when the leaf chains to the CA and is not about to expire
#   preflight     check the VM, then only the writes those checks allow
#   trust         prove the CA signs the VM's WAF, then import it in every browser store
#   health        born2root's verdict on the platform, its reach and its forwards
#   verify        prove the plan, the pages, the mounts and the browsers
#   browsers      relaunch the browsers when a store changed and someone is at the terminal
#   dc TARGET     run an allowed grobase target in the VM (datacenter-vm.sh)
#
# Caveat: a models change is seen from a hash of models/*.sql recorded in the VM's database, so a
# file edited on the VM directly reads as converged (under-reports).
# Caveat: the host key of this user's own VM is re-read on every run, trusted because the loopback
# listener is this user's own qemu (kernel-reported pid, uid and comm). A process of this user
# could fake that, but it could read the ssh key anyway. Any other target keeps a strict pin.
# Caveat: the default-route source address assumes the host's forward binds that interface;
# GROBASE_CONNECT_IP in a credential file overrides it. It is re-read on every make all, so a DHCP
# change between two runs leaves the relay dialling the old address until the next make all.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"
CTL_CFG_DIR="${CTL_CFG_DIR:-$HOME/.config/42ctl}"
MACHINE_FILE="$CTL_CFG_DIR/secrets/datacenter.env"
CERT_DIR="${LOCAL_CERT_DIR:-$REPO/apps/grobase/certs}"
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
LEAF_CERT="$CERT_DIR/localhost.pem"
LEAF_KEY="$CERT_DIR/localhost-key.pem"
CONF="${GROBASE_LINK_CONF:-$REPO/.env.grobase-link.local}"
LINK_DIR="${GROBASE_LINK_DIR:-${XDG_RUNTIME_DIR:-/tmp}/track-binocle-link}"
BROWSER_MARK="$LINK_DIR/browsers-stale"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/groot"
DUMP_DIR="$STATE_DIR/datacenter-dumps"
KNOWN_HOSTS="$STATE_DIR/admin_known_hosts"
DEFAULT_ALIAS=b2b
WAF_PORT=8443
VAULT_FILES=".env.local apps/grobase/.env"
PG_CTN=mini-baas-postgres
TRUST="$REPO/scripts/certs-trust-user.sh"
MODELS="$REPO/scripts/apply-models-migrations.sh"

note() { printf '[datacenter] %s\n' "$*" >&2; }
die() {
  note "$*"
  exit 1
}
vm_ssh() { ssh -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$@"; }
# shellcheck source=scripts/lib/datacenter-vm.sh
. "$REPO/scripts/lib/datacenter-vm.sh"
# shellcheck source=scripts/lib/datacenter-gate.sh
. "$REPO/scripts/lib/datacenter-gate.sh"
# shellcheck source=scripts/lib/datacenter-build.sh
. "$REPO/scripts/lib/datacenter-build.sh"
# shellcheck source=scripts/lib/datacenter-verify.sh
. "$REPO/scripts/lib/datacenter-verify.sh"
# shellcheck source=scripts/lib/datacenter-binds.sh
. "$REPO/scripts/lib/datacenter-binds.sh"
# shellcheck source=scripts/lib/datacenter-models.sh
. "$REPO/scripts/lib/datacenter-models.sh"

# machine_value KEY — KEY's first value across the operator's credential files, the same files
# scripts/lib/vault42-session.sh reads. Those files are outside the checkout, so a fresh clone
# keeps them.
machine_value() {
  local file
  while IFS= read -r file; do
    get_env "$file" "$1" && return 0
  done < <(find "$CTL_CFG_DIR" -maxdepth 2 -path "$CTL_CFG_DIR/secret*" -type f 2>/dev/null | sort)
  return 1
}

cmd_setting() {
  local alias
  alias=$(machine_value GROBASE_DATACENTER) || alias=""
  if [ -z "$alias" ]; then
    { machine_value FT_PASSPHRASE || machine_value VAULT42_PASSPHRASE; } >/dev/null || return 0
    [ -f "$CTL_CFG_DIR/keystore.v42" ] || machine_value FT_KEYSTORE_B64 >/dev/null || return 0
    alias=$DEFAULT_ALIAS
  fi
  [ "$alias" = local ] || printf '%s\n' "$alias"
}

cmd_vault_needed() {
  local file
  [ "${VAULT42_REFRESH:-0}" != 1 ] || return 0
  for file in $VAULT_FILES; do
    [ -s "$REPO/$file" ] || return 0
  done
  note "the vault's files are here; VAULT42_REFRESH=1 pulls them again"
  return 1
}

# verify_set CA LEAF KEY — the leaf chains to the CA, is not about to expire, and the key is its own.
verify_set() {
  local out
  [ -s "$3" ] || die "no edge key at $3; make all copies it from the VM"
  out=$(openssl verify -CAfile "$1" "$2" 2>&1) || die "the edge certificate does not chain to the CA ($out); make all copies both from the VM"
  openssl x509 -in "$2" -noout -checkend 86400 >/dev/null || die "the edge certificate expires within a day; renew it on the VM, then make all"
  [ "$(openssl x509 -in "$2" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$3" -pubout | sha256sum)" ] ||
    die "the edge key does not match its certificate"
}

cmd_certs_verify() { verify_set "$CA_CERT" "$LEAF_CERT" "$LEAF_KEY"; }

# The pinned path, not the alias, which carries forwards and an unverified host key.
admin_ssh() {
  local host port user
  read -r host port user < <(ssh -G "$ALIAS" | awk '$1 == "hostname" { h = $2 } $1 == "port" { p = $2 } $1 == "user" { u = $2 } END { print h, p, u }')
  ssh -F /dev/null -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR \
    -o StrictHostKeyChecking=yes -o HostKeyAlias=grobase-admin -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -p "$port" -l "$user" "$host" "$@"
}

# The VM is the authority on its certificates, so a rebuild that minted a CA needs nothing here. The
# CA key stays out: this CA has no name constraints, so its key could impersonate any site in a
# browser that trusts it, and nothing on this host signs. The leaf key is root's on the VM, so it is
# read as the WAF holds it. Each file lands by rename only after the set verifies.
cmd_certs() {
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center"
  (umask 077 && mkdir -p "$CERT_DIR") || die "cannot create $CERT_DIR"
  INCOMING=$(mktemp -d "$CERT_DIR/.incoming.XXXXXX") || die "cannot write in $CERT_DIR"
  trap 'rm -rf "$INCOMING"' EXIT
  admin_ssh "cat $REMOTE_DIR/certs/track-binocle-local-ca.pem" >"$INCOMING/ca" || die "cannot read the VM's CA certificate"
  admin_ssh 'docker exec mini-baas-waf cat /run/secrets/localhost_cert' >"$INCOMING/leaf" || die "cannot read the WAF's certificate"
  admin_ssh 'docker exec mini-baas-waf cat /run/secrets/localhost_key' >"$INCOMING/key" || die "cannot read the WAF's key"
  verify_set "$INCOMING/ca" "$INCOMING/leaf" "$INCOMING/key"
  mv -f "$INCOMING/ca" "$CA_CERT"
  mv -f "$INCOMING/leaf" "$LEAF_CERT"
  mv -f "$INCOMING/key" "$LEAF_KEY"
}

own_vm_listens() {
  local pid
  pid=$(ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n 1)
  [ -n "$pid" ] && [ -O "/proc/$pid" ] || return 1
  case "$(cat "/proc/$pid/comm" 2>/dev/null)" in qemu-system* | VBoxHeadless*) return 0 ;; esac
  return 1
}

# pinned_host_key ALIAS — this user's own VM is read every run and the pin follows it, because a
# rebuild changes the key. Anything else keeps what the machine file holds.
pinned_host_key() {
  local key pinned endpoint
  pinned=$(machine_value GROBASE_ADMIN_HOST_KEY) || pinned=""
  endpoint=$(ssh -G "$1" | awk '$1 == "hostname" { h = $2 } $1 == "port" { p = $2 } END { print h, p }')
  case "$endpoint" in
  127.* | "localhost "*) own_vm_listens "${endpoint##* }" || endpoint="" ;;
  *) endpoint="" ;;
  esac
  if [ -z "$endpoint" ]; then
    [ -n "$pinned" ] || die "cannot prove $1 is this user's own VM; put its host key in $MACHINE_FILE as GROBASE_ADMIN_HOST_KEY=<type> <base64>"
    printf '%s\n' "$pinned"
    return 0
  fi
  key=$(vm_ssh "$1" 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{ print $1, $2 }')
  [[ $key =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+$ ]] || die "the VM gave no ed25519 host key"
  if [ "$key" != "$pinned" ]; then
    put_env "$MACHINE_FILE" GROBASE_ADMIN_HOST_KEY "$key"
    note "pinned the VM's host key in ${MACHINE_FILE#"$HOME"/}"
  fi
  printf '%s\n' "$key"
}

# A container cannot use the host's loopback (rootless Docker refuses it, and 127.0.0.1 there is
# the relay), so the relay dials the host's own address, where the VM's forward listens.
connect_ip() {
  local addr
  addr=$(machine_value GROBASE_CONNECT_IP) || addr=""
  [ -n "$addr" ] || addr=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  [ -n "$addr" ] || addr=$(hostname -I 2>/dev/null | awk '{ print $1 }')
  [ -n "$addr" ] || die "no address for the relay to reach the VM; set GROBASE_CONNECT_IP in $MACHINE_FILE"
  printf '%s\n' "$addr"
}

cmd_configure() {
  local alias key addr
  alias=$(cmd_setting)
  [ -n "$alias" ] || die "this machine has no data center (no vault42 credentials, no GROBASE_DATACENTER)"
  key=$(pinned_host_key "$alias") || exit 1
  addr=$(connect_ip) || exit 1
  umask 077
  mkdir -p "$STATE_DIR"
  printf 'grobase-admin %s\n' "$key" >"$KNOWN_HOSTS"
  cat >"$CONF.tmp" <<EOF
GROBASE_TARGET=https://localhost:$WAF_PORT
GROBASE_API_URL=https://localhost:$WAF_PORT
GROBASE_CA_FILE=$CA_CERT
GROBASE_CONNECT_IP=$addr
GROBASE_ADMIN_SSH=$alias
GROBASE_ADMIN_HOST_KEY=$key
EOF
  mv "$CONF.tmp" "$CONF"
  note "$alias at https://localhost:$WAF_PORT, reached from containers through $addr"
}

cmd_preflight() {
  local host sock="$LINK_DIR/tenant-control-3022.sock"
  ALIAS=$(cmd_setting)
  host=$(bash "$REPO/scripts/grobase-link.sh" docker-host) || die "no daemon for the linked VM; re-run make all"
  [ -z "$host" ] || export DOCKER_HOST="$host"
  models_converge
  [ ! -S "$sock" ] || export TENANT_CONTROL_SOCKET="$sock"
  live_data_converge
}

# --check alone passes on a machine with no store at all, so a browser installed but never started
# would still warn on the first visit.
require_browser_stores() {
  local stores
  stores=$(bash "$TRUST" --check "$CA_CERT" 2>&1) || true
  if command -v firefox >/dev/null 2>&1 && ! grep -qE '^[A-Za-z]+ +firefox ' <<<"$stores"; then
    die "Firefox is installed but has no profile to trust the CA in; start it once, then make all"
  fi
  if command -v google-chrome >/dev/null 2>&1 && ! grep -qE '^[A-Za-z]+ +chrome ' <<<"$stores"; then
    die "Chrome is installed but has no NSS store to trust the CA in; start it once, then make all"
  fi
}

# Anchored on the WAF, because --check compares the stores to the local file: a CA minted here by
# mistake would pass it while every browser warned.
cmd_trust() {
  local url="https://localhost:$WAF_PORT/" code
  code=$(curl --noproxy '*' --cacert "$CA_CERT" -s -o /dev/null -m 10 -w '%{http_code}' "$url") || code=000
  [ "$code" != 000 ] || die "$CA_CERT does not verify $url; repair: rm -r apps/grobase/certs, then VAULT42_REFRESH=1 make all"
  require_browser_stores
  bash "$TRUST" --check "$CA_CERT" >/dev/null 2>&1 && return 0
  bash "$TRUST" "$CA_CERT" || die "the CA could not be imported in the browser stores"
  bash "$TRUST" --check "$CA_CERT" || die "a browser store still lacks the CA"
  : >"$BROWSER_MARK"
}

# Last step of make all. Under the Update button stdin is no terminal, and restarting would close
# the tab that asked for the rebuild.
cmd_browsers() {
  [ -f "$BROWSER_MARK" ] || return 0
  rm -f "$BROWSER_MARK"
  if [ "${GROOT_NO_BROWSER_RESTART:-0}" = 1 ] || [ ! -t 0 ]; then
    note "the browsers' stores changed: relaunch Firefox and Chrome to pick the CA up"
    return 0
  fi
  bash "$REPO/vendor/born2root/setup/host/restart_browsers.sh" ||
    note "the browsers did not restart; relaunch Firefox and Chrome to pick the CA up"
}

case "${1:-}" in
gate) cmd_gate ;;
setting) cmd_setting ;;
vault-needed) cmd_vault_needed ;;
vm) cmd_vm ;;
certs) cmd_certs ;;
certs-verify) cmd_certs_verify ;;
configure) cmd_configure ;;
preflight) cmd_preflight ;;
trust) cmd_trust ;;
health)
  load_vm_paths
  require_born2root health
  born2root_make health
  ;;
verify) cmd_verify ;;
binds) cmd_binds ;;
local-binds) cmd_local_binds ;;
read-binds) cmd_read_binds ;;
browsers) cmd_browsers ;;
dc) cmd_dc "${2:-}" ;;
*)
  sed -n '6,18p' "$0" >&2
  exit 2
  ;;
esac
