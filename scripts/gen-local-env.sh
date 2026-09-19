#!/usr/bin/env bash
# gen-local-env.sh — assemble the ROOT ./.env.local for a NO-VAULT fresh machine.
#
# The frontends (osionos, bridge, auth-gateway, website) authenticate to the
# grobase backend with keys that must match grobase's JWT_SECRET. Those secrets
# are RANDOM per install (apps/grobase/scripts/env/generate-env.sh: openssl rand),
# so we cannot ship them — we DERIVE ./.env.local from grobase's already-generated
# apps/grobase/.env (the source of truth, written synchronously by `make -C
# apps/grobase up` before its containers start). The osionos-only app secrets are
# generated locally; optional cloud keys are left empty.
#
# Wired into `make all` via the `env-local-ensure` step, AFTER backend-up. Run by
# hand for a no-vault machine: `bash scripts/gen-local-env.sh`.
#
# Idempotent: never overwrites an existing ./.env.local (so it won't clobber a
# vault-pulled or hand-edited file) unless FORCE=1. OUT=<path> redirects output
# (used by the self-check to validate without touching the real file).
#
# --check / --sync: the seven BaaS keys below are DERIVED from apps/grobase/.env, and
# that file changes under an existing ./.env.local (a vault pull, a JWT rotation, a
# backend regenerated in LOCAL mode). A stale copy is the recurring "Kong says 401 /
# the app's anon token does not match" failure. `--check` reports drift by KEY NAME
# (never a value) and exits 1; `--sync` rewrites only the drifted keys, in place,
# atomically, leaving every other line (minted secrets, hand edits, comments) as is.
# An empty source value is never written. Run by `make all` (env-local-ensure) and by
# vault42-team.sh after an applied pull.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GRO_ENV="${GRO_ENV:-$REPO/apps/grobase/.env}"
OUT="${OUT:-$REPO/.env.local}"
FORCE="${FORCE:-0}"
MODE="${1:-generate}"

note() { printf '[gen-local-env] %s\n' "$1" >&2; }
# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"

# The declared mapping — <key in ./.env.local>=<key in apps/grobase/.env>. Only these
# seven are derived; --check/--sync never look at any other key.
# A "|" lists fallbacks: the Kong-facing keys follow KONG_PUBLIC_API_KEY — the credential
# Kong actually runs (generate-env.sh: KONG_PUBLIC_API_KEY=${ANON_KEY}) — and only then the
# JWT it aliases, so --check is authoritative for the 401, not merely self-consistent.
DERIVED="JWT_SECRET=JWT_SECRET ANON_KEY=ANON_KEY SERVICE_ROLE_KEY=SERVICE_ROLE_KEY \
KONG_PUBLIC_API_KEY=KONG_PUBLIC_API_KEY|ANON_KEY KONG_SERVICE_API_KEY=KONG_SERVICE_API_KEY|SERVICE_ROLE_KEY \
SB_KONG_KEY=KONG_PUBLIC_API_KEY|ANON_KEY ADAPTER_REGISTRY_SERVICE_TOKEN=ADAPTER_REGISTRY_SERVICE_TOKEN"
# NOT derived: VITE_BAAS_REALTIME_TOKEN — the generator seeds it with the anon key, but
# `make seed-live-demo` (live-data-ensure) later replaces it with a tenant realtime token
# minted from RT_JWT_SECRET; it travels as a team value (vault42-team.sh), never a derived one.

