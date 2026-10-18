#!/usr/bin/env bats
# vault42-push-guard.sh stands between a checkout and `42ctl env push`, which publishes exactly
# what is on disk. These tests pin what it refuses (a dump that would drop out, a pulled tree
# mirrored under ./secrets, pull-everything's sandbox), that it writes nothing, that the one
# move-aside it prints works as printed, and that both push entry points stop before 42ctl when
# it refuses.
#
# Run: docker run --rm -v "$PWD:/code:ro" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils findutils && bats scripts/tests/vault42-push-guard.bats'

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts/lib" "$ROOT/secrets" "$ROOT/apps/grobase/scripts/vault" "$ROOT/utils/mk"
  cp "$BATS_TEST_DIRNAME/../vault42-push-guard.sh" "$BATS_TEST_DIRNAME/../vault42-team.sh" "$ROOT/scripts/"
  cp "$BATS_TEST_DIRNAME/../lib/envfile.sh" "$BATS_TEST_DIRNAME/../lib/seed-check.sh" "$ROOT/scripts/lib/"
  cp "$BATS_TEST_DIRNAME/../../utils/mk/repo.mk" "$ROOT/utils/mk/"
  printf 'ENGINE_SEEDS="postgres-all.sql.gz redis.rdb"\n' >"$ROOT/scripts/restore-if-empty.sh"
  cat >"$ROOT/apps/grobase/scripts/vault/ctl-env.sh" <<STUB
#!/bin/sh
echo "ctl-env personal=\${VAULT_ENV_PERSONAL:-0} \$*" >>"$BATS_TEST_TMPDIR/ctl.log"
STUB
  for d in postgres-all.sql.gz redis.rdb minio.tar.gz; do echo "dump $d" >"$ROOT/secrets/$d"; done
  (cd "$ROOT/secrets" && sha256sum postgres-all.sql.gz redis.rdb minio.tar.gz >SHA256SUMS)
  touch "$ROOT/.env" "$ROOT/secrets/dylan.env"
}

guard() { run bash "$ROOT/scripts/vault42-push-guard.sh"; }

tree_state() { (cd "$ROOT" && find . -exec stat -c '%n %a %s' {} + | sort); }

@test "a checkout whose dumps all match passes, a personal secrets/*.env included" {
  guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ every dump matches"* ]]
}

@test "no SHA256SUMS is refused" {
  mv "$ROOT/secrets/SHA256SUMS" "$ROOT/secrets/SUMS.old"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"./secrets/SHA256SUMS is absent or a symlink"* ]]
}

@test "an empty SHA256SUMS is refused" {
  : >"$ROOT/secrets/SHA256SUMS"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"lists nothing"* ]]
}

@test "a symlinked SHA256SUMS is refused: 42ctl would push a tree without it" {
  mv "$ROOT/secrets/SHA256SUMS" "$ROOT/sums.real"
  ln -s "$ROOT/sums.real" "$ROOT/secrets/SHA256SUMS"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"./secrets/SHA256SUMS is absent or a symlink"* ]]
}

@test "a listed dump that is absent or differs is refused, by name, with both remedies" {
  mv "$ROOT/secrets/minio.tar.gz" "$ROOT/minio.aside"
  echo changed >>"$ROOT/secrets/redis.rdb"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets/minio.tar.gz: absent: the tree would lose it — make vault42-recover-dumps"*"make vault42-seed"* ]]
  [[ "$output" == *"secrets/redis.rdb: does not match SHA256SUMS"* ]]
}

@test "an ENGINE_SEEDS dump SHA256SUMS does not list is refused" {
  (cd "$ROOT/secrets" && sha256sum redis.rdb minio.tar.gz >SHA256SUMS)
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets/postgres-all.sql.gz: not in SHA256SUMS"* ]]
}

@test "no ENGINE_SEEDS line is refused: which dumps the tree must carry is unknown" {
  : >"$ROOT/scripts/restore-if-empty.sh"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"names no ENGINE_SEEDS"* ]]
}

@test "a symlinked dump is refused: 42ctl skips symlinks" {
  mv "$ROOT/secrets/redis.rdb" "$ROOT/redis.real"
  ln -s "$ROOT/redis.real" "$ROOT/secrets/redis.rdb"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets/redis.rdb is a symlink"* ]]
}

