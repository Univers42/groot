#!/usr/bin/env bats
# The committed contract.json is exactly what extract.mjs reads from graph_render at groot's
# apps/graph_render gitlink, and the check bites on the changes it exists to catch.
#
# Needs node, jq, git, and GR_SRC: a graph_render git clone that has the gitlink commit (the
# submodule is `update = none`, so CI fetches that one commit; locally any clone will do):
#   GR_SRC=~/recon/graph_render bats tests/graph-studio-contract

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  HERE=$BATS_TEST_DIRNAME
  : "${GR_SRC:?set GR_SRC to a graph_render clone that has the apps/graph_render gitlink}"
  PIN=$(git -C "$REPO" ls-tree HEAD apps/graph_render | awk '$2 == "commit" { print $3 }')
  [ "${#PIN}" -eq 40 ]
  git -C "$GR_SRC" cat-file -e "$PIN^{commit}"
  TREE=$BATS_FILE_TMPDIR/tree
  mkdir -p "$TREE"
  git -C "$GR_SRC" archive "$PIN" -- packages/graph-studio/src crates/graph-sdk-js/src crates/graph-wasm/src/lib.rs |
    tar -x -C "$TREE"
  export REPO HERE PIN TREE
}

# A private copy of the pinned tree for one control to break.
copy() {
  cp -r "$TREE" "$BATS_TEST_TMPDIR/t"
  echo "$BATS_TEST_TMPDIR/t"
}

# The one file under $1 whose code holds the fixed string $2 (the control fails if it moved away).
holding() {
  local hits
  hits=$(grep -rlF --include='*.ts' -- "$2" "$1/packages/graph-studio/src")
  [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] || { echo "control anchor '$2' is in: $hits" >&2; return 1; }
  echo "$hits"
}

check_tree() {
  run "$HERE/check.sh" --tree "$1" --rev "$PIN"
}

@test "contract.json is what the apps/graph_render gitlink says" {
  run "$HERE/check.sh" --git "$GR_SRC" --rev "$PIN"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "contract.json was generated at the gitlink" {
  [ "$(jq -r .source_rev "$HERE/contract.json")" = "$PIN" ]
}

@test "baseline: the archived tree gives the committed contract (the controls start from no diff)" {
  check_tree "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "control: a HOST_API bump is a value change" {
  t=$(copy)
  f=$(holding "$t" "export const HOST_API = 2;")
  sed -i 's/^export const HOST_API = 2;/export const HOST_API = 3;/' "$f"
  check_tree "$t"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VALUES CHANGED"* ]]
  grep -qE '^\+ +"host_api": 3' <<<"$output"
}

@test "control: a changed ingest default (child_first) is a value change" {
  t=$(copy)
  f=$(holding "$t" "child_first: optionalBoolean(value.child_first, false)")
  sed -i 's/child_first: optionalBoolean(value.child_first, false)/child_first: optionalBoolean(value.child_first, true)/' "$f"
  check_tree "$t"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VALUES CHANGED"* ]]
  grep -qE '^\+ +"child_first": true' <<<"$output"
}

@test "control: a renamed event is a value change" {
  t=$(copy)
  f=$(holding "$t" 'readonly "node-open": ')
  sed -i 's/readonly "node-open": /readonly "node-activate": /' "$f"
  check_tree "$t"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VALUES CHANGED"* ]]
  grep -qE '^\+ +"node-activate"' <<<"$output"
}

@test "control: a dropped dangling-edge refusal fails the extractor, not silently" {
  t=$(copy)
  f=$(holding "$t" "which is not a node")
  sed -i '/which is not a node/d' "$f"
  check_tree "$t"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"EXTRACTOR FAILED"* ]]
}

@test "control: a missing anchor fails the extractor, not silently" {
  t=$(copy)
  f=$(holding "$t" "export const HOST_API = 2;")
  sed -i '/^export const HOST_API = 2;/d' "$f"
  check_tree "$t"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOST_API"* ]]
}

@test "control: code that only moved is reported as citations, and still fails until regenerated" {
  t=$(copy)
  f=$(holding "$t" "export const HOST_API = 2;")
  sed -i '1i // a line that moves every citation below it' "$f"
  check_tree "$t"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CITATIONS ONLY"* ]]
}
