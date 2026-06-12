#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m52-pb-edge.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M52 — Phase N gate:
#   1. in-binary automatic HTTPS: ACME against a pebble test CA — the server
#      orders a cert for ONE_HTTPS_DOMAIN and serves it on the TLS listener;
#   2. view collections + S3 file storage + gif thumbs: official-SDK n-suite
#      against BOTH binocle-one and real PB (shared MinIO, one bucket each),
#      normalized outcomes diffed.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M52] $*"; }
ok(){ green "  ✓ $*"; }
fail(){ red "[M52] FAIL — $*"; cleanup; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="${SCRIPT_DIR}/pb-sdk-suite"
ONE_IMAGE="${ONE_IMAGE:-binocle-one}"
PB_VERSION="${PB_VERSION:-0.39.3}"
US_PORT=18971
PB_PORT=18972
TLS_PORT=18973
SU_EMAIL="su@local.dev"
SU_PASS="m52-su-pass-12345"
WORK="$(mktemp -d)"
NET="m52net"
NODE_IMG="public.ecr.aws/docker/library/node:22-slim"

cleanup(){
  docker rm -fv m52-one m52-pb m52-pebble m52-shim m52-minio >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

docker image inspect "${ONE_IMAGE}" >/dev/null 2>&1 || fail "build first: make one-build"
docker network create "${NET}" >/dev/null 2>&1 || true

step "boot pebble (test ACME CA) + compatibility shim"
# REAL TLS-ALPN-01: pebble resolves one.test through docker DNS (network
# alias on our container) and dials its validation tlsPort 5001 — which is
# exactly where our ACME listener answers with the challenge certificate.
docker run -d --name m52-pebble --network "${NET}" \
  -e PEBBLE_WFE_NONCEREJECT=0 \
  ghcr.io/letsencrypt/pebble:latest >/dev/null
# pebble REQUIRES a User-Agent; rustls-acme 0.14 sends none. Pebble builds its
# returned URLs from the Host header, so a tiny https shim that injects the
# header keeps the ENTIRE flow on the shim.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/shim.key" \
  -out "${WORK}/shim.crt" -days 2 -subj "/CN=m52-shim" >/dev/null 2>&1
cat > "${WORK}/ua-shim.mjs" <<'EOF'
import https from "node:https";
import fs from "node:fs";
const upstream = "m52-pebble";
const server = https.createServer(
  { key: fs.readFileSync("/work/shim.key"), cert: fs.readFileSync("/work/shim.crt") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      const headers = { ...req.headers, "user-agent": "binocle-acme-test/1.0" };
      delete headers["content-length"];
      if (body.length) headers["content-length"] = body.length;
      const up = https.request(
        { host: upstream, port: 14000, path: req.url, method: req.method,
          headers, rejectUnauthorized: false },
        (ur) => {
          const bufs = [];
          ur.on("data", (c) => bufs.push(c));
          ur.on("end", () => {
            let rb = Buffer.concat(bufs);
            // rustls-acme 0.14 cannot parse pebble's draft dns-account-01
            // challenge entries (different shape) — drop them from authz
            // responses; the client only ever uses tls-alpn-01 anyway.
            try {
              const j = JSON.parse(rb.toString());
              if (Array.isArray(j.challenges)) {
                j.challenges = j.challenges.filter((c) =>
                  ["tls-alpn-01", "http-01", "dns-01"].includes(c.type));
                rb = Buffer.from(JSON.stringify(j));
              }
            } catch {}
            const h = { ...ur.headers };
            delete h["content-length"];
            h["content-length"] = rb.length;
            res.writeHead(ur.statusCode, h);
            res.end(rb);
          });
        }
      );
      up.on("error", () => { res.writeHead(502); res.end(); });
      up.end(body);
    });
  }
);
server.listen(14000, "0.0.0.0", () => console.log("ua shim up"));
EOF
docker run -d --name m52-shim --network "${NET}" -v "${WORK}:/work" \
  "${NODE_IMG}" node /work/ua-shim.mjs >/dev/null

step "boot MinIO + create buckets"
docker run -d --name m52-minio --network "${NET}" \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  quay.io/minio/minio:latest server /data >/dev/null
sleep 3
docker run --rm --network "${NET}" --entrypoint sh quay.io/minio/mc:latest -c \
  "mc alias set m http://m52-minio:9000 minioadmin minioadmin >/dev/null \
   && mc mb -p m/usfiles >/dev/null && mc mb -p m/pbfiles >/dev/null" \
  || fail "minio bucket setup"
ok "minio ready (buckets usfiles + pbfiles)"

step "boot binocle-one (ACME → pebble) + real PocketBase"
docker run -d --name m52-one --network "${NET}" --network-alias one.test \
  -p "${US_PORT}:8090" -p "${TLS_PORT}:5001" \
  -e NANO_ADMIN_KEY="m52-$$" \
  -e ONE_SUPERUSER_EMAIL="${SU_EMAIL}" -e ONE_SUPERUSER_PASSWORD="${SU_PASS}" \
  -e ONE_HTTPS_DOMAIN=one.test \
  -e ONE_ACME_DIRECTORY="https://m52-shim:14000/dir" \
  -e ONE_ACME_INSECURE=1 \
  -e ONE_ACME_CONTACT=admin@one.test \
  -e ONE_HTTPS_ADDR=0.0.0.0:5001 \
  "${ONE_IMAGE}" >/dev/null

