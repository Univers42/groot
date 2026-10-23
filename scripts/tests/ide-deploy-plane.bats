#!/usr/bin/env bats
# deploy-plane.sh ships the ide-socket-proxy + osionos-bridge images from the
# BUILD machine's main daemon into the VM's MAIN daemon (docker save | ssh …
# docker load, layer-checked), then brings the `ide` profile up there over the
# ssh transport, pinning each VM container to the shipped image id. It never
# prints the token secret (it only confirms the env file carries one), never
# removes an image, and never touches a container outside project
# osionos-ide-plane. check-plane.sh is its read-only placement proof: one
# ok|FAIL line per risk condition C1/C2/C4/C6/C7/C8/C10/C21, then a RESULT tally.
# The fakes exercise the same remote-quoting discipline as ide-ship-images.bats:
# the fake ssh runs commands against the fake docker (exporting DOCKER_REMOTE, or
# left to the sh -c it execs); the fake docker treats a call as VM-side when
# DOCKER_REMOTE is set or DOCKER_HOST is an ssh:// URL.

SECRET='ide-token-fixture-9f2b7c1d4e6a80-do-not-echo'
PIN="sha256:$(printf 'a%.0s' $(seq 1 64))"

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  ENV_FILE="$BATS_TEST_TMPDIR/env.file"
  mkdir -p "$BIN"
  : > "$CALLS"
  unset IDE_SHIP_HOST OSIONOS_IDE_ENV_FILE || true
  # The fakes read $CALLS from the environment (exported here), everything else
  # from a scenario variable the test sets as a command prefix.
  export CALLS

  cat > "$BIN/docker" <<'FAKE'
#!/bin/sh
# Fake docker for deploy-plane / check-plane. A call targets the VM when the fake
# ssh exported DOCKER_REMOTE (deploy's ssh load/inspect) or when DOCKER_HOST is an
# ssh:// URL (check-plane's d() wrapper, deploy's compose); otherwise it is the
# local build daemon. Scenario knobs: MISSING (images absent locally), VM_ABSENT
# (images the VM lacks until a load brings them), RUN_RC (the busybox run's status),
# LAYERS_MISMATCH (images whose VM RootFS.Layers differ), PROXY_/SERVER_* (the two
# plane containers' inspect fields, plus *_PB/*_NP PortBindings/Ports JSON),
# CTRL_SUBNET/EDGE_SUBNET (plane network subnets), HOSTNET (ids using host net),
# RUN_REACH=1 (the mini-baas box CAN dial the plane), HOST_REACH=0 (host cannot).
daemon=main
[ -n "${DOCKER_REMOTE:-}" ] && daemon=vm
case "${DOCKER_HOST:-}" in ssh://*) daemon=vm ;; esac
echo "$daemon $*" >> "$CALLS"
case " $* " in
  *" compose "*) printf 'compose-env DOCKER_HOST=%s OSIONOS_BRIDGE_IMAGE=%s OSIONOS_IDE_SOCKET_PROXY_IMAGE=%s OSIONOS_IDE_DOCKER_GID=%s\n' "${DOCKER_HOST:-}" "${OSIONOS_BRIDGE_IMAGE:-}" "${OSIONOS_IDE_SOCKET_PROXY_IMAGE:-}" "${OSIONOS_IDE_DOCKER_GID:-}" >> "$CALLS" ;;
esac

if [ "$1" = image ] && [ "$2" = inspect ]; then
  fmt=''; img=$3
  [ "$3" = -f ] && { fmt=$4; img=$5; }
  if [ "$daemon" = main ]; then case " ${MISSING:-} " in *" $img "*) exit 1 ;; esac; fi
  if [ "$daemon" = vm ]; then
    case " ${VM_ABSENT:-} " in *" $img "*) grep -qxF "$img" "$CALLS.loaded" 2>/dev/null || exit 1 ;; esac
  fi
  case "$fmt" in
    *RootFS.Layers*)
      # The config the way each daemon prints it: the whole object differs between the
      # build machine (Docker 28.1 prints zero-value fields) and the VM (29.9 omits them),
      # field by field it is identical unless CONFIG_MISMATCH names the image.
      case "$fmt" in
        *'{{json .Config}}'*)
          if [ "$daemon" = main ]; then printf '{"Cmd":["node"],"Tty":false,"Labels":null} '; else printf '{"Cmd":["node"]} '; fi ;;
        *'.Config.Cmd'*)
          cmd='["node"]'
          if [ "$daemon" = vm ]; then case " ${CONFIG_MISMATCH:-} " in *" $img "*) cmd='["sh"]' ;; esac; fi
          printf '%s ' "$cmd" ;;
      esac
      if [ "$daemon" = vm ]; then case " ${LAYERS_MISMATCH:-} " in *" $img "*) echo '["sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"]'; exit 0 ;; esac; fi
      echo '["sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]'
      ;;
    *.Id*)
      case "$img" in
        *socket-proxy*) echo 'sha256:1111111111111111111111111111111111111111111111111111111111111111' ;;
        *bridge*) echo 'sha256:2222222222222222222222222222222222222222222222222222222222222222' ;;
        *) echo 'sha256:3333333333333333333333333333333333333333333333333333333333333333' ;;
      esac
      ;;
  esac
  exit 0
