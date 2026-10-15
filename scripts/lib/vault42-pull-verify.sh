# shellcheck shell=bash disable=SC2034 # tree_damaged and tree_kept are the caller's to read
# vault42-pull-verify.sh — where vault42-pull-everything.sh stages a pull, and the checks it runs
# on what the pull delivered. Uses the caller's WORK (with <env>.files, the listing), MAIN_ENV,
# REPO, note, fail and die, and seed-check.sh + envfile.sh.
#
#   make_work                 WORK beside the checkout, pinned as its own repository root.
#   verify_listed ENV STAGE   every listed path arrived in the (empty at start) staging dir.
#   verify_dumps ENV STAGE    the dumps beside the tree's SHA256SUMS match it; keeps that SHA256SUMS.
#   verify_required           every ENGINE_SEEDS dump in ./secrets matches the delivered SHA256SUMS.

RECOVER="bring them back: make vault42-recover-dumps"
REPUBLISH="Republish a whole tree: bash scripts/vault42-push-guard.sh (it prints the move-aside for a pulled copy), then make vault42-team-push (CTL_USER=0:0 on rootless docker)"
# Set when this checkout ends whole but the tree it came from would fail a teammate's pull;
# tree_kept names the dumps only this checkout holds.
tree_damaged=0
tree_kept=""

# The check that cannot pass vacuously: the staging directory started empty.
verify_listed() {
  local env="$1" stage="$2" path
  while IFS= read -r path; do
    [ -e "$stage/$path" ] || fail "$env: listed but not delivered: $path"
  done <"$WORK/$env.files"
}

# The tree's SHA256SUMS: secrets/SHA256SUMS, else every shallowest one under secrets/ (more than
# one is a tie the caller refuses). A tree pushed from a checkout holding a pulled copy under
# ./secrets keeps it at secrets/secrets/ (prod, 2026-10-15).
tree_sums() {
  awk -F/ '/^secrets\/(.*\/)?SHA256SUMS$/ { if (!depth || NF < depth) { depth = NF; best = "" }
		if (NF == depth) best = best $0 "\n" } END { printf "%s", best }' "$WORK/$1.files"
}

# Dumps are checked beside the SHA256SUMS that lists them; a CORRUPT one is renamed so install
# never moves it. The delivered SHA256SUMS is kept for verify_required.
verify_dumps() {
  local env="$1" stage="$2" sums seeds problem
  sums="$(tree_sums "$env")"
  [ -n "$sums" ] || return 0
  if [ "$(wc -l <<<"$sums")" -gt 1 ]; then
    fail "$env: $(tr '\n' ' ' <<<"$sums")— one tree, two SHA256SUMS at one depth: which lists the dumps is unknown. $REPUBLISH"
    return 0
  fi
  seeds="${sums%/SHA256SUMS}"
  if [ "$seeds" != secrets ]; then
    tree_damaged=1
    note "! $env: the tree keeps its dumps in $seeds/, not secrets/ — it was pushed from a checkout holding a pulled copy under ./secrets. $REPUBLISH"
  fi
  [ ! -f "$stage/$sums" ] || cp "$stage/$sums" "$WORK/$env.sums"
  sed -n "s|^$seeds/||p" "$WORK/$env.files" >"$WORK/$env.seeds"
  note "$env: $seeds/ against $sums"
  while IFS= read -r problem; do
    fail "$env: $seeds/$problem"
  done < <(seed_problems "$stage/$seeds" "$WORK/$env.seeds")
}

# Where restore-if-empty.sh reads them: every ENGINE_SEEDS dump in ./secrets, proven against the
# SHA256SUMS this pull delivered (the anchor; never the checkout's own, which would vouch for
# itself), and listed alike by ./secrets/SHA256SUMS, which the restore checks. A dump the tree
# does not hold at secrets/ but whose bytes here match is a warning: the restore has it.
verify_required() {
  local sums="$WORK/$MAIN_ENV.sums" here="$REPO/secrets/SHA256SUMS" list name problem
  local -a required kept=()
  if ! list="$(engine_seeds "$REPO")"; then
    fail "$MAIN_ENV: scripts/restore-if-empty.sh names no ENGINE_SEEDS, so which dumps the restore needs is unknown"
    return 0
  fi
  read -ra required <<<"$list"
  if [ ! -f "$sums" ]; then
    [ -n "$(tree_sums "$MAIN_ENV")" ] ||
      fail "$MAIN_ENV: the tree carries no SHA256SUMS, so no dump can be proven whole — $RECOVER, then $REPUBLISH"
    return 0
  fi
  [ -f "$here" ] ||
    fail "$MAIN_ENV: ./secrets/SHA256SUMS, which the restore checks, is absent (the tree's is ./$(tree_sums "$MAIN_ENV")) — $REPUBLISH"
  for name in "${required[@]}"; do
    problem="$(seeds_unverified "$REPO/secrets" "$sums" "$name")"
    if [ -n "$problem" ]; then
      fail "$MAIN_ENV: secrets/$problem — $RECOVER"
    elif [ ! -f "$here" ]; then
      continue
    elif problem="$(seeds_unverified "$REPO/secrets" "$here" "$name")" && [ -n "$problem" ]; then
      fail "$MAIN_ENV: by ./secrets/SHA256SUMS, which the restore checks, secrets/$problem — $RECOVER"
    elif ! grep -qxF "secrets/$name" "$WORK/$MAIN_ENV.files"; then
      kept+=("$name")
    fi
  done
  [ "${#kept[@]}" -gt 0 ] || return 0
  tree_damaged=1
  tree_kept="${kept[*]}"
  note "! $MAIN_ENV: $tree_kept not in the tree at secrets/; this checkout's copies match the tree's SHA256SUMS, so the restore has them. $REPUBLISH"
}

# WORK holds the stage, so it sits beside the checkout (one filesystem: installing is a rename a
# kill cannot truncate), outside the checkout: 42ctl roots a pull at the nearest
# .42ctl/project.json inside the git repository it runs in (src/core/project.rs root_of, v0.1.16),
# which `env push` creates at the checkout root, so a stage inside it would be bypassed and the
# checkout overwritten unverified. WORK/.git makes WORK that repository, so a .git and a marker
# planted above it while the run waits at a prompt (/goinfre is world-writable) cannot pull the
# root out of this 0700 directory.
make_work() {
  WORK="$(mktemp -d "$(dirname "$REPO")/.groot-vault42-pull.XXXXXX")" ||
    die "no work directory beside the checkout ($(dirname "$REPO")) — nothing written"
  trap 'rm -rf "$WORK"' EXIT
  mkdir -m 700 "$WORK/.git" || die "cannot pin the pull's root at $WORK/.git — nothing written"
}
