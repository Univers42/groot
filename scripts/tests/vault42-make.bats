#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# utils/mk/vault42.mk drives the shared vault42 CLI (vendor/scripts/vault42) through
# utils/vault42.conf. The CLI is tested in its own repo; these tests pin what groot adds: the
# make-to-flag mapping, the devil's conditions G1-G7 for this wiring, and that the new path
# publishes the same private set as the old one (vault42-team.sh), which stays the verified path.
#
# Nothing here reaches a real vault: 42ctl is the CLI's own fake and docker is a recorder.
#
# Run: W=$PWD; docker run --rm -v "$W:$W" -v /goinfre/dlesieur/groot/.git:/goinfre/dlesieur/groot/.git \
#        -w "$W" --entrypoint sh bats/bats:1.11.1 -c 'apk add -q --no-cache make coreutils git jq \
#        findutils bash diffutils curl >/dev/null && git config --global --add safe.directory "*" && \
#        bats --tap scripts/tests/vault42-make.bats'

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLI="$REPO/vendor/scripts/vault42"
  [ -f "$CLI/vault42.sh" ] || {
    echo "vendor/scripts is not initialised; run: git submodule update --init vendor/scripts" >&2
    return 1
  }
  export FAKE42="$BATS_TEST_TMPDIR/fake42" FAKE_SCAN_LIB="$CLI/lib/scan.sh"
  export DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE42" "$BIN"
  : >"$DOCKER_LOG"
  cp "$CLI/tests/helpers/fake-42ctl" "$BIN/42ctl"
  # A recorder: one line per call, every argument space-joined. Exit 0, no output, which is what
  # the old path's `auth me` and secret lookups need to carry on.
  # shellcheck disable=SC2016 # the recorder must expand "$*" when docker runs, not when it is written
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$DOCKER_LOG"\nexit 0\n' >"$BIN/docker"
  # gen-local-env.sh mints secrets with openssl; the bats image has none (randomness is all it needs).
  printf '#!/bin/sh\nprintf "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0\\n"\n' >"$BIN/openssl"
  chmod +x "$BIN/42ctl" "$BIN/docker" "$BIN/openssl"
  PATH="$BIN:$PATH"
  unset FT_PASSPHRASE VAULT42_ORG VAULT42_PROJECT VAULT42_ENV VAULT42_VOLUMES_ROOT APPLY YES ALL BACKUP
}

# dry TARGET [VAR=value...] — what `make -n` would run, from the real checkout.
# Runs of spaces from empty expansions are squeezed so a line reads as the command it spells.
dry() { make -n --no-print-directory -C "$REPO" "$@" | sed -e 's/  */ /g' -e 's/ $//'; }

# fixture — a throwaway checkout holding only what the vault42 path touches, with every dump the
# push guard demands, so a real `make` can run against the fakes without touching this worktree.
fixture() {
  FX="$BATS_TEST_TMPDIR/co/groot"
  mkdir -p "$FX/vendor/scripts" "$FX/apps/grobase/scripts/vault" "$FX/secrets"
  cp -a "$REPO/Makefile" "$REPO/utils" "$FX/"
  mkdir -p "$FX/infrastructure"
  cp -a "$REPO/infrastructure/scripts" "$FX/infrastructure/scripts"
  cp -a "$REPO/scripts" "$FX/scripts"
  rm -rf "$FX/scripts/tests"
  cp -a "$CLI" "$FX/vendor/scripts/vault42"
  rm -rf "$FX/vendor/scripts/vault42/tests"
  cp -a "$REPO/apps/grobase/scripts/vault/ctl-env.sh" "$FX/apps/grobase/scripts/vault/"
  # The guard reads the engine list from this file; the real one lists dumps this fixture lacks.
  printf 'ENGINE_SEEDS="postgres-all.sql.gz redis.rdb"\n' >"$FX/scripts/restore-if-empty.sh"
  for d in postgres-all.sql.gz redis.rdb; do echo "dump $d" >"$FX/secrets/$d"; done
  (cd "$FX/secrets" && sha256sum postgres-all.sql.gz redis.rdb >SHA256SUMS)
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\n' >"$FX/apps/grobase/.env"
  git -C "$FX" init -q
  git -C "$FX" add -A
  git -C "$FX" -c user.email=t@example.test -c user.name=t commit -qm fixture
  printf '7704efb0-5a6a-4117-9cdd-a9265a8fc350 active\n' >"$FAKE42/keys.prod"
  export FT_PASSPHRASE=pass-planted-1111
}

