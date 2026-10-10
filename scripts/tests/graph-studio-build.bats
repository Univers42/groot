#!/usr/bin/env bats
# app.Dockerfile refuses to build osionos-app unless GRAPH_RENDER_SHA names the commit the
# graph_render pack was built from (tests/graph-studio/serve.bats proves that on a real build).
# These tests pin the make side: every recipe that builds osionos-app passes the gitlink, and runs
# only after submodules-pinned. No docker; the recipes are read from make's database (-p).
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils git && bats scripts/tests'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
}

# The rule block make prints for target $1: the prerequisite line, then the recipe.
rule() {
  make -C "$REPO" -pq __no_such_target__ 2>/dev/null |
    awk -v t="$1:" '$1 == t {on = 1} on && /^$/ {exit} on'
}

@test "every recipe that builds osionos-app passes GRAPH_RENDER_SHA and needs submodules-pinned" {
  for target in frontends-up update_web osionos-app-live; do
    block=$(rule "$target")
    [[ "$block" == "$target: "*submodules-pinned* ]] || { echo "$target: no submodules-pinned"; false; }
    after=${block#*"\$(WITH_GRAPH_RENDER_SHA)"}
    [ "$after" != "$block" ] || { echo "$target: no GRAPH_RENDER_SHA"; false; }
    [[ "$after" == *compose* ]] || { echo "$target: GRAPH_RENDER_SHA is set after the compose call"; false; }
  done
}

@test "WITH_GRAPH_RENDER_SHA exports the apps/graph_render gitlink" {
  want=$(git -C "$REPO" ls-tree HEAD apps/graph_render | awk '$2 == "commit" { print $3 }')
  [ "${#want}" -eq 40 ]
  run make -s -C "$REPO" --eval "print-graph-render-sha: ; @\$(WITH_GRAPH_RENDER_SHA) printf %s \"\$\$GRAPH_RENDER_SHA\"" print-graph-render-sha
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "compose passes GRAPH_RENDER_SHA to the osionos-app build" {
  run awk '/^  osionos-app:/ {on = 1} on && /^  [a-z]/ && !/osionos-app/ {exit} on' "$REPO/docker-compose.yml"
  [[ "$output" == *"GRAPH_RENDER_SHA: \${GRAPH_RENDER_SHA:-}"* ]]
}
