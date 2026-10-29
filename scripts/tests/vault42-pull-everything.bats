#!/usr/bin/env bats
# vault42-pull-everything.sh writes secrets and the engine dumps into the checkout. These tests
# run a copy of it against a fake 42ctl (one prod env with the five dumps and a SHA256SUMS, one
# dev env, notes, env secrets) and a fake git, and pin the promises its header makes: nothing is
# written before the confirmation, a dump failing SHA256SUMS is never installed, a backup is
# never overwritten, and no credential value reaches the output or 42ctl's argv.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/vault42-pull-everything.bats

SECRET_VALUES='SECRETPASS|PASSWORDVALUE|FAKEKEYVALUE|FAKES3SECRETVALUE|TEAMSALTVALUE|ENVFILEVALUE|HANDBOOKSECRET'

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  BIN="$BATS_TEST_TMPDIR/bin"
  CFG="$BATS_TEST_TMPDIR/cfg"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$ROOT/scripts/lib" "$BIN" "$CFG/secret" "$FAKE_STATE"
  cp "$BATS_TEST_DIRNAME/../vault42-pull-everything.sh" "$ROOT/scripts/"
  for lib in envfile git-ignored seed-check vault42-pull-verify vault42-session; do
    cp "$BATS_TEST_DIRNAME/../lib/$lib.sh" "$ROOT/scripts/lib/"
  done
  grep '^ENGINE_SEEDS=' "$BATS_TEST_DIRNAME/../restore-if-empty.sh" >"$ROOT/scripts/restore-if-empty.sh"
  cat >"$ROOT/scripts/gen-local-env.sh" <<'GEN'
#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
echo "gen-local-env ${1:-mint} S3=${FT_S3_KEY:+inherited} PASS=${FT_PASSPHRASE:+inherited}"
[ -n "${1:-}" ] || [ -f .env.local ] || printf 'SALT=MINTED\nOTHER=1\n' >.env.local
GEN
  : >"$CFG/keystore.v42"
  printf 'FT_PASSPHRASE=SECRETPASS\nFT_PASSWORD=PASSWORDVALUE\nFT_LOGIN_EMAIL=me@example.test\n' >"$CFG/secret/creds"
  printf 'n\n' >"$BATS_TEST_TMPDIR/tty"
  touch "$FAKE_STATE/session"
  write_fake_git
  write_fake_42ctl
}

# Fake git: the repository is ROOT; NOT_IGNORED names the one path prefix it would take.
write_fake_git() {
  cat >"$BIN/git" <<'GIT'
#!/usr/bin/env bash
case " $* " in
*" rev-parse --show-toplevel "*) printf '%s\n' "$FAKE_ROOT" ;;
*" check-ignore "*) path="${*: -1}"; [ -z "${NOT_IGNORED:-}" ] || [[ "$path" != "$FAKE_ROOT/$NOT_IGNORED"* ]] ;;
*) exit 1 ;;
esac
GIT
  chmod +x "$BIN/git"
}

