#!/usr/bin/env bash
# ai-image-closure.test.sh — proves ai-image-closure.sh computes the closure.
#
# A fixture (a tiny app tree + a Dockerfile) in a temp dir: the whole chain
# must be found (a.ts -> x -> y -> z), the double-quoted and the dynamic
# import must be read, the scripts nobody imports must stay out of the report
# and a copy that is missing must fail the check.
#
# Then the real tree: the closure of the osionos AI service against this
# repo's Dockerfile, and the two bites (a script dropped from the COPY line —
# on a copy of the Dockerfile, so the tracked file is never touched).
#
# The osionos app checkout the image is built from: $OSIONOS, else the repo's
# own apps/osionos/app submodule; neither → the real-tree part is SKIPPED.
set -uo pipefail
skipped=""

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/verify/ai-image-closure.sh"
TEST="$REPO/scripts/verify/ai-image-closure.test.sh"
DOCKERFILE="$REPO/infrastructure/docker/osionos/ai.Dockerfile"
status=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; status=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SVC="$TMP/svc"
mkdir -p "$SVC/services/osionos-ai/src" "$SVC/scripts"

cat > "$SVC/services/osionos-ai/src/a.ts" <<'EOF'
import { x } from '../../../scripts/x.mjs';
EOF
cat > "$SVC/services/osionos-ai/src/b.ts" <<'EOF'
const m = await import("../../../scripts/d.mjs");
EOF
cat > "$SVC/scripts/x.mjs" <<'EOF'
import { y } from "./y.mjs";
EOF
cat > "$SVC/scripts/y.mjs" <<'EOF'
import { z } from './z.mjs';
EOF
cat > "$SVC/scripts/z.mjs" <<'EOF'
export const z = 1;
EOF
cat > "$SVC/scripts/d.mjs" <<'EOF'
export const d = 1;
EOF
cat > "$SVC/scripts/unrelated.mjs" <<'EOF'
import { q } from './q.mjs';
EOF
cat > "$SVC/scripts/q.mjs" <<'EOF'
export const q = 1;
EOF
cat > "$SVC/Dockerfile" <<'EOF'
COPY scripts/x.mjs scripts/y.mjs scripts/d.mjs ./scripts/
EOF

out="$("$SCRIPT" "$SVC" "$SVC/Dockerfile" 2>&1)"
code=$?
if [ "$code" -eq 1 ]; then pass "fixture: exit 1"; else fail "fixture: exit $code, expected 1"; fi
if grep -qF "MISSING z.mjs" <<<"$out"; then
	pass "fixture: MISSING z.mjs (transitive: a.ts -> x -> y -> z)"
else
	fail "fixture: MISSING z.mjs is not reported"
fi
if grep -qF "ok x.mjs" <<<"$out" && grep -qF "ok y.mjs" <<<"$out" && grep -qF "ok d.mjs" <<<"$out"; then
	pass "fixture: ok x.mjs, ok y.mjs, ok d.mjs (double quotes and dynamic import read)"
else
	fail "fixture: ok x.mjs / ok y.mjs / ok d.mjs are missing"
fi
if grep -qF "unrelated.mjs" <<<"$out" || grep -qF "q.mjs" <<<"$out"; then
	fail "fixture: the scripts nobody imports are reported"
else
	pass "fixture: unrelated.mjs and q.mjs are not reported"
fi
if grep -qF "FAIL: 1 script(s)" <<<"$out"; then
	pass "fixture: FAIL: 1 script(s)"
else
	fail "fixture: FAIL: 1 script(s) is missing"
fi

cat > "$SVC/Dockerfile.all" <<'EOF'
COPY scripts/x.mjs scripts/y.mjs scripts/z.mjs scripts/d.mjs ./scripts/
EOF
out="$("$SCRIPT" "$SVC" "$SVC/Dockerfile.all" 2>&1)"
code=$?
if [ "$code" -eq 0 ] && grep -qF "PASS" <<<"$out"; then
	pass "fixture: z.mjs copied -> exit 0 and PASS"
