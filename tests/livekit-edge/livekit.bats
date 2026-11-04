#!/usr/bin/env bats
# LiveKit's signalling behind the :4000 TLS front door (groot#174): the REAL nginx.conf plus
# infrastructure/tls/bridge-livekit.conf, in the image compose runs, in front of stub `livekit`
# and `osionos-bridge` upstreams that echo what they received. Proves the path rewrite, the
# WebSocket Upgrade pass-through and that the SFU's admin API is not fronted.
# Needs docker and openssl:
#   bats tests/livekit-edge

NGINX_IMAGE=public.ecr.aws/docker/library/nginx:1.27-alpine

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  NET=lk-edge-$$
  docker network create "$NET" >/dev/null

  stub() {
    local id
    id=$(docker create --network "$NET" --network-alias "$1" "$NGINX_IMAGE")
    cat >"$BATS_FILE_TMPDIR/$1.conf" <<NGINX
events {}
http {
  server {
    listen $2;
    location / {
      add_header X-Stub $1 always;
      add_header X-Stub-Uri \$request_uri always;
      add_header X-Stub-Upgrade \$http_upgrade always;
      return 200 "stub\n";
    }
  }
}
NGINX
    docker cp "$BATS_FILE_TMPDIR/$1.conf" "$id:/etc/nginx/nginx.conf" >/dev/null
    docker start "$id" >/dev/null
    printf '%s' "$id"
  }
  LIVEKIT=$(stub livekit 7880)
  BRIDGE=$(stub osionos-bridge 4000)

  local certs=$BATS_FILE_TMPDIR/etc/track-binocle/certs
  mkdir -p "$certs" "$BATS_FILE_TMPDIR/etc/nginx/track-binocle.d"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$certs/localhost-key.pem" -out "$certs/localhost.pem" 2>/dev/null
  cp "$REPO/infrastructure/tls/bridge-livekit.conf" "$BATS_FILE_TMPDIR/etc/nginx/track-binocle.d/"
  PROXY=$(docker create --network "$NET" "$NGINX_IMAGE")
  docker cp "$REPO/infrastructure/tls/nginx.conf" "$PROXY:/etc/nginx/nginx.conf" >/dev/null
  docker cp "$BATS_FILE_TMPDIR/etc/." "$PROXY:/etc/" >/dev/null
  docker start "$PROXY" >/dev/null
  for _ in $(seq 50); do
    docker exec "$PROXY" curl -sk -o /dev/null https://127.0.0.1:4000/ && break
    sleep 0.2
  done
  export NET LIVEKIT BRIDGE PROXY
}

teardown_file() {
  docker rm -f "${PROXY:-}" "${LIVEKIT:-}" "${BRIDGE:-}" >/dev/null 2>&1 || true
  docker network rm "${NET:-}" >/dev/null 2>&1 || true
}

# Lower-cased response headers of a request to the :4000 TLS server; extra curl args follow.
edge() {
  local path="$1"
  shift
  docker exec "$PROXY" curl -sk -o /dev/null -D - "$@" "https://127.0.0.1:4000$path" |
    tr -d '\r' | tr '[:upper:]' '[:lower:]'
}

@test "nginx -t accepts nginx.conf with the livekit include" {
  run docker exec "$PROXY" nginx -t
  [ "$status" -eq 0 ]
}

@test "/livekit/rtc/v1 reaches the SFU as /rtc/v1, query string kept" {
  run edge '/livekit/rtc/v1?access_token=t'
  [[ "$output" == *"x-stub: livekit"* ]]
  [[ "$output" == *"x-stub-uri: /rtc/v1?access_token=t"* ]]
}

@test "the validate probe reaches the SFU too" {
  run edge /livekit/rtc/v1/validate
  [[ "$output" == *"x-stub-uri: /rtc/v1/validate"* ]]
}

@test "the WebSocket Upgrade header is passed on" {
  run edge /livekit/rtc/v1 -H 'Connection: Upgrade' -H 'Upgrade: websocket'
  [[ "$output" == *"x-stub-upgrade: websocket"* ]]
}

@test "the SFU's twirp admin API is not fronted" {
  run edge /livekit/twirp/livekit.RoomService/ListRooms
  [[ "$output" != *"x-stub: livekit"* ]]
}

@test "the rest of :4000 still goes to the bridge" {
  run edge /api/rtc/token
  [[ "$output" == *"x-stub: osionos-bridge"* ]]
}