write_fake_42ctl() {
  cat >"$BIN/42ctl" <<'CTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CALLS"
E=""; prev=""; for a in "$@"; do [ "$prev" = --env ] && E="$a"; prev="$a"; done
DUMPS="postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb"
# FAKE_SHIFTED: the tree prod had on 2026-10-15 — the checkout pushed again under secrets/, its
# SHA256SUMS at secrets/secrets/ listing every dump while holding one.
SEEDS=secrets HELD="$DUMPS" ENVS_AT=""
[ -z "${FAKE_SHIFTED:-}" ] || { SEEDS=secrets/secrets; HELD=redis.rdb; ENVS_AT=secrets/; }
manifest() {
  [ "${FAKE_EMPTY:-}" != "$1" ] || return 0
  if [ "$1" = prod ]; then
    printf "$ENVS_AT%s\n" .env apps/grobase/.env
    [ -n "${FAKE_NO_SUMS:-}" ] || printf '%s/SHA256SUMS\n' "$SEEDS"
    [ -z "${FAKE_TIE:-}" ] || printf 'secrets/other/SHA256SUMS\n'
    for d in $HELD; do printf '%s/%s\n' "$SEEDS" "$d"; done
  else printf '.env\n'; fi
}
apply() {
  manifest "$E" | grep -v "^$SEEDS/" | grep -vxF "${FAKE_DROP:-none}" | while read -r f; do
    mkdir -p "$(dirname "$f")"; echo "KEY_$E=ENVFILEVALUE" >"$f"; done
  [ "$E" = prod ] || return 0
  mkdir -p "$SEEDS"; : >"$WORK_SUMS"
  for d in $DUMPS; do
    printf 'dump %s %s\n' "$d" "${FAKE_DUMP_VERSION:-1}" >"$WORK_SUMS.body"
    [ "${FAKE_UNLISTED:-}" = "$d" ] ||
      printf '%s  %s\n' "$(sha256sum <"$WORK_SUMS.body" | cut -d' ' -f1)" "$d" >>"$WORK_SUMS"
    [[ " $HELD " != *" $d "* ]] || cp "$WORK_SUMS.body" "$SEEDS/$d"
  done
  printf '%064d  private.local\n' 0 >>"$WORK_SUMS"
  [ -n "${FAKE_NO_SUMS:-}" ] || cp "$WORK_SUMS" "$SEEDS/SHA256SUMS"
  [ -z "${FAKE_TIE:-}" ] || { mkdir -p secrets/other; cp "$WORK_SUMS" secrets/other/SHA256SUMS; }
  [ -z "${FAKE_CORRUPT:-}" ] || echo garbage >>"$SEEDS/$FAKE_CORRUPT"
}
# Where 42ctl v0.1.16 writes a pull (src/core/project.rs root_of): the nearest .42ctl/project.json
# no higher than the first ancestor holding a .git, else the directory it runs in.
root_of() {
  local dir="$PWD" repo=""
  while [ -z "$repo" ]; do
    if [ -e "$dir/.git" ]; then repo="$dir"; elif [ "$dir" = / ]; then pwd; return; fi
    dir="$(dirname "$dir")"
  done
  dir="$PWD"
  while [ ! -f "$dir/.42ctl/project.json" ]; do
    [ "$dir" != "$repo" ] || { pwd; return; }
    dir="$(dirname "$dir")"
  done
  printf '%s\n' "$dir"
}
WORK_SUMS="$FAKE_STATE/sums"
case "$1 $2" in
"auth me") [ -f "$FAKE_STATE/session" ] ;;
"auth status") echo "logged in — session and contract" ;;
# --tenant binds the contract to the keystore, so the real CLI unlocks it: without FT_PASSPHRASE it
# opens /dev/tty, and with no terminal that is ENXIO (42ctl 0.1.15, 2026-10-29).
"auth login")
  [[ " $* " != *" --tenant "* ]] || [ "${FT_PASSPHRASE:-}" = SECRETPASS ] ||
    { echo "error: No such device or address (os error 6)" >&2; exit 1; }
  echo "password=${FT_PASSWORD:+env}" >"$FAKE_STATE/login"; touch "$FAKE_STATE/session" "$FAKE_STATE/bound" ;;