fi

if [ "$1" = ps ]; then
  case " $* " in
    *" label=com.docker.compose.service=osionos-ide-socket-proxy"*) printf '%s\n' "${PROXY_CID:-proxy0}" ;;
    *" label=com.docker.compose.service=osionos-ide-server"*) printf '%s\n' "${SERVER_CID:-server0}" ;;
    *" network=host "*) [ -n "${HOSTNET:-}" ] && echo "$HOSTNET" ;;
  esac
  exit 0
fi

if [ "$1" = network ] && [ "$2" = inspect ]; then
  case "$*" in *Containers*) echo "${PLANE_MEMBERS-plane-proxy plane-server}"; exit 0 ;; esac
  case " $3 " in
    *control-net*) echo "${CTRL_SUBNET:-172.19.0.0/16}" ;;
    *edge-net*) echo "${EDGE_SUBNET:-172.20.0.0/16}" ;;
    *) echo "172.21.0.0/16" ;;
  esac
  exit 0
fi

if [ "$1" = inspect ]; then
  if [ "$2" = -f ]; then fmt=$3; cid=$4; else cid=$2; fmt=''; fi
  case "$cid" in *proxy*) role=proxy ;; *) role=server ;; esac
  case "$fmt" in
    *'{{.Image}}'*) [ "$role" = proxy ] && echo 'sha256:1111111111111111111111111111111111111111111111111111111111111111' || echo 'sha256:2222222222222222222222222222222222222222222222222222222222222222' ;;
    *HostConfig.Memory*) [ "$role" = proxy ] && echo "${PROXY_MEM:-134217728}" || echo "${SERVER_MEM:-402653184}" ;;
    *HostConfig.PidsLimit*) [ "$role" = proxy ] && echo "${PROXY_PIDS:-128}" || echo "${SERVER_PIDS:-256}" ;;
    *.HostConfig.PortBindings*) [ "$role" = proxy ] && echo "${PROXY_PB:-{}}" || echo "${SERVER_PB:-{}}" ;;
    *.NetworkSettings.Ports*) [ "$role" = proxy ] && echo "${PROXY_NP:-{}}" || echo "${SERVER_NP:-{}}" ;;
    *'{{.Name}}'*) printf '/plane-proxy\n/plane-server\n' ;;
    *'{{.IPAddress}}: '*) echo "${PROXY_CTRL_IP:-172.19.0.7}: ${SERVER_CTRL_IP:-172.19.0.8}:" ;;
    *.NetworkSettings.Networks*) [ "$role" = proxy ] && echo "${PROXY_CTRL_IP:-172.19.0.7}" || echo "${SERVER_CTRL_IP:-172.19.0.8}" ;;
  esac
  exit 0
fi

if [ "$1" = run ]; then
  case " $* " in *busybox*) [ "${RUN_REACH:-0}" = 1 ] && exit 0; exit "${RUN_RC:-1}" ;; esac
  exit 0
fi

case "$daemon $1" in
  "main save") echo "tarball of $2" ;;
  "vm load") read -r line; cat >/dev/null; printf '%s\n' "${line#tarball of }" >> "$CALLS.loaded"; echo "Loaded image: ${line#tarball of }" ;;
esac
exit 0
FAKE
  chmod +x "$BIN/docker"

  cat > "$BIN/ssh" <<'FAKE'
