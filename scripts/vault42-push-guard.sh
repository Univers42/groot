#!/usr/bin/env bash
# vault42-push-guard.sh — refuse a vault42 push from a checkout that would publish a damaged tree.
# `42ctl env push` publishes what is on disk and nothing else: a dump missing here leaves the newest
# tree without it, which is how 10 prod dumps fell out of reach. Its scanner reads no .gitignore,
# skips symlinks, and takes every *.env* and every file under any secrets/ directory, so a pulled
# copy parked under ./secrets or ./.vault42 goes up too, and prod's tree was found shifted under
# secrets/ on 2026-10-15. Read-only: it moves nothing and prints the one command that would.
# Run by vault42-team.sh push and make vault42-push-all before any prompt.
# Exit: 0 safe to push; 1 refused, each reason and its remedy printed.
#
# Caveat: mirrors 42ctl 0.1.16's scanner (src/core/project.rs) by hand. It misses a pulled copy
# parked anywhere but ./secrets and ./.vault42, and one under ./secrets whose top-level name the
# checkout root lacks; it refuses a .vault42 holding only files the scanner would skip. A dump that
# ./secrets/SHA256SUMS itself omits (and that is not an ENGINE_SEEDS dump) can still drop out. It
# guards these two entry points only: apps/grobase/scripts/vault/ctl-env.sh run directly,
# scripts/vault42-ctl.sh env push and a native `42ctl env push` bypass it — and the push that
# shifted prod's tree did not go through these wrappers at all.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SEEDS="$REPO/secrets"
ASIDE="$(dirname "$REPO")/$(basename "$REPO")-vault42-aside-$(date +%Y%m%d-%H%M%S)"
problems=0
aside=()

# shellcheck source=scripts/lib/envfile.sh
. "$HERE/lib/envfile.sh"
# shellcheck source=scripts/lib/seed-check.sh
. "$HERE/lib/seed-check.sh"

refuse() {
  printf '[push-guard] ✗ %s\n' "$1" >&2
  problems=$((problems + 1))
}

# Every name SHA256SUMS lists and every ENGINE_SEEDS dump: listed, a regular file (42ctl skips a
# symlink) and matching.
check_seeds() {
  local name problem list
  local -a names required
  if [ -L "$SEEDS" ] || [ -L "$SEEDS/SHA256SUMS" ] || [ ! -f "$SEEDS/SHA256SUMS" ]; then
    refuse "./secrets/SHA256SUMS is absent or a symlink (42ctl skips symlinks): the tree would carry no provable dump — make vault42-pull-everything, or make vault42-seed from running engines"
    return 0
  fi
  if ! list="$(engine_seeds "$REPO")"; then
    refuse "scripts/restore-if-empty.sh names no ENGINE_SEEDS: which dumps the tree must carry is unknown"
    return 0
  fi
  read -ra required <<<"$list"
  mapfile -t names < <(seed_names "$SEEDS/SHA256SUMS")
  if [ "${#names[@]}" -eq 0 ]; then
    refuse "./secrets/SHA256SUMS lists nothing: no dump is proven — make vault42-seed"
    return 0
  fi
  mapfile -t names < <(printf '%s\n' "${names[@]}" "${required[@]}" | awk 'NF && !seen[$0]++')
  for name in "${names[@]}"; do
    [ ! -L "$SEEDS/$name" ] || refuse "secrets/$name is a symlink, which 42ctl skips: the tree would lose it"
  done
  while IFS= read -r problem; do
    refuse "secrets/$problem: the tree would lose it — make vault42-recover-dumps (a dump sealed to another pusher: make vault42-seed)"
  done < <(seeds_unverified "$SEEDS" "$SEEDS/SHA256SUMS" "${names[@]}")
}

# An entry of ./secrets that the checkout root also has (secrets/apps, secrets/secrets,
# secrets/.env) is a pulled tree mirrored under secrets/, not a seed.
check_mirror() {
  local entry name
  local -a mirror=()
  for entry in "$SEEDS"/* "$SEEDS"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    [ ! -e "$REPO/$name" ] || mirror+=("secrets/$name")
  done
  [ "${#mirror[@]}" -gt 0 ] || return 0
  refuse "${mirror[*]}: a pulled tree mirrored under ./secrets would be published there"
  aside+=("${mirror[@]}")
}

check_sandbox() {
  local count
  [ -d "$REPO/.vault42" ] || return 0
  count="$(find "$REPO/.vault42" -type f | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || return 0
  refuse ".vault42 holds $count file(s) (pull-everything's sandbox); 42ctl reads no .gitignore and would publish them"
  aside+=(.vault42)
}

# One command for every move, into a fresh owner-only directory beside the checkout: mkdir
# without -p refuses one that already exists. Nothing is deleted.
print_move_aside() {
  [ "${#aside[@]}" -gt 0 ] || return 0
  printf '[push-guard]   move them aside: cd %q && (umask 077 && mkdir -m 700 %q) && mv %s %q/\n' \
    "$REPO" "$ASIDE" "${aside[*]}" "$ASIDE" >&2
}

main() {
  if [ -d "$SEEDS" ] && [ ! -L "$SEEDS" ]; then check_mirror; fi
  check_seeds
  check_sandbox
  if [ "$problems" -gt 0 ]; then
    print_move_aside
    printf '[push-guard] ✗ %s problem(s): nothing was pushed\n' "$problems" >&2
    exit 1
  fi
  printf '[push-guard] ✓ every dump matches ./secrets/SHA256SUMS; no pulled copy under ./secrets or ./.vault42\n' >&2
}

main "$@"
