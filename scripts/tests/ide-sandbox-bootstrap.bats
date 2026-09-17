#!/usr/bin/env bats
# bootstrap.sh seeds the IDE sandbox images from the main daemon into docker-ide. Only
# docker-ide runs the sandbox image, so after a confirmed load the main daemon's copy (the
# largest image on the machine) is removed. The egress image stays: verify.sh runs its
# selfcheck on the main daemon. A fake docker records every call.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BIN"
  : > "$CALLS"
  cat > "$BIN/docker" <<FAKE
#!/bin/sh
# Fake docker. "-H <sock>" marks a docker-ide call. MISSING: images absent from the main
# daemon. LOAD_FAIL=1: docker-ide rejects the load. RM_FAIL=1: the main daemon refuses the rm.
daemon=main
if [ "\$1" = -H ]; then daemon=ide; shift 2; fi
echo "\$daemon \$*" >> "$CALLS"
case "\$daemon \$1 \$2" in
  "main image inspect") case " \${MISSING:-} " in *" \$3 "*) exit 1 ;; esac ;;
  "main save "*) echo "tarball of \$2" ;;
  "ide load "*) cat >/dev/null; [ "\${LOAD_FAIL:-0}" = 1 ] && exit 1 ;;
  "ide network inspect") exit 1 ;;
  "main image rm") [ "\${RM_FAIL:-0}" = 1 ] && { echo "conflict: image is in use" >&2; exit 1; } ;;
esac
exit 0
FAKE
  chmod +x "$BIN/docker"
  PATH="$BIN:$PATH"
}

bootstrap() {
  run sh "$REPO/infrastructure/docker/osionos/ide-sandbox/bootstrap.sh"
}

@test "seeds both images, then drops only the main daemon's sandbox copy" {
  bootstrap
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ide load' "$CALLS")" -eq 2 ]
  grep -qx 'main image rm osionos-ide-sandbox:latest' "$CALLS"
  run grep -E '^main image rm .*egress' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "the main copy is removed only after docker-ide confirms it has the image" {
  bootstrap
  inspect=$(grep -n '^ide image inspect osionos-ide-sandbox:latest' "$CALLS" | cut -d: -f1)
  remove=$(grep -n '^main image rm' "$CALLS" | cut -d: -f1)
  [ -n "$inspect" ] && [ -n "$remove" ] && [ "$inspect" -lt "$remove" ]
}

@test "OSIONOS_IDE_KEEP_MAIN_COPY=1 keeps the main daemon's sandbox image" {
  OSIONOS_IDE_KEEP_MAIN_COPY=1 bootstrap
  [ "$status" -eq 0 ]
  run grep '^main image rm' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "a sandbox image missing from the main daemon stops before any load, naming the fix" {
  MISSING=osionos-ide-sandbox:latest bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker build -t osionos-ide-sandbox:latest"* ]]
  run grep '^ide load' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "a refused rm of the main copy still finishes the setup and says what was kept" {
  RM_FAIL=1 bootstrap
  [ "$status" -eq 0 ]
  grep -q '^ide network create' "$CALLS"
  grep -q '^ide run -d --name ide-egress' "$CALLS"
  [[ "$output" == *"kept the main daemon's copy"* ]]
}

@test "the main copy goes only after the egress proxy is running" {
  bootstrap
  egress=$(grep -n '^ide run -d --name ide-egress' "$CALLS" | cut -d: -f1)
  remove=$(grep -n '^main image rm' "$CALLS" | cut -d: -f1)
  [ -n "$egress" ] && [ -n "$remove" ] && [ "$egress" -lt "$remove" ]
}

@test "a failed docker-ide load keeps the main copy" {
  LOAD_FAIL=1 bootstrap
  [ "$status" -ne 0 ]
  run grep '^main image rm' "$CALLS"
  [ "$status" -eq 1 ]
}
