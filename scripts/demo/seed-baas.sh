#!/usr/bin/env bash
# seed-baas.sh — seeds the Arlet demo into the baas VM, additive only (D-039, ADR 0005, devil
# verdict docs/redesign/verdicts/phase2-baas-submission.md). Human-run: the agent session may
# not write to baas.
#
#   scripts/demo/seed-baas.sh --only spike [--dry-run]   # one record per mapping, first
#   scripts/demo/seed-baas.sh [--dry-run]                # the full dataset, after the spike
#
# 1. The manifest (scripts/demo/manifests/baas.json, git-ignored, ids only) is written BEFORE
#    anything leaves this host: uid8, anchor date, workspace ids and slugs (condition 1).
# 2. The demo passwords live in ./.env.demo-arlet (mode 600, lib/envfile.sh), never printed.
# 3. The generator writes the bundle; vm-bootstrap.sh runs in the VM over `ssh b2b` and prints
#    its state (ids), which is merged into the manifest.
# 4. load-pages.mjs writes the pages through the running bridge as Inès.
# --dry-run stops after step 3's bundle: it prints what would be shipped and writes nothing.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"
cd "$REPO"

ONLY=full DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
  --only) ONLY="${2:?--only needs spike}" && shift ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: scripts/demo/seed-baas.sh [--only spike] [--dry-run]" >&2 && exit 2 ;;
  esac
  shift
done
[ "$ONLY" = full ] || [ "$ONLY" = spike ] || { echo "--only takes spike" >&2 && exit 2; }

SSH_HOST="${SEED_SSH_HOST:-b2b}"
BRIDGE_CONTAINER="${SEED_BRIDGE_CONTAINER:-track-binocle-osionos-bridge-1}"
BRIDGE_URL="${SEED_BRIDGE_URL:-https://localhost:4000}"
MANIFEST="scripts/demo/manifests/baas.json"
SECRETS=".env.demo-arlet"
say() { printf '[seed-baas] %s\n' "$*" >&2; }
die() {
  say "$*"
  exit 1
}

preflight() {
  pgrep -f '[d]eploy-mountlist' >/dev/null 2>&1 && die "deploy-mountlist is running on this host; wait for it"
  TENANT="$(docker exec "$BRIDGE_CONTAINER" printenv OSIONOS_BAAS_TENANT_ID)" ||
    die "cannot read the bridge's tenant from $BRIDGE_CONTAINER (is the link stack up?)"
  ssh -o BatchMode=yes -o ClearAllForwardings=yes "$SSH_HOST" true || die "ssh $SSH_HOST failed"
}

ensure_passwords() {
  local key
  [ -f "$SECRETS" ] || (umask 077 && : >"$SECRETS")
  for key in ARLET_INES_PASSWORD ARLET_JULES_PASSWORD; do
    get_env "$SECRETS" "$key" >/dev/null 2>&1 ||
      put_env "$SECRETS" "$key" "$(od -An -tx1 -N18 /dev/urandom | tr -d ' \n')"
  done
}

ensure_manifest() {
  scripts/tools.sh node scripts/demo/manifest.mjs init --file "$MANIFEST" --target "$SSH_HOST" --tenant "$TENANT" </dev/null >&2
  UID8="$(jq -r .uid8 "$MANIFEST")"
  OUT="scripts/demo/out/$UID8/$ONLY"
}

build_bundle() {
  local spike_flag=()
  [ "$ONLY" = spike ] && spike_flag=(--spike)
  scripts/tools.sh node scripts/demo/generate.mjs --anchor "$(jq -r .anchor "$MANIFEST")" --seed 42 \
    --uid8 "$UID8" --out "$OUT" "${spike_flag[@]}" </dev/null >&2
  cp scripts/demo/vm/lib.sh scripts/demo/vm/vm-bootstrap.sh scripts/demo/vm/mongo-user.js scripts/demo/vm/mongo-load.js "$OUT/"
  scripts/tools.sh node scripts/demo/manifest.mjs params --file "$MANIFEST" --out "$OUT" --only "$ONLY" </dev/null >"$OUT/params.env"
  (
    umask 077
    printf 'INES_PASSWORD=%s\nJULES_PASSWORD=%s\n' "$(get_env "$SECRETS" ARLET_INES_PASSWORD)" \
      "$(get_env "$SECRETS" ARLET_JULES_PASSWORD)" >"$OUT/secrets.env"
  )
}

run_bootstrap() {
  local state="$OUT/vm-state.txt"
  tar -C "$OUT" -cf - --exclude=pages.json --exclude=stats.json . |
    ssh -o BatchMode=yes -o ClearAllForwardings=yes "$SSH_HOST" \
      'd="$(mktemp -d)" && tar -x -C "$d" && bash "$d/vm-bootstrap.sh" "$d"; s=$?; rm -rf "$d"; exit $s' >"$state"
  scripts/tools.sh node scripts/demo/manifest.mjs merge-state --file "$MANIFEST" --state "$state" </dev/null >&2
}

load_pages() {
  NODE_EXTRA_CA_CERTS=/certs/local-ca.pem ARLET_INES_PASSWORD="$(get_env "$SECRETS" ARLET_INES_PASSWORD)" \
  ARLET_JULES_PASSWORD="$(get_env "$SECRETS" ARLET_JULES_PASSWORD)" \
  TOOLS_PASS_ENV="NODE_EXTRA_CA_CERTS ARLET_INES_PASSWORD ARLET_JULES_PASSWORD" \
    scripts/tools.sh node scripts/demo/load-pages.mjs --manifest "$MANIFEST" --pages "$OUT/pages.json" \
    --bridge "$BRIDGE_URL" --utc-offset "$(date +%z)" </dev/null
}

main() {
  preflight
  ensure_passwords
  ensure_manifest
  trap 'rm -f "$OUT/secrets.env"' EXIT
  build_bundle
  if [ "$DRY_RUN" = 1 ]; then
    say "dry run: this bundle would be shipped to $SSH_HOST (tenant $TENANT, uid8 $UID8):"
    (cd "$OUT" && ls -l) >&2
    grep -v '^$' "$OUT/params.env" >&2
    exit 0
  fi
  run_bootstrap
  load_pages
  say "done: manifest $MANIFEST"
}

main