# old_private LOG — the sorted --private patterns in the docker line of the old path's `env push`.
old_private() {
  tr ' ' '\n' <"$1" | awk 'p { print; p = 0 } $0 == "--private" { p = 1 }' | LC_ALL=C sort
}

# new_private LOG — the sorted patterns the CLI's fake 42ctl logged as "env push PATTERN...".
new_private() {
  sed 's/^env push //' "$1" | tr ' ' '\n' | LC_ALL=C sort
}

# ---- the make-to-flag mapping, from `make -n` ----

@test "status and login are one CLI call each" {
  run dry vault42-status
  [ "$status" -eq 0 ]
  [[ "$output" == *"bash vendor/scripts/vault42/vault42.sh --config utils/vault42.conf doctor" ]]
  run dry vault42-login
  [[ "$output" == *"--config utils/vault42.conf login" ]]
}

@test "list and diff default to the secrets target; KIND becomes repeated --kind, TARGET --target" {
  run dry vault42-list
  [[ "$output" == *"--config utils/vault42.conf --target 'secrets' list" ]]
  run dry vault42-diff KIND="env secrets" TARGET=volumes
  [[ "$output" == *"--target 'volumes' --kind 'env' --kind 'secrets' diff" ]]
}

@test "pull is a preview by default and maps ONLY to repeated --only" {
  run dry vault42-pull
  [[ "$output" == *"--target 'secrets' pull" ]]
  [[ "$output" != *"--apply"* ]]
  run dry vault42-pull ONLY="a.env b.env" KIND=env APPLY=1
  [[ "$output" == *"--kind 'env' pull --apply --only 'a.env' --only 'b.env'" ]]
}

@test "push maps YES to --yes and FILE with two paths to two arguments" {
  run dry vault42-push FILE="a.env secrets/b.env" YES=1
  [[ "$output" == *"--target 'secrets' push --yes 'a.env' 'secrets/b.env'" ]]
  run dry vault42-push
  [[ "$output" != *"--yes"* ]]
}

@test "secret-get and secret-set pass KEY and refuse a missing one" {
  run dry vault42-secret-get KEY=team/env-local
  [[ "$output" == *"--target secrets secret get 'team/env-local'" ]]
  run dry vault42-secret-set KEY=team/env-local
  [[ "$output" == *"--target secrets secret set 'team/env-local'" ]]
  fixture
  run make -C "$FX" vault42-secret-get
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: make vault42-secret-get KEY=<path>"* ]]
}

@test "volumes targets always name the volumes target" {
  run dry vault42-volumes-list
  [[ "$output" == *"--target volumes volumes list" ]]
  run dry vault42-volumes-capture ONLY="vol1 vol2"
  [[ "$output" == *"--target volumes volumes capture --only 'vol1' --only 'vol2'" ]]
  run dry vault42-volumes-restore ARCHIVE=secrets/volume-x.tar.gz
  [[ "$output" == *"--target volumes volumes restore 'secrets/volume-x.tar.gz'" ]]
  run dry vault42-volumes-restore ALL=1
  [[ "$output" == *"volumes restore --all" ]]
}

@test "volumes-restore with neither ARCHIVE nor ALL stops with a usage line" {
  fixture
  run make -C "$FX" vault42-volumes-restore
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: make vault42-volumes-restore ARCHIVE=<file> | ALL=1"* ]]
  [ ! -s "$DOCKER_LOG" ]
}

# ---- G5: the dangerous switches count only from the command line ----

@test "G5: APPLY YES ALL BACKUP in the environment add no flag" {
  run env APPLY=1 YES=1 ALL=1 BACKUP=1 ARCHIVE=x make -n -C "$REPO" vault42-pull vault42-push vault42-volumes-restore
  [ "$status" -eq 0 ]
  for flag in --apply --yes --all --backup; do
    [[ "$output" != *"$flag"* ]] || {
      echo "environment leaked $flag" >&2
      return 1
    }
  done
}

