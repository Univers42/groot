#!/usr/bin/env bats
# A submodule .gitmodules marks `update = none` (apps/graph_render) is a build input: the
# gitlink groot records decides what gets built, never a branch tip. These tests pin the three
# halves of that: syncro-submodule and repair-detached leave it and everything under it alone,
# pin-submodules.sh checks it out at the gitlink and fails when it is anywhere else, and
# frontends-up cannot run without that check. Every negative control shows the same fixture
# moving or failing once the protection is removed.
#
# Fixtures are local bare repos under $BATS_TEST_TMPDIR; no network, no git against the repo
# itself. The syncro / repair-detached recipes are the real ones, expanded by `make -n`.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils git && bats scripts/tests'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  export GIT_CONFIG_KEY_1=init.defaultBranch GIT_CONFIG_VALUE_1=main
  export GIT_AUTHOR_NAME=bats GIT_AUTHOR_EMAIL=bats@example.invalid
  export GIT_COMMITTER_NAME=bats GIT_COMMITTER_EMAIL=bats@example.invalid
  mkdir -p "$HOME"
}

# Upstream $1 with two commits on main; prints nothing, records <name>_1 / <name>_2 SHAs.
upstream() {
  git init -q "$T/src/$1"
  echo 1 >"$T/src/$1/f"
  git -C "$T/src/$1" add f
  git -C "$T/src/$1" commit -qm one
  eval "${1}_1=\$(git -C \"\$T/src/\$1\" rev-parse HEAD)"
  echo 2 >"$T/src/$1/f"
  git -C "$T/src/$1" commit -qam two
  eval "${1}_2=\$(git -C \"\$T/src/\$1\" rev-parse HEAD)"
}

# The pinned upstream carries its own nested submodule (graph_render's SciGraphs), pinned at
# nested_1 in both of its commits.
pinned_upstream() {
  upstream nested
  git clone -q --bare "$T/src/nested" "$T/nested.git"
  git init -q "$T/src/pinned"
  git -C "$T/src/pinned" submodule add -q "file://$T/nested.git" nested
  git -C "$T/src/pinned/nested" checkout -q "$nested_1"
  git -C "$T/src/pinned" add nested
  git -C "$T/src/pinned" commit -qm one
  pinned_1=$(git -C "$T/src/pinned" rev-parse HEAD)
  echo 2 >"$T/src/pinned/f"
  git -C "$T/src/pinned" add f
  git -C "$T/src/pinned" commit -qm two
  pinned_2=$(git -C "$T/src/pinned" rev-parse HEAD)
  git clone -q --bare "$T/src/pinned" "$T/pinned.git"
}

# Superproject with apps/plain (follows its branch) and apps/pinned at pinned_1; $1 is the
# `update` value for apps/pinned ("" = none set). Clones it to $W as a user would.
fixture() {
  upstream plain
  git clone -q --bare "$T/src/plain" "$T/plain.git"
  pinned_upstream
  git init -q "$T/super"
  git -C "$T/super" submodule add -q "file://$T/plain.git" apps/plain
  git -C "$T/super/apps/plain" checkout -q "$plain_1"
  git -C "$T/super" submodule add -q "file://$T/pinned.git" apps/pinned
  git -C "$T/super/apps/pinned" checkout -q "$pinned_1"
  [ -z "$1" ] || git -C "$T/super" config -f .gitmodules submodule.apps/pinned.update "$1"
  git -C "$T/super" add -A
  git -C "$T/super" commit -qm super
  git clone -q "$T/super" "$T/work"
  W="$T/work"
  git -C "$W" submodule update -q --init --recursive
}

# Populate apps/pinned and its nested submodule at their gitlinks, the way `make pulls` does.
populate_pinned() {
  git -C "$W" submodule update -q --init --checkout --recursive -- apps/pinned
}

recipe() {
  make -s -C "$REPO" -n "$1" GIT_COMMIT_MESSAGE=bats
}

run_recipe() {
  local body
  body=$(recipe "$1")
  run bash -c "cd \"$W\" && bash -eu -o pipefail -c \"\$0\"" "$body"
}

# Every ref, local and upstream, that repair-detached could commit to or push.
refs() {
  local r
  for r in "$W/apps/pinned" "$W/apps/pinned/nested" "$T/pinned.git" "$T/nested.git"; do
    git -C "$r" for-each-ref --format='%(refname) %(objectname)'
  done
}

