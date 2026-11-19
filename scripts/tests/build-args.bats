#!/usr/bin/env bats
# Docker drops a --build-arg its Dockerfile never declares with only a warning, and vite inlines
# what it was not given as empty. osionos 2e24e1e8 made an empty VITE_WHITEBOARD_APP_URL hide the
# whiteboard; app.Dockerfile had no ARG for it, so every osionos-app image built through compose
# shipped without the whiteboard. These tests check every arg the base and public compose files
# pass against the Dockerfile that builds it (scripts/lib/build-args.sh). Every fixture test that
# expects a report has a twin that differs only in the Dockerfile, so a check that reports
# everything fails.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache coreutils && bats scripts/tests/build-args.bats'

# shellcheck disable=SC2016 # the fixtures write a literal $NAME into Dockerfiles and compose files
setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  . "$REPO/scripts/lib/build-args.sh"
}

# The args compose passes to SERVICE (base + public overlay) that its Dockerfile drops.
dropped_for() {
  local service="$1" dockerfile args
  dockerfile=$(cd "$REPO" && compose_build_args docker-compose.yml docker-compose.public.yml |
    awk -F'\t' -v s="$service" '$1 == s { print $2; exit }')
  [ -n "$dockerfile" ] || { echo "compose builds no service named $service" >&2; return 2; }
  [ -f "$REPO/$dockerfile" ] || { echo "SKIP $dockerfile"; return 0; }
  mapfile -t args < <(cd "$REPO" && compose_build_args docker-compose.yml docker-compose.public.yml |
    awk -F'\t' -v s="$service" '$1 == s { print $3 }')
  dropped_build_args "$REPO/$dockerfile" "${args[@]}"
}

assert_none_dropped() {
  run dropped_for "$1"
  [ "$status" -eq 0 ]
  case $output in "SKIP "*) skip "${output#SKIP } is not checked out" ;; esac
  [ -z "$output" ] || {
    echo "$1: compose passes, the Dockerfile drops: $output" >&2
    false
  }
}

fixture_dockerfile() {
  FIXTURE_DOCKERFILE=$BATS_TEST_TMPDIR/Dockerfile
  printf '%b' "$1" >"$FIXTURE_DOCKERFILE"
}

@test "osionos-app: app.Dockerfile hands every compose build arg to the vite build" {
  assert_none_dropped osionos-app
}

@test "beta: app.Dockerfile hands every build arg the beta updater passes to the vite build" {
  local args
  mapfile -t args < <(script_build_args "$REPO/infrastructure/beta/update.sh")
  [ "${#args[@]}" -gt 10 ]
  run dropped_build_args "$REPO/infrastructure/docker/osionos/app.Dockerfile" "${args[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "the beta passes, app.Dockerfile drops: $output" >&2; false; }
}

@test "osionos-app: every VITE_OSIO flag defaults off and reaches .env.production.local" {
  run osio_flags_off_env_file "$REPO/infrastructure/docker/osionos/app.Dockerfile"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "VITE_OSIO flags with a default or missing from the env file: $output" >&2; false; }
}

@test "PH2: only the beta updater turns on the profile page" {
  # CI runs bats as root on a runner-owned checkout: git refuses it as dubious ownership unless trusted here.
  run git -c safe.directory="$REPO" -C "$REPO" grep -l 'VITE_OSIO_PROFILE_PAGE=1' -- . ':!scripts/tests/build-args.bats'
  [ "$output" = infrastructure/beta/update.sh ]
}

@test "opposite-osiris-web: its Dockerfile hands every compose build arg to the build" {
  assert_none_dropped opposite-osiris-web
}

@test "hydrawn-web: its Dockerfile hands every compose build arg to the build" {
  assert_none_dropped hydrawn-web
}

@test "mail-web and calendar-web: their Dockerfiles hand every public build arg to the build" {
  assert_none_dropped mail-web
  assert_none_dropped calendar-web
}

