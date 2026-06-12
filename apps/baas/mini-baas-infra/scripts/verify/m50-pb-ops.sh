#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m50-pb-sdk-parity.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M50 — Phase J gate, parity certificate part 3 (OPS: backups/logs/crons/settings): the OFFICIAL PocketBase JS
# SDK (npm `pocketbase`) runs one scenario — health, superuser auth,
# backups create-list-delete, request logs (list+stats), crons (list+run),
# settings round-trip — against BOTH; PLUS a binocle-only restore lane.
# binocle-one and real PocketBase. PASS = normalized outcome maps IDENTICAL.

#
# Inputs: ONE_IMAGE (binocle-one), PB_VERSION (0.39.3), M50_PORTS (18965/18966).

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M50] $*"; }
fail(){ red "[M50] FAIL — $*"; cleanup; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="${SCRIPT_DIR}/pb-sdk-suite"
ONE_IMAGE="${ONE_IMAGE:-binocle-one}"
PB_VERSION="${PB_VERSION:-0.39.3}"
US_PORT="${M50_US_PORT:-18965}"
PB_PORT="${M50_PB_PORT:-18966}"
SU_EMAIL="su@local.dev"
SU_PASS="m50-su-pass-12345"
WORK="$(mktemp -d)"
NODE_IMG="public.ecr.aws/docker/library/node:22-slim"

cleanup(){
  docker rm -fv m50-one m50-pb >/dev/null 2>&1 || true
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/pb_data /w/pb_migrations' >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

docker image inspect "${ONE_IMAGE}" >/dev/null 2>&1 || fail "build first: make one-build"

step "booting binocle-one (:${US_PORT}) + PocketBase v${PB_VERSION} (:${PB_PORT})"
docker run -d --name m50-one -p "${US_PORT}:8090" -e NANO_ADMIN_KEY="m50-$$" \
  -e ONE_SUPERUSER_EMAIL="${SU_EMAIL}" -e ONE_SUPERUSER_PASSWORD="${SU_PASS}" \
  "${ONE_IMAGE}" >/dev/null

curl -sL -o "${WORK}/pb.zip" \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
(cd "${WORK}" && unzip -oq pb.zip)
docker run -d --name m50-pb -p "${PB_PORT}:8090" -v "${WORK}:/pb" \
  public.ecr.aws/docker/library/alpine:3.20 \
  /pb/pocketbase serve --http 0.0.0.0:8090 --dir /pb/pb_data >/dev/null

for i in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${US_PORT}/api/health" >/dev/null 2>&1 \
    && curl -sf "http://127.0.0.1:${PB_PORT}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "boot timeout"
  sleep 0.5
done
docker exec m50-pb /pb/pocketbase superuser upsert "${SU_EMAIL}" "${SU_PASS}" --dir /pb/pb_data >/dev/null 2>&1

step "official SDK suite vs binocle-one"
docker run --rm --network host -v "${SUITE}":/suite -w /suite "${NODE_IMG}" \
  sh -c "npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 \
    && node ops-suite.mjs http://127.0.0.1:${US_PORT} ${SU_EMAIL} ${SU_PASS}" \
  > "${WORK}/us.json" || { cat "${WORK}/us.json"; fail "suite failed against binocle-one"; }

step "official SDK suite vs real PocketBase"
docker run --rm --network host -v "${SUITE}":/suite -w /suite "${NODE_IMG}" \
  sh -c "npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 \
    && node ops-suite.mjs http://127.0.0.1:${PB_PORT} ${SU_EMAIL} ${SU_PASS}" \
  > "${WORK}/pb.json" || { cat "${WORK}/pb.json"; fail "suite failed against PocketBase"; }

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

step "binocle-only lane: backup -> mutate -> restore -> state rewound"
SU_TOKEN=$(curl -s -X POST "http://127.0.0.1:${US_PORT}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" -d "{\"identity\":\"${SU_EMAIL}\",\"password\":\"${SU_PASS}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -X POST "http://127.0.0.1:${US_PORT}/api/collections" -H "Authorization: ${SU_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"m50r","type":"base","fields":[{"name":"v","type":"text"}],"listRule":"","viewRule":"","createRule":"","updateRule":"","deleteRule":""}' >/dev/null
curl -s -X POST "http://127.0.0.1:${US_PORT}/api/collections/m50r/records" -H "Content-Type: application/json" \
  -d '{"v":"before-backup"}' >/dev/null
curl -s -X POST "http://127.0.0.1:${US_PORT}/api/backups" -H "Authorization: ${SU_TOKEN}" \
  -H "Content-Type: application/json" -d '{"name":"m50restore.zip"}' >/dev/null
curl -s -X POST "http://127.0.0.1:${US_PORT}/api/collections/m50r/records" -H "Content-Type: application/json" \
  -d '{"v":"after-backup"}' >/dev/null
PRE_RAW=$(curl -s "http://127.0.0.1:${US_PORT}/api/collections/m50r/records")
PRE=$(printf '%s' "${PRE_RAW}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalItems','RAW'))" 2>/dev/null || true)
[[ "${PRE}" =~ ^[0-9]+$ ]] || fail "records list unusable: ${PRE_RAW:0:200}"
[[ "${PRE}" == "2" ]] || fail "expected 2 rows before restore, got ${PRE}"
curl -s -X POST "http://127.0.0.1:${US_PORT}/api/backups/m50restore.zip/restore" -H "Authorization: ${SU_TOKEN}" -o /dev/null
sleep 1.5
docker start m50-one >/dev/null 2>&1 || true
for i in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${US_PORT}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "server did not come back after restore"
  sleep 0.5
done
POST_RAW=$(curl -s "http://127.0.0.1:${US_PORT}/api/collections/m50r/records")
POST=$(printf '%s' "${POST_RAW}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalItems','RAW'))" 2>/dev/null || true)
[[ "${POST}" =~ ^[0-9]+$ ]] || fail "post-restore list unusable: ${POST_RAW:0:200}"
[[ "${POST}" == "1" ]] || fail "restore did not rewind state (rows: ${POST}, want 1)"
green "  ✓ restore rewound 2 rows -> 1 (the post-backup write is gone)"

green "[M50] PASS — ops surfaces identical + restore round-trip proven"
