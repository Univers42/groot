#!/usr/bin/env bats
# `make all` builds the images this repo owns from source as track-binocle/*:local, so the
# stack runs the pinned submodules and not whatever was last pushed to Docker Hub.
# PULL_PREBUILT=1 is the explicit opt-in to the published dlesieur/*:latest tags.
# frontends-up runs against a fake `docker` that records every call.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils bash && bats scripts/tests'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BIN"
  : > "$CALLS"
  cat > "$BIN/docker" <<FAKE
#!/bin/sh
# Fake docker: images are cached, so the prefetch pulls nothing; log compose calls with
# the image variables they see.
case "\$1" in
  image) exit 0 ;;
  compose) echo "\$* | gw=\${AUTH_GATEWAY_IMAGE:-} web=\${OPPOSITE_OSIRIS_WEB_IMAGE:-}" >> "$CALLS" ;;
esac
exit 0
FAKE
  chmod +x "$BIN/docker"
  PATH="$BIN:$PATH"
}

frontends_up() {
  make -s -C "$REPO" -o certs -o drawnosaurus-wasm frontends-up \
    COMPOSE_HEALTHY_SERVICES= COMPOSE_RUNNING_SERVICES= COMPOSE_COMPLETED_SERVICES= "$@"
}

@test "no compose image defaults to a published dlesieur tag" {
  run grep -nE 'image: \$\{[A-Z_]+_IMAGE:-dlesieur/' "$REPO/docker-compose.yml"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "auth-gateway and opposite-osiris-web build from the submodule as :local" {
  for svc in auth-gateway opposite-osiris-web; do
    block=$(awk -v s="  $svc:" '$0 == s {on = 1; next} on && /^  [a-z]/ {exit} on' "$REPO/docker-compose.yml")
    [[ "$block" == *"track-binocle/"*":local}"* ]] || { echo "$svc: not :local"; return 1; }
    [[ "$block" == *"dockerfile: apps/opposite-osiris/docker/services/"* ]] || { echo "$svc: no build"; return 1; }
  done
}

@test "by default frontends-up builds and never pulls our images" {
  run frontends_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q ' up -d --build --wait .*auth-gateway opposite-osiris-web' "$CALLS"
  grep -q 'gw= web=$' "$CALLS"
  run grep -E ' pull |--no-build' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "PULL_PREBUILT=1 pulls the published tags and starts without building them" {
  run frontends_up PULL_PREBUILT=1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q ' pull osionos-bridge osionos-app auth-gateway opposite-osiris-web | gw=dlesieur/prismatica-auth-gateway:latest web=dlesieur/opposite-osiris-web:latest$' "$CALLS"
  grep -q ' up -d --no-build --wait .* | gw=dlesieur/prismatica-auth-gateway:latest' "$CALLS"
  run grep -E ' build [^|]*(osionos-bridge|osionos-app|auth-gateway|opposite-osiris-web)' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "PULL_PREBUILT=1 keeps an explicit image override" {
  AUTH_GATEWAY_IMAGE=example/gw:pinned run frontends_up PULL_PREBUILT=1
  [ "$status" -eq 0 ]
  grep -q ' pull .* | gw=example/gw:pinned web=dlesieur/opposite-osiris-web:latest$' "$CALLS"
}