"auth whoami") [ "$FT_PASSPHRASE" = SECRETPASS ] || { echo "could not unlock keystore" >&2; exit 1; } ;;
"env ls") printf 'prod\ndev\n' ;;
"env files") manifest "$E" ;;
"env secret")
  [ -z "${FAKE_NO_S3:-}" ] || [[ "$4" != infra/* ]] || { echo "error: no scope key for this env" >&2; exit 1; }
  [ -z "${FAKE_UNBOUND:-}" ] || [ -f "$FAKE_STATE/bound" ] || { echo 'error: message: "contract not bound to this key"' >&2; exit 1; }
  case "$4" in
  infra/S3_KEY) echo FAKEKEYVALUE ;; infra/S3_SECRET) echo FAKES3SECRETVALUE ;;
  team/env-local) printf 'SALT=TEAMSALTVALUE\n' ;; team/handbook.html) echo '<html>HANDBOOKSECRET</html>' ;;
  *) exit 1 ;;
  esac ;;
"env pull")
  [[ " $* " == *" --apply "* ]] || { manifest "$E" | sed 's/^/  + /'; exit 0; }
  [ "${FAKE_FAIL_PULL:-}" != "$E" ] || { echo "transfer interrupted" >&2; exit 1; }
  root="$(root_of)"
  printf '%s\n' "$root" >>"$FAKE_STATE/apply-cwd"
  cd "$root" && apply ;;
"note ls") printf '%s\n' ${FAKE_NOTES:-runbooks/restart.md} ;;
"note get") echo "body of $3" ;;
"vault ls" | "vault get") [ "$2" = ls ] && echo personal-thing || exit 1 ;;
*) echo "fake 42ctl: unhandled $*" >&2; exit 3 ;;
esac
CTL
  chmod +x "$BIN/42ctl"
}

pull() {
  cd "$ROOT" || return 1
  run env PATH="$BIN:$PATH" FAKE_ROOT="$ROOT" FAKE_CALLS="$CALLS" CTL_BIN=42ctl CTL_CFG_DIR="$CFG" \
    VAULT42_TTY="$BATS_TEST_TMPDIR/tty" HOME="$BATS_TEST_TMPDIR" "$@" \
    bash scripts/vault42-pull-everything.sh --yes
}

nothing_written() {
  [ ! -e "$ROOT/secrets" ] && [ ! -e "$ROOT/.env" ] && [ ! -e "$ROOT/.vault42" ] && [ ! -e "$ROOT/.env.local" ]
}

no_secret_leaked() {
  [ -s "$CALLS" ] && ! grep -qE "$SECRET_VALUES" <<<"$output" && ! grep -qE "$SECRET_VALUES" "$CALLS"
}

@test "without --yes, a 'n' at the prompt writes nothing and exits 0" {
  cd "$ROOT"
  run env PATH="$BIN:$PATH" FAKE_ROOT="$ROOT" FAKE_CALLS="$CALLS" CTL_BIN=42ctl CTL_CFG_DIR="$CFG" \
    VAULT42_TTY="$BATS_TEST_TMPDIR/tty" bash scripts/vault42-pull-everything.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ secrets/postgres-all.sql.gz"* ]]
  [[ "$output" == *"nothing written"* ]]
  nothing_written
  run ! grep -q -- '--apply' "$CALLS"
}

@test "a full run installs prod, sandboxes dev, the notes and the handbook, all owner-only" {
  pull
  [ "$status" -eq 0 ]
  for d in postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb SHA256SUMS; do
    [ "$(stat -c %a "$ROOT/secrets/$d")" = 600 ]
  done
  [ -f "$ROOT/apps/grobase/.env" ]
  [ -f "$ROOT/.vault42/env/dev/.env" ]
  [ ! -e "$ROOT/.vault42/staging" ]
  [ "$(cat "$ROOT/.vault42/notes/runbooks/restart.md")" = "body of runbooks/restart.md" ]
  [ "$(stat -c %a "$ROOT/groot-vault42-handbook.team.html")" = 600 ]
  [[ "$output" == *"private"*"private.local"* ]]
  [[ "$output" == *"loaded FT_PASSPHRASE from secret/creds"* ]]
  no_secret_leaked
}

@test ".env.local is minted, then the team keys replace the minted ones; children get no credential" {
  pull
  [ "$status" -eq 0 ]
  grep -qx 'SALT=TEAMSALTVALUE' "$ROOT/.env.local"
  grep -qx 'OTHER=1' "$ROOT/.env.local"
  [[ "$output" == *"gen-local-env --sync S3= PASS="* ]]
  [[ "$output" != *inherited* ]]
}

@test "a dump failing SHA256SUMS is kept aside, never installed, and the run exits 1" {
  pull FAKE_CORRUPT=redis.rdb
  [ "$status" -eq 1 ]
  [ ! -e "$ROOT/secrets/redis.rdb" ]
  [ -f "$ROOT/.vault42/staging/prod/secrets/redis.rdb.corrupt" ]
  [ -f "$ROOT/secrets/postgres-all.sql.gz" ]
  [[ "$output" == *"CORRUPT"*"redis.rdb"* ]]
}

# What the seeds in ./secrets look like: name, mode, size, hash.
seeds_state() {
  (cd "$ROOT/secrets" && for d in postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb SHA256SUMS; do
    printf '%s %s\n' "$(stat -c '%n %a %s' "$d")" "$(sha256sum <"$d")"; done)
}

@test "a tree shifted under secrets/: the dumps this checkout holds are proven, untouched, and the run says to republish" {
  pull
  [ "$status" -eq 0 ]
  before="$(seeds_state)"
  pull FAKE_SHIFTED=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeps its dumps in secrets/secrets/, not secrets/"* ]]
  [[ "$output" == *"postgres-all.sql.gz"*"match the tree's SHA256SUMS"* ]]
  [[ "$output" != *"SHA256SUMS: absent"* ]]
  [[ "$output" != *"arrived and checks"* ]]
  [[ "$(tail -n 1 <<<"$output")" == *"only this checkout holds postgres-all.sql.gz"*"a teammate's pull of it fails"*"vault42-push-guard.sh"*"make vault42-team-push"* ]]
  [ "$(seeds_state)" = "$before" ]
  [ -f "$ROOT/secrets/secrets/redis.rdb" ]
}

@test "a shifted tree with no ./secrets/SHA256SUMS fails: the restore checks that one" {
  pull
  mv "$ROOT/secrets/SHA256SUMS" "$ROOT/secrets/SUMS.old"
  pull FAKE_SHIFTED=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"./secrets/SHA256SUMS, which the restore checks, is absent (the tree's is ./secrets/secrets/SHA256SUMS)"* ]]
}

@test "a shifted tree with a stale ./secrets/SHA256SUMS fails, naming the dump it misses" {
  pull
  grep -v ' redis.rdb$' "$ROOT/secrets/SHA256SUMS" >"$ROOT/secrets/SUMS.new"
  mv "$ROOT/secrets/SUMS.new" "$ROOT/secrets/SHA256SUMS"
  pull FAKE_SHIFTED=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"by ./secrets/SHA256SUMS, which the restore checks, secrets/redis.rdb: not in SHA256SUMS"* ]]
}

@test "no ENGINE_SEEDS line fails the run: which dumps the restore needs is unknown" {
  : >"$ROOT/scripts/restore-if-empty.sh"
  pull FAKE_SHIFTED=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"names no ENGINE_SEEDS"* ]]
}

@test "a .git and a .42ctl marker planted above the stage cannot redirect the pull" {
  mkdir -p "$BATS_TEST_TMPDIR/.git" "$BATS_TEST_TMPDIR/.42ctl"
  echo '{}' >"$BATS_TEST_TMPDIR/.42ctl/project.json"
  pull
  [ "$status" -eq 0 ]
  [ -s "$FAKE_STATE/apply-cwd" ]
  run ! grep -qvx "$BATS_TEST_TMPDIR/.groot-vault42-pull\.[^/]*/staging/[a-z]*" "$FAKE_STATE/apply-cwd"
  [ ! -e "$BATS_TEST_TMPDIR/.env" ] && [ ! -e "$BATS_TEST_TMPDIR/secrets" ]
  [ -f "$ROOT/secrets/redis.rdb" ]
}

@test "a dump the tree delivers CORRUPT fails the run even when this checkout's copy matches" {
  pull
  pull FAKE_SHIFTED=1 FAKE_CORRUPT=redis.rdb
  [ "$status" -eq 1 ]
  [[ "$output" == *"prod: secrets/secrets/redis.rdb: does not match SHA256SUMS, kept aside"* ]]
}

@test "an ENGINE_SEEDS dump the tree's SHA256SUMS does not list fails the run" {
  pull FAKE_UNLISTED=mongo.archive.gz
  [ "$status" -eq 1 ]
  [[ "$output" == *"prod: secrets/mongo.archive.gz: not in SHA256SUMS"* ]]
}

@test "two SHA256SUMS at the same depth is refused: which one lists the dumps is unknown" {
  pull
  pull FAKE_SHIFTED=1 FAKE_TIE=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"two SHA256SUMS at one depth"* ]]
}

