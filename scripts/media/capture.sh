#!/usr/bin/env bash
# capture.sh — the Phase 4 product captures (tests/e2e/media/, PLAN.md §6.1), shot as the Arlet
# demo users, then cut into what the site serves:
#   media/screenshots/<id>.jpg                        the 2880×1800 master, JPEG q85 (local: screenshots/ is git-ignored)
#   apps/opposite-osiris/public/media/<id>-<w>.{avif,webp}  w = 720, 1440, 2880 (CaptureFrame)
#   apps/opposite-osiris/public/media/<id>-1440.jpg   the <img> fallback
# The logins come from ./.env.demo-arlet (scripts/demo/seed-baas.sh) and reach the e2e container
# by name only (run.sh passes every E2E_* variable as `-e NAME`); the page ids, from the seed's
# manifest. S12 (the tour poster) is S1: the player draws its own play button.
#
#   scripts/media/capture.sh [playwright args]      # e.g. -g S9
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"
cd "$REPO"

SECRETS=".env.demo-arlet"
MANIFEST="scripts/demo/manifests/baas.json"
MASTERS="tests/e2e/test-results/media-masters"
SITE_MEDIA="apps/opposite-osiris/public/media"
for file in "$SECRETS" "$MANIFEST"; do
  [ -f "$file" ] || {
    echo "capture: $file is missing; run scripts/demo/seed-baas.sh first" >&2
    exit 1
  }
done

E2E_ARLET_INES_PASSWORD="$(get_env "$SECRETS" ARLET_INES_PASSWORD)"
E2E_ARLET_JULES_PASSWORD="$(get_env "$SECRETS" ARLET_JULES_PASSWORD)"
E2E_ARLET_PAGES="$(jq -c .pages "$MANIFEST")"
export E2E_ARLET_INES_PASSWORD E2E_ARLET_JULES_PASSWORD E2E_ARLET_PAGES
rm -rf "$MASTERS"
mkdir -p "$MASTERS"
bash tests/e2e/run.sh -c media.config.ts "$@"

# cut ID FROM — one master into the archive JPEG and the site's sizes, named after ID.
cut() {
  local id="$1" from="$2" w
  scripts/tools.sh vips copy "$from" "media/screenshots/$id.jpg[Q=85,strip]" </dev/null
  for w in 720 1440 2880; do
    scripts/tools.sh vips thumbnail "$from" "$SITE_MEDIA/$id-$w.avif[Q=55,strip]" "$w" </dev/null
    scripts/tools.sh vips thumbnail "$from" "$SITE_MEDIA/$id-$w.webp[Q=80,strip]" "$w" </dev/null
  done
  scripts/tools.sh vips thumbnail "$from" "$SITE_MEDIA/$id-1440.jpg[Q=82,strip]" 1440 </dev/null
  echo "capture: $id" >&2
}

mkdir -p media/screenshots "$SITE_MEDIA"
for master in "$MASTERS"/*.png; do
  [ -e "$master" ] || continue
  id="$(basename "$master" .png | tr '[:upper:]' '[:lower:]')"
  cut "$id" "$master"
  if [ "$id" = s1 ]; then cut s12 "$master"; fi
done
