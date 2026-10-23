#!/usr/bin/env bats
# utils/mk/public.mk is glue: it must layer the compose files in the right order (the public
# overlay LAST, PUBLIC_COMPOSE_EXTRA before it) and hand the scope to the script. Asserted on
# `make -n` output, so nothing is built, recreated or opened.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils && bats scripts/tests/public-make.bats'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link" GROBASE_LINK_CONF=/dev/null
}

dry() { run make -n -C "$REPO" "$@"; }

@test "public-up recreates the public services and the two static apps, then opens 443 by default" {
  dry public-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPOSE_FILE='docker-compose.yml:docker-compose.grobase-link.yml:docker-compose.public.yml'"* ]]
  [[ "$output" == *"--env-file ./.env.local --env-file ./.env.public"* ]]
  [[ "$output" == *"up -d --build --wait osionos-app opposite-osiris-web auth-gateway osionos-bridge local-https-proxy mail-web calendar-web"* ]]
  [[ "$output" == *"bash scripts/public-funnel.sh up 443"* ]]
}

@test "PUBLIC_COMPOSE_EXTRA files sit between the link overlay and the public overlay" {
  dry public-up PUBLIC_PORTS=all PUBLIC_COMPOSE_EXTRA="/a/live.yml /b/two.yml"
  [[ "$output" == *"docker-compose.grobase-link.yml:/a/live.yml:/b/two.yml:docker-compose.public.yml'"* ]]
  [[ "$output" == *"public-funnel.sh up all"* ]]
}

@test "public-down, public-status and public-verify call the script and nothing else" {
  dry public-down
  [[ "$output" == *"bash scripts/public-funnel.sh down"* ]]
  [[ "$output" != *"docker compose"* ]]
  dry public-status
  [[ "$output" == *"public-funnel.sh status"* ]]
  dry public-verify PUBLIC_VERIFY_ARGS="--pre"
  [[ "$output" == *"public-funnel.sh verify --pre"* ]]
}

@test "every public target is documented in make help" {
  run make -s -C "$REPO" help NO_COLOR=1
  [ "$status" -eq 0 ]
  for t in public-env public-up public-down public-status public-verify; do
    [[ "$output" == *"$t "* ]]
  done
  [[ "$output" == *"Public (Funnel)"* ]]
}