#!/bin/sh
# Fake ssh: drops the host arg and joins the rest into one remote-shell command.
# Host-level probes (the C2 grep, the C6 positive control, the C7 operator/group)
# are answered directly so no real VM state is touched; anything else is routed
# through the fake docker on PATH with DOCKER_REMOTE set (deploy's load / vm()).
shift
echo "ssh $*" >> "$CALLS"
case " $* " in
  *"grep -rlF"*)
    cat >/dev/null
    if [ -n "${C2_FILES:-}" ]; then printf '%s\n' "$C2_FILES"; exit 0; fi
    # C2_STDERR: what grep says on stderr (an unreadable path), one line per entry.
    [ -z "${C2_STDERR:-}" ] || printf '%s\n' "$C2_STDERR" >&2
    exit "${C2_RC:-1}"
    ;;
  *"stat -c %g /run/docker-ide.sock"*) printf '%s\n' "${IDE_SOCK_GID-1002}" ;;
  *"command -v nc"*) exit 0 ;;
  *"nc -z -w 3"*) [ "${HOST_REACH:-1}" = 0 ] && exit 1; exit 0 ;;
  *"id -un"*) printf '%s\n' "${OPERATOR:-oper}" ;;
  *"getent group docker"*) printf '%s\n' "${DOCKER_GROUP:-docker:x:998:oper}" ;;
  *"tailscale serve status"*)
    [ "${TS_RC:-0}" = 0 ] || exit "$TS_RC"
    ts_default='{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"https+insecure://127.0.0.1:8443"}}}}}'
    printf '%s\n' "${TS_JSON:-$ts_default}"
    ;;
  *) export DOCKER_REMOTE=1; exec sh -c "$*" ;;
esac
FAKE
  chmod +x "$BIN/ssh"
  PATH="$BIN:$PATH"
}

write_env() { printf '%s\n' "$@" > "$ENV_FILE"; }
deploy() { run sh "$REPO/infrastructure/docker/osionos/ide-sandbox/deploy-plane.sh"; }
check()  { run sh "$REPO/infrastructure/docker/osionos/ide-sandbox/check-plane.sh"; }
valid_env() { write_env "OSIONOS_IDE_TOKEN_SECRET=$SECRET" "OSIONOS_IDE_SANDBOX_IMAGE=$PIN"; }
BOTH='osionos-ide-socket-proxy:latest track-binocle/osionos-bridge:local'

# ---------------------------------------------------------------- deploy-plane
@test "IDE_SHIP_HOST unset refuses before any docker call" {
  valid_env
  deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *IDE_SHIP_HOST* ]]
  [ ! -s "$CALLS" ]
}

@test "secret absent or empty refuses, keeps the secret out of the log, no save/load" {
  write_env "OSIONOS_IDE_TOKEN_SECRET=" "OSIONOS_IDE_SANDBOX_IMAGE=$PIN"
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" deploy
  [ "$status" -ne 0 ]
  [[ "$output" != *"$SECRET"* ]]
  run grep -E 'save|load' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "a sandbox image that is not a sha256 pin is refused before anything ships" {
  write_env "OSIONOS_IDE_TOKEN_SECRET=$SECRET" "OSIONOS_IDE_SANDBOX_IMAGE=osionos-ide-sandbox:latest"
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"OSIONOS_IDE_SANDBOX_IMAGE"* ]]
  run grep -E 'save|load' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "differing layers between the machines stop the deploy, naming the image, no compose" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" VM_ABSENT="$BOTH" LAYERS_MISMATCH=osionos-ide-socket-proxy:latest deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *osionos-ide-socket-proxy:latest* ]]
  run grep -E 'compose' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "happy path ships both, pins the VM containers to the shipped ids, prints deployed" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" VM_ABSENT="$BOTH" deploy
  [ "$status" -eq 0 ]
  grep -qx 'main save osionos-ide-socket-proxy:latest' "$CALLS"
  grep -qx 'main save track-binocle/osionos-bridge:local' "$CALLS"
  grep -q 'OSIONOS_IDE_DOCKER_GID=1002$' "$CALLS"
  [[ "$output" == *"deployed: socket-proxy sha256:1111111111111111111111111111111111111111111111111111111111111111 ide-server sha256:2222222222222222222222222222222222222222222222222222222222222222"* ]]
  grep -q -- '-p osionos-ide-plane' "$CALLS"
  grep -q -- '--no-build' "$CALLS"
  grep -q -- '--pull never' "$CALLS"
  grep -q -- '--wait' "$CALLS"
  grep -q 'osionos-ide-socket-proxy osionos-ide-server' "$CALLS"
  grep -q 'DOCKER_HOST=ssh://vm' "$CALLS"
  grep -q 'OSIONOS_BRIDGE_IMAGE=sha256:2222222222222222222222222222222222222222222222222222222222222222' "$CALLS"
  grep -q 'OSIONOS_IDE_SOCKET_PROXY_IMAGE=sha256:1111111111111111111111111111111111111111111111111111111111111111' "$CALLS"
  run grep -E 'rmi|sudo|(^| )down( |$)' "$CALLS"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$SECRET"* ]]
  run grep -F "$SECRET" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "a config field that differs on the VM stops the deploy, naming the image, no compose" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" VM_ABSENT="$BOTH" CONFIG_MISMATCH=track-binocle/osionos-bridge:local deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *track-binocle/osionos-bridge:local* ]]
  run grep -E 'compose' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "the same image printed by Docker 28 and 29 compares equal: shipped, deployed, C1 ok" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" VM_ABSENT="$BOTH" deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"deployed: socket-proxy"* ]]
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" check
  [[ "$output" == *"ok C1 "* ]]
}

