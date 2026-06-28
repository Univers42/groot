#!/usr/bin/env bash
# **************************************************************************** #
#  fetch.sh — download the official CS50 SQL problem-set datasets FROM CS50.  #
#                                                                            #
#  We do NOT redistribute CS50's data in this repo (their bundles include    #
#  third-party-licensed data such as IMDb). This script pulls the ZIPs       #
#  straight from CS50's CDN onto your machine, into ./downloads/ (gitignored)#
#                                                                            #
#  Docker-first: the download + unzip run inside a throwaway alpine          #
#  container, so you need no host curl/unzip — only Docker.                  #
#                                                                            #
#  Source:  https://cs50.harvard.edu/sql/   (CC BY-NC-SA 4.0)                #
#  Usage:   bash fetch.sh [YEAR]            (YEAR defaults to 2024)          #
# **************************************************************************** #
set -euo pipefail

YEAR="${1:-2024}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SCRIPT_DIR}/downloads"
CDN="https://cdn.cs50.net/sql/${YEAR}/x/psets"

# pset number : theme : space-separated problem slugs (the CDN file basenames).
# Some problems are codespace-only (no public .zip) and will 404 — those are
# skipped automatically. Pattern verified for cyberchase / packages / meteorites.
PSETS=(
  "0:querying:cyberchase views normals players"
  "1:relating:packages dese moneyball"
  "2:designing:atl connect donuts"
  "3:writing:meteorites dont-panic"
  "4:viewing:census private bnb"
  "5:optimizing:snap your.harvard"
  "6:scaling:connect deep"
)

# Build the list of "url<TAB>destdir" lines on the host, then hand them to one
# alpine container that does all the curl + unzip work.
manifest=""
for entry in "${PSETS[@]}"; do
  IFS=: read -r num theme slugs <<<"$entry"
  for slug in $slugs; do
    url="${CDN}/${num}/${slug}.zip"
    dest="pset${num}-${theme}/${slug}"
    manifest+="${url}	${dest}"$'\n'
  done
done

mkdir -p "$OUT"
echo "Fetching CS50 ${YEAR} SQL datasets → ${OUT}/ (skipping any that 404)…"
echo

printf '%s' "$manifest" | docker run --rm -i -v "${OUT}:/out" -w /out alpine sh -s <<'INNER'
set -u
apk add --no-cache curl unzip >/dev/null 2>&1
ok=0; skip=0
while IFS="$(printf '\t')" read -r url dest; do
  [ -z "${url:-}" ] && continue
  mkdir -p "$dest"
  zip="$dest/$(basename "$url")"
  if curl -fsSL "$url" -o "$zip" 2>/dev/null; then
    if unzip -o -q "$zip" -d "$dest" 2>/dev/null; then rm -f "$zip"; fi
    echo "  [ok]   $url"
    ok=$((ok+1))
  else
    rmdir "$dest" 2>/dev/null || true
    echo "  [skip] $url (not a public download — use cs50.dev / update50)"
    skip=$((skip+1))
  fi
done
echo
echo "Done: $ok fetched, $skip skipped."
INNER

echo
echo "Datasets are under ${OUT}/  (gitignored)."
echo "Next: load one into an engine, e.g."
echo "  bash ${SCRIPT_DIR}/../loaders/sqlite-to-csv.sh ${OUT}/pset1-relating/packages/packages.db /tmp/packages-csv"
echo "  bash ${SCRIPT_DIR}/../loaders/load-cs50-postgres.sh ${OUT}/pset1-relating/packages/packages.db"
