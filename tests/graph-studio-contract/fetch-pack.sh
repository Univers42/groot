#!/usr/bin/env bash
# Fetches the graph_render pack that app.Dockerfile pins (ARG GRAPH_STUDIO_PACK, by digest) from
# the registry's HTTP API, anonymously and without docker, and unpacks its /pack/ into OUT_DIR.
# Every byte is checked: the manifest against the pinned digest, the layer against the manifest,
# each file against pack.json, and pack.json's source_rev against the apps/graph_render gitlink.
# Usage: fetch-pack.sh OUT_DIR
# Exit: 0 ok · 3 registry unreachable (retried; not a finding about the pin) · 1 pin mismatch.
set -euo pipefail

out=${1:?usage: fetch-pack.sh OUT_DIR}
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
ref=$(sed -n 's/^ARG GRAPH_STUDIO_PACK=//p' "$repo/infrastructure/docker/osionos/app.Dockerfile")
pin=$(git -C "$repo" ls-tree HEAD apps/graph_render | awk '$2 == "commit" { print $3 }')
mismatch() { echo "PIN MISMATCH: $*" >&2; exit 1; }
unreachable() { echo "REGISTRY UNREACHABLE: $* (retried; rerun the job)" >&2; exit 3; }

[[ "$ref" =~ ^([a-z0-9.-]+)/([a-z0-9._/-]+)@(sha256:[0-9a-f]{64})$ ]] ||
  mismatch "app.Dockerfile's GRAPH_STUDIO_PACK '$ref' is not <registry>/<name>@sha256:<digest>"
registry=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} digest=${BASH_REMATCH[3]}
[ "${#pin}" -eq 40 ] || mismatch "no apps/graph_render gitlink"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
get() { curl -fsSL --retry 4 --retry-all-errors --retry-delay 2 --connect-timeout 10 --max-time 120 "$@"; }

token=$(get "https://$registry/token?scope=repository:$name:pull" | jq -er .token) ||
  unreachable "no anonymous pull token for $registry/$name"
auth="Authorization: Bearer $token"
accept="Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
get -H "$auth" -H "$accept" -o "$tmp/manifest" "https://$registry/v2/$name/manifests/$digest" ||
  unreachable "manifest $digest"
[ "sha256:$(sha256sum <"$tmp/manifest" | cut -d' ' -f1)" = "$digest" ] ||
  mismatch "the manifest served for $digest does not hash to it"
[ "$(jq '.layers | length' "$tmp/manifest")" -eq 1 ] || mismatch "expected a one-layer pack image"
layer=$(jq -er '.layers[0].digest' "$tmp/manifest")
get -H "$auth" -o "$tmp/layer" "https://$registry/v2/$name/blobs/$layer" || unreachable "layer $layer"
[ "sha256:$(sha256sum <"$tmp/layer" | cut -d' ' -f1)" = "$layer" ] || mismatch "layer $layer does not hash to its digest"

mkdir -p "$tmp/root" "$out"
tar -xzf "$tmp/layer" -C "$tmp/root" pack
cp -R "$tmp/root/pack/." "$out/"

rev=$(jq -er .source_rev "$out/pack.json")
[ "$rev" = "$pin" ] || mismatch "pack.json source_rev $rev is not the gitlink $pin — bump GRAPH_STUDIO_PACK with apps/graph_render"
mapfile -t listed < <(jq -r '.files | keys[]' "$out/pack.json")
for f in "${listed[@]}"; do
  [ -f "$out/$f" ] || mismatch "pack.json lists $f, the layer has no such file"
  [ "$(sha256sum <"$out/$f" | cut -d' ' -f1)" = "$(jq -r --arg f "$f" '.files[$f].sha256' "$out/pack.json")" ] ||
    mismatch "$f does not match its sha256 in pack.json"
done
for path in "$out"/*; do
  f=${path##*/}
  [ "$f" = pack.json ] || jq -e --arg f "$f" '.files | has($f)' "$out/pack.json" >/dev/null ||
    mismatch "$f is in the pack and not in pack.json"
done
echo "pack $digest (source_rev $rev): ${#listed[@]} files verified into $out"