curl -sL -o "${WORK}/pb.zip" \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
(cd "${WORK}" && unzip -oq pb.zip)
docker run -d --name m52-pb --network "${NET}" -p "${PB_PORT}:8090" -v "${WORK}:/pb" \
  public.ecr.aws/docker/library/alpine:3.20 \
  /pb/pocketbase serve --http 0.0.0.0:8090 --dir /pb/pb_data >/dev/null
for i in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${US_PORT}/api/health" >/dev/null 2>&1 \
    && curl -sf "http://127.0.0.1:${PB_PORT}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "boot timeout"
  sleep 0.5
done
docker exec m52-pb /pb/pocketbase superuser upsert "${SU_EMAIL}" "${SU_PASS}" --dir /pb/pb_data >/dev/null 2>&1

step "ACME: cert for one.test ordered + served on the TLS listener"
# ACME certs carry the domain in the SAN (subject CN is deprecated/empty)
GOT=""
for i in $(seq 1 45); do
  GOT=$(echo | timeout 5 openssl s_client -connect "127.0.0.1:${TLS_PORT}" \
    -servername one.test 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)
  [[ "${GOT}" == *"one.test"* ]] && break
  sleep 1
done
[[ "${GOT}" == *"one.test"* ]] || { docker logs m52-one 2>&1 | grep -i acme | tail -5; fail "no ACME cert served (got: ${GOT})"; }
ok "TLS listener serves an ACME certificate (SAN: one.test)"
HTTPS_BODY=$(curl -sk "https://127.0.0.1:${TLS_PORT}/api/health" | head -c 60)
[[ "${HTTPS_BODY}" == *"healthy"* ]] || fail "https api unhealthy: ${HTTPS_BODY}"
ok "API serves over the ACME-certified listener"

step "n-suite (views + S3 + gif) vs binocle-one"
docker run --rm --network host -v "${SUITE}":/suite -w /suite "${NODE_IMG}" \
  sh -c "npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 \
    && node n-suite.mjs http://127.0.0.1:${US_PORT} ${SU_EMAIL} ${SU_PASS} http://m52-minio:9000 usfiles" \
  > "${WORK}/us.json" || { cat "${WORK}/us.json"; fail "n-suite failed against binocle-one"; }

step "n-suite vs real PocketBase"
docker run --rm --network host -v "${SUITE}":/suite -w /suite "${NODE_IMG}" \
  sh -c "npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 \
    && node n-suite.mjs http://127.0.0.1:${PB_PORT} ${SU_EMAIL} ${SU_PASS} http://m52-minio:9000 pbfiles" \
  > "${WORK}/pb.json" || { cat "${WORK}/pb.json"; fail "n-suite failed against PocketBase"; }

step "diffing normalized outcomes"
python3 - "${WORK}/us.json" "${WORK}/pb.json" <<'PY' || fail "outcome maps differ"
import json, sys
us = json.load(open(sys.argv[1]))
pb = json.load(open(sys.argv[2]))
diffs = [k for k in sorted(set(us) | set(pb)) if us.get(k) != pb.get(k)]
for k in sorted(us):
    mark = "\033[0;32m✓\033[0m" if us[k] == pb.get(k) else "\033[0;31m✗\033[0m"
    print(f"  {mark} {k}")
if diffs:
    for k in diffs:
        print(f"\n== {k}\n  us: {json.dumps(us.get(k))}\n  pb: {json.dumps(pb.get(k))}")
    sys.exit(1)
print(f"\n  {len(us)} steps — outcome maps are IDENTICAL")
PY

step "binocle-only lane: protected file field requires a token"
SU_TOKEN=$(curl -s -X POST "http://127.0.0.1:${US_PORT}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" -d "{\"identity\":\"${SU_EMAIL}\",\"password\":\"${SU_PASS}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -X POST "http://127.0.0.1:${US_PORT}/api/collections" -H "Authorization: ${SU_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"m52prot","type":"base","fields":[{"name":"title","type":"text"},{"name":"doc","type":"file","maxSelect":1,"protected":true}],"listRule":"","viewRule":"","createRule":"","updateRule":"","deleteRule":""}' >/dev/null
printf '\x89PNG\r\n\x1a\n' > "${WORK}/p.png"; head -c 200 /dev/urandom >> "${WORK}/p.png"
PR=$(curl -s -X POST "http://127.0.0.1:${US_PORT}/api/collections/m52prot/records" \
  -F "title=secret" -F "doc=@${WORK}/p.png;type=image/png")
PRID=$(printf '%s' "${PR}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
PRDOC=$(printf '%s' "${PR}" | python3 -c "import sys,json;print(json.load(sys.stdin)['doc'])")
BARE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${US_PORT}/api/files/m52prot/${PRID}/${PRDOC}")
FTOK=$(curl -s -X POST "http://127.0.0.1:${US_PORT}/api/files/token" -H "Authorization: ${SU_TOKEN}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
WITHTOK=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${US_PORT}/api/files/m52prot/${PRID}/${PRDOC}?token=${FTOK}")
[[ "${BARE}" == "404" ]] || fail "protected file served without a token (${BARE})"
[[ "${WITHTOK}" == "200" ]] || fail "protected file not served WITH a token (${WITHTOK})"
green "  ✓ protected file: bare ${BARE}, with-token ${WITHTOK}"

green "[M52] PASS — ACME HTTPS + views + S3 + gif thumbs + protected files proven"
