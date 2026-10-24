#!/usr/bin/env bats
# The osionos-bridge image copies only the scripts its Dockerfile names, so a module its entry
# point loads but the image lacks crash-loops the container on ERR_MODULE_NOT_FOUND (groot main,
# CI run 39089475219: bridge-realtime-socket.mjs, added by app 08418d7f). These tests walk the
# entry's import closure (scripts/lib/mjs-closure.sh) and check each module against the
# Dockerfile's COPY sources minus its .dockerignore. Every fixture test that expects a report
# has a twin that differs only in the module name, so a check that reports everything fails.
#
# Caveat: .dockerignore lines are matched with shell `case` patterns, where `*` also crosses `/`,
#   so a module can be reported missing that Docker would copy (noisy, never silent). `!`
#   re-includes are honoured, the last matching line deciding, as Docker's do. The COPY globs
#   themselves expand exactly as Docker's do.
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

# Exit 0 when PATH, or a directory above it, is ignored by the patterns on stdin: the last
# pattern that matches decides, and a `!pattern` re-includes (ai.Dockerfile.dockerignore ignores
# scripts/* and re-includes its closure one module at a time).
is_ignored() {
  local prefix pattern verdict=1 reinclude
  while IFS= read -r pattern; do
    reinclude=0
    case $pattern in '!'*) reinclude=1 pattern=${pattern#!} ;; esac
    prefix=$1
    while :; do
      # shellcheck disable=SC2254 # the pattern is meant to glob
      case $prefix in $pattern) verdict=$reinclude && break ;; esac
      case $prefix in */*) prefix=${prefix%/*} ;; *) break ;; esac
    done
  done
  return "$verdict"
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

# The directories a reached module reads beside itself, `new URL('./DIR/…', import.meta.url)`.
# Caveat: only that literal shape is seen; a path built another way (path.join, a variable) is
# not, so a missing directory read that way still passes here and crashes the container.
data_dirs() {
  local app="$1" dockerfile="$2" module
  while IFS= read -r module; do
    [ -f "$app/scripts/$module" ] || continue
    grep -oE "new URL\([\`'\"]\./[A-Za-z0-9_-]+/" "$app/scripts/$module" | sed -E 's#.*\./##; s#/$##'
  done < <(mjs_closure "$app/scripts" "$(entry_point "$dockerfile")") | LC_ALL=C sort -u
}

# The data directories the entry point reads that no COPY line carries; empty when it boots.
# A one-character class (`lists[s]/`, the COPY that stays optional) reads as its literal.
missing_data_dirs() {
  local app="$1" dockerfile="$2" dir
  for dir in $(data_dirs "$app" "$dockerfile"); do
    sed -E 's/\[([^]])\]/\1/g' "$dockerfile" |
      grep -qE "^COPY[[:space:]].*scripts/$dir/?[[:space:]]" || printf '%s\n' "$dir"
  done
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

@test "the real bridge.Dockerfile copies every directory a loaded module reads beside itself" {
  APP=$REPO/apps/osionos/app
  [ -f "$APP/scripts/bridge-api.mjs" ] || skip "apps/osionos/app is not checked out"
  run missing_data_dirs "$APP" "$BRIDGE_DOCKERFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "the bridge image would lack the data directories: $output" >&2
    false
  }
}

@test "negative control: a word list read beside a module, not copied, is named" {
  COPY="scripts/bridge-*.mjs" fixture "bridge-api.mjs=import './bridge-mod.mjs';" \
    "bridge-mod.mjs=readFileSync(new URL(\`./word-lists/en.txt\`, import.meta.url));"
  run missing_data_dirs "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$output" = word-lists ]
}

@test "twin: the same word list with its own COPY line is not named" {
  COPY="scripts/bridge-*.mjs" fixture "bridge-api.mjs=import './bridge-mod.mjs';" \
    "bridge-mod.mjs=readFileSync(new URL(\`./word-lists/en.txt\`, import.meta.url));"
  printf 'COPY scripts/word-lists/ ./scripts/word-lists/\n' >>"$FIXTURE_DOCKERFILE"
  run missing_data_dirs "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "twin: the same word list behind an optional one-character-class COPY is not named" {
  COPY="scripts/bridge-*.mjs" fixture "bridge-api.mjs=import './bridge-mod.mjs';" \
    "bridge-mod.mjs=readFileSync(new URL(\`./word-lists/en.txt\`, import.meta.url));"
  printf 'COPY scripts/word-list[s]/ ./scripts/word-lists/\n' >>"$FIXTURE_DOCKERFILE"
  run missing_data_dirs "$APP_DIR" "$FIXTURE_DOCKERFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the real bridge.Dockerfile carries the moderation word lists whatever the pin" {
  grep -qE '^COPY[[:space:]]+scripts/moderation-list\[s\]/[[:space:]]' "$BRIDGE_DOCKERFILE"
}

# The osionos-ai image runs TypeScript (src/server.ts), so its CMD names no bridge module: its
# entries are the scripts/*.mjs the service's sources import, and the image must hold their
# closure. Release of the account platform (2026-10-23): P0-4 made bridge-session-token.mjs import
# bridge-session-revocations.mjs, ai.Dockerfile's hand-kept list lacked it, and the public
# osionos-ai crash-looped on ERR_MODULE_NOT_FOUND until it was rolled back.
ai_entries() {
  grep -rhoE "/scripts/[A-Za-z0-9_.-]+\.mjs" "$1/services/osionos-ai/src" | sed 's#^/scripts/##' | LC_ALL=C sort -u
}

@test "the real ai.Dockerfile copies every bridge module the AI service loads" {
  APP=$REPO/apps/osionos/app
  AI_DOCKERFILE="$REPO/infrastructure/docker/osionos/ai.Dockerfile"
  [ -d "$APP/services/osionos-ai/src" ] || skip "apps/osionos/app is not checked out"
  entries=$(ai_entries "$APP")
  [ -n "$entries" ]
  run comm -23 <(for entry in $entries; do mjs_closure "$APP/scripts" "$entry"; done | LC_ALL=C sort -u) \
    <(image_scripts "$APP" "$AI_DOCKERFILE" | LC_ALL=C sort -u)
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "missing from ai.Dockerfile: $output"; false; }
}

@test "a !pattern re-includes what an earlier line ignored" {
  run is_ignored scripts/kept.mjs <<<$'scripts/*\n!scripts/kept.mjs'
  [ "$status" -eq 1 ]
}

@test "twin: a module no !pattern names stays ignored" {
  run is_ignored scripts/dropped.mjs <<<$'scripts/*\n!scripts/kept.mjs'
  [ "$status" -eq 0 ]
}
