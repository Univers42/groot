#!/usr/bin/env bats
# grobase-paths.sh discovers which ways THIS device reaches grobase. These tests stub
# curl and ssh in $BATS_TEST_TMPDIR/bin and drive them with env vars. No real network.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-paths.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-paths.sh"
  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"

  # Create a dummy CA file for tests that need it
  echo "dummy ca" >"$BATS_TEST_TMPDIR/ca.pem"

  # Stub curl: records argv, prints HTTP_CODE VERIFY_RESULT from env
  cat >"$BIN_DIR/curl" <<'CURL_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
# Expect: curl -s -o /dev/null -m 8 -w '%{http_code} %{ssl_verify_result}' [--cacert CA] "URL"
# Env: CURL_HTTP_CODE (default 200), CURL_VERIFY (default 0)
printf '%s %s\n' "${CURL_HTTP_CODE:-200}" "${CURL_VERIFY:-0}"
CURL_STUB
  chmod +x "$BIN_DIR/curl"

  # Stub ssh: records argv, prints docker ps output from env or exits with code
  cat >"$BIN_DIR/ssh" <<'SSH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_LOG"
# Env: SSH_EXIT (default 0), SSH_OUTPUT (default "mini-baas-kong\nother"), SSH_STDERR
printf '%s\n' "${SSH_OUTPUT:-mini-baas-kong}"
[ -z "${SSH_STDERR:-}" ] || printf '%s\n' "$SSH_STDERR" >&2
exit "${SSH_EXIT:-0}"
SSH_STUB
  chmod +x "$BIN_DIR/ssh"

  export PATH="$BIN_DIR:$PATH"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
  unset GROBASE_CA_FILE GROBASE_TARGET GROBASE_API_URL
}

@test "URL 401 with verify 0 -> PASS, --cacert passed, path ends /auth/v1/health" {
  export CURL_HTTP_CODE=401
  export CURL_VERIFY=0
  run bash "$SCRIPT" --ca "$BATS_TEST_TMPDIR/ca.pem" https://grobase.example.ts.net:8443
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +url\ +https://grobase\.example\.ts\.net:8443 ]]
  [[ "$output" == *"1/1 paths work"* ]]
  # Check curl was called with --cacert and correct path
  grep -q -- '--cacert' "$CURL_LOG"
  grep -q "$BATS_TEST_TMPDIR/ca.pem" "$CURL_LOG"
  grep -q '/auth/v1/health' "$CURL_LOG"
}

@test "URL 000 with verify 20 -> FAIL with TLS verify failed, exit 1" {
  export CURL_HTTP_CODE=000
  export CURL_VERIFY=20
  run bash "$SCRIPT" https://bad.example.ts.net:8443
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +url\ +https://bad\.example\.ts\.net:8443 ]]
  [[ "$output" == *"TLS verify failed (code 20)"* ]]
  [[ "$output" == *"0/1 paths work"* ]]
}

@test "ssh://alice@10.0.0.7:2222 -> ssh called with user@host and -p 2222 and BatchMode=yes; stub prints mini-baas-kong -> PASS" {
  export SSH_EXIT=0
  export SSH_OUTPUT="mini-baas-kong"
  run bash "$SCRIPT" ssh://alice@10.0.0.7:2222
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +ssh\ +ssh://alice@10\.0\.0\.7:2222 ]]
  [[ "$output" == *"1/1 paths work"* ]]
  # Check ssh args
  grep -q 'alice@10.0.0.7' "$SSH_LOG"
  grep -q '\-p 2222' "$SSH_LOG"
  grep -q 'BatchMode=yes' "$SSH_LOG"
  grep -q 'ConnectTimeout=5' "$SSH_LOG"
}

@test "ssh target prints other names -> FAIL no mini-baas-kong" {
  export SSH_EXIT=0
  export SSH_OUTPUT="other-container"
  run bash "$SCRIPT" ssh://alice@10.0.0.7:2222
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +ssh\ +ssh://alice@10\.0\.0\.7:2222 ]]
  [[ "$output" == *"no mini-baas-kong running there"* ]]
  [[ "$output" == *"0/1 paths work"* ]]
}

@test "ssh stub exit 255 -> FAIL ssh refused or timed out" {
  export SSH_EXIT=255
  run bash "$SCRIPT" ssh://alice@10.0.0.7:2222
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ +ssh\ +ssh://alice@10\.0\.0\.7:2222 ]]
  [[ "$output" == *"ssh refused or timed out"* ]]
  [[ "$output" == *"0/1 paths work"* ]]
}

@test "ssh host key changed -> FAIL names the host key, not the network" {
  export SSH_EXIT=255
  export SSH_STDERR="@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@
Host key verification failed."
  run bash "$SCRIPT" ssh://alice@10.0.0.7:2222
  [ "$status" -eq 1 ]
  [[ "$output" == *"host key unknown or changed"* ]]
  [[ "$output" != *"refused or timed out"* ]]
}

@test "ssh key not accepted -> FAIL says so" {
  export SSH_EXIT=255
  export SSH_STDERR="alice@10.0.0.7: Permission denied (publickey)."
  run bash "$SCRIPT" ssh://alice@10.0.0.7:2222
  [ "$status" -eq 1 ]
  [[ "$output" == *"no key accepted"* ]]
}

@test "--ca pointing to missing file -> exit 2" {
  run bash "$SCRIPT" --ca /nonexistent/ca.pem https://example.com
  [ "$status" -eq 2 ]
  [[ "$output" == *"CA file not readable"* ]]
}

@test "no target and no config -> exit 2 naming GROBASE_TARGET/GROBASE_API_URL" {
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
  unset GROBASE_TARGET GROBASE_API_URL
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"GROBASE_TARGET"* ]] || [[ "$output" == *"GROBASE_API_URL"* ]]
}

@test "summary line 1/2 paths work with one PASS and one FAIL" {
  export CURL_HTTP_CODE=200
  export CURL_VERIFY=0
  export SSH_EXIT=255
  run bash "$SCRIPT" https://good.example.ts.net:8443 ssh://bad@host:22
  [ "$status" -eq 1 ]
  [[ "$output" =~ PASS\ +url\ +https://good\.example\.ts\.net:8443 ]]
  [[ "$output" =~ FAIL\ +ssh\ +ssh://bad@host:22 ]]
  [[ "$output" == *"ssh refused or timed out"* ]]
  [[ "$output" == *"1/2 paths work"* ]]
}

@test "http:// URL -> PASS with plaintext detail" {
  export CURL_HTTP_CODE=200
  export CURL_VERIFY=0
  run bash "$SCRIPT" http://grobase.lan:8080
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +url\ +http://grobase\.lan:8080 ]]
  [[ "$output" == *"plaintext"* ]]
  [[ "$output" == *"1/1 paths work"* ]]
}

@test "ssh alias target (no ssh:// prefix) works" {
  export SSH_EXIT=0
  export SSH_OUTPUT="mini-baas-kong"
  run bash "$SCRIPT" my-grobase-alias
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +ssh\ +my-grobase-alias ]]
  grep -q 'my-grobase-alias' "$SSH_LOG"
  grep -q 'BatchMode=yes' "$SSH_LOG"
}

@test "user@host target (no ssh:// prefix) works" {
  export SSH_EXIT=0
  export SSH_OUTPUT="mini-baas-kong"
  run bash "$SCRIPT" user@host.example.com
  [ "$status" -eq 0 ]
  [[ "$output" =~ PASS\ +ssh\ +user@host\.example\.com ]]
  grep -q 'user@host.example.com' "$SSH_LOG"
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
  [[ "$output" == *"--ca"* ]]
}