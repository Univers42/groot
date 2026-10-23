#!/usr/bin/env bats
# check-runtime.sh is verify.sh's runtime assertion (K11/R1): exit 0 when the isolated daemon's
# default runtime and the probe box both run OSIONOS_IDE_REQUIRE_RUNTIME, 1 when either differs or
# cannot be read, 3 (a skip) when the variable is unset. A fake docker answers `info` and
# `inspect` from DEFAULT_RUNTIME and BOX_RUNTIME ("-" makes the call fail). Every assertion reads
# `status` and `output` from `run`, so none is a bare negation.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SCRIPT="$REPO/infrastructure/docker/osionos/ide-sandbox/check-runtime.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat > "$BIN/docker" <<'FAKE'
#!/bin/sh
case "$1" in
  info) [ "$DEFAULT_RUNTIME" = - ] && exit 1; echo "$DEFAULT_RUNTIME" ;;
  inspect) [ "$BOX_RUNTIME" = - ] && exit 1; echo "$BOX_RUNTIME" ;;
esac
FAKE
  chmod +x "$BIN/docker"
  export PATH="$BIN:$PATH"
  unset OSIONOS_IDE_REQUIRE_RUNTIME || true
}

@test "unset: skip status 3, nothing asserted," {
  DEFAULT_RUNTIME=runc BOX_RUNTIME=runc run sh "$SCRIPT" ide-probe-a
  [ "$status" -eq 3 ]
  [[ "$output" == *"unset"* ]]
}

@test "default and box both runsc: pass" {
  OSIONOS_IDE_REQUIRE_RUNTIME=runsc DEFAULT_RUNTIME=runsc BOX_RUNTIME=runsc run sh "$SCRIPT" ide-probe-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"runsc"* ]]
}

@test "daemon default is runc: fail naming it" {
  OSIONOS_IDE_REQUIRE_RUNTIME=runsc DEFAULT_RUNTIME=runc BOX_RUNTIME=runsc run sh "$SCRIPT" ide-probe-a
  [ "$status" -eq 1 ]
  [[ "$output" == *"default runtime is 'runc'"* ]]
}

@test "default is runsc but the probe box runs runc: fail naming the box" {
  OSIONOS_IDE_REQUIRE_RUNTIME=runsc DEFAULT_RUNTIME=runsc BOX_RUNTIME=runc run sh "$SCRIPT" ide-probe-a
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe box ide-probe-a runs under 'runc'"* ]]
}

@test "an unreachable daemon is a failure, not a pass" {
  OSIONOS_IDE_REQUIRE_RUNTIME=runsc DEFAULT_RUNTIME=- BOX_RUNTIME=runsc run sh "$SCRIPT" ide-probe-a
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown"* ]]
}

@test "a missing probe box is a failure" {
  OSIONOS_IDE_REQUIRE_RUNTIME=runsc DEFAULT_RUNTIME=runsc BOX_RUNTIME=- run sh "$SCRIPT" ide-probe-a
  [ "$status" -eq 1 ]
}

@test "an empty runtime from the daemon is a failure" {
  OSIONOS_IDE_REQUIRE_RUNTIME=runsc DEFAULT_RUNTIME="" BOX_RUNTIME=runsc run sh "$SCRIPT" ide-probe-a
  [ "$status" -eq 1 ]
}

@test "no probe box argument is a failure" {
  OSIONOS_IDE_REQUIRE_RUNTIME=runsc DEFAULT_RUNTIME=runsc BOX_RUNTIME=runsc run sh "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "verify.sh maps exit 0 to PASS, 3 to SKIP and anything else to FAIL, and counts one probe" {
  VERIFY="$REPO/infrastructure/docker/osionos/ide-sandbox/verify.sh"
  run sh -n "$VERIFY"
  [ "$status" -eq 0 ]
  run grep -c 'check-runtime.sh' "$VERIFY"
  [ "$output" -eq 1 ]
  run sed -n '/Runtime assertion (K11\/R1)/,/Socket-proxy body filter/p' "$VERIFY"
  [[ "$output" == *'0) ok '* && "$output" == *'3) skip '* && "$output" == *'*) bad '* ]]
}