# Read a key's value from an env file — LAST match, the rule apps/grobase/.env is assembled
# under (assemble-env.sh: config.env < .env.secrets < .env.local, later wins); strips one
# layer of quotes; empty if absent.
val() { sed -n "s/^$2=//p" "$1" | tail -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
gval() { val "$GRO_ENV" "$1"; }
# gsrc SPEC — value of the first non-empty source in a "|"-separated list.
gsrc() {
  _spec="$1"
  while :; do
    _one="${_spec%%|*}"
    _v="$(gval "$_one")"
    [ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
    [ "$_spec" = "$_one" ] && return 0
    _spec="${_spec#*|}"
  done
}
# URL-safe random secret for the osionos-only app secrets.
gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48; }

# drift_report: one line per derived key — "sync KEY" | "drift KEY" | "missing KEY" |
# "unknown KEY" (source empty). Key names only. Returns 1 when anything is not in sync.
drift_report() {
  bad=0
  for pair in $DERIVED; do
    dst="${pair%%=*}"
    src="${pair#*=}"
    want="$(gsrc "$src")"
    if [ -z "$want" ]; then printf 'unknown %s\n' "$dst"; bad=1
    elif ! grep -q "^$dst=" "$OUT"; then printf 'missing %s\n' "$dst"; bad=1
    elif [ "$(val "$OUT" "$dst")" = "$want" ]; then printf 'sync %s\n' "$dst"
    else printf 'drift %s\n' "$dst"; bad=1
    fi
  done
  return "$bad"
}

require_inputs() {
  [ -f "$GRO_ENV" ] || { note "apps/grobase/.env not found — bring the backend up first (make backend-up)."; exit 1; }
}

check_mode() {
  require_inputs
  [ -f "$OUT" ] || { note "$(basename "$OUT") absent — run without --check to generate it."; exit 1; }
  rc=0
  report="$(drift_report)" || rc=$?
  printf '%s\n' "$report" | sed 's/^/[gen-local-env]   /' >&2
  if [ "$rc" -eq 0 ]; then note "in sync with apps/grobase/.env (7 derived keys)."; else
    note "DRIFT — $(basename "$OUT") disagrees with apps/grobase/.env. Fix: bash scripts/gen-local-env.sh --sync"
  fi
  exit "$rc"
}

# sync_mode: rewrite only the drifted/missing derived keys, one put_env each (in place,
# atomic, mode kept, every other line untouched). An EMPTY source is never written.
sync_mode() {
  require_inputs
  [ -f "$OUT" ] || { note "$(basename "$OUT") absent — generating it."; generate; return; }
  rc=0
  report="$(drift_report)" || rc=$?
  [ "$rc" -ne 0 ] || { note "in sync with apps/grobase/.env — nothing to write."; exit 0; }
  changed=""
  unknown=""
  for pair in $DERIVED; do
    dst="${pair%%=*}"
    if printf '%s\n' "$report" | grep -qx "unknown $dst"; then unknown="$unknown $dst"
    elif printf '%s\n' "$report" | grep -qx "drift $dst\|missing $dst"; then
      put_env "$OUT" "$dst" "$(gsrc "${pair#*=}")"
      changed="$changed $dst"
    fi
  done
  [ -z "$changed" ] || note "synced from apps/grobase/.env:$changed"
  [ -z "$unknown" ] || { note "left as is (EMPTY source in apps/grobase/.env — is the backend healthy?):$unknown"; exit 1; }
}

generate() {
if [ -f "$OUT" ] && [ "$FORCE" != 1 ]; then
  note "$(basename "$OUT") already present — leaving it (FORCE=1 to overwrite; --sync to refresh the derived keys)."
  exit 0
fi
require_inputs
command -v openssl >/dev/null 2>&1 || {
  note "openssl required"
  exit 1
}

# grobase co-signs these against its random JWT_SECRET: anon==kong-public,
# service-role==kong-service. The frontends need the SAME values to authenticate.
PUBLIC="$(gval ANON_KEY)"
SERVICE="$(gval SERVICE_ROLE_KEY)"
JWT="$(gval JWT_SECRET)"
ADAPTER="$(gval ADAPTER_REGISTRY_SERVICE_TOKEN)"
if [ -z "$PUBLIC" ] || [ -z "$SERVICE" ] || [ -z "$JWT" ]; then
  note "grobase .env is missing ANON_KEY/SERVICE_ROLE_KEY/JWT_SECRET — is the backend healthy?"
  exit 1
fi

# VAPID P-256 keypair for Web Push (RFC 8292); empty when node is absent so push
# stays dormant (an off-by-default feature — never blocks provisioning).
VAPID_PUBLIC=""
VAPID_PRIVATE=""
if command -v node >/dev/null 2>&1; then
  VAPID_KEYS="$(node -e 'const c=require("crypto"),e=c.createECDH("prime256v1");e.generateKeys();const u=b=>b.toString("base64url");process.stdout.write(u(e.getPublicKey())+" "+u(e.getPrivateKey()))')"
  VAPID_PUBLIC="${VAPID_KEYS%% *}"
  VAPID_PRIVATE="${VAPID_KEYS##* }"
fi

umask 077
cat >"$OUT" <<EOF
# ./.env.local — GENERATED for a no-vault local machine by scripts/gen-local-env.sh.
# Derived from apps/grobase/.env (BaaS keys) + locally-minted osionos secrets.
# Delete this file and re-run \`make all\` to regenerate against a fresh backend.

# ── BaaS auth keys (must match grobase's JWT_SECRET — derived, do not edit) ──
JWT_SECRET=$JWT
ANON_KEY=$PUBLIC
SERVICE_ROLE_KEY=$SERVICE
KONG_PUBLIC_API_KEY=$PUBLIC
KONG_SERVICE_API_KEY=$SERVICE
SB_KONG_KEY=$PUBLIC
ADAPTER_REGISTRY_SERVICE_TOKEN=$ADAPTER
# Browser-facing BaaS origin — baked into the bundle by vite, so it must be a URL a
# BROWSER can reach. Deliberately the APP'S OWN origin: the proxy mounts Kong's
# /auth/v1 /rest/v1 /realtime/v1 /storage/v1 /query/v1 /meta/v1 on :3001 too
# (infrastructure/tls/nginx.conf), so the whole app needs exactly ONE reachable
# port. Any other value adds a second browser-facing port that every host
# tunnel/port-forward must also know about — and when it doesn't, the app
# half-loads with a dead realtime socket. liveRealtimeUrl() rewrites http->ws,
# so this also decides the socket: wss://localhost:3001/realtime/v1/ws.
# Kong's own 127.0.0.1:8000 is docker-host loopback + plain HTTP: never valid here.
VITE_BAAS_URL=https://localhost:3001
VITE_BAAS_REALTIME_TOKEN=$PUBLIC
VITE_CHAT_WS=true

# ── osionos app secrets (local-only, freshly minted) ──
OSIONOS_APP_SESSION_SECRET=$(gen)
OSIONOS_BRIDGE_EMAIL_HASH_SALT=$(gen)
OSIONOS_BRIDGE_SHARED_SECRET=$(gen)
OSIONOS_APP_SESSION_TTL_SECONDS=2592000
OSIONOS_ALLOWED_ORIGIN=https://localhost:3001
OSIONOS_APP_URL=https://localhost:3001
PUBLIC_OSIONOS_APP_URL=https://localhost:3001

# ── Web Push (RFC 8292 VAPID); empty = push dormant (off by default) ──
OSIONOS_VAPID_PUBLIC_KEY=$VAPID_PUBLIC
OSIONOS_VAPID_PRIVATE_KEY=$VAPID_PRIVATE
OSIONOS_VAPID_SUBJECT=mailto:admin@osionos.local

# ── Degrade-until-provisioned (empty is safe) ──
# OSIONOS_BAAS_API_KEY: the live-DB demo's mbk_ app key — minted by \`make seed-live-demo\`.
# PERMS_SERVICE_*: optional overrides for the bridge's permission-engine credentials. Leave
# blank: the bridge then uses its own service identity (copies here went stale once).
OSIONOS_BAAS_API_KEY=
PERMS_SERVICE_APIKEY=
PERMS_SERVICE_TOKEN=

# ── Optional cloud integrations (empty = feature dormant; LiveKit uses compose dev defaults) ──
GIPHY_API=
DOCKER_USER=
DOCKER_PAT=
DOCKER_USERNAME=
DOCKER_PAS=
FLY_API_TOKEN=
SONAR_TOK=
GITHUB_PAT=
EMAIL_RECUP_ADMIN_VAULT=
EOF

note "wrote $(basename "$OUT") (BaaS keys derived from grobase, osionos secrets minted, cloud keys empty)."
}

case "$MODE" in
--check) check_mode ;;
--sync) sync_mode ;;
generate) generate ;;
*) printf 'usage: gen-local-env.sh [--check|--sync]   (no flag: generate ./.env.local when absent)\n' >&2; exit 2 ;;
esac