@test "compose: the public overlay keeps the base file's dockerfile and adds its own args" {
  mkdir -p "$BATS_TEST_TMPDIR/c"
  printf 'services:\n  web:\n    image: x\n    build:\n      context: ./app\n      dockerfile: ../infra/web.Dockerfile\n      args:\n        # a comment\n        A: "1"\n        B: ${B:-}\n    environment:\n      NOT_AN_ARG: "1"\n  short:\n    build: ./s\n' >"$BATS_TEST_TMPDIR/c/base.yml"
  printf 'services:\n  web:\n    build:\n      args:\n        B: ""\n        C: "3"\n' >"$BATS_TEST_TMPDIR/c/public.yml"
  run compose_build_args "$BATS_TEST_TMPDIR/c/base.yml" "$BATS_TEST_TMPDIR/c/public.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'web\tinfra/web.Dockerfile\t%s\n' A B C)" ]
}

@test "negative control: an arg with no ARG line is named" {
  fixture_dockerfile 'FROM node AS build\nARG VITE_A=\nENV VITE_A=$VITE_A\nRUN vite build\n'
  run dropped_build_args "$FIXTURE_DOCKERFILE" VITE_A VITE_WHITEBOARD_APP_URL
  [ "$output" = VITE_WHITEBOARD_APP_URL ]
}

@test "twin: the same arg declared and put in ENV is not named" {
  fixture_dockerfile 'FROM node AS build\nARG VITE_A=\nARG VITE_WHITEBOARD_APP_URL=x\nENV VITE_A=$VITE_A \\\n    VITE_WHITEBOARD_APP_URL=$VITE_WHITEBOARD_APP_URL\nRUN vite build\n'
  run dropped_build_args "$FIXTURE_DOCKERFILE" VITE_A VITE_WHITEBOARD_APP_URL
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "negative control: an ARG declared in another stage is named" {
  fixture_dockerfile 'FROM node AS build\nRUN vite build\nFROM nginx\nARG VITE_A=\n'
  run dropped_build_args "$FIXTURE_DOCKERFILE" VITE_A
  [ "$output" = VITE_A ]
}

@test "twin: the same ARG before the stage's RUN reaches it through the environment" {
  fixture_dockerfile 'FROM node AS build\nARG VITE_A=\nRUN vite build\nFROM nginx\n'
  run dropped_build_args "$FIXTURE_DOCKERFILE" VITE_A
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "negative control: a longer name that starts with the arg is not a use of it" {
  fixture_dockerfile 'FROM node\nARG VITE_A=\nLABEL x=$VITE_AB\n'
  run dropped_build_args "$FIXTURE_DOCKERFILE" VITE_A
  [ "$output" = VITE_A ]
}

@test "twin: a \${VITE_A} reference in a COPY line is a use" {
  fixture_dockerfile 'FROM node\nARG VITE_A=\nCOPY a /x/${VITE_A}/\n'
  run dropped_build_args "$FIXTURE_DOCKERFILE" VITE_A
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "negative control: a VITE_OSIO flag left out of the env file, or on by default, is named" {
  fixture_dockerfile 'FROM node\nARG VITE_OSIO_A=\nARG VITE_OSIO_B=\nARG VITE_OSIO_C=1\nRUN printf %s "VITE_OSIO_A=%s\\nVITE_OSIO_C=%s\\n" > .env.production.local\n'
  run osio_flags_off_env_file "$FIXTURE_DOCKERFILE"
  [ "$output" = "$(printf 'VITE_OSIO_B\nVITE_OSIO_C')" ]
}

@test "twin: the same flags all written and all empty are not named" {
  fixture_dockerfile 'FROM node\nARG VITE_OSIO_A=\nARG VITE_OSIO_B=\nARG VITE_OSIO_C=\nRUN printf %s "VITE_OSIO_A=%s\\nVITE_OSIO_B=%s\\nVITE_OSIO_C=%s\\n" > .env.production.local\n'
  run osio_flags_off_env_file "$FIXTURE_DOCKERFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "script_build_args: lists each --build-arg name once" {
  printf 'docker build \\\n  --build-arg A=1 --build-arg B= \\\n  --build-arg A=2 .\n' >"$BATS_TEST_TMPDIR/u.sh"
  run script_build_args "$BATS_TEST_TMPDIR/u.sh"
  [ "$output" = "$(printf 'A\nB')" ]
}
