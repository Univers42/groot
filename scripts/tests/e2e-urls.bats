#!/usr/bin/env bats
# scripts/lib/e2e-urls.sh sends the browser suites to the ports host-ports.sh chose.

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib"
  PORTS="$BATS_TEST_TMPDIR/.env.ports"
  printf 'OSIONOS_APP_HOST_PORT=3004\nOPPOSITE_OSIRIS_HOST_PORT=4324\nGROBASE_TLS_HOST_PORT=8445\n' >"$PORTS"
}

urls() { run bash -c ". '$LIB/envfile.sh'; . '$LIB/e2e-urls.sh'; e2e_export_urls '$1'; env | grep '^E2E_.*_URL=' | sort"; }

@test "a moved port reaches the URL the specs read" {
  urls "$PORTS"
  [[ "$output" == *"E2E_OSIONOS_URL=https://localhost:3004"* ]]
  [[ "$output" == *"E2E_PRISMATICA_URL=https://localhost:4324"* ]]
  [[ "$output" == *"E2E_KONG_URL=https://localhost:8445"* ]]
}

@test "a name missing from the file leaves the default in env.ts" {
  urls "$PORTS"
  [[ "$output" != *"E2E_MAIL_URL"* ]]
}

@test "no file changes nothing" {
  urls "$BATS_TEST_TMPDIR/absent"
  [ -z "$output" ]
}

@test "a URL set by hand wins" {
  E2E_OSIONOS_URL=https://elsewhere:1 urls "$PORTS"
  [[ "$output" == *"E2E_OSIONOS_URL=https://elsewhere:1"* ]]
}

@test "every URL in the map is one env.ts reads, and every name a compose port" {
  repo="$BATS_TEST_DIRNAME/../.."
  # shellcheck source=/dev/null
  . "$LIB/e2e-urls.sh"
  while read -r url name; do
    grep -q "process.env.$url" "$repo/tests/e2e/lib/env.ts"
    grep -q "\${$name:-" "$repo/docker-compose.yml"
  done <<<"$E2E_URL_PORTS"
}