@test "an image the VM already holds under the same id is not shipped again" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"not shipped again"* ]]
  [[ "$output" == *"deployed: socket-proxy sha256:1111"* ]]
  run grep -E ' (save|load)( |$)' "$CALLS"
  [ "$status" -eq 1 ]
  grep -q -- '--wait' "$CALLS"
}

@test "a docker-ide socket owned by root, or unreadable, stops before anything ships" {
  valid_env
  for gid in 0 '' docker; do
    : > "$CALLS"
    IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" IDE_SOCK_GID="$gid" VM_ABSENT="$BOTH" deploy
    [ "$status" -ne 0 ]
    [[ "$output" == *install-docker-ide.sh* ]]
    run grep -E ' (save|load|compose)( |$)' "$CALLS"
    [ "$status" -eq 1 ]
  done
}

# ----------------------------------------------------------------- check-plane
@test "an all-good placement reports 8 ok, 0 failed and exits 0" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: 8 ok, 0 failed"* ]]
  [[ "$output" != *"$SECRET"* ]]
}

@test "a plane container whose image differs from the local one fails C1" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" \
    LAYERS_MISMATCH=sha256:2222222222222222222222222222222222222222222222222222222222222222 check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C1"* ]]
}

@test "a host port binding on the ide-server fails C10 and exits 1" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" \
    SERVER_PB='{"4100/tcp":[{"HostIp":"127.0.0.1","HostPort":"8446"}]}' check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C10"* ]]
}

@test "C2 decides when every grep error is a path the operator may not read" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" C2_RC=2 \
    C2_STDERR="grep: /home/oper/data/mariadb/mysql: Permission denied
grep: /home/oper/data/wordpress/wp-config.php: Permission denied" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok C2 token-secret-in-no-home-file (2 path(s) the operator may not read: not searched)"* ]]
}

@test "C2 stays undecided when grep fails for another reason" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" C2_RC=2 \
    C2_STDERR="grep: /home/oper/x: Input/output error" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C2 token-secret-in-no-home-file:cannot-decide(grep rc=2)"* ]]
}

@test "a token secret found in a VM home file fails C2, naming the file, exits 1" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" C2_FILES='/home/oper/.bash_history' check
  [ "$status" -eq 1 ]
  [[ "$output" == *"/home/oper/.bash_history"* ]]
  [[ "$output" == *"FAIL C2"* ]]
}

@test "a box run docker itself refused (rc 125) is undecided, never unreachable" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" RUN_RC=125 check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C6"*"cannot-decide(box run rc=125)"* ]]
}

@test "a C2 grep that exited 2 and said nothing on stderr is undecided" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" C2_RC=2 check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C2"*"cannot-decide(grep rc=2)"* ]]
  [[ "$output" != *"$SECRET"* ]]
}

@test "a tailscale serve target on the ide-server port fails C21" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" \
    TS_JSON='{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://osionos-ide-server:4100"}}}}}' check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C21 exposed: serve->:4100"* ]]
}

@test "a serve target at a plane container address fails C21" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" \
    TS_JSON='{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://172.19.0.8:80"}}}}}' check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C21 exposed: serve->172.19.0.8:"* ]]
}

@test "a third container on a plane network fails C21, naming it" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" PLANE_MEMBERS='plane-proxy ts-sidecar plane-server' check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C21 exposed: extra-on-plane-net:ts-sidecar"* ]]
}

@test "an unreadable tailscale status is undecided, never a pass" {
  valid_env
  IDE_SHIP_HOST=vm OSIONOS_IDE_ENV_FILE="$ENV_FILE" TS_RC=1 check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL C21 cannot-decide"* ]]
}
