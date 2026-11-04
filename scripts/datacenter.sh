#!/usr/bin/env bash
# datacenter.sh — what `make all` does on a machine with vault42 credentials: deploy the frontends
# here against the grobase in the VM on this host, over TLS, never starting grobase from groot
# (ADR 0047). utils/mk/datacenter.mk strings these steps together.
#
#   setting       print the data center's ssh alias; nothing means this machine has none
#   vault-needed  exit 0 when the vault's tree must be pulled
#   certs         restore the CA certificate and the edge leaf, never the CA key
#   certs-verify  exit 0 when the leaf chains to the CA and is not about to expire
#   configure     check the VM, pin its host key, write the link's settings
#   preflight     read-only checks of the VM, then only the writes they allow
#   trust         prove the CA signs the VM's WAF, then import it in every browser store
#   browsers      relaunch the browsers when a store changed and someone is at the terminal
#
# Caveat: `pending` in the models check looks for missing TABLES (apply-models-migrations.sh), so a
# migration that only adds a column reads as converged and is not applied here (under-reports).
# DATACENTER_MIGRATE=1 replays every file after a verified dump; do that after a models change.
# Caveat: the first host key is read over the unverified alias, trusted because the loopback
# listener is this user's own qemu (kernel-reported pid, uid and comm). A process of this user
# could fake that, but it could read the ssh key anyway. Delete GROBASE_ADMIN_HOST_KEY from
# datacenter.env after rebuilding the VM.
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
CERT_ARCHIVE="$REPO/secrets/grobase-certs.tar.gz"
CONF="${GROBASE_LINK_CONF:-$REPO/.env.grobase-link.local}"
LINK_DIR="${GROBASE_LINK_DIR:-${XDG_RUNTIME_DIR:-/tmp}/track-binocle-link}"
BROWSER_MARK="$LINK_DIR/browsers-stale"
DUMP_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/groot/datacenter-dumps"
DEFAULT_ALIAS=b2b
WAF_PORT=8443
VAULT_FILES=".env.local apps/grobase/.env secrets/grobase-certs.tar.gz"
PG_CTN=mini-baas-postgres
TRUST="$REPO/scripts/certs-trust-user.sh"
MODELS="$REPO/scripts/apply-models-migrations.sh"

note() { printf '[datacenter] %s\n' "$*" >&2; }
die() {
  note "$*"
  exit 1
}

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
    [ -f "$CTL_CFG_DIR/keystore.v42" ] || return 0
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

cmd_certs_verify() {
  local out
  [ -s "$LEAF_KEY" ] || die "no $LEAF_KEY; repair: rm -r apps/grobase/certs, then make all"
  out=$(openssl verify -CAfile "$CA_CERT" "$LEAF_CERT" 2>&1) ||
    die "the edge certificate does not chain to the CA ($out); repair: rm -r apps/grobase/certs, then make all"
  openssl x509 -in "$LEAF_CERT" -noout -checkend 86400 >/dev/null ||
    die "the edge certificate expires within a day; repair: renew it on the VM, then VAULT42_REFRESH=1 make all"
}

# The CA key stays out: this CA has no name constraints, so its key could impersonate any site in
# a browser that trusts it, and nothing on this host signs. certs.mk keeps the generator away from
# a tree without it, because the generator deletes such a CA and mints another.
cmd_certs() {
  if [ ! -s "$CA_CERT" ] || [ ! -s "$LEAF_CERT" ] || [ ! -s "$LEAF_KEY" ]; then
    [ -f "$CERT_ARCHIVE" ] || die "no ${CERT_ARCHIVE#"$REPO"/}; the vault should deliver it: VAULT42_REFRESH=1 make all"
    tar -xzf "$CERT_ARCHIVE" -C "$REPO" apps/grobase/certs/track-binocle-local-ca.pem \
      apps/grobase/certs/localhost.pem apps/grobase/certs/localhost-key.pem ||
      die "${CERT_ARCHIVE#"$REPO"/} does not hold the CA certificate and the edge leaf"
  fi
  cmd_certs_verify
}

