#!/usr/bin/env bats
# The public overlay must not offer the IDE or any surface that frames the visitor's own
# machine. Each case sets a key in the stubbed bridge/IDE env (or the bundle scan answer) and
# reads `verify --pre`: red with the key or port named, or green. Stubs: public-funnel-helpers.bash.
# Caveat: the bundle scan is a stub answering what the in-image grep would print; the real grep
# is not exercised here.
# Assertions use `run` + status + has/lacks: a `! cmd` that is not the last line never fails.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 -c \
#   'apk add -q coreutils findutils git jq openssl && bats scripts/tests/public-verify-surfaces.bats'

bats_require_minimum_version 1.5.0

load public-funnel-helpers

@test "the bridge IDE token secret set to any value goes red, key named, value withheld" {
  echo "OSIONOS_IDE_TOKEN_SECRET=ide-HHHH-8888" >>"$T/env-bridge"
  run_pf verify --pre
  [ "$status" -ne 0 ]
  has "FAIL  bridge-env     OSIONOS_IDE_TOKEN_SECRET is set (value withheld)"
  lacks "ide-HHHH-8888"
}

@test "OSIONOS_IDE_ACCESS verified or approved on the bridge goes red, key and mode named" {
  for mode in verified approved; do
    printf 'OSIONOS_IDE_ACCESS=%s\n' "$mode" >>"$T/env-bridge"
    run_pf verify --pre
    [ "$status" -ne 0 ]
    has "FAIL  ide-access     osionos-bridge: OSIONOS_IDE_ACCESS=$mode, expected unset, allowlist or off"
    sed -i '/^OSIONOS_IDE_ACCESS=/d' "$T/env-bridge"
  done
}

@test "OSIONOS_IDE_ACCESS allowlist, off or empty passes" {
  for mode in allowlist off ""; do
    printf 'OSIONOS_IDE_ACCESS=%s\n' "$mode" >>"$T/env-bridge"
    run_pf verify --pre
    [ "$status" -eq 0 ]
    has "PASS  ide-access     osionos-bridge: OSIONOS_IDE_ACCESS="
    sed -i '/^OSIONOS_IDE_ACCESS=/d' "$T/env-bridge"
  done
}

@test "a running IDE server with a verified mode goes red; with off it passes" {
  printf 'OSIONOS_IDE_ACCESS=verified\n' >"$T/env-ide"
  run_pf verify --pre
  [ "$status" -ne 0 ]
  has "FAIL  ide-access     osionos-ide-server: OSIONOS_IDE_ACCESS=verified, expected unset, allowlist or off"
  printf 'OSIONOS_IDE_ACCESS=off\n' >"$T/env-ide"
  run_pf verify --pre
  [ "$status" -eq 0 ]
  has "PASS  ide-access     osionos-ide-server: OSIONOS_IDE_ACCESS=off"
}

@test "no IDE server running passes and says so" {
  run_pf verify --pre
  [ "$status" -eq 0 ]
  has "PASS  ide-access     no osionos-ide-server runs in this project"
}

@test "a bundle with localhost links goes red, listing each distinct port" {
  export LINK_OUT=$'2\nlocalhost:3002\nlocalhost:3007'
  run_pf verify --pre
  [ "$status" -ne 0 ]
  has "FAIL  bundle-links   2 file(s) in track-binocle/osionos-web:public link to localhost:3002 localhost:3007"
}

@test "a clean bundle passes the link check" {
  run_pf verify --pre
  [ "$status" -eq 0 ]
  has "PASS  bundle-links   0 files in track-binocle/osionos-web:public link to localhost"
}

@test "an unscannable bundle fails the link check" {
  export LINK_OUT=""
  run_pf verify --pre
  [ "$status" -ne 0 ]
  has "FAIL  bundle-links   could not be scanned in track-binocle/osionos-web:public"
}

@test "the public overlay points the mail and calendar tabs at the apps origins (empty when unset) and empties whiteboard and IDE" {
  overlay="$BATS_TEST_DIRNAME/../../docker-compose.public.yml"
  grep -qE '^ +VITE_MAIL_APP_URL: \$\{PUBLIC_MAIL_ORIGIN:-\}$' "$overlay"
  grep -qE '^ +VITE_CALENDAR_APP_URL: \$\{PUBLIC_CALENDAR_ORIGIN:-\}$' "$overlay"
  for key in VITE_WHITEBOARD_APP_URL VITE_OSIONOS_IDE_URL OSIONOS_IDE_TOKEN_SECRET OSIONOS_IDE_ACCESS; do
    grep -qE "^ +$key: \"\"$" "$overlay" || { echo "overlay does not empty $key" >&2; return 1; }
  done
}

@test "osionos :3001 sending both anti-framing headers on every probed path passes" {
  run_pf verify --pre
  [ "$status" -eq 0 ]
  has "PASS  frame-headers  osionos :3001 sends X-Frame-Options DENY and frame-ancestors 'none'"
}

@test "a /storage/v1 response without X-Frame-Options goes red, the path named" {
  printf 'HTTP/2 200\r\ncontent-security-policy: frame-ancestors %s\r\n\r\n' "'none'" >"$T/hdr-3001-storage"
  run_pf verify --pre
  [ "$status" -ne 0 ]
  [[ "$out" == *"FAIL  frame-headers"*"/storage/v1/object/public/x"* ]]
}

@test "frame-ancestors 'self' is not accepted" {
  printf 'HTTP/2 200\r\nx-frame-options: DENY\r\ncontent-security-policy: frame-ancestors %s\r\n\r\n' "'self'" >"$T/hdr-3001"
  run_pf verify --pre
  [ "$status" -ne 0 ]
  [[ "$out" == *"FAIL  frame-headers"* ]]
}
