#!/bin/sh
# pin-submodules.sh — keep every submodule that .gitmodules marks `update = none` at the
# commit groot's HEAD records. Today that is apps/graph_render, whose pack is a build input:
# the gitlink, not a branch tip, decides what gets built.
#
# `update = none` keeps git's own `submodule update --recursive` out of it (and so out of
# graph_render's SSH-only nested submodules, which the pack never reads). syncro-submodule
# and repair-detached (repo.mk) skip it and everything under it, using --list. Nothing then
# moves it TO the pin either, so this script does that once: an absent one is checked out at
# the gitlink, non-recursively. A checked-out one is never moved, only checked.
#
# Usage, from groot's top level:
#   pin-submodules.sh          check out absent pinned submodules, then exit 1 if any HEAD
#                              differs from its gitlink or has edits to tracked files
#   pin-submodules.sh --list   print the pinned paths, one per line
#
# Does NOT: move a checked-out submodule (after a pointer bump it prints the fix instead);
# check nested submodules or untracked files (the pack reads neither); see a local
# .git/config `update` override (it reads .gitmodules); guard a raw `docker compose build`,
# which never goes through make.
set -eu

TAG='[submodules-pinned]'

pinned_paths() {
  git config -f .gitmodules --get-regexp '^submodule\..*\.update$' 2>/dev/null |
    while read -r key value; do
      [ "$value" = none ] || continue
      name=${key#submodule.}
      git config -f .gitmodules --get "submodule.${name%.update}.path" || continue
    done
}

gitlink() {
  git ls-tree HEAD -- "$1" | awk '$2 == "commit" { print $3 }'
}

check_out_if_absent() {
  [ ! -e "$1/.git" ] || return 0
  git submodule update --init --checkout -- "$1" || {
    echo "$TAG cannot check out $1 at $2 — see git's error above (network? URL?)" >&2
    printf '  fix: once online, run make submodules-pinned (or: git submodule update --init --checkout -- %s)\n' "$1" >&2
    return 1
  }
}

assert_at_pin() {
  actual=$(git -C "$1" rev-parse HEAD)
  if [ "$actual" != "$2" ]; then
    printf '%s %s is at %s but groot pins %s — refusing to build from it.\n' "$TAG" "$1" "$actual" "$2" >&2
    printf '  fix: git submodule update --checkout -- %s\n' "$1" >&2
    return 1
  fi
  if ! git -C "$1" diff --quiet --ignore-submodules HEAD; then
    printf '%s %s has uncommitted edits to tracked files — the build would not be the pin.\n' "$TAG" "$1" >&2
    printf '  fix: commit or stash them (git -C %s status)\n' "$1" >&2
    return 1
  fi
  echo "$TAG $1 at $2 — ok"
}

main() {
  if [ "${1:-}" = --list ]; then
    pinned_paths
    return 0
  fi
  failed=0
  for path in $(pinned_paths); do
    pin=$(gitlink "$path")
    if [ -z "$pin" ]; then
      echo "$TAG $path: no gitlink in HEAD — skipped"
      continue
    fi
    check_out_if_absent "$path" "$pin" || { failed=1; continue; }
    assert_at_pin "$path" "$pin" || failed=1
  done
  return "$failed"
}

main "$@"
