#!/usr/bin/env bash
# favicon.sh — derive the site's public favicons from its one source mark,
# apps/opposite-osiris/src/assets/brand/favicon.svg: a copy at /favicon.svg (browsers that ask
# for it by path) and a 16/32/48 px /favicon.ico (ImageMagick in the groot-tools image).
#
#   scripts/media/favicon.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
site="apps/opposite-osiris"

cp "$REPO/$site/src/assets/brand/favicon.svg" "$REPO/$site/public/favicon.svg"
"$REPO/scripts/tools.sh" magick -background none -density 384 "$site/public/favicon.svg" \
  -define icon:auto-resize=48,32,16 "$site/public/favicon.ico" </dev/null
printf 'favicon.ico\t%s bytes\n' "$(wc -c <"$REPO/$site/public/favicon.ico")"
