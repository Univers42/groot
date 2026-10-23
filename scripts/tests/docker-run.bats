#!/usr/bin/env bats
# scripts/lib/docker-run.sh — the one place that decides whose uid a one-shot container runs as
# and where the local CA lives (tests/e2e/run.sh and scripts/tools.sh both source it). Also the
# shared CA-trust entrypoint's opt-out, and that scripts/tools.sh derives its image tag from the
# files that define the image. `docker` is a stub on PATH; nothing here needs a daemon.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache coreutils git && bats scripts/tests/docker-run.bats'

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  . "$ROOT/scripts/lib/docker-run.sh"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  PATH="$STUB:$PATH"
  unset LOCAL_CA_FILE
}

stub_docker_security() {
  printf '#!/bin/sh\necho "%s"\n' "$1" >"$STUB/docker"
  chmod +x "$STUB/docker"
}

@test "rootful docker: run as the calling uid:gid" {
  stub_docker_security '[name=seccomp,profile=builtin name=cgroupns]'
  run docker_run_user_args
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--user" ]
  [ "${lines[1]}" = "$(id -u):$(id -g)" ]
}

@test "rootless docker: no --user at all" {
  stub_docker_security '[name=seccomp,profile=builtin name=rootless name=cgroupns]'
  run docker_run_user_args
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "local_ca_file finds the CA under the given root" {
  mkdir -p "$BATS_TEST_TMPDIR/r/apps/grobase/certs"
  touch "$BATS_TEST_TMPDIR/r/apps/grobase/certs/track-binocle-local-ca.pem"
  run local_ca_file "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/r/apps/grobase/certs/track-binocle-local-ca.pem" ]
}

@test "LOCAL_CA_FILE wins over the root (a worktree has no grobase checkout)" {
  touch "$BATS_TEST_TMPDIR/elsewhere.pem"
  LOCAL_CA_FILE="$BATS_TEST_TMPDIR/elsewhere.pem" run local_ca_file "$BATS_TEST_TMPDIR/nothing-here"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/elsewhere.pem" ]
}

git_quiet() { git -c user.email=t@example.test -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

@test "a linked worktree finds the main checkout's CA (the CA is generated, never committed)" {
  main="$BATS_TEST_TMPDIR/main"
  git_quiet init "$main"
  git_quiet -C "$main" commit --allow-empty -m root
  git_quiet -C "$main" worktree add "$BATS_TEST_TMPDIR/wt"
  mkdir -p "$main/apps/grobase/certs"
  touch "$main/apps/grobase/certs/track-binocle-local-ca.pem"
  run local_ca_file "$BATS_TEST_TMPDIR/wt"
  [ "$status" -eq 0 ]
  [ "$output" = "$main/apps/grobase/certs/track-binocle-local-ca.pem" ]
}

@test "a main checkout without a CA fails rather than finding itself" {
  git_quiet init "$BATS_TEST_TMPDIR/bare-main"
  run local_ca_file "$BATS_TEST_TMPDIR/bare-main"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an unreadable LOCAL_CA_FILE fails; it never falls back silently" {
  mkdir -p "$BATS_TEST_TMPDIR/r/apps/grobase/certs"
  touch "$BATS_TEST_TMPDIR/r/apps/grobase/certs/track-binocle-local-ca.pem"
  LOCAL_CA_FILE="$BATS_TEST_TMPDIR/absent.pem" run local_ca_file "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 1 ]
}

@test "tools.sh forwards TOOLS_PASS_ENV by name; the value never reaches argv" {
  t="$(fake_tools_tree)"
  cat >"$STUB/docker" <<'EOF'
#!/bin/sh
[ "$1" = image ] && exit 0
[ "$1" = info ] && exit 0
printf '%s\n' "$@"
EOF
  chmod +x "$STUB/docker"
  SOME_URL=https://secret.example.test TOOLS_PASS_ENV="SOME_URL" run bash "$t/scripts/tools.sh" true
  [ "$status" -eq 0 ]
  [[ "$output" == *$'-e\nSOME_URL'* ]]
  run grep -c 'secret.example.test' <<<"$output"
  [ "$output" = "0" ]
}

@test "local_ca_file fails, printing nothing, when no CA is readable" {
  run local_ca_file "$BATS_TEST_TMPDIR/nothing-here"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "run.sh and tools.sh take both decisions from the library, not inline copies" {
  for f in tests/e2e/run.sh scripts/tools.sh; do
    grep -q 'scripts/lib/docker-run.sh' "$ROOT/$f"
    run grep -n 'SecurityOptions\|track-binocle-local-ca.pem' "$ROOT/$f"
    [ "$status" -eq 1 ]
  done
}

@test "entrypoint: a missing CA is fatal by default (the e2e image's behaviour)" {
  [ ! -e /certs/local-ca.pem ] || skip "this container has a real CA mounted"
  run "$ROOT/tests/e2e/docker-entrypoint.sh" echo ran
  [ "$status" -eq 2 ]
  [[ "$output" == *"local CA not mounted"* ]]
}

@test "entrypoint: CA_REQUIRED=0 runs the command without a CA (groot-tools)" {
  [ ! -e /certs/local-ca.pem ] || skip "this container has a real CA mounted"
  CA_REQUIRED=0 run "$ROOT/tests/e2e/docker-entrypoint.sh" echo ran
  [ "$status" -eq 0 ]
  [ "$output" = "ran" ]
}

fake_tools_tree() {
  local t="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$t/scripts/lib" "$t/infrastructure/docker/tools" "$t/tests/e2e"
  cp "$ROOT/scripts/tools.sh" "$t/scripts/"
  cp "$ROOT/scripts/lib/docker-run.sh" "$t/scripts/lib/"
  cp "$ROOT/infrastructure/docker/tools/Dockerfile" "$t/infrastructure/docker/tools/"
  cp "$ROOT/tests/e2e/docker-entrypoint.sh" "$t/tests/e2e/"
  printf '%s\n' "$t"
}

@test "tools.sh --tag is content-addressed: same files, same tag; an edit, a new tag" {
  t="$(fake_tools_tree)"
  run bash "$t/scripts/tools.sh" --tag
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^groot-tools:[0-9a-f]{12}$ ]]
  first="$output"
  run bash "$ROOT/scripts/tools.sh" --tag
  [ "$output" = "$first" ]
  echo '# bump' >>"$t/infrastructure/docker/tools/Dockerfile"
  run bash "$t/scripts/tools.sh" --tag
  [ "$status" -eq 0 ]
  [ "$output" != "$first" ]
}

@test "tools.sh with no command prints usage and exits 2" {
  run bash "$ROOT/scripts/tools.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"scripts/tools.sh <command>"* ]]
}
