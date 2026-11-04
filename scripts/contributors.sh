#!/bin/sh
# contributors.sh — commits per member in groot and in each project submodule, read through
# groot's .mailmap. The submodules keep no mailmap of their own, so a bare `git shortlog` in
# one of them shows a member once per address they ever committed with.
#
# Usage, from groot's working tree (inside a submodule, --show-toplevel is the submodule):
#   contributors.sh                            every repository below, all refs
#   contributors.sh <repo>...                  only those repositories (paths from groot's top)
#   contributors.sh --paths <repo> <path>...   one line per member: commits touching <path>s
#                                              in <repo>, merges excluded
#
# Caveat: a commit count is not effort. One large commit and one typo fix weigh the same, and
# pairing, reviews and work committed by someone else do not show at all. --paths credits a
# commit to every path it touches, so a sweeping refactor counts for each feature it crossed.
#
# Does NOT: fetch (counts are of the refs this clone holds); count a submodule that is not
# checked out (it prints "not checked out" instead).
set -eu

top=$(git rev-parse --show-toplevel)
mailmap="$top/.mailmap"
[ -f "$mailmap" ] || { echo "contributors.sh: $mailmap is missing" >&2; exit 1; }

if [ "${1:-}" = --paths ]; then
  [ "$#" -ge 3 ] || { echo "usage: contributors.sh --paths <repo> <path>..." >&2; exit 2; }
  repo=$2
  shift 2
  git -C "$top/$repo" -c mailmap.file="$mailmap" log --all --no-merges --format='%aN' -- "$@" |
    sort | uniq -c | sort -rn
  exit 0
fi

[ "$#" -gt 0 ] || set -- . apps/osionos/app apps/grobase apps/opposite-osiris \
  apps/mail apps/calendar vendor/QA vendor/monkey-bot

for path in "$@"; do
  echo "== $path"
  if ! git -C "$top/$path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "   not checked out"
    continue
  fi
  git -C "$top/$path" -c mailmap.file="$mailmap" shortlog -sne --all </dev/null
done
