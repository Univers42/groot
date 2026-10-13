#!/usr/bin/env bash
# ************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::   #
#   ide-compose-shape.sh                               :+:      :+:    :+:   #
#                                                    +:+ +:+         +:+     #
#   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        #
#                                                +#+#+#+#+#+   +#+           #
#   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             #
#   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       #
#                                                                            #
# ************************************************************************** #

# ide-compose-shape.sh — validate the rendered Compose model for the IDE plane.
# Runs on the host from the repo root. Never prints environment VALUES, only
# keys and booleans. Exits 1 on any FAIL.
#
# Ponytail: it checks the rendered compose model and one nginx block by text,
# not a running stack. A rule enforced only at runtime (e.g. Docker dropping a
# publish on an internal network) is not seen here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

cfg_file=$(mktemp)
trap 'rm -f "$cfg_file"' EXIT
timeout 60 docker compose --env-file /dev/null -f docker-compose.yml --profile ide config --format json --no-env-resolution > "$cfg_file"

failed=0

ok() { printf 'ok %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failed=1; }

# Extract service config from JSON
svc() { jq -r ".services[\"$1\"] // empty" "$cfg_file"; }

# ----- osionos-ide-server -----
server=$(svc "osionos-ide-server")

if [ -z "$server" ]; then
  fail "osionos-ide-server: service missing"
else
  # no ports
  if echo "$server" | jq -e '.ports == null or .ports == []' >/dev/null; then
    ok "osionos-ide-server: no ports"
  else
    fail "osionos-ide-server: has ports"
  fi

  # no env_file
  if echo "$server" | jq -e '.env_file == null or .env_file == []' >/dev/null; then
    ok "osionos-ide-server: no env_file"
  else
    fail "osionos-ide-server: has env_file"
  fi

  # networks exactly {control-net, edge-net}
  nets=$(echo "$server" | jq -r '.networks | keys | sort | join(",")')
  if [ "$nets" = "osionos-ide-control-net,osionos-ide-edge-net" ]; then
    ok "osionos-ide-server: networks exact"
  else
    fail "osionos-ide-server: networks=$nets"
  fi

  # read_only true
  if echo "$server" | jq -e '.read_only == true' >/dev/null; then
    ok "osionos-ide-server: read_only true"
  else
    fail "osionos-ide-server: read_only not true"
  fi

  # cap_drop == ["ALL"]
  cap_drop=$(echo "$server" | jq -r '.cap_drop | sort | join(",")')
  if [ "$cap_drop" = "ALL" ]; then
    ok "osionos-ide-server: cap_drop ALL"
  else
    fail "osionos-ide-server: cap_drop=$cap_drop"
  fi

  # security_opt contains no-new-privileges:true
  if echo "$server" | jq -e '.security_opt[]? | select(. == "no-new-privileges:true")' >/dev/null; then
    ok "osionos-ide-server: security_opt no-new-privileges"
  else
    fail "osionos-ide-server: missing no-new-privileges"
  fi

  # mem_limit set
  if echo "$server" | jq -e '.mem_limit != null and .mem_limit != ""' >/dev/null; then
    ok "osionos-ide-server: mem_limit set"
  else
    fail "osionos-ide-server: mem_limit missing"
  fi

  # pids_limit set
  if echo "$server" | jq -e '.pids_limit != null' >/dev/null; then
    ok "osionos-ide-server: pids_limit set"
  else
    fail "osionos-ide-server: pids_limit missing"
  fi

  # every environment key matches ^(OSIONOS_IDE_[A-Z_]+|NODE_ENV)$
  env_keys=$(echo "$server" | jq -r '.environment | keys[]?' 2>/dev/null | sort)
  env_ok=true
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if ! [[ "$key" =~ ^(OSIONOS_IDE_[A-Z_]+|NODE_ENV)$ ]]; then
      env_ok=false
      fail "osionos-ide-server: env key '$key' does not match pattern"
    fi
  done <<< "$env_keys"
  if [ "$env_ok" = true ]; then
    ok "osionos-ide-server: env keys match pattern"
  fi

  # command ends with scripts/ide-server.mjs
  cmd=$(echo "$server" | jq -r '.command | join(" ")')
  if [[ "$cmd" == *scripts/ide-server.mjs ]]; then
    ok "osionos-ide-server: command ends with ide-server.mjs"
  else
    fail "osionos-ide-server: command='$cmd'"
  fi
fi

# ----- osionos-bridge -----
bridge=$(svc "osionos-bridge")

if [ -z "$bridge" ]; then
  fail "osionos-bridge: service missing"
else
  # not on osionos-ide-control-net
  bridge_nets=$(echo "$bridge" | jq -r '.networks | keys | sort | join(",")')
  if [[ "$bridge_nets" != *"osionos-ide-control-net"* ]]; then
    ok "osionos-bridge: not on osionos-ide-control-net"
  else
    fail "osionos-bridge: still on osionos-ide-control-net"
  fi

  # OSIONOS_IDE_SANDBOX == ""
  if echo "$bridge" | jq -e '.environment.OSIONOS_IDE_SANDBOX == ""' >/dev/null; then
    ok "osionos-bridge: OSIONOS_IDE_SANDBOX empty"
  else
    val=$(echo "$bridge" | jq -r '.environment.OSIONOS_IDE_SANDBOX // "<missing>"')
    fail "osionos-bridge: OSIONOS_IDE_SANDBOX=$val"
  fi

  # OSIONOS_IDE_DOCKER_HOST == ""
  if echo "$bridge" | jq -e '.environment.OSIONOS_IDE_DOCKER_HOST == ""' >/dev/null; then
    ok "osionos-bridge: OSIONOS_IDE_DOCKER_HOST empty"
  else
    val=$(echo "$bridge" | jq -r '.environment.OSIONOS_IDE_DOCKER_HOST // "<missing>"')
    fail "osionos-bridge: OSIONOS_IDE_DOCKER_HOST=$val"
  fi
fi

# ----- local-https-proxy -----
proxy=$(svc "local-https-proxy")

if [ -z "$proxy" ]; then
  fail "local-https-proxy: service missing"
else
  # on osionos-ide-edge-net
  proxy_nets=$(echo "$proxy" | jq -r '.networks | keys | sort | join(",")')
  if [[ "$proxy_nets" == *"osionos-ide-edge-net"* ]]; then
    ok "local-https-proxy: on osionos-ide-edge-net"
  else
    fail "local-https-proxy: not on osionos-ide-edge-net (nets=$proxy_nets)"
  fi

  # publishes target 8446 with host_ip exactly 127.0.0.1
  pub_ok=false
  while IFS= read -r line; do
    if echo "$line" | jq -e '.target == 8446 and .host_ip == "127.0.0.1"' >/dev/null; then
      pub_ok=true
      break
    fi
  done < <(echo "$proxy" | jq -c '.ports[]?')
  if [ "$pub_ok" = true ]; then
    ok "local-https-proxy: publishes 8446 on 127.0.0.1"
  else
    fail "local-https-proxy: missing 8446 publish on 127.0.0.1"
  fi
fi

# ----- osionos-ide-socket-proxy -----
# Long syntax with create_host_path: false — a missing host socket must fail the
# start, never become a directory docker-ide can no longer bind (README, step A).
# Ponytail: compose v2.36 renders that `false` as an EMPTY bind object, so a bind
# block must be PRESENT and say false-or-nothing; no block at all = FAIL.
sockproxy=$(svc "osionos-ide-socket-proxy")
if [ -z "$sockproxy" ]; then
  fail "osionos-ide-socket-proxy: service missing"
else
  # sp_check DESC FILTER — ok when FILTER holds on the rendered service.
  sp_check() {
    if echo "$sockproxy" | jq -e "$2" >/dev/null; then
      ok "osionos-ide-socket-proxy: $1"
    else
      fail "osionos-ide-socket-proxy: $1"
    fi
  }
  # sp_check DESC VOLUME-FILTER — FILTER must hold on the one volume entry.
  sp_vol() { sp_check "$1" "(.volumes | type) == \"array\" and (.volumes | length) == 1 and any(.volumes[]; $2)"; }
  sp_check "no ports" '.ports == null or .ports == []'
  sp_check "networks exact" '.networks | (keys | sort) == ["osionos-ide-control-net"]'
  sp_check "read_only true" '.read_only == true'
  sp_check "cap_drop ALL" '.cap_drop | sort == ["ALL"]'
  sp_check "security_opt no-new-privileges" 'any(.security_opt[]?; . == "no-new-privileges:true")'
  sp_check "mem_limit set" '.mem_limit != null and .mem_limit != ""'
  sp_check "pids_limit set" '.pids_limit != null'
  sp_check "exactly one volume" '(.volumes | type) == "array" and (.volumes | length) == 1'
  sp_vol "bind of /dind-run/docker.sock" '.type == "bind" and .target == "/dind-run/docker.sock"'
  sp_vol "create_host_path false" '(.bind | type) == "object" and (.bind.create_host_path // false) == false'
  # The proxy refuses a create whose image differs from its own setting, so it must render the
  # same value as the ide-server for whatever pin the environment carries.
  srv_image=$(svc "osionos-ide-server" | jq -r '.environment.OSIONOS_IDE_SANDBOX_IMAGE // empty')
  sp_check "sandbox image equals the ide-server's" ".environment.OSIONOS_IDE_SANDBOX_IMAGE == \"${srv_image:-unset}\""
fi

# ----- networks are internal: true -----
# Read compose's real network key from the config JSON (project-prefixed or .name)
edge_net_key=$(jq -r '.networks | keys[] | select(. | endswith("osionos-ide-edge-net") or . == "osionos-ide-edge-net")' "$cfg_file" | head -1)
control_net_key=$(jq -r '.networks | keys[] | select(. | endswith("osionos-ide-control-net") or . == "osionos-ide-control-net")' "$cfg_file" | head -1)

if [ -n "$edge_net_key" ] && jq -e ".networks.\"$edge_net_key\".internal == true" "$cfg_file" >/dev/null; then
  ok "network osionos-ide-edge-net: internal true"
else
  fail "network osionos-ide-edge-net: not internal (key=$edge_net_key)"
fi

if [ -n "$control_net_key" ] && jq -e ".networks.\"$control_net_key\".internal == true" "$cfg_file" >/dev/null; then
  ok "network osionos-ide-control-net: internal true"
else
  fail "network osionos-ide-control-net: not internal (key=$control_net_key)"
fi

# ----- infrastructure/tls/nginx.conf: listen 8446 block has access_log off and osionos-ide-server:4100 -----
nginx_conf="$REPO_ROOT/infrastructure/tls/nginx.conf"
if [ ! -f "$nginx_conf" ]; then
  fail "nginx.conf: file missing"
else
  # Extract block between "listen 8446" and next "^  }"
  block=$(awk '/listen 8446 ssl;/{flag=1} flag{print} /^  }$/ && flag{exit}' "$nginx_conf")
  if echo "$block" | grep -q 'access_log off;'; then
    ok "nginx.conf: listen 8446 block has access_log off"
  else
    fail "nginx.conf: listen 8446 block missing access_log off"
  fi
  if echo "$block" | grep -q 'osionos-ide-server:4100'; then
    ok "nginx.conf: listen 8446 block has osionos-ide-server:4100 upstream"
  else
    fail "nginx.conf: listen 8446 block missing osionos-ide-server:4100 upstream"
  fi
fi

# ----- Image closure: every module an image's entries import is a COPY source of its Dockerfile -----
# Ponytail: follows `from './x.mjs'`, `import './x.mjs'` and `import("./x.mjs")` text
# only, and compares basenames (one source directory per image). A computed import(), a
# ../ path or a bare package specifier is invisible, so a module reached that way can be
# missing from the image without a FAIL here.

# copied_modules DOCKERFILE — basenames of every .mjs a COPY instruction sources (its
# destination, the last word, dropped), continuation lines joined.
copied_modules() {
  sed ':a;/\\$/N;s/\\\n/ /;ta' "$1" \
    | awk '$1 == "COPY" { for (i = 2; i < NF; i++) if ($i ~ /\.mjs$/) { n = split($i, part, "/"); print part[n] } }' \
    | sort -u
}

# local_imports FILE — the ./x.mjs modules FILE imports, statically or by a literal import().
local_imports() {
  grep -oE "(from|import)[[:space:]]*\(?[[:space:]]*['\"]\./[^'\"/]+\.mjs['\"]" "$1" \
    | sed -E "s/.*['\"]\.\/([^'\"]+)['\"]$/\1/"
}

# image_closure SRC_DIR DOCKERFILE "ENTRY…" — FAIL for each module of the closure the
# Dockerfile does not copy or SRC_DIR does not hold.
image_closure() {
  local copied queue seen=" " idx=0 mod closure_ok=true label
  label=${2#"$REPO_ROOT"/}
  copied=$(copied_modules "$2")
  read -r -a queue <<< "$3"
  while [ "$idx" -lt "${#queue[@]}" ]; do
    mod="${queue[$idx]}"
    idx=$((idx + 1))
    case "$seen" in *" $mod "*) continue ;; esac
    seen="$seen$mod "
    grep -qxF "$mod" <<< "$copied" || { closure_ok=false; fail "image closure: $mod missing from $label COPY"; }
    [ -f "$1/$mod" ] || { closure_ok=false; fail "image closure: $mod imported but absent"; continue; }
    while IFS= read -r dep; do queue+=("$dep"); done < <(local_imports "$1/$mod")
  done
  [ "$closure_ok" = false ] || ok "image closure: $(wc -w <<< "$seen") modules, all in $label COPY"
}

osionos_docker="$REPO_ROOT/infrastructure/docker/osionos"
image_closure "$osionos_docker/ide-socket-proxy" "$osionos_docker/ide-socket-proxy/Dockerfile" "proxy.mjs"
image_closure "$osionos_docker/ide-egress-proxy" "$osionos_docker/ide-egress-proxy/Dockerfile" "proxy.mjs"
if [ ! -f "$REPO_ROOT/apps/osionos/app/scripts/ide-server.mjs" ]; then
  printf 'SKIP image closure of bridge.Dockerfile (submodule not checked out)\n'
else
  image_closure "$REPO_ROOT/apps/osionos/app/scripts" "$osionos_docker/bridge.Dockerfile" "ide-server.mjs bridge-api.mjs"
fi

exit "$failed"