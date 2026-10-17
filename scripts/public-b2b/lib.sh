#!/usr/bin/env bash
# lib.sh — constants and checks shared by build-images.sh, deploy.sh and rollback.sh
# (ADR 0013): the public URL, the ssh invocation, the image identity test and the serve-config
# diff. One home so the three scripts cannot disagree on what "unchanged" means.
# Sourced, not run; the caller sets `set -euo pipefail`.
#
# Caveat: layers_hash compares RootFS layer ids, which proves the same filesystem arrived but
# not the same config (env, cmd): a retag of different config over equal layers passes.
# The serve diff compares JSON values after the 10000 keys are removed, so a reordered but
# equal config passes (it is equal).

PUBLIC_HOST=baas.tail10f2ea.ts.net
FUNNEL_PORT=10000
PUBLIC_URL=https://$PUBLIC_HOST:$FUNNEL_PORT
REMOTE_DIR=/opt/prismatica-public
PROJECT=prismatica-public
export PUBLIC_HOST FUNNEL_PORT PUBLIC_URL REMOTE_DIR PROJECT
B2B=(ssh -o ClearAllForwardings=yes -o ConnectTimeout=10 b2b)

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

layers_hash() {
	docker image inspect "$1" --format '{{json .RootFS.Layers}}' | sha256sum | cut -c1-16
}

remote_layers_hash() {
	"${B2B[@]}" "docker image inspect $1 --format '{{json .RootFS.Layers}}'" | sha256sum | cut -c1-16
}

# True when AFTER (a file on the VM) is BEFORE plus exactly the three :10000 keys.
# $1 = before.json, $2 = after.json, both paths on the VM.
serve_adds_only_funnel_keys() {
	"${B2B[@]}" "jq -e --arg h '$PUBLIC_HOST:$FUNNEL_PORT' --slurpfile b '$1' \
		'(.TCP[\"$FUNNEL_PORT\"] != null and .Web[\$h] != null and .AllowFunnel[\$h] == true)
		and (del(.TCP[\"$FUNNEL_PORT\"], .Web[\$h], .AllowFunnel[\$h]) == \$b[0])' '$2' >/dev/null"
}

# True when the two serve configs hold equal values. Both paths on the VM.
serve_equal() {
	"${B2B[@]}" "jq -e --slurpfile b '$1' '. == \$b[0]' '$2' >/dev/null"
}
