#!/usr/bin/env bash
# subset-fonts.sh — cut the site's one web font (Instrument Serif, regular only) down to
# the Latin range and write the woff2 file the stylesheet loads
# (apps/opposite-osiris/src/styles/base/_base.scss). The full file stays as the source.
#
#   scripts/media/subset-fonts.sh
#
# The range is Google Fonts' "latin" subset: ASCII, Latin-1, the common punctuation block, the
# euro and trademark signs. Caveat: a glyph outside it (Polish ł, Czech ř, Vietnamese) falls back
# to the system serif inside a heading; widen UNICODES before copy in those languages ships.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fonts="$REPO/apps/opposite-osiris/public/fonts"
UNICODES='U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD'

for face in instrument-serif; do
	"$REPO/scripts/tools.sh" pyftsubset "$fonts/$face.woff2" \
		--unicodes="$UNICODES" --layout-features='kern,liga,calt,locl' \
		--flavor=woff2 --output-file="$fonts/$face-latin.woff2" </dev/null
	printf '%s\t%s bytes\n' "$face-latin.woff2" "$(wc -c <"$fonts/$face-latin.woff2")"
done
