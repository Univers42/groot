#!/bin/sh
# https-only.sh — subject III.3 (groot#174): nothing outside the backend gets a plaintext URL
# or a plaintext port. Resolves the compose files with `docker compose config` (every profile,
# TRACK_BINOCLE_BIND_ADDR=0.0.0.0 as inside a NAT VM, where the bind address leaves loopback)
# and fails on:
#   - an environment value or build arg starting ws:// or http:// whose host is not internal;
#   - the same in the env file(s);
#   - a published port that is neither loopback, nor the TLS proxy, nor LiveKit's media
#     (7881/tcp ICE and the UDP range carry DTLS-SRTP, not HTTP).
# Internal host = a bare Docker DNS name (no dot, not localhost) or host.docker.internal.
# Caveat: the host rule is lexical. A plaintext URL to a dotted internal name (a FQDN on the
# compose network) is reported though harmless (noise); a URL assembled at runtime from parts,
# or set only in an untracked .env, is never seen (under-report): pass that env file as
# HTTPS_ONLY_ENV_FILE to cover it.
#
# Env: HTTPS_ONLY_COMPOSE_FILES  colon list, like COMPOSE_FILE (default docker-compose.yml)
#      HTTPS_ONLY_ENV_FILE       space list of env files (default .env.example)
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FILES="${HTTPS_ONLY_COMPOSE_FILES:-$REPO/docker-compose.yml}"
ENV_FILES="${HTTPS_ONLY_ENV_FILE:-$REPO/.env.example}"

# Host-network test harness (`testing` profile): it reads LiveKit's admin API and Mailpit on the
# host's loopback, with no browser involved.
ALLOW='agency-simulation AGENCY_LIVEKIT_HTTP_URL
agency-simulation AGENCY_MAILPIT_URL'

# The jq predicate for "plaintext URL to a host outside the backend".
# shellcheck disable=SC2016 # $h is a jq variable, not a shell one (groot#174)
EXTERNAL='test("^(ws|http)://") and (capture("^[a-z]+://(?<h>[^/:?#]+)").h as $h | ($h | test("^[a-z0-9_-]+$") and $h != "localhost") or $h == "host.docker.internal" | not)'

status=0
found=$(mktemp)
trap 'rm -f "$found"' EXIT

env_args=""
for f in $ENV_FILES; do env_args="$env_args --env-file $f"; done

# shellcheck disable=SC2086 # env_args is a word list on purpose (groot#174)
config=$(cd "$REPO" && COMPOSE_FILE="$FILES" TRACK_BINOCLE_BIND_ADDR=0.0.0.0 \
	timeout 60 docker compose $env_args --profile '*' config --format json)

printf '%s' "$config" | jq -r --arg allow "$ALLOW" "
	(\$allow | split(\"\n\")) as \$ok |
	.services | to_entries[] | .key as \$s |
	((.value.environment // {}) + (.value.build.args // {})) | to_entries[] |
	select(.value != null and (.value | $EXTERNAL)) |
	select((\"\(\$s) \(.key)\") as \$k | \$ok | index(\$k) | not) |
	\"FAIL: \(\$s) \(.key)=\(.value)\"" >>"$found"

for f in $ENV_FILES; do
	sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)$/\1 \2/p' "$f" | while read -r key value; do
		printf '%s' "$value" | jq -R -r --arg k "$key" "select($EXTERNAL) | \"FAIL: env \(\$k)=\(.)\""
	done >>"$found"
done

printf '%s' "$config" | jq -r '
	.services | to_entries[] | .key as $s | (.value.ports // [])[] |
	select((.host_ip // "0.0.0.0") != "127.0.0.1") |
	select($s != "local-https-proxy") |
	select(($s == "livekit" and (.protocol == "udp" or .target == 7881)) | not) |
	"FAIL: \($s) publishes \(.host_ip // "0.0.0.0"):\(.published)->\(.target)/\(.protocol)"' >>"$found"

if [ -s "$found" ]; then
	cat "$found"
	status=1
else
	echo "PASS: no plaintext URL or port outside the backend ($FILES; $ENV_FILES)"
fi
exit "$status"
