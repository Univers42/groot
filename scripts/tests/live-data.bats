#!/usr/bin/env bats
# ensure-live-data-access.sh issues the osionos tenant API key. On a stack where nothing was
# restored the tenant does not exist: in LOCAL mode that is a notice and exit 0 (the live
# mounts stay 503 until data arrives), outside LOCAL mode it is still the failure it was.
# docker, curl and grobase's service-auth.sh are stubs.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/live-data.bats

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts/lib" "$ROOT/apps/grobase/scripts/lib" "$ROOT/apps/osionos/app" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../ensure-live-data-access.sh" "$ROOT/scripts/"
  cp "$BATS_TEST_DIRNAME/../lib/envfile.sh" "$ROOT/scripts/lib/"
  printf 'svc_auth() { SVC_AUTH=(-H "X-Service-Auth: stub"); }\n' >"$ROOT/apps/grobase/scripts/lib/service-auth.sh"
  export ENV_LOCAL="$ROOT/.env.local" APP_ENV="$ROOT/apps/osionos/app/.env" SERVICE_TOKEN=stub
  export LOCAL_MODE_MARK="$ROOT/.vault42-local-mode"
  printf 'OSIONOS_BAAS_API_KEY=\n' >"$ENV_LOCAL"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
ps) printf 'mini-baas-tenant-control\nmini-baas-postgres\n' ;;
*) exit 1 ;;
esac
STUB
  # The control plane answers the key issue as it does for a tenant that was never created.
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in
*/v1/tenants/*/keys*) printf '{"error":"validation_error","message":"tenant not found","statusCode":400}' ;;
*) printf '' ;;
esac
STUB
  # The script requires python3 on PATH (it only uses it on the re-stamp path, never reached here).
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/curl" "$BATS_TEST_TMPDIR/bin/python3"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "LOCAL mode with no tenant: notice, exit 0, nothing written, names the seed and the pull" {
  touch "$LOCAL_MODE_MARK"
  run bash "$ROOT/scripts/ensure-live-data-access.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tenant 'agency' does not exist"*"LOCAL mode"* ]]
  [[ "$output" == *"make seed-live-demo"* ]]
  [[ "$output" == *"make vault42-pull-all APPLY=1"* ]]
  [ "$(cat "$ENV_LOCAL")" = "OSIONOS_BAAS_API_KEY=" ]
  [ ! -e "$APP_ENV" ]
}

@test "outside LOCAL mode a missing tenant is still a failure" {
  run bash "$ROOT/scripts/ensure-live-data-access.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"key issue failed"*"tenant not found"* ]]
}