else
	fail "fixture: z.mjs copied -> exit $code, no PASS"
fi

# The osionos app checkout the image is built from.
app_dir=""
for candidate in "${OSIONOS:-}" "$REPO/apps/osionos/app"; do
	if [ -n "$candidate" ] && [ -d "$candidate/services/osionos-ai/src" ]; then
		app_dir="$(cd "$candidate" && pwd)"
		break
	fi
done

if [ -z "$app_dir" ]; then
	skipped="$skipped real-tree"; echo "SKIPPED: the real tree (the osionos app checkout was not found — set OSIONOS=/path/to/osionos)"
else
	echo "-- real tree: $app_dir"
	out="$("$SCRIPT" "$app_dir" 2>&1)"
	code=$?
	if [ "$code" -eq 0 ]; then pass "real tree: exit 0"; else fail "real tree: exit $code, expected 0"; fi
	if grep -qF "PASS" <<<"$out"; then pass "real tree: PASS"; else fail "real tree: PASS is missing"; fi
	count="$(grep -c '^ok ' <<<"$out")"
	if [ "$count" -eq 6 ]; then pass "real tree: 6 ok lines"; else fail "real tree: $count ok lines, expected 6"; fi
	for name in bridge-baas-body.mjs bridge-graph-edges.mjs bridge-live-workspaces.mjs \
		bridge-page-read.mjs bridge-session-cutoff.mjs bridge-session-token.mjs; do
		if grep -qF "ok $name" <<<"$out"; then
			pass "real tree: ok $name"
		else
			fail "real tree: ok $name is missing"
		fi
	done
	if grep -qF "MISSING " <<<"$out"; then
		fail "real tree: a script of the closure is MISSING"
	else
		pass "real tree: no script of the closure is MISSING"
	fi

	# The bites: a script dropped from the COPY line must be reported (the
	# copy of the Dockerfile keeps the tracked file untouched).
	sed 's| scripts/bridge-graph-edges.mjs||' "$DOCKERFILE" > "$TMP/no-graph.Dockerfile"
	out="$("$SCRIPT" "$app_dir" "$TMP/no-graph.Dockerfile" 2>&1)"
	code=$?
	if [ "$code" -eq 1 ] && grep -qF "MISSING bridge-graph-edges.mjs" <<<"$out" &&
		grep -qF "FAIL: 1 script(s)" <<<"$out"; then
		pass "bite: bridge-graph-edges.mjs out of the COPY line -> MISSING, FAIL: 1, exit 1"
	else
		fail "bite: bridge-graph-edges.mjs out of the COPY line -> exit $code, no MISSING"
	fi

	sed 's| scripts/bridge-baas-body.mjs||' "$DOCKERFILE" > "$TMP/no-body.Dockerfile"
	out="$("$SCRIPT" "$app_dir" "$TMP/no-body.Dockerfile" 2>&1)"
	code=$?
	if [ "$code" -eq 1 ] && grep -qF "MISSING bridge-baas-body.mjs" <<<"$out"; then
		pass "bite: bridge-baas-body.mjs out of the COPY line -> MISSING (transitive), exit 1"
	else
		fail "bite: bridge-baas-body.mjs out of the COPY line -> exit $code, no MISSING"
	fi
fi

if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck "$SCRIPT" "$TEST" >"$TMP/shellcheck.log" 2>&1; then
		pass "shellcheck: $SCRIPT and $TEST are clean"
	else
		fail "shellcheck: $(cat "$TMP/shellcheck.log")"
	fi
else
	skipped="$skipped shellcheck"; echo "SKIPPED: shellcheck is not installed"
fi

if [ "$status" -ne 0 ]; then echo "FAIL: a check failed"
elif [ -n "$skipped" ]; then echo "PASS: every check that ran passed; SKIPPED:$skipped"
else echo "PASS: all the checks passed"; fi
exit "$status"