@test "a symlinked ./secrets is refused" {
  mv "$ROOT/secrets" "$ROOT/seeds.real"
  ln -s "$ROOT/seeds.real" "$ROOT/secrets"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"absent or a symlink"* ]]
}

@test "each twin of a checkout-root entry under ./secrets is refused, and nothing is moved" {
  local twin
  mkdir -p "$ROOT/secrets/apps/grobase" "$ROOT/secrets/secrets"
  touch "$ROOT/secrets/apps/grobase/.env" "$ROOT/secrets/secrets/SHA256SUMS" "$ROOT/secrets/.env"
  for twin in .env.example .env.grobase-link .env.grobase-remote; do touch "$ROOT/$twin" "$ROOT/secrets/$twin"; done
  before="$(tree_state)"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets/apps secrets/secrets secrets/.env secrets/.env.example secrets/.env.grobase-link secrets/.env.grobase-remote: a pulled tree mirrored under ./secrets"* ]]
  [ "$(tree_state)" = "$before" ]
}

@test "pull-everything's sandbox holding a file is refused; an empty one is not" {
  mkdir -p "$ROOT/.vault42/staging/prod"
  guard
  [ "$status" -eq 0 ]
  touch "$ROOT/.vault42/staging/prod/x.env"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *".vault42 holds 1 file(s)"* ]]
}

@test "the one printed move-aside, run as printed from anywhere, clears the mirror and the sandbox" {
  mkdir -p "$ROOT/secrets/secrets" "$ROOT/.vault42/staging/prod"
  touch "$ROOT/secrets/secrets/SHA256SUMS" "$ROOT/.vault42/staging/prod/x.env"
  guard
  [ "$status" -eq 1 ]
  [ "$(grep -c 'move them aside:' <<<"$output")" -eq 1 ]
  cmd="$(sed -n 's/^\[push-guard\]   move them aside: //p' <<<"$output")"
  (cd / && bash -c "$cmd")
  guard
  [ "$status" -eq 0 ]
  aside="$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'repo-vault42-aside-*')"
  [ "$(stat -c %a "$aside")" = 700 ]
  [ -f "$aside/secrets/SHA256SUMS" ]
  [ -f "$aside/.vault42/staging/prod/x.env" ]
}

@test "the team push stops before ctl-env.sh when the guard refuses, and reaches it when it passes" {
  : >"$ROOT/secrets/SHA256SUMS"
  run sh "$ROOT/scripts/vault42-team.sh" push
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/ctl.log" ]
  (cd "$ROOT/secrets" && sha256sum postgres-all.sql.gz redis.rdb minio.tar.gz >SHA256SUMS)
  run sh "$ROOT/scripts/vault42-team.sh" push
  [ "$status" -eq 0 ]
  grep -q '^ctl-env personal=0 push --private \*.bak --private .env.grobase-remote' "$BATS_TEST_TMPDIR/ctl.log"
}

@test "make vault42-push-all: shared is the team push (.env.grobase-remote sealed), blank is personal; both guarded" {
  run make -C "$ROOT" -f utils/mk/repo.mk vault42-push-all VAULT42_ORG=o VAULT42_PROJECT=p VAULT42_ENV=e
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ every dump matches"* ]]
  grep -q -- 'personal=0 push --private \*.bak --private .env.grobase-remote' "$BATS_TEST_TMPDIR/ctl.log"
  : >"$BATS_TEST_TMPDIR/ctl.log"
  run make -C "$ROOT" -f utils/mk/repo.mk vault42-push-all VAULT42_ORG= VAULT42_ENV=
  [ "$status" -eq 0 ]
  grep -qx 'ctl-env personal=1 push' "$BATS_TEST_TMPDIR/ctl.log"
  : >"$ROOT/secrets/SHA256SUMS"
  : >"$BATS_TEST_TMPDIR/ctl.log"
  run make -C "$ROOT" -f utils/mk/repo.mk vault42-push-all VAULT42_ORG= VAULT42_ENV=
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/ctl.log" ]
}
