#!/usr/bin/env bats
# ship-images.sh streams the sandbox + egress images from the build machine's main
# daemon into the VM's docker-ide daemon (docker save | ssh … load, each bound by
# timeout) and prints the pinned ids the operator copies into the env files. A fake
# docker records every call ("-H unix:///…" marks a remote/docker-ide one); a fake
# ssh drops its host argument and runs the rest against the fake docker.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BIN"
  : > "$CALLS"
  cat > "$BIN/docker" <<FAKE
#!/bin/sh
# Fake docker. "-H unix:///run/docker-ide.sock" marks a remote (docker-ide) call.
# MISSING: images absent from the local daemon. LAYERS_MISMATCH: images whose remote
# RootFS.Layers differ from the local ones. Remote ids are fixed per image name.
daemon=main
if [ "\$1" = -H ]; then daemon=remote; shift 2; fi
echo "\$daemon \$*" >> "$CALLS"
if [ "\$1" = image ] && [ "\$2" = inspect ]; then
  fmt=""
  if [ "\$3" = -f ]; then fmt="\$4"; img="\$5"; else img="\$3"; fi
  case " \${MISSING:-} " in *" \$img "*) exit 1 ;; esac
  case "\$fmt" in
    *RootFS.Layers*)
      if [ "\$daemon" = remote ]; then
        case " \${LAYERS_MISMATCH:-} " in
          *" \$img "*) printf '%s\n' '["sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"]'; exit 0 ;;
        esac
      fi
      printf '%s\n' '["sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]'
      ;;
    *.Id*)
      case "\$img" in
        *sandbox*) printf '%s\n' 'sha256:1111111111111111111111111111111111111111111111111111111111111111' ;;
        *egress*) printf '%s\n' 'sha256:2222222222222222222222222222222222222222222222222222222222222222' ;;
        *) printf '%s\n' 'sha256:3333333333333333333333333333333333333333333333333333333333333333' ;;
      esac
      ;;
  esac
  exit 0
fi
case "\$daemon \$1" in
  "main save") echo "tarball of \$2" ;;
  "remote load") read -r line; cat >/dev/null; echo "Loaded image: \${line#tarball of }" ;;
esac
exit 0
FAKE
  chmod +x "$BIN/docker"
  cat > "$BIN/ssh" <<FAKE
#!/bin/sh
# Fake ssh: drops the host argument and, like real ssh, joins the rest into ONE string
# for a remote shell, run against the fake docker on PATH (-H marks the call "remote").
shift
echo "ssh \$*" >> "$CALLS"
exec sh -c "\$*"
FAKE
  chmod +x "$BIN/ssh"
  PATH="$BIN:$PATH"
}

ship() {
  run sh "$REPO/infrastructure/docker/osionos/ide-sandbox/ship-images.sh"
}

@test "IDE_SHIP_HOST unset refuses before any docker call" {
  ship
  [ "$status" -ne 0 ]
  [[ "$output" == *IDE_SHIP_HOST* ]]
  [ ! -s "$CALLS" ]
}

@test "an image missing from the local daemon stops before anything is saved, naming it" {
  IDE_SHIP_HOST=vm MISSING=osionos-ide-sandbox:latest ship
  [ "$status" -ne 0 ]
  [[ "$output" == *osionos-ide-sandbox:latest* ]]
  run grep -E '^(main save|ssh )' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "an image reference a remote shell would split or expand is refused before any call" {
  IDE_SHIP_HOST=vm OSIONOS_IDE_SANDBOX_IMAGE='img;touch x' ship
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing image reference"* ]]
  [ ! -s "$CALLS" ]
}

@test "differing layers between the daemons stop the ship, naming the image" {
  IDE_SHIP_HOST=vm LAYERS_MISMATCH=osionos-ide-egress:latest ship
  [ "$status" -ne 0 ]
  [[ "$output" == *osionos-ide-egress:latest* ]]
}

@test "ships both images and prints the pinned ids docker-ide reports" {
  IDE_SHIP_HOST=vm ship
  [ "$status" -eq 0 ]
  [ "$(tail -n 2 <<<"$output")" = "OSIONOS_IDE_SANDBOX_IMAGE=sha256:1111111111111111111111111111111111111111111111111111111111111111
OSIONOS_IDE_EGRESS_IMAGE=sha256:2222222222222222222222222222222222222222222222222222222222222222" ]
  run grep -E 'rmi|sudo' "$CALLS"
  [ "$status" -eq 1 ]
}
