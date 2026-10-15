#!/usr/bin/env bash
# site-audit.sh — measure every public route of the Prismatica site (tests/e2e/site-audit/routes.txt)
# and keep the raw evidence under docs/redesign/<label>/:
#   lighthouse/{mobile,desktop}/  Lighthouse CI: the representative (median) run of 3 per route, kept
#                                 as gzipped JSON (the raw LHR; every run as HTML+JSON was 72 MB)
#   screenshots/ pages/           390/768/1440 px captures, axe violations, console errors
#   summary.md                    the tables docs/redesign/AUDIT.md and REPORT.md quote
# The Lighthouse step also asserts PLAN.md §8.2's budgets (tests/e2e/site-audit/lighthouserc.*.json,
# SEO only on indexable routes, weights only on /): the evidence is kept either way, and the script
# exits non-zero when a budget is broken. E2E_PRISMATICA_URL picks the site, e.g. the build that
# scripts/serve-site.sh serves.
# Re-run with another label to compare: `baseline` before the redesign, `after` once it lands.
#
#   scripts/site-audit.sh <label> [all|lighthouse|capture|summary]
#
# Caveat: lab numbers from this machine, never field data. Lighthouse's navigation mode measures
# no INP (TBT is its lab stand-in), and its simulated throttling still scales with this host's
# CPU, so compare two labels only when both were measured on the same machine.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
site="${E2E_PRISMATICA_URL:-https://localhost:4322}"
label="${1:?usage: scripts/site-audit.sh <label> [all|lighthouse|capture|summary]}"
step="${2:-all}"
out="$REPO/docs/redesign/$label"
mapfile -t routes < <(grep -vE '^[[:space:]]*(#|$)|capture-only' "$REPO/tests/e2e/site-audit/routes.txt" | awk '{print $1}')

lighthouse() {
  local form="$1" dir="$out/lighthouse/$1"
  local -a args=(--numberOfRuns=3 --chromePath=/usr/bin/chromium-browser
    "--settings.chromeFlags=--headless=new --no-sandbox --disable-gpu --ignore-certificate-errors")
  [[ "$form" == desktop ]] && args+=(--settings.preset=desktop)
  for route in "${routes[@]}"; do args+=("--url=$site$route"); done
  rm -rf "$dir"
  mkdir -p "$dir"
  local asserted=0
  (cd "$dir" && "$REPO/scripts/tools.sh" lhci collect "${args[@]}") </dev/null
  (cd "$dir" && "$REPO/scripts/tools.sh" lhci assert --config="$REPO/tests/e2e/site-audit/lighthouserc.$form.json") </dev/null || asserted=$?
  (cd "$dir" && "$REPO/scripts/tools.sh" lhci upload --target=filesystem --outputDir=.) </dev/null
  rm -rf "$dir/.lighthouseci"
  "$REPO/scripts/tools.sh" node "$REPO/scripts/site-audit-summary.mjs" --prune "$dir" </dev/null
  return "$asserted"
}

capture() {
  local results="$REPO/tests/e2e/test-results/site-audit/$label"
  rm -rf "$results" "$out/screenshots" "$out/pages"
  E2E_SITE_AUDIT_LABEL="$label" bash "$REPO/tests/e2e/run.sh" -c site-audit.config.ts
  mkdir -p "$out"
  cp -r "$results/screenshots" "$results/pages" "$out/"
}

summary() {
  "$REPO/scripts/tools.sh" node "$REPO/scripts/site-audit-summary.mjs" "$out" >"$out/summary.md"
  echo "[site-audit] $out/summary.md" >&2
}

# Both form factors and the capture always run; the first broken budget decides the exit status.
budgets=0
case "$step" in
all)
  lighthouse mobile || budgets=$?
  lighthouse desktop || budgets=$((budgets ? budgets : $?))
  capture
  summary
  ;;
lighthouse)
  lighthouse mobile || budgets=$?
  lighthouse desktop || budgets=$((budgets ? budgets : $?))
  ;;
capture) capture ;;
summary) summary ;;
*)
  echo "unknown step: $step (all|lighthouse|capture|summary)" >&2
  exit 2
  ;;
esac
exit "$budgets"
