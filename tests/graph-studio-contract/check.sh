#!/usr/bin/env bash
# Regenerates the <graph-studio> contract from a graph_render source and compares it with the
# committed one. Any difference fails (exit 1), and the report says which kind it is:
#   VALUES CHANGED   — something osionos relies on moved; read the value diff before bumping.
#   CITATIONS ONLY   — same contract, the code moved; regenerate contract.json in the bump commit.
# Usage: check.sh (--git <graph_render clone> | --tree <dir>) --rev <rev> [contract.json]
# Exit: 0 same · 1 different · 2 the extractor could not read the contract (a rule matched badly).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
[ "$#" -ge 4 ] || { echo "usage: check.sh (--git DIR | --tree DIR) --rev REV [contract.json]" >&2; exit 2; }
committed=${5:-$here/contract.json}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! node "$here/extract.mjs" "$1" "$2" "$3" "$4" >"$tmp/fresh.json" 2>"$tmp/err"; then
  cat "$tmp/err" >&2
  echo "EXTRACTOR FAILED: a contract rule no longer matches the source exactly once" >&2
  exit 2
fi
cmp -s "$committed" "$tmp/fresh.json" && { echo "contract unchanged"; exit 0; }

# Values only: every { value, at } leaf collapsed to its value, source_rev dropped.
values='walk(if type == "object" and has("value") and has("at") then .value else . end) | del(.source_rev)'
jq -S "$values" "$committed" >"$tmp/committed.values"
jq -S "$values" "$tmp/fresh.json" >"$tmp/fresh.values"
if diff -u "$tmp/committed.values" "$tmp/fresh.values" >"$tmp/values.diff"; then
  echo "CITATIONS ONLY: the contract's values are unchanged; regenerate contract.json with extract.mjs"
else
  echo "VALUES CHANGED: osionos's contract with <graph-studio> differs (committed → regenerated):"
  sed '1,2d' "$tmp/values.diff"
fi
echo "--- full diff (committed → regenerated)"
diff -u "$committed" "$tmp/fresh.json" | sed '1,2d' || true
exit 1
