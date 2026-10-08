#!/usr/bin/env bats
# account-roundtrip.sh proves persistence against the live stack, so its own logic must be
# right before its verdict is trusted: an account the gateway rejects, a psql run on the
# wrong host or a token leaked into a detail line would each make the proof lie. These
# tests source the script (its main steps aside when sourced) and cover the pure helpers
# only: credential generation, the link mode -> psql argv plan (stub state file), the edge
# port discovery (stub docker on PATH) and the line format. No network, no docker.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/account-roundtrip.bats
# The bats image has no jq, so the one test of jq-parsed bodies skips there and says so.

# shellcheck disable=SC2016 # helper's code runs in the sourcing bash: its $ must not expand here

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../verify/account-roundtrip.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  mkdir -p "$GROBASE_LINK_DIR" "$BATS_TEST_TMPDIR/bin"
  # Keep this machine's ./.env.grobase-link and live link state out of every test.
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
  unset OPPOSITE_OSIRIS_HOST_PORT RT_SSH_TIMEOUT
  INNER="docker exec -i mini-baas-postgres psql -U postgres -d postgres -X -q -tA -v ON_ERROR_STOP=1 -v email=a@b.test"
}

# Runs shell code in a bash that sourced the script, so its functions are callable.
helper() { run bash -c "source '$SCRIPT' && $1"; }
link_state() { printf '%s\n' "$@" >"$GROBASE_LINK_DIR/state"; }
# A docker that answers `compose port` with $1 (empty = fails like a stopped edge) and logs
# its argv, so edge_port is tested without a daemon.
stub_docker() {
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/docker.argv"\n[ -n "%s" ] || exit 1\necho "%s"\n' \
    "$BATS_TEST_TMPDIR" "$1" "$1" >"$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "rt_line: the verdict is padded to four columns, two spaces before the detail" {
  helper 'rt_line ok edge "two words"; rt_line FAIL db x; rt_line SKIP db "direct link"'
  [ "$status" -eq 0 ]
  [ "$output" = $'ok   edge  two words\nFAIL db  x\nSKIP db  direct link' ]
}

@test "report: only a FAIL line marks the run failed; SKIP does not" {
  helper 'report ok a b; report SKIP c d; echo "FAILED=$FAILED"; report FAIL e f; echo "FAILED=$FAILED"'
  [ "$output" = $'ok   a  b\nSKIP c  d\nFAILED=0\nFAIL e  f\nFAILED=1' ]
}

@test "fail: prints the FAIL line and stops the run with exit 1" {
  helper 'fail login "HTTP 401 bad credentials"; echo reached'
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL login  HTTP 401 bad credentials" ]
}

@test "rt_identity: the largest epoch and pid still give an allowlisted email and a valid username" {
  helper 'rt_identity 9999999999 4194304'
  read -r email user <<<"$output"
  [[ $email =~ ^roundtrip-9999999999-4194304@example\.test$ ]]
  # USERNAME_REGEX, auth-gateway.mjs:90: ^\w[\w.-]{2,31}$
  [[ $user =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$ ]]
}

@test "rt_password: 200 passwords all meet PASSWORD_REGEX (auth-gateway.mjs:89) and differ" {
  helper 'for i in $(seq 200); do rt_password; done'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 200 ]
  for pw in "${lines[@]}"; do
    [ "${#pw}" -ge 8 ]
    [[ $pw =~ [a-z] && $pw =~ [A-Z] && $pw =~ [0-9] && $pw =~ [^A-Za-z0-9] ]]
  done
  [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq 200 ]
}

@test "rt_sh_join: a remote sh gets back every word, quotes, globs and blanks included" {
  run bash -c 'source "$1" && sh -c "$(rt_sh_join printf "<%s>" a "b c" "it'"'"'s" "*" "\$HOME" "")"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "<a><b c><it's><*><\$HOME><>" ]
}

@test "rt_psql_plan: local link and no link both docker exec psql on this daemon" {
  link_state mode=local target=local
  helper 'rt_psql_plan -v email=a@b.test; echo "$DB_MODE"; echo "${PSQL[*]}"'
  [ "$output" = "local"$'\n'"$INNER" ]
  rm "$GROBASE_LINK_DIR/state"
  helper 'rt_psql_plan -v email=a@b.test; echo "$DB_MODE"; echo "${PSQL[*]}"'
  [ "$output" = "local"$'\n'"$INNER" ]
}

