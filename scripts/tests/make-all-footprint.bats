#!/usr/bin/env bats
# A fresh-machine `make all` has to fit a 20-30 GB /var. These tests pin the choices that keep
# it there: frontends-up builds only the images it starts, pre-pulls only the base images those
# builds use, and the vault restore pulls its 650 MB DynamoDB client only when DynamoDB runs.
# Every check drives the real Makefile or script against a fake `docker` that records pulls.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils && bats scripts/tests'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  PULLS="$BATS_TEST_TMPDIR/pulls"
  mkdir -p "$BIN"
  : > "$PULLS"
  cat > "$BIN/docker" <<FAKE
#!/bin/sh
# Fake docker: no image is cached; RUNNING lists the containers that are up.
case "\$1" in
  image) exit 1 ;;
  pull) echo "\$3" >> "$PULLS" ;;
  ps) for c in \${RUNNING:-}; do echo "\$c"; done ;;
esac
exit 0
FAKE
  chmod +x "$BIN/docker"
  PATH="$BIN:$PATH"
}

prefetch() {
  make -s -C "$REPO" docker-prefetch-images DOCKER_PREFETCH_SCOPE="$1"
}

# The base images of everything frontends-up builds, named the way the prefetch tags them.
frontend_bases() {
  local d="$REPO/infrastructure/docker/osionos"
  sed -n -e 's/^FROM \([^ ]*\).*/\1/p' -e 's/^# *syntax=\(.*\)/\1/p' \
    "$d/app.Dockerfile" "$d/bridge.Dockerfile" "$d/runner/Dockerfile" "$d/ide-socket-proxy/Dockerfile" \
    | sed 's#^public.ecr.aws/docker/library/##' | sort -u
}

pulled() {
  sed 's#^public.ecr.aws/docker/library/##' "$PULLS" | sort -u
}

@test "frontends-up does not bake the :local images that make all never starts" {
  run make -C "$REPO" -pq __no_such_target__
  block=$(printf '%s\n' "$output" | awk '/^frontends-up:/ {on = 1} on && /^$/ {exit} on')
  [ -n "$block" ]
  [[ "$block" != *compose-build* ]]
  [[ "$block" != *bake* ]]
}

@test "the frontends prefetch covers every base image frontends-up builds from" {
  run prefetch frontends
  [ "$status" -eq 0 ]
  for base in $(frontend_bases); do
    pulled | grep -qxF "$base" || { echo "not prefetched: $base"; return 1; }
  done
}

@test "the frontends prefetch pulls nothing those builds do not use" {
  prefetch frontends
  extra=$(pulled | grep -vxF -f <(frontend_bases) || true)
  [ -z "$extra" ] || { echo "pulled but unused: $extra"; return 1; }
}

@test "scope all keeps pulling the root compose set that up and up-infra start" {
  prefetch all
  grep -qF 'hashicorp/vault:1.16' "$PULLS"
  grep -qF 'kong:3.8' "$PULLS"
  grep -qF 'postgres-meta' "$PULLS"
}

@test "an unknown prefetch scope is refused" {
  run prefetch everything
  [ "$status" -ne 0 ]
  [[ "$output" == *DOCKER_PREFETCH_SCOPE* ]]
}

# vault-restore pulls its helpers, then stops containers via `make up`. A failing fake make
# ends the run right there, so PULLS holds exactly the helpers it fetched up front.
restore_until_first_stop() {
  local root="$BATS_TEST_TMPDIR/grobase" seeds="$BATS_TEST_TMPDIR/seeds"
  mkdir -p "$root/scripts/ops" "$seeds"
  cp "$REPO/apps/grobase/scripts/ops/vault-restore.sh" "$root/scripts/ops/"
  for f in postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb dynamodb-all.tar.gz; do
    : > "$seeds/$f"
  done
  printf '#!/bin/sh\nexit 1\n' > "$BIN/make"
  chmod +x "$BIN/make"
  run env SEED_DIR="$seeds" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" sh "$root/scripts/ops/vault-restore.sh"
}

@test "vault restore skips the aws-cli pull when DynamoDB is not running" {
  RUNNING="mini-baas-postgres mini-baas-kong" restore_until_first_stop
  [[ "$output" == *"could not start engines"* ]]
  grep -qxF 'mongo:7' "$PULLS"
  run grep -F 'aws-cli' "$PULLS"
  [ "$status" -eq 1 ]
}

@test "vault restore pulls aws-cli before stopping anything when DynamoDB runs" {
  RUNNING="mini-baas-postgres mini-baas-dynamodb-local" restore_until_first_stop
  [[ "$output" == *"could not start engines"* ]]
  grep -qxF 'amazon/aws-cli' "$PULLS"
}
