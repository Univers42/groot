#!/usr/bin/env bats
# The groot-tools image (infrastructure/docker/tools) answers for every tool the redesign brief
# names, through scripts/tools.sh exactly as callers use it. Needs a Docker daemon, so it lives
# outside scripts/tests (whose CI job has none).
#
# Run (bats in a container, talking to this machine's daemon; the repo at its own path because
# tools.sh bind-mounts it by host path):
#   docker run --rm -v "$PWD:$PWD" -w "$PWD" -e DOCKER_HOST=unix:///docker.sock \
#     -v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock:/docker.sock" --entrypoint sh \
#     bats/bats:1.11.1 -c 'apk add -q --no-cache bash coreutils docker-cli openssl && bats tests/tools-image'
# On a rootful daemon, mount /var/run/docker.sock instead.

setup_file() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export ROOT
  bash "$ROOT/scripts/tools.sh" --build >/dev/null
}

# tools.sh mounts the repo and nothing else, so every file a tool reads or writes lives under it.
setup() { WORK="$(mktemp -d "$ROOT/tests/tools-image/.tmp.XXXXXX")"; }
teardown() { rm -rf "$WORK"; }

tools() { bash "$ROOT/scripts/tools.sh" "$@"; }

@test "the image the runner uses is the one this tree defines" {
  run tools --tag
  [ "$status" -eq 0 ]
  docker image inspect "$output" >/dev/null
}

@test "ffmpeg encodes H.264, VP9 and AV1, and muxes WebVTT" {
  run tools ffmpeg -hide_banner -encoders
  [ "$status" -eq 0 ]
  [[ "$output" == *libx264* ]]
  [[ "$output" == *libvpx-vp9* ]]
  [[ "$output" == *libaom-av1* || "$output" == *libsvtav1* ]]
  [[ "$output" == *webvtt* ]]
}

@test "ffmpeg turns a generated frame into a playable MP4 with faststart" {
  out="$WORK/t.mp4"
  run tools ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=64x64:d=1 \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$out"
  [ "$status" -eq 0 ]
  [ -s "$out" ]
}

@test "vips and ImageMagick both write AVIF and WebP" {
  src="$WORK/s.png"
  run tools magick -size 32x32 xc:red "$src"
  [ "$status" -eq 0 ]
  run tools vips copy "$src" "$WORK/v.avif"
  [ "$status" -eq 0 ]
  run tools magick "$src" "$WORK/m.webp"
  [ "$status" -eq 0 ]
  [ -s "$WORK/v.avif" ]
  [ -s "$WORK/m.webp" ]
}

@test "svgo optimises an SVG" {
  printf '<svg xmlns="http://www.w3.org/2000/svg"><!-- c --><rect width="1" height="1"/></svg>' > "$WORK/a.svg"
  run tools svgo "$WORK/a.svg" -o "$WORK/b.svg"
  [ "$status" -eq 0 ]
  run grep -c 'c -->' "$WORK/b.svg"
  [ "$output" = "0" ]
}

@test "Lighthouse CI and both browser MCP servers are on PATH at their pinned versions" {
  run tools lhci --version
  [ "$status" -eq 0 ]
  [ "$output" = "0.15.1" ]
  run tools chrome-devtools-mcp --version
  [ "$status" -eq 0 ]
  [[ "$output" == *1.10.1* ]]
  run tools npm ls -g --depth 0 @playwright/mcp
  [ "$status" -eq 0 ]
  [[ "$output" == *@playwright/mcp@0.0.83* ]]
}

@test "Chromium renders a page headless" {
  run tools sh -c 'chromium-browser --headless=new --no-sandbox --disable-gpu --dump-dom "data:text/html,<p>ok-render</p>" 2>/dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *ok-render* ]]
}

@test "grobase-cli is the pinned commit" {
  run tools grobase version
  [ "$status" -eq 0 ]
  [[ "$output" == *112a848* ]]
}

@test "a mounted local CA lands in Chromium's trust store; without one the tool still runs" {
  ca="$WORK/ca.pem"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" \
    -subj /CN=smoke-ca -days 1 -out "$ca" 2>/dev/null
  [ -s "$ca" ]
  LOCAL_CA_FILE="$ca" run tools sh -c 'certutil -d sql:$HOME/.pki/nssdb -L'
  [ "$status" -eq 0 ]
  [[ "$output" == *track-binocle-local-ca* ]]
  LOCAL_CA_FILE="$WORK/absent.pem" run tools sh -c 'echo no-ca-ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *no-ca-ok* ]]
}
