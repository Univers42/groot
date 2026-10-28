#!/usr/bin/env bash
# ai-image-closure.sh — the AI service image must copy every script it imports.
#
# Usage: ai-image-closure.sh <osionos-app-dir> [dockerfile]
#   <osionos-app-dir>  the osionos app checkout the image is built from: its
#                      services/osionos-ai/src holds the seeds, its scripts/
#                      the imported modules.
#   [dockerfile]       the Dockerfile to check (default: this repo's
#                      infrastructure/docker/osionos/ai.Dockerfile).
#
# Closure: the seeds are the relative imports of services/osionos-ai/src that
# resolve into <dir>/scripts/; their own imports are followed to the end.
#
# Caveat: the imports are read with a regex — an import whose specifier is computed at run time (a template string, a variable) is not seen, so the check can under-report; it never over-reports a static import.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
usage() { echo "Usage: $(basename "$0") <osionos-app-dir> [dockerfile]" >&2; exit 2; }
[[ "$#" -ge 1 ]] || usage
APPDIR="$(realpath -m "$1")"
SRCDIR="$APPDIR/services/osionos-ai/src"
SCRIPTSDIR="$(realpath -m "$APPDIR/scripts")"
DOCKERFILE="${2:-$REPO/infrastructure/docker/osionos/ai.Dockerfile}"
[[ -d "$SRCDIR" ]] || usage
[[ -f "$DOCKERFILE" ]] || usage

# The specifiers of one file — from '…', from "…", import '…', import "…",
# import('…'), import("…") — the text between the quotes, relative ones only.
specs_of() {
	grep -oE "(from|import)[[:space:]]*\(?[[:space:]]*['\"][^'\"]+['\"]" "$1" 2>/dev/null |
		grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | grep -E '^\.\.?/' || true
}

declare -A VISITED=()
WORKLIST=()
# Queue every scripts/ file the imports of one file resolve to.
push_specs() {
	local source="$1" spec resolved
	while IFS= read -r spec; do
		resolved="$(realpath -m "$(dirname "$source")/$spec")"
		case "$resolved" in
		"$SCRIPTSDIR"/*)
			if [[ -f "$resolved" ]]; then WORKLIST+=("$resolved"); fi
			;;
		esac
	done < <(specs_of "$source")
}

while IFS= read -r source; do push_specs "$source"; done < <(find "$SRCDIR" -type f -name '*.ts' | sort)
while [[ "${#WORKLIST[@]}" -gt 0 ]]; do
	file="${WORKLIST[0]}"
	WORKLIST=("${WORKLIST[@]:1}")
	if [[ -n "${VISITED[$file]:-}" ]]; then continue; fi
	VISITED["$file"]=1
	push_specs "$file"
done
mapfile -t COPIED < <(grep -vE '^[[:space:]]*#' "$DOCKERFILE" |
	grep -E '^[[:space:]]*COPY[[:space:]]' |
	grep -oE 'scripts/[A-Za-z0-9._-]+\.mjs' | sed 's|^scripts/||' | sort -u || true)
mapfile -t NAMES < <(for file in "${!VISITED[@]}"; do basename "$file"; done | sort)
missing=0
for name in "${NAMES[@]}"; do
	if printf '%s\n' "${COPIED[@]}" | grep -qxF "$name"; then echo "ok $name"
	else echo "MISSING $name"; missing=$((missing + 1)); fi
done

if [[ "$missing" -eq 0 ]]; then echo "PASS"; exit 0; fi
echo "FAIL: $missing script(s) imported by the AI service are not copied into its image"
exit 1