@test "the pull runs outside the repository, so a .42ctl marker in the checkout cannot redirect it" {
  pull
  [ "$status" -eq 0 ]
  [ -s "$FAKE_STATE/apply-cwd" ]
  run ! grep -q "^$ROOT" "$FAKE_STATE/apply-cwd"
}

@test "a tree shifted under secrets/ on a fresh checkout fails, naming each dump and the recovery" {
  pull FAKE_SHIFTED=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"prod: secrets/postgres-all.sql.gz: absent — bring them back: make vault42-recover-dumps"* ]]
  [[ "$output" == *"prod: secrets/redis.rdb: absent"* ]]
}

@test "a checkout dump that differs from the tree's SHA256SUMS fails the run" {
  pull
  pull FAKE_SHIFTED=1 FAKE_DUMP_VERSION=2
  [ "$status" -eq 1 ]
  [[ "$output" == *"prod: secrets/mysql-all.sql.gz: does not match SHA256SUMS"* ]]
}

@test "a tree with no SHA256SUMS anywhere fails, naming the recovery and the republish" {
  pull FAKE_NO_SUMS=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"the tree carries no SHA256SUMS"*"make vault42-recover-dumps"*"make vault42-team-push"* ]]
}

@test "a file listed but not delivered fails the run" {
  pull FAKE_DROP=apps/grobase/.env
  [ "$status" -eq 1 ]
  [[ "$output" == *"listed but not delivered: apps/grobase/.env"* ]]
}

