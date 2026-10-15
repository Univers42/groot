#!/usr/bin/env bats
# .mcp.json — the project's MCP servers must start on any machine that checks the repo out. The
# osionos entry once pointed at /home/dlesieur/Documents/ft_transcendence and an nvm node that no
# other seat had, so it failed with "connection closed" everywhere else. These tests pin the
# repair: every server goes through scripts/tools.sh (the one runner, nothing on the host) and no
# entry names a host-specific path. Whether each server answers is tests/tools-image/smoke.bats.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache jq && bats scripts/tests/mcp-config.bats'

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CFG="$ROOT/.mcp.json"
}

@test ".mcp.json is valid JSON with at least the three servers the redesign needs" {
  run jq -r '.mcpServers | keys[]' "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" == *playwright* ]]
  [[ "$output" == *chrome-devtools* ]]
  [[ "$output" == *osionos* ]]
}

@test "every server runs through scripts/tools.sh" {
  run jq -r '.mcpServers | to_entries[] | select(.value.command != "bash" or .value.args[0] != "scripts/tools.sh") | .key' "$CFG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no entry names a host-specific path or a host toolchain" {
  run jq -r '.mcpServers[] | [.command] + .args + [(.env // {})[]] | .[]' "$CFG"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run grep -nE '/home/|/Users/|/goinfre/|\$HOME|~/|\.nvm|-lc' <<<"$output"
  [ "$status" -eq 1 ]
}

@test "variables set for a server reach its container by name" {
  run jq -r '.mcpServers | to_entries[] | select(.value.env) | .key as $k | .value.env as $e
    | ($e | keys - ["TOOLS_PASS_ENV"])[] as $v
    | select(($e.TOOLS_PASS_ENV // "" | split(" ") | index($v)) == null) | "\($k):\($v)"' "$CFG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the osionos bridge is addressed over https (http on :4000 is a 308 to https)" {
  run jq -r '.mcpServers.osionos.env | to_entries[] | select(.key | endswith("_URL")) | .value' "$CFG"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run grep -v '^https://' <<<"$output"
  [ "$status" -eq 1 ]
}