@test "rt_psql_plan: ssh link runs the same psql through ssh, as one quoted remote command" {
  link_state mode=ssh target=ssh://alice@box:2222
  helper 'RT_SSH_TIMEOUT=7; rt_psql_plan -v email=a@b.test; echo "$DB_MODE"
    echo "${PSQL[*]:0:${#PSQL[@]}-1}"; eval "set -- ${PSQL[-1]}"; echo "$*"'
  [ "${lines[0]}" = ssh ]
  [ "${lines[1]}" = "ssh -o BatchMode=yes -o ClearAllForwardings=yes -o LogLevel=ERROR -o ConnectTimeout=7 alice@box -p 2222" ]
  [ "${lines[2]}" = "$INNER" ]
}

@test "rt_psql_plan: an ssh alias target is passed to ssh as is" {
  link_state mode=ssh target=ssh://gro-vm
  helper 'rt_psql_plan; echo "${PSQL[*]:0:${#PSQL[@]}-1}"'
  [ "$output" = "ssh -o BatchMode=yes -o ClearAllForwardings=yes -o LogLevel=ERROR -o ConnectTimeout=10 gro-vm" ]
}

@test "rt_psql_plan: direct, an ssh link without target and an unknown mode plan no psql" {
  link_state mode=direct target=https://kong.example
  helper 'rt_psql_plan; echo "$DB_MODE ${#PSQL[@]}"'
  [ "$output" = "direct 0" ]
  link_state mode=ssh
  helper 'rt_psql_plan; echo "$DB_MODE ${#PSQL[@]}"'
  [ "$output" = "ssh 0" ]
  link_state mode=carrier-pigeon target=x
  helper 'rt_psql_plan; echo "$DB_MODE ${#PSQL[@]}"'
  [ "$output" = "carrier-pigeon 0" ]
}

@test "edge_port: compose's wildcard bind is reached on 127.0.0.1 under the certificate's name" {
  stub_docker 0.0.0.0:14322
  helper 'edge_port 4322 OPPOSITE_OSIRIS_HOST_PORT P; echo "$P ${RESOLVE[*]}"'
  [ "$output" = "14322 --resolve localhost:14322:127.0.0.1" ]
  grep -qx "compose -f .*/docker-compose.yml port local-https-proxy 4322" "$BATS_TEST_TMPDIR/docker.argv"
}

@test "edge_port: a bind to a specific address keeps that address; [::] counts as a wildcard" {
  stub_docker 192.168.7.5:14000
  helper 'edge_port 4000 OSIONOS_BRIDGE_HOST_PORT P; echo "${RESOLVE[*]}"'
  [ "$output" = "--resolve localhost:14000:192.168.7.5" ]
  stub_docker '[::]:14000'
  helper 'edge_port 4000 OSIONOS_BRIDGE_HOST_PORT P; echo "${RESOLVE[*]}"'
  [ "$output" = "--resolve localhost:14000:127.0.0.1" ]
}

@test "edge_port: without compose's answer, the compose variable, then the container port" {
  stub_docker ""
  run env OPPOSITE_OSIRIS_HOST_PORT=5555 bash -c "source '$SCRIPT' && edge_port 4322 OPPOSITE_OSIRIS_HOST_PORT P && echo \"\$P \${RESOLVE[*]}\""
  [ "$output" = "5555 --resolve localhost:5555:127.0.0.1" ]
  helper 'edge_port 4322 OPPOSITE_OSIRIS_HOST_PORT P; echo "$P"'
  [ "$output" = 4322 ]
}

# Runs said on a response body and a curl error, as request leaves them in $TMP.
said_on() {
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/resp"
  printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/curl.err"
  helper "TMP='$BATS_TEST_TMPDIR'; said"
}

@test "said: a body without message or error never reaches the detail line, curl's error does" {
  said_on '{"access_token":"tok-must-not-print","refresh_token":"r"}' "curl: (28) timed out"
  [ "$output" = "curl: (28) timed out" ]
  said_on 'not json, maybe a token' ""
  [ "$output" = "" ]
}

@test "said: the server's message, else its error, cut to 160 bytes" {
  command -v jq >/dev/null || skip "jq is not installed here (bats/bats:1.11.1 lacks it)"
  said_on '{"message":"Account created","error":"x"}' "curl: (28) timed out"
  [ "$output" = "Account created" ]
  said_on '{"error":"rate limited"}' ""
  [ "$output" = "rate limited" ]
  said_on "{\"message\":\"$(printf 'm%.0s' $(seq 300))\"}" ""
  [ "${#output}" -eq 160 ]
}
