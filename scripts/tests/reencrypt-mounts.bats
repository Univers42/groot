#!/usr/bin/env bats
# reencrypt-mounts.sh authenticates to the adapter-registry with the service token it reads
# from the RUNNING registry container's environment. grobase's compose maps the host-side
# ADAPTER_REGISTRY_SERVICE_TOKEN into that container as INTERNAL_SERVICE_TOKEN
# (orchestrators/compose/base/control-plane.yml), so the old name is only present in the
# monolith shape — on grobase develop 7abe647d the check died "no adapter-registry service
# token" against a healthy registry (2026-10-10). These tests run a copy of the script against
# a fake `docker` whose `inspect` answers with a chosen set of env names (values are dummies).
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/reencrypt-mounts.bats

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts" "$ROOT/apps/grobase/scripts/lib" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../reencrypt-mounts.sh" "$ROOT/scripts/"
  # The real lib signs requests; none is sent here (the fake registry has no mounts).
  printf 'svc_auth() { SVC_AUTH=(); }\n' > "$ROOT/apps/grobase/scripts/lib/service-auth.sh"
  # python3 is only a presence check until a mount needs re-registering.
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/python3"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'FAKE'
#!/bin/sh
# Fake docker: the registry and postgres are up; CONTAINER_ENV is the registry's env, one
# NAME=value per line; the mount listing is empty so nothing is connected or repaired.
case "$1" in
  ps) printf 'mini-baas-adapter-registry-go\nmini-baas-postgres\n' ;;
  inspect) printf '%s\n' "$CONTAINER_ENV" ;;
  exec) exit 0 ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/python3"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

run_check() { CONTAINER_ENV="$1" run bash "$ROOT/scripts/reencrypt-mounts.sh" --check; }

@test "the token under its container-side name INTERNAL_SERVICE_TOKEN is accepted" {
  run_check 'SERVICE_TOKEN_MODE=hmac
INTERNAL_SERVICE_TOKEN=dummy-token
INTERNAL_SERVICE_TOKEN_PREV='
  [ "$status" -eq 0 ]
  [[ "$output" == *"mounts open under the current key"* ]]
}

@test "the host-side name ADAPTER_REGISTRY_SERVICE_TOKEN still works (monolith shape)" {
  run_check 'ADAPTER_REGISTRY_SERVICE_TOKEN=dummy-token'
  [ "$status" -eq 0 ]
}

@test "a registry exposing neither name fails loudly, not vacuously" {
  run_check 'SERVICE_TOKEN_MODE=hmac'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no adapter-registry service token"* ]]
}
