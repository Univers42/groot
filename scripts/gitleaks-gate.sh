#!/usr/bin/env bash
# gitleaks-gate.sh — gitleaks over every TRACKED file (submodules included), in Docker.
#
#   bash scripts/gitleaks-gate.sh              gate: exit 1 on any finding not in .gitleaksignore
#   bash scripts/gitleaks-gate.sh --list       print every current finding's fingerprint (no gate)
#
# Only tracked content is scanned (git ls-files --recurse-submodules, working-tree bytes), so
# an untracked ./.env.local full of real secrets never trips it. Findings print REDACTED
# (-v: in `dir` mode gitleaks 8.21 prints only the count without it, so a red gate named
# nothing: main aad6a1cb went red over a baselined fixture that had moved 6 lines).
# .gitleaksignore is the reviewed baseline of today's test fixtures and placeholders, grouped
# by reason. It is edited by hand: --list shows candidates, a person decides what is a fixture.
#
# Caveat: gitleaks matches by regex and entropy. A secret in a format no rule knows (the
# demo password this gate was built after is one) is NOT found — under-reporting, so
# it complements review instead of replacing it. A baseline entry is file:rule:line: moving
# a fixture to another line reports it as new (noisy, never silent); update its line then.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# ghcr.io, not Docker Hub: the hosted runners share egress IPs and Docker Hub 429s anonymous
# pulls per IP (osionos run 37990792990, 2026-10-09). Same image index, same digest.
IMAGE="ghcr.io/gitleaks/gitleaks:v8.21.2@sha256:0e99e8821643ea5b235718642b93bb32486af9c8162c8b8731f7cbdc951a7f46"
BASELINE="$REPO/.gitleaksignore"
MODE="${1:-gate}"

note() { printf '[gitleaks-gate] %s\n' "$1" >&2; }

case "$MODE" in gate | --list) ;; *)
	printf 'usage: gitleaks-gate.sh [--list]\n' >&2
	exit 2
	;;
esac

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# Uninitialised submodules list nothing; a tracked file deleted in the work tree is skipped.
(cd "$REPO" && git ls-files -z --recurse-submodules |
	while IFS= read -r -d '' f; do if [ -f "$f" ]; then printf '%s\0' "$f"; fi; done |
	tar --null -T - -cf -) | tar -xf - -C "$stage"
note "scanning $(find "$stage" -type f | wc -l) tracked files with gitleaks v8.21.2"

if [ "$MODE" = --list ]; then
	docker run --rm -v "$stage:/scan:ro" -w /scan "$IMAGE" dir . --no-banner --redact \
		-f json -r /dev/stdout --exit-code 0 --log-level error | jq -r '.[].Fingerprint' | sort -u
	exit 0
fi

touch "$BASELINE"
if docker run --rm -v "$stage:/scan:ro" -v "$BASELINE:/baseline:ro" -w /scan "$IMAGE" \
	dir . --no-banner --redact -v --gitleaks-ignore-path /baseline --exit-code 1; then
	note "no new secrets ($(grep -c '^[^#]' "$BASELINE") baselined fixture findings ignored)."
else
	rc=$?
	note "NEW secret-like findings above (values redacted). Remove the secret, or — only for a"
	note "fixture/placeholder — add its Fingerprint line to .gitleaksignore with a reason."
	exit "$rc"
fi
