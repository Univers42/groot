#!/usr/bin/env bats
# The ownership init (osio-volume-init, ADR 0011, verdict A3.6) and the per-uid passwd line box-init
# writes. Runs the real script and the real box-init.c from infrastructure/docker/osionos/ide-sandbox
# against throwaway directories, with hostile content planted first: a 0700 tree left by another
# uid, symlinks out of the volume, a setuid file, odd names. The script's own caps (CHOWN, FOWNER,
# DAC_READ_SEARCH) are not what this container has, it is just root, so a pass here proves the walk
# and its order, not the capability set; that is the VM-side A3.8/A3.9 and the local A3.7 run.
#
# Caveat: the container's root is not the VM's userns-remapped root; an id the container cannot
# chown to fails the test with the chown error rather than skipping.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#   -c 'apk add -q --no-cache bash gcc musl-dev util-linux-misc && bats scripts/tests/ide-volume-init.bats'

bats_require_minimum_version 1.5.0

SRC="$BATS_TEST_DIRNAME/../../infrastructure/docker/osionos/ide-sandbox"
INIT="$SRC/osio-volume-init.sh"
UID_BOX=20042

setup() {
  [ "$(id -u)" = 0 ] || skip "needs a disposable root container"
  VOL="$BATS_TEST_TMPDIR/vol"
  OUTSIDE="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$VOL" "$OUTSIDE"
  : > "$OUTSIDE/victim"
  chmod 644 "$OUTSIDE/victim"
}

owner() { stat -c '%u:%g:%a' "$1"; }
run_init() { OSIO_UID="$UID_BOX" sh "$INIT" "$@"; }

@test "the root ends up uid:10001 700 and the contents follow" {
  mkdir -p "$VOL/a/b"
  echo x > "$VOL/a/b/f"
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  [ "$(owner "$VOL")" = "$UID_BOX:10001:700" ]
  [ "$(stat -c '%u:%g' "$VOL/a/b/f")" = "$UID_BOX:10001" ]
}

@test "a 0700 tree another uid left behind is walked to the end" {
  mkdir -p "$VOL/old/deep/deeper"
  echo x > "$VOL/old/deep/deeper/f"
  chown -R 10001:10001 "$VOL"
  chmod 700 "$VOL/old" "$VOL/old/deep" "$VOL/old/deep/deeper"
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u:%g' "$VOL/old/deep/deeper/f")" = "$UID_BOX:10001" ]
}

@test "a symlink out of the volume is chowned itself and its target is left alone" {
  ln -s "$OUTSIDE/victim" "$VOL/link"
  ln -s "$OUTSIDE" "$VOL/dirlink"
  ln -s ../.. "$VOL/up"
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u' "$OUTSIDE/victim")" = 0 ]
  [ "$(stat -c '%u' "$OUTSIDE")" = 0 ]
  # stat does not follow a symlink by default: these are the links' own owners.
  [ "$(stat -c '%u' "$VOL/link")" = "$UID_BOX" ]
  [ "$(stat -c '%u' "$VOL/dirlink")" = "$UID_BOX" ]
}

@test "a setuid file does not stay setuid" {
  echo x > "$VOL/suid"
  chmod 4755 "$VOL/suid"
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  run ! test -u "$VOL/suid"
}

@test "names with spaces, newlines and a leading dash are chowned" {
  mkdir -p "$VOL/with space"
  : > "$VOL/-rf"
  : > "$VOL/new
line"
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  [ "$(find "$VOL" ! -user "$UID_BOX" | wc -l)" -eq 0 ]
}

@test "a second run over a finished volume is a no-op: the root is the completion marker" {
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  echo later > "$VOL/later"
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u' "$VOL/later")" = 0 ]
}

@test "a root that was only half done (not 700) is walked again" {
  mkdir "$VOL/sub"
  chown "$UID_BOX:10001" "$VOL"
  run run_init "$VOL"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u' "$VOL/sub")" = "$UID_BOX" ]
  [ "$(owner "$VOL")" = "$UID_BOX:10001:700" ]
}

@test "a directory argument that is a symlink or missing is refused, and nothing is chowned" {
  ln -s "$OUTSIDE" "$BATS_TEST_TMPDIR/sym"
  run run_init "$BATS_TEST_TMPDIR/sym"
  [ "$status" -ne 0 ]
  run run_init "$BATS_TEST_TMPDIR/absent"
  [ "$status" -ne 0 ]
  [ "$(stat -c '%u' "$OUTSIDE/victim")" = 0 ]
}

@test "a missing or out-of-range OSIO_UID is refused before any chown" {
  for bad in "" 10001 19999 60000 abc 200000 "20000;id" "20000 "; do
    run env OSIO_UID="$bad" sh "$INIT" "$VOL"
    [ "$status" -eq 2 ] || { echo "accepted: '$bad'"; return 1; }
  done
  [ "$(stat -c '%u' "$VOL")" = 0 ]
}

@test "box-init writes the coder line with the box's own uid and leaves the other lines" {
  command -v gcc >/dev/null && command -v setpriv >/dev/null || skip "needs gcc and setpriv"
  gcc -Wall -Wextra -Werror -O2 -o "$BATS_TEST_TMPDIR/box-init" "$SRC/box-init.c"
  printf 'root:x:0:0:root:/root:/bin/bash\ncoder:x:10001:10001::/home/coder:/bin/bash\nxcoder:x:10001:10001::/x:/bin/sh\n' > /etc/passwd.base
  rm -rf /tmp/.osio
  chmod 755 "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/box-init"
  timeout 2 setpriv --reuid="$UID_BOX" --regid=10001 --clear-groups "$BATS_TEST_TMPDIR/box-init" true || true
  [ "$(cat /tmp/.osio/passwd)" = "$(printf 'root:x:0:0:root:/root:/bin/bash\ncoder:x:20042:10001::/home/coder:/bin/bash\nxcoder:x:10001:10001::/x:/bin/sh')" ]
}
