#!/usr/bin/env bats
# The osionos-bridge image copies only the scripts its Dockerfile names, so a module its entry
# point loads but the image lacks crash-loops the container on ERR_MODULE_NOT_FOUND (groot main,
# CI run 39089475219: bridge-realtime-socket.mjs, added by app 08418d7f). These tests walk the
# entry's import closure (scripts/lib/mjs-closure.sh) and check each module against the
# Dockerfile's COPY sources minus its .dockerignore. Every fixture test that expects a report
# has a twin that differs only in the module name, so a check that reports everything fails.
#
# Caveat: .dockerignore lines are matched with shell `case` patterns, where `*` also crosses `/`
#   and `!` re-includes are not honoured, so a module can be reported missing that Docker would
#   copy (noisy, never silent). The COPY globs themselves expand exactly as Docker's do.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'bats scripts/tests/bridge-image-closure.bats'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BRIDGE_DOCKERFILE="$REPO/infrastructure/docker/osionos/bridge.Dockerfile"
  . "$REPO/scripts/lib/mjs-closure.sh"
}

# The COPY sources whose destination is ./scripts/, continuation lines joined.
copy_sources() {
  awk '{ line = line $0 }
    /\\$/ { sub(/\\$/, " ", line); next }
    { n = split(line, f, /[[:space:]]+/)
      if (f[1] == "COPY" && f[n] ~ /^(\.\/)?scripts\/?$/)
        for (i = 2; i < n; i++) if (f[i] !~ /^--/) print f[i]
      line = "" }' "$1"
}

# The script the image runs: the scripts/*.mjs named on its CMD line.
entry_point() {
  grep -E '^CMD' "$1" | grep -oE 'scripts/[^" ]+\.mjs' | sed 's#^scripts/##'
}

# BuildKit reads DOCKERFILE.dockerignore first and falls back to the context's .dockerignore.
ignore_patterns() {
  local file="$2.dockerignore"
  [ -f "$file" ] || file="$1/.dockerignore"
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's#^/##'
}

# Exit 0 when PATH, or a directory above it, matches an ignore pattern on stdin.
is_ignored() {
  local prefix pattern
  while IFS= read -r pattern; do
    prefix=$1
    while :; do
      # shellcheck disable=SC2254 # the pattern is meant to glob
      case $prefix in $pattern) return 0 ;; esac
      case $prefix in */*) prefix=${prefix%/*} ;; *) break ;; esac
    done
  done
  return 1
}

# The module names APP's image would hold under scripts/, one per line.
image_scripts() {
  local app="$1" dockerfile="$2" source path patterns
  patterns=$(ignore_patterns "$app" "$dockerfile")
  while IFS= read -r source; do
    for path in "$app"/$source; do
      [ -f "$path" ] || continue
      path=${path#"$app"/}
      is_ignored "$path" <<<"$patterns" || printf '%s\n' "${path#scripts/}"
    done
  done < <(copy_sources "$dockerfile")
}

# The modules the entry point reaches that the image would not hold; empty when it boots.
missing_from_image() {
  local app="$1" dockerfile="$2"
  LC_ALL=C comm -23 <(mjs_closure "$app/scripts" "$(entry_point "$dockerfile")") \
    <(image_scripts "$app" "$dockerfile" | LC_ALL=C sort -u)
}

# A fixture build context: scripts/NAME=CONTENT pairs, plus a Dockerfile whose COPY line lists $COPY.
fixture() {
  APP_DIR=$BATS_TEST_TMPDIR/app
  mkdir -p "$APP_DIR/scripts"
  local pair
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$APP_DIR/scripts/${pair%%=*}"
  done
  FIXTURE_DOCKERFILE=$BATS_TEST_TMPDIR/bridge.Dockerfile
  printf 'FROM scratch\nCOPY %s ./scripts/\nCMD ["node", "scripts/bridge-api.mjs"]\n' "$COPY" >"$FIXTURE_DOCKERFILE"
  cp "$BRIDGE_DOCKERFILE.dockerignore" "$FIXTURE_DOCKERFILE.dockerignore"
}

@test "closure: static, re-export and dynamic imports are followed, a cycle ends" {
  fixture "bridge-api.mjs=import { a } from './a.mjs'; export * from \"./b.mjs\"; await import( './c.mjs' );" \
    "a.mjs=import './bridge-api.mjs'; import x from 'node:fs'; import y from '../outside.mjs';" \
    "b.mjs=" "c.mjs=" "unreached.mjs="
  run mjs_closure "$APP_DIR/scripts" bridge-api.mjs
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' a.mjs b.mjs bridge-api.mjs c.mjs)" ]
}

@test "closure: a reached module absent from the directory is still printed" {
  fixture "bridge-api.mjs=import './gone.mjs';"
  run mjs_closure "$APP_DIR/scripts" bridge-api.mjs
  [ "$output" = "$(printf '%s\n' bridge-api.mjs gone.mjs)" ]
}

@test "the real bridge.Dockerfile copies every module bridge-api.mjs loads" {
  APP=$REPO/apps/osionos/app
  [ -f "$APP/scripts/bridge-api.mjs" ] || skip "apps/osionos/app is not checked out"
  [ "$(entry_point "$BRIDGE_DOCKERFILE")" = bridge-api.mjs ]
  run missing_from_image "$APP" "$BRIDGE_DOCKERFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "the bridge image would lack: $output" >&2
    false
  }
}

@test "the real globs keep the unit tests beside the modules out of the image" {
  COPY="$(copy_sources "$BRIDGE_DOCKERFILE" | tr '\n' ' ')" fixture "bridge-api.mjs=" "bridge-rtc.test.mjs=" "ide-ws.mjs="
  run image_scripts "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$output" = "$(printf '%s\n' bridge-api.mjs ide-ws.mjs)" ]
}

@test "negative control: a module outside the COPY globs is named" {
  COPY="scripts/bridge-*.mjs" fixture "bridge-api.mjs=import './helper.mjs';" "helper.mjs="
  run missing_from_image "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$output" = helper.mjs ]
}

@test "twin: the same import under the COPY globs is not named" {
  COPY="scripts/bridge-*.mjs" fixture "bridge-api.mjs=import './bridge-helper.mjs';" "bridge-helper.mjs="
  run missing_from_image "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "negative control: a module the .dockerignore drops is named" {
  COPY="scripts/bridge-*.mjs" fixture "bridge-api.mjs=import './bridge-x.test.mjs';" "bridge-x.test.mjs="
  run missing_from_image "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$output" = bridge-x.test.mjs ]
}

@test "negative control: the old hand-kept list, split over continuation lines, misses the new module" {
  COPY="scripts/bridge-api.mjs \\
	scripts/bridge-social-core.mjs" fixture \
    "bridge-api.mjs=import './bridge-social-core.mjs';" \
    "bridge-social-core.mjs=import { open } from './bridge-realtime-socket.mjs';" \
    "bridge-realtime-socket.mjs="
  run missing_from_image "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$output" = bridge-realtime-socket.mjs ]
}

@test "twin: the hand-kept list that names it is complete" {
  COPY="scripts/bridge-api.mjs \\
	scripts/bridge-social-core.mjs scripts/bridge-realtime-socket.mjs" fixture \
    "bridge-api.mjs=import './bridge-social-core.mjs';" \
    "bridge-social-core.mjs=import { open } from './bridge-realtime-socket.mjs';" \
    "bridge-realtime-socket.mjs="
  run missing_from_image "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
