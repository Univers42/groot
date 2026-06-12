#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m53-pb-certificate.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M53 — THE PARITY CERTIFICATE: every official-PocketBase-SDK suite this
# program built (records/realtime/files, auth+rules, ops, views+S3) runs
# against binocle-one AND real PocketBase in one session; every normalized
# outcome map must be IDENTICAL. Plus the budget walls:
#   nano ≤ 8 MB image, one ≤ 12 MB image, idle RSS ≤ 10/15 MiB.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M53] $*"; }
ok(){ green "  ✓ $*"; }
fail(){ red "[M53] FAIL — $*"; cleanup; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="${SCRIPT_DIR}/pb-sdk-suite"
ONE_IMAGE="${ONE_IMAGE:-binocle-one}"
NANO_IMAGE="${NANO_IMAGE:-binocle-nano}"
PB_VERSION="${PB_VERSION:-0.39.3}"
US_PORT=18975
PB_PORT=18976
SU_EMAIL="su@local.dev"
SU_PASS="m53-su-pass-12345"
WORK="$(mktemp -d)"
NET="m53net"
NODE_IMG="public.ecr.aws/docker/library/node:22-slim"

cleanup(){
  docker rm -fv m53-one m53-pb m53-minio m53-nano >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

docker image inspect "${ONE_IMAGE}" >/dev/null 2>&1 || fail "build first: make one-build"
docker network create "${NET}" >/dev/null 2>&1 || true

step "boot binocle-one + real PocketBase v${PB_VERSION} + MinIO"
docker run -d --name m53-minio --network "${NET}" \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  quay.io/minio/minio:latest server /data >/dev/null
sleep 3
docker run --rm --network "${NET}" --entrypoint sh quay.io/minio/mc:latest -c \
  "mc alias set m http://m53-minio:9000 minioadmin minioadmin >/dev/null \
   && mc mb -p m/usfiles >/dev/null && mc mb -p m/pbfiles >/dev/null" >/dev/null \
  || fail "minio bucket setup"
docker run -d --name m53-one --network "${NET}" -p "${US_PORT}:8090" \
  -e NANO_ADMIN_KEY="m53-$$" \
  -e ONE_SUPERUSER_EMAIL="${SU_EMAIL}" -e ONE_SUPERUSER_PASSWORD="${SU_PASS}" \
  "${ONE_IMAGE}" >/dev/null
curl -sL -o "${WORK}/pb.zip" \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
(cd "${WORK}" && unzip -oq pb.zip)
docker run -d --name m53-pb --network "${NET}" -p "${PB_PORT}:8090" -v "${WORK}:/pb" \
  public.ecr.aws/docker/library/alpine:3.20 \
  /pb/pocketbase serve --http 0.0.0.0:8090 --dir /pb/pb_data >/dev/null
for i in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${US_PORT}/api/health" >/dev/null 2>&1 \
    && curl -sf "http://127.0.0.1:${PB_PORT}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "boot timeout"
  sleep 0.5
done
docker exec m53-pb /pb/pocketbase superuser upsert "${SU_EMAIL}" "${SU_PASS}" --dir /pb/pb_data >/dev/null 2>&1

run_suite(){ # run_suite <suite.mjs> <base> <out> [extra args...]
  local script="$1" base="$2" out="$3"; shift 3
  docker run --rm --network host -v "${SUITE}":/suite -w /suite "${NODE_IMG}" \
    sh -c "npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 \
      && node ${script} ${base} ${SU_EMAIL} ${SU_PASS} $*" > "${out}" \
    || { tail -8 "${out}"; return 1; }
}

TOTAL=0
for spec in \
  "suite.mjs:" \
  "auth-suite.mjs:" \
  "ops-suite.mjs:" \
  "n-suite.mjs:http://m53-minio:9000" \
; do
  script="${spec%%:*}"
  extra="${spec#*:}"
  step "${script} vs binocle-one AND real PB"
  if [[ -n "${extra}" ]]; then
    run_suite "${script}" "http://127.0.0.1:${US_PORT}" "${WORK}/us.json" "${extra} usfiles" \
      || fail "${script} failed against binocle-one"
    run_suite "${script}" "http://127.0.0.1:${PB_PORT}" "${WORK}/pb.json" "${extra} pbfiles" \
      || fail "${script} failed against PocketBase"
  else
    run_suite "${script}" "http://127.0.0.1:${US_PORT}" "${WORK}/us.json" \
      || fail "${script} failed against binocle-one"
    run_suite "${script}" "http://127.0.0.1:${PB_PORT}" "${WORK}/pb.json" \
      || fail "${script} failed against PocketBase"
  fi
  N=$(python3 - "${WORK}/us.json" "${WORK}/pb.json" <<'PY'
import json, sys
us = json.load(open(sys.argv[1]))
pb = json.load(open(sys.argv[2]))
diffs = [k for k in sorted(set(us) | set(pb)) if us.get(k) != pb.get(k)]
if diffs:
    for k in diffs:
        print(f"== {k}\n  us: {json.dumps(us.get(k))}\n  pb: {json.dumps(pb.get(k))}", file=sys.stderr)
    sys.exit(1)
print(len(us))
PY
) || fail "${script}: outcome maps differ"
  ok "${script}: ${N} steps IDENTICAL"
  TOTAL=$((TOTAL + N))
done

step "budget walls"
for pair in "${NANO_IMAGE}:8" "${ONE_IMAGE}:12"; do
  img="${pair%%:*}"; cap="${pair#*:}"
  SIZE_MB=$(docker image inspect "${img}" --format '{{.Size}}' | python3 -c "print(round(int(input())/1e6,2))")
  python3 -c "import sys; sys.exit(0 if float('${SIZE_MB}') <= float('${cap}') else 1)" \
    || fail "${img} ${SIZE_MB} MB > ${cap} MB"
  ok "${img}: ${SIZE_MB} MB ≤ ${cap} MB"
done
docker run -d --name m53-nano -e NANO_ADMIN_KEY="m53-$$" "${NANO_IMAGE}" >/dev/null
sleep 3
for pair in "m53-nano:10" "m53-one:15"; do
  name="${pair%%:*}"; cap="${pair#*:}"
  RSS=$(docker stats --no-stream --format '{{.MemUsage}}' "${name}" | awk '{print $1}')
  python3 - "$RSS" "$cap" <<'PY' || fail "${name} idle RSS ${RSS} > ${cap} MiB"
import sys
v = float(sys.argv[1].replace("MiB","").replace("KiB","e-3").replace("GiB","e3"))
sys.exit(0 if v <= float(sys.argv[2]) else 1)
PY
  ok "${name} idle RSS ${RSS} ≤ ${cap} MiB"
done

green "[M53] CERTIFICATE — ${TOTAL} official-SDK steps IDENTICAL to real PocketBase v${PB_VERSION}; budgets intact"