head_of() {
  git -C "$W/$1" rev-parse HEAD
}

@test "syncro leaves an update=none submodule and its nested one at their gitlinks" {
  fixture none
  populate_pinned
  run_recipe syncro-submodule
  [ "$status" -eq 0 ]
  [ "$(head_of apps/pinned)" = "$pinned_1" ]
  [ "$(head_of apps/pinned/nested)" = "$nested_1" ]
  [ "$(head_of apps/plain)" = "$plain_2" ]
  [[ "$output" != *"STILL DETACHED"* ]]
}

@test "negative control: without update=none syncro moves it and its nested one to the tips" {
  fixture ""
  populate_pinned
  run_recipe syncro-submodule
  [ "$status" -eq 0 ]
  [ "$(head_of apps/pinned)" = "$pinned_2" ]
  [ "$(head_of apps/pinned/nested)" = "$nested_2" ]
}

@test "repair-detached neither commits nor pushes under an update=none submodule" {
  fixture none
  populate_pinned
  git -C "$W/apps/plain" checkout -q -B main origin/main
  before=$(refs)
  run_recipe repair-detached
  [ "$status" -eq 0 ]
  [ "$(head_of apps/pinned)" = "$pinned_1" ]
  [ "$(head_of apps/pinned/nested)" = "$nested_1" ]
  [ "$(refs)" = "$before" ]
}

@test "a clean recursive init skips an update=none submodule and never reaches its nested one" {
  fixture none
  [ ! -e "$W/apps/pinned/.git" ]
  [ ! -e "$W/apps/pinned/nested/.git" ]
  [ -e "$W/apps/plain/.git" ]
}

@test "pin-submodules checks out an absent pinned submodule at its gitlink, non-recursively" {
  fixture none
  cd "$W"
  run sh "$REPO/scripts/pin-submodules.sh"
  [ "$status" -eq 0 ]
  [ "$(head_of apps/pinned)" = "$pinned_1" ]
  [ ! -e "$W/apps/pinned/nested/.git" ]
}

@test "pin-submodules passes when the checkout is the gitlink" {
  fixture none
  populate_pinned
  cd "$W"
  run sh "$REPO/scripts/pin-submodules.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps/pinned at $pinned_1"* ]]
}

@test "negative control: pin-submodules fails when the checkout moved off the gitlink" {
  fixture none
  populate_pinned
  git -C "$W/apps/pinned" checkout -q "$pinned_2"
  cd "$W"
  run sh "$REPO/scripts/pin-submodules.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$pinned_2"* ]]
  [[ "$output" == *"$pinned_1"* ]]
  [ "$(head_of apps/pinned)" = "$pinned_2" ]
}

@test "pin-submodules fails on a tracked edit inside the pinned submodule" {
  fixture none
  populate_pinned
  echo edited >>"$W/apps/pinned/.gitmodules"
  cd "$W"
  run sh "$REPO/scripts/pin-submodules.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"apps/pinned"* ]]
}

@test "pin-submodules ignores drift in the pinned submodule's nested submodules" {
  fixture none
  populate_pinned
  git -C "$W/apps/pinned/nested" checkout -q "$nested_2"
  cd "$W"
  run sh "$REPO/scripts/pin-submodules.sh"
  [ "$status" -eq 0 ]
}

@test "pin-submodules --list prints only the update=none paths" {
  fixture none
  cd "$W"
  run sh "$REPO/scripts/pin-submodules.sh" --list
  [ "$status" -eq 0 ]
  [ "$output" = "apps/pinned" ]
}

@test "groot pins apps/graph_render over HTTPS with update=none and no branch" {
  m="$REPO/.gitmodules"
  cd "$T"
  [ "$(git config -f "$m" submodule.apps/graph_render.url)" = "https://github.com/Univers42/graph_render.git" ]
  [ "$(git config -f "$m" submodule.apps/graph_render.update)" = none ]
  run git config -f "$m" submodule.apps/graph_render.branch
  [ "$status" -ne 0 ]
}

@test "frontends-up cannot run without submodules-pinned" {
  run make -C "$REPO" -pq __no_such_target__
  block=$(printf '%s\n' "$output" | awk '/^frontends-up:/ {on = 1} on && /^$/ {exit} on')
  [[ "$block" == "frontends-up: "*submodules-pinned* ]]
}
