#!/usr/bin/env bats
# The publish-socket compose overlay is opt-in: the real public.mk adds it only for
# OSIONOS_PUBLISH_SOCKET=1, and only the bridge receives the socket directory read-only.
#   bats tests/osionos-publish-socket/overlay.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  OVERLAY=$REPO/docker-compose.publish-socket.yml
  HELPER=$BATS_TEST_TMPDIR/print-compose-files.mk
  cat >"$HELPER" <<'MAKEFILE'
.PHONY: print-compose-files
print-compose-files:
	@printf '%s\n' '$(PUBLIC_COMPOSE_FILES)'
MAKEFILE
  unset OSIONOS_PUBLISH_SOCKET OSIONOS_PUBLISH_SOCKET_DIR PUBLIC_COMPOSE_EXTRA
  cd "$REPO"
}

print_compose_files() {
  make -s --no-print-directory -f utils/mk/public.mk -f "$HELPER" print-compose-files "$@"
}

@test "S13: without the opt-in flag the compose file list is unchanged" {
  run print_compose_files
  [ "$status" -eq 0 ]
  [ "$output" = "docker-compose.yml:docker-compose.grobase-link.yml:docker-compose.public.yml" ]
}

@test "S13: OSIONOS_PUBLISH_SOCKET=1 inserts the overlay before the public file" {
  OSIONOS_PUBLISH_SOCKET=1 run print_compose_files
  [ "$status" -eq 0 ]
  [ "$output" = "docker-compose.yml:docker-compose.grobase-link.yml:docker-compose.publish-socket.yml:docker-compose.public.yml" ]
}

@test "S13: flag values other than exactly 1 leave the compose file list unchanged" {
  for value in 0 yes '0 1' '1 0' 'yes 1'; do
    OSIONOS_PUBLISH_SOCKET=$value run print_compose_files
    [ "$status" -eq 0 ]
    [ "$output" = "docker-compose.yml:docker-compose.grobase-link.yml:docker-compose.public.yml" ]
  done
}

@test "an existing PUBLIC_COMPOSE_EXTRA stays before the opt-in overlay" {
  PUBLIC_COMPOSE_EXTRA=x.yml OSIONOS_PUBLISH_SOCKET=1 run print_compose_files
  [ "$status" -eq 0 ]
  [ "$output" = "docker-compose.yml:docker-compose.grobase-link.yml:x.yml:docker-compose.publish-socket.yml:docker-compose.public.yml" ]
}

@test "a command-line PUBLIC_COMPOSE_EXTRA does not drop the opt-in overlay" {
  run print_compose_files PUBLIC_COMPOSE_EXTRA=x.yml OSIONOS_PUBLISH_SOCKET=1
  [ "$status" -eq 0 ]
  [ "$output" = "docker-compose.yml:docker-compose.grobase-link.yml:x.yml:docker-compose.publish-socket.yml:docker-compose.public.yml" ]
}

@test "S4/S5: the overlay mounts only the directory read-only and adds no TCP exposure" {
  [ -f "$OVERLAY" ]
  grep -qx 'services:' "$OVERLAY"
  run grep -E '^  [^ #][^:]*:$' "$OVERLAY"
  [ "$status" -eq 0 ]
  [ "$output" = "  osionos-bridge:" ]
  grep -Eq '^[[:space:]]+REALTIME_PUBLISH_SOCKET:[[:space:]]*/run/osionos-publish/kong\.sock[[:space:]]*$' "$OVERLAY"
  grep -Fq '${OSIONOS_PUBLISH_SOCKET_DIR:?run make publish-socket; it prints the dir}:/run/osionos-publish:ro' "$OVERLAY"
  for forbidden in 'ports:' 'networks:' 'aliases' 'socat' '4000' ':8000'; do
    if grep -Fq "$forbidden" "$OVERLAY"; then
      echo "overlay contains forbidden TCP exposure marker: $forbidden"
      return 1
    fi
  done
}

@test "compose config without the socket directory names the publish-socket remedy" {
  if ! command -v docker >/dev/null 2>&1; then
    skip "docker is not on PATH; cannot run docker compose config"
  fi
  run docker compose -f "$OVERLAY" config
  [ "$status" -ne 0 ]
  [[ "$output" == *"make publish-socket"* ]]
}