vm_ssh() { ssh -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$@"; }

# require_vm ALIAS — the VM answers and runs the WAF, else stop: falling back would start a second
# grobase here, the thing this path exists to prevent.
require_vm() {
  local names
  names=$(vm_ssh "$1" 'docker ps --format "{{.Names}}"' 2>/dev/null) ||
    die "the data center VM ($1) does not answer. Start it: make -C vendor/born2root qemu_start. groot never starts grobase here (make all GROBASE_DATACENTER= takes the local path)."
  grep -qx mini-baas-waf <<<"$names" ||
    die "the VM ($1) answers but mini-baas-waf is not running; start grobase on the VM. groot never starts grobase here."
}

own_vm_listens() {
  local pid
  pid=$(ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n 1)
  [ -n "$pid" ] && [ -O "/proc/$pid" ] || return 1
  case "$(cat "/proc/$pid/comm" 2>/dev/null)" in qemu-system* | VBoxHeadless*) return 0 ;; esac
  return 1
}

# pinned_host_key ALIAS — the VM's key from the machine file, pinned on first use for a VM this
# user's own process serves on loopback. Anything else needs the operator to pin it.
pinned_host_key() {
  local key endpoint
  key=$(machine_value GROBASE_ADMIN_HOST_KEY) || key=""
  if [ -z "$key" ]; then
    endpoint=$(ssh -G "$1" | awk '$1 == "hostname" { h = $2 } $1 == "port" { p = $2 } END { print h, p }')
    case "$endpoint" in
    127.* | "localhost "*) own_vm_listens "${endpoint##* }" ;;
    *) false ;;
    esac || die "cannot prove $1 is this user's own VM; put its host key in $MACHINE_FILE as GROBASE_ADMIN_HOST_KEY=<type> <base64>"
    key=$(vm_ssh "$1" 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{ print $1, $2 }')
    [[ $key =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+$ ]] || die "the VM gave no ed25519 host key"
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
  require_vm "$alias"
  key=$(pinned_host_key "$alias") || exit 1
  addr=$(connect_ip) || exit 1
  umask 077
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

# The dump is taken before any DDL and read back by the same server's pg_restore: a file that
# lists no osionos rows is not a backup, whatever its size.
dump_postgres() {
  local file
  file="$DUMP_DIR/postgres-$(date +%Y%m%d-%H%M%S).dump"
  (umask 077 && mkdir -p "$DUMP_DIR")
  docker exec "$PG_CTN" pg_dump -U postgres -d postgres -Fc >"$file" || die "pg_dump failed"
  docker exec -i "$PG_CTN" pg_restore -l <"$file" | grep -q 'TABLE DATA public osionos_pages' ||
    die "the dump $file does not list osionos_pages; no migration ran"
  note "verified dump: $file"
}

# models_converge — the VM's schema against models/*.sql. Armed realtime triggers come back after
# every grobase `up`, so they are routine and only their own file runs; ADR 0003 records what the
# full replay can do, so DDL waits for an explicit DATACENTER_MIGRATE=1 and a verified dump.
models_converge() {
  local out rc=0
  out=$(sh "$MODELS" --check 2>&1) || rc=$?
  printf '%s\n' "$out" >&2
  ! grep -qE 'not running|query failed' <<<"$out" || die "the VM's postgres could not be read; nothing was written"
  if grep -q 'pending: ' <<<"$out"; then
    [ "${DATACENTER_MIGRATE:-0}" = 1 ] ||
      die "models migrations are pending on the VM. make all DATACENTER_MIGRATE=1 dumps postgres, verifies the dump, then applies them. Nothing was written."
    dump_postgres
    sh "$MODELS" || die "the models migrations failed; the dump is in $DUMP_DIR"
  elif [ "$rc" -ne 0 ]; then
    docker exec -i "$PG_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
      <"$REPO/models/realtime-cdc-off-migration.sql" >/dev/null || die "realtime-cdc-off failed"
  fi
  sh "$MODELS" --check || die "the VM's schema is still not converged"
}

cmd_preflight() {
  local host sock="$LINK_DIR/tenant-control-3022.sock"
  host=$(bash "$REPO/scripts/grobase-link.sh" docker-host) || die "no daemon for the linked VM; re-run make all"
  [ -z "$host" ] || export DOCKER_HOST="$host"
  models_converge
  [ ! -S "$sock" ] || export TENANT_CONTROL_SOCKET="$sock"
  bash "$REPO/scripts/ensure-live-data-access.sh" --check ||
    die "the app's API key does not verify on the VM. make all never issues one: it re-stamps demo rows (ADR 0003). Read that, then: make link-live-data-ensure"
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
setting) cmd_setting ;;
vault-needed) cmd_vault_needed ;;
certs) cmd_certs ;;
certs-verify) cmd_certs_verify ;;
configure) cmd_configure ;;
preflight) cmd_preflight ;;
trust) cmd_trust ;;
browsers) cmd_browsers ;;
*)
  sed -n '6,13p' "$0" >&2
  exit 2
  ;;
esac
