#!/usr/bin/env bash
# ai-guard-wire.sh — devil C72/C73: the gates of the image generation are
# wired in groot.
#
# The service must reach the guard of the image prompt (L1) and the models of
# the output check (C73); the guard must live on its own internal network, on
# no other; the image must carry the L0 gate and the lists it reads. The
# compose config is rendered (no container starts) and the Dockerfile is read.
#
# Caveat: the config is RENDERED, not run — the assertions prove what the
# files say, not that the guard answers or that the classifiers load. The
# smokes are that proof: the image build, then the L0 gate and the output
# check in the image, then the guard with a prompt.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
DOCKERFILE="$REPO/infrastructure/docker/osionos/ai.Dockerfile"

# The variables the stack requires get throwaway values, and the images are
# ON: the render then carries the whole image plane.
if ! config=$(
	OSIONOS_AI_IMAGES=on \
	PUBLIC_ORIGIN=https://verify.invalid \
	AUTH_LINK_SIGNING_KEY=verify-only \
	AUTH_TRUSTED_PROXY_HOPS=1 \
	OSIONOS_ADMIN_EMAILS=none \
	docker compose --env-file /dev/null --profile ai --profile ai-gpu-vulkan config --format json
); then
	echo "FAIL the compose config does not render"
	exit 1
fi

status=0
ok() { echo "ok $1"; }
fail() { echo "FAIL $1"; status=1; }

# assert <what> <jq filter>: the filter must answer true.
assert() {
	local what="$1" filter="$2"
	if jq -e "$filter" <<<"$config" >/dev/null 2>&1; then
		ok "$what"
	else
		fail "$what"
	fi
}

# The COPY lines of the Dockerfile, the comments left out.
copies=$(grep -vE '^[[:space:]]*#' "$DOCKERFILE" | grep -E '^[[:space:]]*COPY[[:space:]]' || true)

assert "the service osionos-ai-guard exists" \
	'(.services["osionos-ai-guard"] | type) == "object"'
assert "the guard is on osionos-ai-guard-net and on no other network" \
	'(.services["osionos-ai-guard"].networks | keys) == ["osionos-ai-guard-net"]'
assert "the network osionos-ai-guard-net is internal (no egress)" \
	'.networks["osionos-ai-guard-net"].internal == true'
assert "the service osionos-ai has OSIONOS_AI_PROMPT_GUARD_URL" \
	'((.services["osionos-ai"].environment.OSIONOS_AI_PROMPT_GUARD_URL // "") | length) > 0'
assert "the service osionos-ai has OSIONOS_AI_IMAGE_CHECK_DIR" \
	'((.services["osionos-ai"].environment.OSIONOS_AI_IMAGE_CHECK_DIR // "") | length) > 0'
assert "the service osionos-ai mounts osionos_ai_image_check read-only" \
	'any(.services["osionos-ai"].volumes[]?; .source == "osionos_ai_image_check" and .read_only == true)'
assert "the image of the guard is pinned by digest" \
	'((.services["osionos-ai-guard"].image // "") | test("@sha256:[0-9a-f]{64}$"))'

if grep -qE '^[[:space:]]*COPY[[:space:]].*scripts/bridge-moderation\.mjs' <<<"$copies"; then
	ok "the image copies scripts/bridge-moderation.mjs"
else
	fail "the image copies scripts/bridge-moderation.mjs"
fi
if grep -qE '^[[:space:]]*COPY[[:space:]].*scripts/moderation-lists' <<<"$copies"; then
	ok "the image copies scripts/moderation-lists"
else
	fail "the image copies scripts/moderation-lists"
fi

if [ "$status" -ne 0 ]; then
	echo "FAIL: the gates of the image generation are not wired"
	exit 1
fi
echo "PASS"