@test "G5: the same switches on the command line appear (BACKUP maps to nothing: the CLI has none)" {
  run dry vault42-pull APPLY=1 BACKUP=1
  [[ "$output" == *"pull --apply"* ]]
  [[ "$output" != *"--backup"* ]]
  run dry vault42-push YES=1
  [[ "$output" == *"push --yes"* ]]
  run dry vault42-volumes-restore ALL=1
  [[ "$output" == *"restore --all"* ]]
}

# ---- G6: the vault coordinates are not overridable ----

@test "G6: VAULT42_ENV ORG PROJECT from the command line or the environment are refused, 42ctl untouched" {
  fixture
  run make -C "$FX" vault42-push YES=1 VAULT42_ENV=staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"VAULT42_ENV cannot be set here; edit utils/vault42.conf"* ]]
  run env VAULT42_ORG=other make -C "$FX" vault42-pull
  [ "$status" -eq 2 ]
  [[ "$output" == *"VAULT42_ORG cannot be set here; edit utils/vault42.conf"* ]]
  run env VAULT42_PROJECT=other make -C "$FX" vault42-status
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE42/argv.log" ]
}

@test "G6 control: without the override the same call does reach 42ctl" {
  fixture
  run make -C "$FX" vault42-status
  [ -s "$FAKE42/argv.log" ]
}

# ---- G7 and the volumes root ----

@test "G7: no absolute path in utils/vault42.conf" {
  run grep -c /goinfre/dlesieur "$REPO/utils/vault42.conf"
  [ "$status" -eq 1 ]
  [ "$output" = 0 ]
  run grep -nE '^(root|stage_dir|stack_file) *= */' "$REPO/utils/vault42.conf"
  [ "$status" -eq 1 ]
}

@test "G7: a missing volumes root fails before any docker call" {
  fixture
  run make -C "$FX" vault42-volumes-list
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"*"does not exist"* ]]
  [ ! -s "$DOCKER_LOG" ]
}

@test "G7 control: VAULT42_VOLUMES_ROOT points the volumes target at a directory and docker is called" {
  fixture
  mkdir -p "$BATS_TEST_TMPDIR/vols"
  run env VAULT42_VOLUMES_ROOT="$BATS_TEST_TMPDIR/vols" make -C "$FX" vault42-volumes-list
  [ -s "$DOCKER_LOG" ]
}

# ---- G1-adjacent: a missing submodule stops with the fix ----

@test "a missing vendor/scripts/vault42 stops with the exact fix" {
  fixture
  rm -rf "$FX/vendor/scripts/vault42"
  run make -C "$FX" vault42-status
  [ "$status" -ne 0 ]
  [[ "$output" == *"run: git submodule update --init vendor/scripts"* ]]
}

# ---- help ----

@test "make help lists the section; help-vault42-push says the old path stays verified" {
  run make -C "$REPO" help
  [[ "$output" == *"Secrets (vault42)"* ]]
  [[ "$output" == *"vault42-volumes-restore"* ]]
  run make -C "$REPO" help-vault42-push
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: make vault42-push"* ]]
  [[ "$output" == *"vault42-team-push"* ]]
  [[ "$output" == *"R1-R6"* ]]
}

# ---- G2/C1: the old and the new path publish the same private set ----

@test "G2: old vault42-team.sh push and new make vault42-push pass the same --private list" {
  fixture
  export CTL_CFG_DIR="$BATS_TEST_TMPDIR/cfg" CTL_IMAGE=fake/42ctl:test
  mkdir -p "$CTL_CFG_DIR"
  : >"$CTL_CFG_DIR/keystore.v42"
  run sh "$FX/scripts/vault42-team.sh" push
    [ "$status" -eq 0 ]
  grep -E ' env push ' "$DOCKER_LOG" >"$BATS_TEST_TMPDIR/old.log"
  [ -s "$BATS_TEST_TMPDIR/old.log" ]
  old_private "$BATS_TEST_TMPDIR/old.log" >"$BATS_TEST_TMPDIR/old.sorted"

  run make -C "$FX" vault42-push YES=1
  [ "$status" -eq 0 ]
  new_private "$FAKE42/push.log" >"$BATS_TEST_TMPDIR/new.sorted"

  [ "$(wc -l <"$BATS_TEST_TMPDIR/old.sorted")" -ge 9 ]
  run diff "$BATS_TEST_TMPDIR/old.sorted" "$BATS_TEST_TMPDIR/new.sorted"
  [ "$status" -eq 0 ]
  grep -qxF 'apps/*/vendor/*' "$BATS_TEST_TMPDIR/new.sorted"
}

