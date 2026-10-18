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
  make -s -C "$REPO" -n "$@" GIT_COMMIT_MESSAGE=bats
}

run_recipe() {
  local body
  body=$(recipe "$@")
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

# Upstream $1 with main at <name>_main and develop one commit ahead at <name>_dev, which main
# does not contain: the shape of osionos-ui, whose develop commit osionos pins.
side_upstream() {
  git init -q "$T/src/$1"
  echo 1 >"$T/src/$1/f"
  git -C "$T/src/$1" add f
  git -C "$T/src/$1" commit -qm one
  eval "${1}_main=\$(git -C \"\$T/src/\$1\" rev-parse HEAD)"
  git -C "$T/src/$1" checkout -qb develop
  echo 2 >"$T/src/$1/f"
  git -C "$T/src/$1" commit -qam two
  eval "${1}_dev=\$(git -C \"\$T/src/\$1\" rev-parse HEAD)"
  git -C "$T/src/$1" checkout -q main
  git clone -q --bare "$T/src/$1" "$T/$1.git"
}

# Superproject whose apps/app follows main and pins its nested lib at lib_dev, the way osionos
# pins packages/osionos-ui; apps/app main moves one commit past the gitlink.
side_pin_fixture() {
  side_upstream lib
  git init -q "$T/src/app"
  git -C "$T/src/app" submodule add -q "file://$T/lib.git" lib
  git -C "$T/src/app/lib" checkout -q "$lib_dev"
  git -C "$T/src/app" add lib
  git -C "$T/src/app" commit -qm one
  app_1=$(git -C "$T/src/app" rev-parse HEAD)
  echo 2 >"$T/src/app/f"
  git -C "$T/src/app" add f
  git -C "$T/src/app" commit -qm two
  app_2=$(git -C "$T/src/app" rev-parse HEAD)
  git clone -q --bare "$T/src/app" "$T/app.git"
  git init -q "$T/super"
  git -C "$T/super" submodule add -q "file://$T/app.git" apps/app
  git -C "$T/super/apps/app" checkout -q "$app_1"
  git -C "$T/super" add -A
  git -C "$T/super" commit -qm super
  git clone -q "$T/super" "$T/work"
  W="$T/work"
  git -C "$W" submodule update -q --init --recursive
}

@test "syncro keeps a nested submodule at a gitlink its branch tip does not contain" {
  side_pin_fixture
  run_recipe syncro-submodule
  [ "$status" -eq 0 ]
  [ "$(head_of apps/app)" = "$app_2" ]
  [ "$(head_of apps/app/lib)" = "$lib_dev" ]
  [[ "$output" == *"apps/app/lib: origin/main does not contain the gitlink"* ]]
}

@test "syncro keeps a top-level submodule pinned ahead of its branch tip" {
  side_upstream lib
  git init -q "$T/super"
  git -C "$T/super" submodule add -q "file://$T/lib.git" apps/lib
  git -C "$T/super/apps/lib" checkout -q "$lib_dev"
  git -C "$T/super" add -A
  git -C "$T/super" commit -qm super
  git clone -q "$T/super" "$T/work"
  W="$T/work"
  git -C "$W" submodule update -q --init --recursive
  run_recipe syncro-submodule
  [ "$status" -eq 0 ]
  [ "$(head_of apps/lib)" = "$lib_dev" ]
}

# Superproject whose apps/<name> submodules track main, each pinned at <name>_1 (main~1).
# $1.. are submodule names; the caller commits and clones with clone_super.
plain_pin_fixture() {
  local n
  git init -q "$T/super"
  for n in "$@"; do
    upstream "$n"
    git clone -q --bare "$T/src/$n" "$T/$n.git"
    git -C "$T/super" submodule add -q "file://$T/$n.git" "apps/$n"
    git -C "$T/super/apps/$n" checkout -q "$(eval "echo \$${n}_1")"
  done
}

clone_super() {
  git -C "$T/super" add -A
  git -C "$T/super" commit -qm super
  git clone -q "$T/super" "$T/work"
  W="$T/work"
}

@test "syncro still fast-forwards a pin that is an ancestor of its branch tip" {
  plain_pin_fixture plain
  clone_super
  git -C "$W" submodule update -q --init --recursive
  [ "$(head_of apps/plain)" = "$plain_1" ]
  run_recipe syncro-submodule
  [ "$status" -eq 0 ]
  [ "$(head_of apps/plain)" = "$plain_2" ]
}

@test "syncro unshallows a depth-1 submodule before proving the pin is on the branch" {
  plain_pin_fixture plain
  clone_super
  git -C "$W" submodule update -q --init --recursive --depth 1
  [ "$(git -C "$W/apps/plain" rev-parse --is-shallow-repository)" = true ]
  [ "$(head_of apps/plain)" = "$plain_1" ]
  run_recipe syncro-submodule
  [ "$status" -eq 0 ]
  [ "$(head_of apps/plain)" = "$plain_2" ]
}

@test "syncro leaves a submodule whose branch does not exist and still syncs the next one" {
  plain_pin_fixture aaa bbb
  git -C "$T/super" config -f .gitmodules submodule.apps/aaa.branch nosuch
  clone_super
  git -C "$W" submodule update -q --init --recursive
  run_recipe syncro-submodule
  [ "$status" -eq 0 ]
  [ "$(head_of apps/aaa)" = "$aaa_1" ]
  [ "$(head_of apps/bbb)" = "$bbb_2" ]
  [[ "$output" == *"no origin/nosuch"* ]]
}

@test "repair-detached makes no commit and moves no ref on a clean develop-only pin" {
  side_upstream lib
  git init -q "$T/super"
  git -C "$T/super" submodule add -q "file://$T/lib.git" apps/lib
  git -C "$T/super/apps/lib" checkout -q "$lib_dev"
  clone_super
  git -C "$W" submodule update -q --init --recursive
  local before after
  before=$(git -C "$W/apps/lib" for-each-ref; git -C "$T/lib.git" for-each-ref)
  run_recipe repair-detached
  [ "$status" -eq 0 ]
  after=$(git -C "$W/apps/lib" for-each-ref; git -C "$T/lib.git" for-each-ref)
  [ "$before" = "$after" ]
  [ "$(head_of apps/lib)" = "$lib_dev" ]
  [[ "$output" == *"nothing to repair"* ]]
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

@test "pin-submodules prints the exact command when it cannot clone (offline)" {
  fixture none
  git -C "$W" config submodule.apps/pinned.url "file://$T/offline.git"
  cd "$W"
  run sh "$REPO/scripts/pin-submodules.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$W/apps/pinned/.git" ]
  [[ "$output" == *"git submodule update --init --checkout -- apps/pinned"* ]]
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

@test "pin-submodules --list skips an update=none entry with no path and keeps listing" {
  fixture none
  cd "$W"
  git config -f .gitmodules submodule.aaa-broken.update none
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

# Superproject whose apps/parent follows main and records its nested lib at lib_1 in both of its
# commits, while lib's main is at lib_2, which contains lib_1: the drawnosaurus / engine shape.
# apps/parent main moves one commit past the gitlink.
parent_pin_fixture() {
  upstream lib
  git clone -q --bare "$T/src/lib" "$T/lib.git"
  git init -q "$T/src/parent"
  git -C "$T/src/parent" submodule add -q "file://$T/lib.git" lib
  git -C "$T/src/parent/lib" checkout -q "$lib_1"
  git -C "$T/src/parent" add lib
  git -C "$T/src/parent" commit -qm one
  echo 2 >"$T/src/parent/f"
  git -C "$T/src/parent" add f
  git -C "$T/src/parent" commit -qm two
  parent_2=$(git -C "$T/src/parent" rev-parse HEAD)
  git clone -q --bare "$T/src/parent" "$T/parent.git"
  git init -q "$T/super"
  git -C "$T/super" submodule add -q "file://$T/parent.git" apps/parent
  git -C "$T/super/apps/parent" checkout -q "$parent_2~1"
  clone_super
  git -C "$W" submodule update -q --init --recursive
}

@test "syncro leaves a parent-pinned nested submodule at the commit its parent records" {
  parent_pin_fixture
  run_recipe syncro-submodule PARENT_PINNED=apps/parent/lib
  [ "$status" -eq 0 ]
  [ "$(head_of apps/parent)" = "$parent_2" ]
  [ "$(head_of apps/parent/lib)" = "$lib_1" ]
  [[ "$output" == *"left at their gitlink with everything under them: "*"apps/parent/lib"* ]]
}

@test "PARENT_PINNED holds every nested submodule a parent records: engine and grobase's scripts" {
  run make -C "$REPO" -pq __no_such_target__
  line=$(printf '%s\n' "$output" | grep -m1 '^PARENT_PINNED ')
  [[ " ${line#*= } " == *" apps/drawnosaurus/engine "* ]]
  [[ " ${line#*= } " == *" apps/grobase/vendor/scripts "* ]]
}

@test "negative control: with PARENT_PINNED empty syncro moves the nested submodule to its tip" {
  parent_pin_fixture
  run_recipe syncro-submodule PARENT_PINNED=
  [ "$status" -eq 0 ]
  [ "$(head_of apps/parent)" = "$parent_2" ]
  [ "$(head_of apps/parent/lib)" = "$lib_2" ]
}

# apps/parent on main (so only the nested lib is a candidate) and lib detached with an edit
# that repair-detached would commit.
parent_dirty_lib() {
  parent_pin_fixture
  git -C "$W/apps/parent" checkout -q -B main origin/main
  echo edited >>"$W/apps/parent/lib/f"
}

@test "repair-detached leaves a dirty parent-pinned nested submodule uncommitted" {
  parent_dirty_lib
  run_recipe repair-detached PARENT_PINNED=apps/parent/lib
  [ "$status" -eq 0 ]
  [ "$(head_of apps/parent/lib)" = "$lib_1" ]
  [ -n "$(git -C "$W/apps/parent/lib" status --porcelain)" ]
}

@test "negative control: with PARENT_PINNED empty repair-detached commits the nested edit" {
  parent_dirty_lib
  run_recipe repair-detached PARENT_PINNED=
  [ "$(head_of apps/parent/lib)" != "$lib_1" ]
}
