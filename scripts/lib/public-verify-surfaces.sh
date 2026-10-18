#!/usr/bin/env bash
# public-verify-surfaces.sh — the checks that keep a surface nobody should reach from the
# internet out of public mode: the IDE (token secret, access mode) and every localhost link in
# the served app bundle. Sourced by lib/public-verify.sh, which provides pass/fail/expect,
# container_env, svc_container, APP_IMAGE and BRIDGE_MUST_BE_EMPTY.
# No check prints a secret value: the mode is a word, the links are localhost:PORT.
#
# Caveat: the link scan matches the literal text https?://localhost:PORT; a URL assembled at run
# time or written with 127.0.0.1 is missed (under-reporting). The mode check reads the running
# containers, not the compose file they came from.

# OSIONOS_IDE_ACCESS values a public stack may run with; unset and empty mean off.
IDE_MODES_ALLOWED="allowlist off"

# $1 label, $2 container id: FAIL naming OSIONOS_IDE_ACCESS and its mode unless the mode is allowed.
check_ide_mode() {
  local mode
  mode=$(container_env "$2" OSIONOS_IDE_ACCESS)
  case " $IDE_MODES_ALLOWED " in
    *" ${mode:-off} "*) pass ide-access "$1: OSIONOS_IDE_ACCESS=${mode:-<empty>}" ;;
    *) fail ide-access "$1: OSIONOS_IDE_ACCESS=$mode, expected unset, allowlist or off" ;;
  esac
}

# The bridge and, when the project runs one, the IDE server.
check_ide_access() {
  local bridge ide
  bridge=$(svc_container osionos-bridge)
  [ -n "$bridge" ] || {
    fail ide-access "osionos-bridge is not running"
    return
  }
  check_ide_mode osionos-bridge "$bridge"
  ide=$(svc_container osionos-ide-server || true)
  if [ -n "$ide" ]; then
    check_ide_mode osionos-ide-server "$ide"
  else pass ide-access "no osionos-ide-server runs in this project"; fi
}

# Line 1: number of files in IMAGE holding an http(s)://localhost:PORT link; then each distinct
# localhost:PORT, one per line.
bundle_links() {
  local re='https?://localhost:[0-9]+' roots='/usr/share/nginx/html /app /srv'
  docker run --rm --entrypoint sh "$1" -c "grep -rlE '$re' $roots 2>/dev/null | wc -l; grep -rhoE '$re' $roots 2>/dev/null | sed 's|.*//||' | sort -u" 2>/dev/null
}

# A localhost link in the bundle frames the visitor's own machine, not ours.
check_bundle_links() {
  local out count ports
  out=$(bundle_links "$APP_IMAGE" || true)
  count=$(head -n1 <<<"$out" | tr -d '[:space:]')
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    fail bundle-links "could not be scanned in $APP_IMAGE"
  elif [ "$count" = 0 ]; then
    pass bundle-links "0 files in $APP_IMAGE link to localhost"
  else
    ports=$(tail -n +2 <<<"$out" | paste -sd' ' -)
    fail bundle-links "$count file(s) in $APP_IMAGE link to $ports"
  fi
}