# ---- G3: a vendored app's env example goes out private ----

@test "G3: apps/x/vendor/y/.env.example is scanned and marked private by the new path" {
  fixture
  # 42ctl's scanner enters vendor/ only for a directory that is itself a git repo, which is
  # what a synced submodule such as apps/grobase/vendor/scripts is.
  mkdir -p "$FX/apps/x/vendor/y"
  git -C "$FX/apps/x/vendor/y" init -q
  echo SECRET=1 >"$FX/apps/x/vendor/y/.env.example"
  git -C "$FX/apps/x/vendor/y" add -A
  git -C "$FX/apps/x/vendor/y" -c user.email=t@example.test -c user.name=t commit -qm app
  git -C "$FX" add -A
  git -C "$FX" -c user.email=t@example.test -c user.name=t commit -qm vendored
  run make -C "$FX" vault42-push YES=1
    [ "$status" -eq 0 ]
  grep -qE ' apps/\*/vendor/\*( |$)' "$FAKE42/push.log"
  grep -qxF apps/x/vendor/y/.env.example "$FAKE42/files.prod" ||
    grep -qF ' apps/x/vendor/y/.env.example' "$FAKE42/files.prod"
  grep -qxF apps/x/vendor/y/.env.example "$FAKE42/private.prod"
}

# ---- G4: an applied pull runs the real post-pull hook ----

@test "G4: make vault42-pull APPLY=1 lays the team overlay on .env.local, no lock error" {
  fixture
  mkdir -p "$FAKE42/tree.prod/apps/grobase" "$FAKE42/secret/team"
  printf 'JWT_SECRET=jwt-B\nANON_KEY=anon-B\nSERVICE_ROLE_KEY=svc-B\n' >"$FAKE42/tree.prod/apps/grobase/.env"
  printf 'OSIONOS_BRIDGE_EMAIL_HASH_SALT=team-salt\nVITE_BAAS_TENANT=t1\n' >"$FAKE42/secret/team/env-local"
  run --separate-stderr make -C "$FX" vault42-pull APPLY=1
  [ "$status" -eq 0 ]
  [[ "$stderr" != *locked* ]]
  grep -qxF 'OSIONOS_BRIDGE_EMAIL_HASH_SALT=team-salt' "$FX/.env.local"
  grep -qxF 'VITE_BAAS_TENANT=t1' "$FX/.env.local"
  [ "$(grep -c '^OSIONOS_BRIDGE_EMAIL_HASH_SALT=' "$FX/.env.local")" -eq 1 ]
  [ "$(stat -c %a "$FX/.env.local")" = 600 ]
  grep -qxF 'JWT_SECRET=jwt-B' "$FX/.env.local"
}

@test "G4: the pre-push hook and the post-pull hook are tracked and executable" {
  # CI's checkout belongs to the runner user while the container runs as root, so git refuses
  # the repo as dubious ownership without this (graph-studio-build.bats does the same).
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
  for f in scripts/vault42-push-guard.sh utils/scripts/vault42-post-pull.sh; do
    [ -x "$REPO/$f" ]
    run git -C "$REPO" ls-files --stage -- "$f"
    [[ "$output" == 100755* ]]
  done
}

@test "G4: a pull without APPLY previews and leaves .env.local alone" {
  fixture
  mkdir -p "$FAKE42/tree.prod"
  echo A=1 >"$FAKE42/tree.prod/x.env"
  run make -C "$FX" vault42-pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"would write x.env"* ]]
  [ ! -e "$FX/.env.local" ]
  [ ! -e "$FX/x.env" ]
}
