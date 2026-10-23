#!/usr/bin/env bash
# public-tailnet.sh — what scripts/public-node.sh, public-funnel.sh and lib/public-verify*.sh share
# about the two Tailscale nodes: where the apps node keeps its state and socket, how to talk to
# it, and how to read what a node's Funnel exposes. Sourced; sets no shell option.
#
# Caveat: funnel_ports and funnel_targets read the JSON of `tailscale funnel status --json`
# (AllowFunnel, Web.<host:port>.Handlers) as tailscale 1.104 prints it; a daemon printing another
# schema reads as "nothing open", which a verify with an explicit scope turns into a FAIL.

# public port:local loopback port of the apps node's edge listeners (local-https-proxy,
# infrastructure/tls/public.d/apps.conf.template): Mail on 443, Calendar on 8443.
# shellcheck disable=SC2034 # read by scripts/public-funnel.sh and lib/public-verify-apps.sh, which source this file
APPS_FUNNEL_MAP="443:3102 8443:3103"

apps_node_name() { printf '%s' "${PUBLIC_APPS_NODE:-osionos-apps}"; }
apps_node_dir() { printf '%s/tailscale-%s' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(apps_node_name)"; }
apps_node_socket() { printf '%s' "${TAILSCALE_APPS_SOCKET:-$(apps_node_dir)/tailscaled.sock}"; }

# The tailscale CLI aimed at the apps node.
tsa() { "${TAILSCALE_BIN:-$HOME/.local/bin/tailscale}" --socket "$(apps_node_socket)" "$@"; }

# DNS name of a node ($1: the CLI function, ts or tsa): empty when it has none, status 1 when the
# daemon does not answer.
node_dns() {
  local json
  json=$("${1:-ts}" status --json 2>/dev/null) || return 1
  jq -r '.Self.DNSName // empty' <<<"$json"
}

# Open Funnel ports of a node, comma-joined ascending; $1 is the CLI function (ts or tsa).
# Fails when tailscale cannot answer.
funnel_ports() {
  local json
  json=$("${1:-ts}" funnel status --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '(.AllowFunnel // {}) | to_entries[] | select(.value == true) | .key | split(":") | last' |
    sort -n | paste -sd, -
}

# Every served handler of a node as "PORT PATH TARGET" (TARGET without its scheme), sorted.
funnel_targets() {
  local json
  json=$("${1:-ts}" funnel status --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '(.Web // {}) | to_entries[] | (.key | split(":") | last) as $port |
    (.value.Handlers // {}) | to_entries[] |
    "\($port) \(.key) \((.value.Proxy // .value.Path // "?") | sub("^[a-z+]+://"; ""))"' | sort -n
}
