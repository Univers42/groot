#!/usr/bin/env bash
# ===========================================================================
# Publish the osionos LOCAL-edition desktop artifacts to a GitHub Release.
#
# Build artifacts (.deb ~80MB, .AppImage ~110MB, .exe) must NEVER live in git
# (GitHub blocks blobs >100MB). They belong on a Release. This builds them (if
# missing) and uploads them as release assets, so a non-cloning user can just
# download from the Releases page.
#
#   bash apps/osionos-electron/release.sh                 # Linux assets only
#   bash apps/osionos-electron/release.sh --all           # Linux + Windows .exe
#   bash apps/osionos-electron/release.sh --tag v0.5.2    # explicit tag
#
# Requires: gh (authenticated), and the build toolchain build.sh uses (Docker).
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
EL="apps/osionos-electron"
DIST="$EL/dist-local"

command -v gh >/dev/null 2>&1 || { echo "✗ gh (GitHub CLI) is required and must be authenticated (gh auth login)."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh is not authenticated. Run: gh auth login"; exit 1; }

# ---- args: platform passthrough + optional explicit tag -------------------
BUILD_ARGS="--local"; TAG=""
while [ $# -gt 0 ]; do case "$1" in
  --all|--win) BUILD_ARGS="$BUILD_ARGS $1";;
  --tag) shift; TAG="${1:-}";;
  *) echo "unknown arg: $1"; exit 2;;
esac; shift; done

VER="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$EL/package.json" | head -1)"
TAG="${TAG:-osionos-v${VER}-local}"

# ---- build if no artifacts present (a non-matching glob makes ls exit non-zero
#      even when others match, so test for any printed line instead) -----------
if ! ls "$DIST"/*.deb "$DIST"/*.AppImage "$DIST"/*.exe 2>/dev/null | grep -q .; then
  echo "==> No artifacts in $DIST — building (build.sh $BUILD_ARGS)…"
  bash "$EL/build.sh" $BUILD_ARGS
fi

mapfile -t ASSETS < <(ls "$DIST"/*.deb "$DIST"/*.AppImage "$DIST"/*.exe 2>/dev/null || true)
[ "${#ASSETS[@]}" -gt 0 ] || { echo "✗ No artifacts to upload in $DIST."; exit 1; }
echo "==> Assets:"; printf '   %s\n' "${ASSETS[@]}"

# ---- create the release once, then upload (idempotent --clobber) ----------
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Release $TAG exists — uploading/replacing assets…"
  gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
  echo "==> Creating release $TAG…"
  gh release create "$TAG" "${ASSETS[@]}" \
    --title "osionos local edition $VER" \
    --notes "Self-contained osionos desktop (local edition). Linux: install the .deb or run the .AppImage. Windows: run the .exe. The lean Docker backend (\`make local\`) must run on the same machine — see apps/osionos-electron/local-edition/README.md."
fi
echo "==> Done. View: gh release view $TAG --web"
