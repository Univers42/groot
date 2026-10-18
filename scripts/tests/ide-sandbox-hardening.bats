#!/usr/bin/env bats
# Stage-1 hardening switches (ADR 0022: named users beyond the operator) that must stay off by
# default, so the operator plane builds and verifies exactly as before. Static: the image layer and
# the gVisor run are proven by the build itself (the strip RUN fails if an entry is left) and by
# verify.sh on the plane.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c "apk add -q coreutils >/dev/null && bats scripts/tests/ide-sandbox-hardening.bats"

setup() {
  SRC="$BATS_TEST_DIRNAME/../../infrastructure/docker/osionos/ide-sandbox"
}

@test "sandbox image: the setuid strip is opt-in and precedes the passwd link" {
  [ "$(grep -c '^ARG STRIP_SETUID=0$' "$SRC/Dockerfile")" -eq 1 ]
  grep -q 'if \[ "\$STRIP_SETUID" = 1 \]' "$SRC/Dockerfile"
  strip=$(grep -n '^ARG STRIP_SETUID' "$SRC/Dockerfile" | cut -d: -f1)
  link=$(grep -n 'ln -sf /tmp/.osio/passwd /etc/passwd' "$SRC/Dockerfile" | cut -d: -f1)
  [ "$strip" -lt "$link" ]
}
