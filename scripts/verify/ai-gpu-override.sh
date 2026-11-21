#!/bin/sh
# ai-gpu-override.sh — FC1, FC2, FC3, FC5, FC8: the dev GPU override of
# osionos-ai-llm is opt-in, pinned, narrow and unpublished.
#
# FC1: the default render (no docker-compose.gpu.yml) is byte-identical to the
# default render at the commit before the gpu file was added, and holds no
# Vulkan image and no /dev/dri device. FC2/FC3/FC5/FC8: the gpu render pins the
# image by digest, passes only renderD128 + group 993, restarts on-failure:3,
# publishes nothing. FC7: the public overlay never names the gpu file.
#
# Caveat: it proves the RENDERED config of docker-compose.yml, not a running
# container, and only for throwaway env values; a host env var that changes the
# default render makes the compare fail loudly (over-reporting), never pass.
# Before the gpu file is committed the baseline is HEAD's docker-compose.yml.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

DIGEST='ghcr.io/ggml-org/llama.cpp:server-vulkan-b11580@sha256:ee2ecb9c3a4d6fa00b918b133fd7a2828195593688eeaef6e6516ef833f88f09'
BASE_COPY="$REPO/.ai-gpu-base-compose.yml"
trap 'rm -f "$BASE_COPY"' EXIT
status=0
n=0
fail() { echo "FAIL: $1"; status=1; }
check() { # check <label> <json> <jq expression that prints true>
	n=$((n + 1))
	[ "$(printf '%s' "$2" | jq -r "$3")" = "true" ] || fail "$1"
}

render() { # render <compose file> [second compose file]
	if [ $# -eq 2 ]; then
		docker compose -f "$1" -f "$2" --env-file /dev/null --profile ai --profile dev config --format json
	else
		docker compose -f "$1" --env-file /dev/null --profile ai --profile dev config --format json
	fi
}

[ -f docker-compose.gpu.yml ] || { echo "FAIL: docker-compose.gpu.yml does not exist"; exit 1; }

added=$(git log --diff-filter=A --format=%H -- docker-compose.gpu.yml | tail -1)
baseline=${added:+$added^}
baseline=${baseline:-HEAD}
git show "$baseline:docker-compose.yml" >"$BASE_COPY"
base_json=$(render "$BASE_COPY" | jq -S 'del(.name)')
now_json=$(render docker-compose.yml | jq -S 'del(.name)')
n=$((n + 1))
[ "$base_json" = "$now_json" ] || fail "FC1 default render differs from the render at $baseline"
n=$((n + 1))
if printf '%s' "$now_json" | grep -q 'server-vulkan\|/dev/dri'; then fail "FC1 default render names a vulkan image or /dev/dri"; fi

gpu=$(render docker-compose.yml docker-compose.gpu.yml)
svc='.services["osionos-ai-llm"]'
check "FC2 image is the digest pin" "$gpu" "$svc.image == \"$DIGEST\""
check "FC3 devices is exactly renderD128" "$gpu" "($svc.devices | length) == 1 and ($svc.devices[0] | tostring | contains(\"/dev/dri/renderD128\")) and (($svc.devices | tostring | contains(\"card\")) | not)"
check "FC3 group_add is render 993" "$gpu" "$svc.group_add == [\"993\"]"
check "FC4 command has -ngl 99 -np 1 -fa on and a -c" "$gpu" "($svc.command | join(\" \")) | test(\"-ngl 99 -np 1 -fa on\") and test(\"-c [0-9]+\")"
check "FC5 restart is on-failure:3" "$gpu" "$svc.restart == \"on-failure:3\""
check "FC8 no ports" "$gpu" "($svc.ports // []) | length == 0"
check "keeps the model and alias" "$gpu" "($svc.command | join(\" \")) | test(\"Qwen3-4B-Instruct-2507-GGUF:Q4_K_M\") and test(\"--alias qwen3-4b\")"
n=$((n + 1))
if [ -n "$(docker compose -f docker-compose.yml -f docker-compose.gpu.yml --env-file /dev/null --profile ai port osionos-ai-llm 8080 2>/dev/null)" ]; then
	fail "FC8 docker compose port osionos-ai-llm 8080 prints a mapping"
fi
n=$((n + 1))
if grep -q 'docker-compose.gpu' docker-compose.public.yml Makefile 2>/dev/null; then fail "FC7 the public overlay or Makefile names the gpu file"; fi

[ "$status" -eq 0 ] && echo "ai-gpu-override: $n checks passed"
exit "$status"
