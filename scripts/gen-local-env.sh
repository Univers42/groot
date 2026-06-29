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
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GRO_ENV="$REPO/apps/grobase/.env"
OUT="${OUT:-$REPO/.env.local}"
FORCE="${FORCE:-0}"

note() { printf '[gen-local-env] %s\n' "$1" >&2; }

if [ -f "$OUT" ] && [ "$FORCE" != 1 ]; then
  note "$(basename "$OUT") already present — leaving it (FORCE=1 to overwrite)."
  exit 0
fi
if [ ! -f "$GRO_ENV" ]; then
  note "apps/grobase/.env not found — bring the backend up first (make backend-up)."
  exit 1
fi
command -v openssl >/dev/null 2>&1 || {
  note "openssl required"
  exit 1
}

# Read a key's value from grobase's generated .env (strip quotes; empty if absent).
gval() { sed -n "s/^$1=//p" "$GRO_ENV" | head -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
# URL-safe random secret for the osionos-only app secrets.
gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48; }

# grobase co-signs these against its random JWT_SECRET: anon==kong-public,
# service-role==kong-service. The frontends need the SAME values to authenticate.
PUBLIC="$(gval ANON_KEY)"
SERVICE="$(gval SERVICE_ROLE_KEY)"
JWT="$(gval JWT_SECRET)"
ADAPTER="$(gval ADAPTER_REGISTRY_SERVICE_TOKEN)"
[ -n "$PUBLIC" ] && [ -n "$SERVICE" ] && [ -n "$JWT" ] || {
  note "grobase .env is missing ANON_KEY/SERVICE_ROLE_KEY/JWT_SECRET — is the backend healthy?"
  exit 1
}

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
VITE_BAAS_URL=http://127.0.0.1:8000
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

# ── Degrade-until-provisioned (empty is safe) ──
# OSIONOS_BAAS_API_KEY: the live-DB demo's mbk_ app key — minted by \`make seed-live-demo\`.
# PERMS_SERVICE_*: agency ABAC service — set by the agency simulation.
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