@test "without the object-store key nothing is written, and the reason is shown" {
  pull FAKE_NO_S3=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no scope key for this env"* ]]
  nothing_written
}

@test "an empty prod listing stops the run before any write" {
  pull FAKE_EMPTY=prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"lists no file you can read"* ]]
  nothing_written
}

@test "one environment failing does not stop the next, and the run exits 1" {
  pull FAKE_FAIL_PULL=dev
  [ "$status" -eq 1 ]
  [ -f "$ROOT/secrets/redis.rdb" ]
  [[ "$output" == *"dev: the pull stopped part-way"* ]]
  [[ "$output" == *"problem(s); what it delivered is in ./.vault42/env/dev"* ]]
  [ -d "$ROOT/.vault42/env/dev" ]
}

@test "a note path climbing out of .vault42/notes is refused" {
  pull FAKE_NOTES="ok.md ../escape.md /etc/abs.md"
  [ "$status" -eq 1 ]
  [ -f "$ROOT/.vault42/notes/ok.md" ]
  [ ! -e "$ROOT/.vault42/escape.md" ]
  [[ "$output" == *"note refused (unsafe path): ../escape.md"* ]]
  [[ "$output" == *"note refused (unsafe path): /etc/abs.md"* ]]
}

@test "a second run keeps the first run's backup and skips identical files" {
  pull
  [ "$status" -eq 0 ]
  sleep 1
  pull FAKE_DUMP_VERSION=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"6 file(s) written, 2 already identical"* ]]
  sleep 1
  pull FAKE_DUMP_VERSION=3
  [ "$(find "$ROOT/secrets" -name 'redis.rdb.bak-*' | wc -l)" -eq 2 ]
  grep -qx 'dump redis.rdb 2' "$(find "$ROOT/secrets" -name 'redis.rdb.bak-*' | sort | tail -n 1)"
  [ -d "$ROOT/.vault42/env/dev.old" ]
}

@test "a sandbox git would take stops the run before any write" {
  pull NOT_IGNORED=.vault42
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not git-ignored"* ]]
  nothing_written
}

@test "a pulled path git would take is named, without stopping the run" {
  pull NOT_IGNORED=apps/grobase/.env
  [ "$status" -eq 0 ]
  [[ "$output" == *"not git-ignored"*"apps/grobase/.env"* ]]
}

@test "a refused passphrase with no terminal stops before any write" {
  pull FT_PASSPHRASE=wrong VAULT42_TTY=/nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"no terminal to ask"* ]]
  nothing_written
}

@test "an expired session signs in with the password from the environment, never argv" {
  rm "$FAKE_STATE/session"
  pull
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_STATE/login")" = "password=env" ]
  grep -q '^auth login --password --email me@example.test' "$CALLS"
  no_secret_leaked
}

@test "a sign-in that takes a contract unlocks the keystore with the passphrase from the credential file, no terminal" {
  rm "$FAKE_STATE/session"
  printf 'FT_TENANT=me\n' >>"$CFG/secret/creds"
  pull VAULT42_TTY=/nonexistent
  [ "$status" -eq 0 ]
  grep -q '^auth login --password --email me@example.test --tenant me' "$CALLS"
  [ -f "$ROOT/secrets/redis.rdb" ]
  no_secret_leaked
}

@test "with no credential file, values exported under their alias names sign in with no terminal" {
  rm "$FAKE_STATE/session" "$CFG/secret/creds"
  pull VAULT42_TTY=/nonexistent FT_PASSPHRASE=SECRETPASS FT_PASSWORD=PASSWORDVALUE \
    FT_EMAIL=me@example.test FT_TENANT=me VAULT42_REGISTER_TOKEN=tok
  [ "$status" -eq 0 ]
  grep -q '^auth login --password --email me@example.test --tenant me' "$CALLS"
  [ -f "$ROOT/secrets/redis.rdb" ]
  no_secret_leaked
}

@test "a contract left on a replaced keystore is not rebound without a 'y' at the terminal" {
  pull FAKE_UNBOUND=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"contract bound to another key — run: 42ctl auth login"* ]]
  [ ! -e "$FAKE_STATE/login" ]
  nothing_written
}

@test "a 'y' rebinds the contract by signing in, then the pull completes" {
  printf 'y\n' >"$BATS_TEST_TMPDIR/tty"
  pull FAKE_UNBOUND=1
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_STATE/login")" = "password=env" ]
  [ -f "$ROOT/secrets/redis.rdb" ]
  no_secret_leaked
}
