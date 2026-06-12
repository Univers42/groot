#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    pb-parity-bench.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Phase H scoreboard: the FULL operation matrix, three columns — binocle-nano,
# binocle-one, official PocketBase. Supersedes nano-one-pb-load.sh (insert+list
# only) as the program's measurement authority: every operation class that a
# PocketBase app exercises, measured identically (oha, same box, same windows).
#
#   insert / list-30 / get-by-id / update-by-id   @ c=1/16/64   (all three;
#   the c=1 insert lane is best-of-3 for every system — serial fsync lottery)
#   auth-login (argon2id vs bcrypt) / file-serve  @ c=1/16/64   (one vs PB)
#   count: list forcing COUNT (PB default) vs our op=aggregate  @ c=64
#   + RSS under c=64 insert, BIG_N-row run, disk-after, boot-to-first-200
#
# delete is intentionally absent from the RPS matrix: oha cannot vary the
# record id per request (PB deletes by id in the URL path), and deleting the
# same id repeatedly measures the 404 path, not deletes. Mechanically delete
# shares update's single-row write path in both systems.
#
# Inputs: PB_VERSION (default 0.39.3), DUR (default 8s), BIG_N (default 100000),
# OUT (artifact path, default artifacts/pb-parity-bench.json — the m46 gate's
# loaded run sets OUT=artifacts/pb-parity-bench-loaded.json while background
# load runs). Writes the JSON artifact + a human table. Measurement only —
# assertions live in the m46 gate.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

PB_VERSION="${PB_VERSION:-0.39.3}"
DUR="${DUR:-8s}"
BIG_N="${BIG_N:-100000}"
OUT="${OUT:-artifacts/pb-parity-bench.json}"
NANO_PORT=18957
ONE_PORT=18958
PB_PORT=18959
WORK="$(mktemp -d)"
OHA_IMG="ghcr.io/hatoo/oha:latest"

cleanup(){
  docker rm -fv p-nano p-one p-pb >/dev/null 2>&1 || true
  docker volume rm -f p-nano-data p-one-data >/dev/null 2>&1 || true
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/pb_data /w/pb_migrations' >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

docker image inspect binocle-nano >/dev/null 2>&1 || { echo "build first: make nano-build"; exit 1; }
docker image inspect binocle-one  >/dev/null 2>&1 || { echo "build first: make one-build"; exit 1; }
docker pull -q "${OHA_IMG}" >/dev/null

oha(){ docker run --rm --network host "${OHA_IMG}" --no-tui --output-format json "$@"; }
parse(){ python3 -c "
import sys, json
r = json.load(sys.stdin)
rps = r['summary']['requestsPerSec']
lp = r.get('latencyPercentiles', {})
def ms(k): return (lp.get(k) or 0) * 1000
print(f\"{rps:.0f} {ms('p50'):.1f} {ms('p95'):.1f} {ms('p99'):.1f}\")"; }
jget(){ python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    print($1)
except Exception:
    sys.stderr.write('jget failed on: ' + raw[:300] + '\n')
"; }

# ── boot all three ───────────────────────────────────────────────────────────
cyan "[H] booting nano (:${NANO_PORT}), one (:${ONE_PORT}), PocketBase v${PB_VERSION} (:${PB_PORT})"
NK="p-admin-$(date +%s)"
docker run -d --name p-nano -p "${NANO_PORT}:8090" -e NANO_ADMIN_KEY="${NK}" \
  -v p-nano-data:/data binocle-nano >/dev/null
docker run -d --name p-one -p "${ONE_PORT}:8090" -e NANO_ADMIN_KEY="${NK}" \
  -v p-one-data:/data binocle-one >/dev/null
NANO="http://127.0.0.1:${NANO_PORT}"
ONE="http://127.0.0.1:${ONE_PORT}"

curl -sL -o "${WORK}/pb.zip" \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
(cd "${WORK}" && unzip -oq pb.zip)
docker run -d --name p-pb -p "${PB_PORT}:8090" -v "${WORK}:/pb" \
  public.ecr.aws/docker/library/alpine:3.20 \
  /pb/pocketbase serve --http 0.0.0.0:8090 --dir /pb/pb_data >/dev/null
PB="http://127.0.0.1:${PB_PORT}"

for i in $(seq 1 30); do
  curl -sf "${NANO}/v1/health" >/dev/null 2>&1 \
    && curl -sf "${ONE}/v1/health" >/dev/null 2>&1 \
    && curl -sf "${PB}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 30 ]] && { echo "boot timeout"; exit 1; }
  sleep 0.5
done

# ── schema + fixed rows ──────────────────────────────────────────────────────
cyan "[H] schema + seed rows"
for base in "${NANO}" "${ONE}"; do
  curl -s -X POST "${base}/nano/v1/raw" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS bench (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, title TEXT)"}' >/dev/null
  curl -s -X POST "${base}/data/v1/query" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d '{"db_id":"main","operation":{"op":"insert","resource":"bench","data":{"id":"fixedrow1","title":"seed"}}}' >/dev/null
done

docker exec p-pb /pb/pocketbase superuser upsert bench@local.dev super-secret-pw-123 --dir /pb/pb_data >/dev/null 2>&1
PB_TOKEN=$(curl -s -X POST "${PB}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" \
  -d '{"identity":"bench@local.dev","password":"super-secret-pw-123"}' | jget "d.get('token','')")
[[ -n "${PB_TOKEN}" ]] || { echo "PocketBase auth failed"; exit 1; }
curl -s -X POST "${PB}/api/collections" -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"bench","type":"base","fields":[{"name":"title","type":"text"}]}' >/dev/null
PB_RID=$(curl -s -X POST "${PB}/api/collections/bench/records" -H "Authorization: ${PB_TOKEN}" \
  -H "Content-Type: application/json" -d '{"title":"seed"}' | jget "d['id']")
[[ -n "${PB_RID}" ]] || { echo "PB seed record failed"; exit 1; }

# ── auth users (login bench) ─────────────────────────────────────────────────
ONE_TOK=$(curl -s -X POST "${ONE}/one/v1/auth/register" -H "Content-Type: application/json" \
  -d '{"email":"bench@local.dev","password":"bench-pass-1234"}' | jget "d.get('token','')")
[[ -n "${ONE_TOK}" ]] || { echo "one register failed"; exit 1; }
curl -s -X POST "${PB}/api/collections/users/records" -H "Authorization: ${PB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"email":"bench@local.dev","password":"bench-pass-1234","passwordConfirm":"bench-pass-1234"}' >/dev/null

# ── files (serve bench): ~12 KB PNG with incompressible pixels ───────────────
python3 -c "
import struct, zlib, os
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
w = h = 64
raw = b''.join(b'\x00' + os.urandom(3 * w) for _ in range(h))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('${WORK}/pic.png', 'wb').write(png)
"
FID=$(curl -s -X POST "${ONE}/one/v1/files/bench/fixedrow1/doc" \
  -H "Authorization: Bearer ${ONE_TOK}" -F "file=@${WORK}/pic.png;type=image/png" | jget "d['file']['id']")
[[ -n "${FID}" ]] || { echo "one file upload failed"; exit 1; }
curl -s -X POST "${PB}/api/collections" -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"docs","type":"base","listRule":"","viewRule":"","fields":[{"name":"doc","type":"file","maxSelect":1,"maxSize":5242880}]}' >/dev/null
PB_FREC=$(curl -s -X POST "${PB}/api/collections/docs/records" -H "Authorization: ${PB_TOKEN}" \
  -F "doc=@${WORK}/pic.png;type=image/png")
PB_DOC_ID=$(echo "${PB_FREC}" | jget "d['id']")
PB_DOC_FN=$(echo "${PB_FREC}" | jget "d['doc']")
[[ -n "${PB_DOC_FN}" ]] || { echo "PB file upload failed"; exit 1; }

# ── request bodies ───────────────────────────────────────────────────────────
INS_BODY='{"db_id":"main","operation":{"op":"insert","resource":"bench","data":{"title":"load"}}}'
LIST_BODY='{"db_id":"main","operation":{"op":"list","resource":"bench","limit":30}}'
GET_BODY='{"db_id":"main","operation":{"op":"get","resource":"bench","filter":{"id":"fixedrow1"}}}'
UPD_BODY='{"db_id":"main","operation":{"op":"update","resource":"bench","filter":{"id":"fixedrow1"},"data":{"title":"upd"}}}'
LOGIN_BODY='{"email":"bench@local.dev","password":"bench-pass-1234"}'
PB_INS_BODY='{"title":"load"}'
PB_UPD_BODY='{"title":"upd"}'
PB_LOGIN_BODY='{"identity":"bench@local.dev","password":"bench-pass-1234"}'

q(){ # base c body  → POST /data/v1/query
  oha -z "${DUR}" -c "$2" -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d "$3" "$1/data/v1/query" | parse
}

best_of(){ # n cmd... — run n trials, keep the row with the highest RPS.
  local n="$1"; shift
  local best="" rps best_rps=0
  for _ in $(seq 1 "$n"); do
    local row; row=$("$@")
    rps=${row%% *}
    if python3 -c "import sys; sys.exit(0 if float('${rps}') > float('${best_rps}') else 1)"; then
      best="$row"; best_rps="$rps"
    fi
  done
  printf '%s' "$best"
}

# ── the matrix ───────────────────────────────────────────────────────────────
declare -A R
for c in 1 16 64; do
  cyan "[H] c=${c} insert"
  # c=1 serial inserts are a per-commit fsync lottery (no group commit can
  # engage with one connection) and swing 2-3x run to run for EVERY system —
  # best-of-3, applied identically to all three, measures the lane honestly.
  TRIALS=1; [[ "$c" == "1" ]] && TRIALS=3
  pb_ins(){ oha -z "${DUR}" -c "${c}" -m POST -H "Authorization: ${PB_TOKEN}" \
    -H "Content-Type: application/json" -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" | parse; }
  R[nano,ins,$c]=$(best_of "$TRIALS" q "${NANO}" "$c" "${INS_BODY}")
  R[one,ins,$c]=$(best_of "$TRIALS" q "${ONE}" "$c" "${INS_BODY}")
  R[pb,ins,$c]=$(best_of "$TRIALS" pb_ins)
  cyan "[H] c=${c} list-30"
  R[nano,list,$c]=$(q "${NANO}" "$c" "${LIST_BODY}")
  R[one,list,$c]=$(q "${ONE}" "$c" "${LIST_BODY}")
  R[pb,list,$c]=$(oha -z "${DUR}" -c "${c}" -H "Authorization: ${PB_TOKEN}" \
    "${PB}/api/collections/bench/records?perPage=30&skipTotal=1" | parse)
  cyan "[H] c=${c} get-by-id"
  R[nano,get,$c]=$(q "${NANO}" "$c" "${GET_BODY}")
  R[one,get,$c]=$(q "${ONE}" "$c" "${GET_BODY}")
  R[pb,get,$c]=$(oha -z "${DUR}" -c "${c}" -H "Authorization: ${PB_TOKEN}" \
    "${PB}/api/collections/bench/records/${PB_RID}" | parse)
  cyan "[H] c=${c} update-by-id"
  R[nano,upd,$c]=$(q "${NANO}" "$c" "${UPD_BODY}")
  R[one,upd,$c]=$(q "${ONE}" "$c" "${UPD_BODY}")
  R[pb,upd,$c]=$(oha -z "${DUR}" -c "${c}" -m PATCH -H "Authorization: ${PB_TOKEN}" \
    -H "Content-Type: application/json" -d "${PB_UPD_BODY}" "${PB}/api/collections/bench/records/${PB_RID}" | parse)
  cyan "[H] c=${c} auth-login (argon2id vs bcrypt)"
  R[one,login,$c]=$(oha -z "${DUR}" -c "${c}" -m POST -H "Content-Type: application/json" \
    -d "${LOGIN_BODY}" "${ONE}/one/v1/auth/login" | parse)
  R[pb,login,$c]=$(oha -z "${DUR}" -c "${c}" -m POST -H "Content-Type: application/json" \
    -d "${PB_LOGIN_BODY}" "${PB}/api/collections/users/auth-with-password" | parse)
  cyan "[H] c=${c} file-serve (~12 KB png)"
  R[one,file,$c]=$(oha -z "${DUR}" -c "${c}" -H "Authorization: Bearer ${ONE_TOK}" \
    "${ONE}/one/v1/file/${FID}" | parse)
  R[pb,file,$c]=$(oha -z "${DUR}" -c "${c}" \
    "${PB}/api/files/docs/${PB_DOC_ID}/${PB_DOC_FN}" | parse)
done

# ── count: our op=aggregate vs PB list forcing COUNT (no skipTotal) ──────────
# The matrix's insert sweeps leave each system with a DIFFERENT row count, so
# counting `bench` would compare unequal tables. Seed a dedicated table to the
# exact same size on all three (oha -n guarantees the count), then measure.
CNT_N="${CNT_N:-20000}"
cyan "[H] seeding cbench to ${CNT_N} rows × 3 (equal-size count target)"
CB_INS='{"db_id":"main","operation":{"op":"insert","resource":"cbench","data":{"title":"c"}}}'
for base in "${NANO}" "${ONE}"; do
  curl -s -X POST "${base}/nano/v1/raw" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS cbench (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, title TEXT)"}' >/dev/null
  oha -n "${CNT_N}" -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d "${CB_INS}" "${base}/data/v1/query" >/dev/null
done
curl -s -X POST "${PB}/api/collections" -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"cbench","type":"base","fields":[{"name":"title","type":"text"}]}' >/dev/null
oha -n "${CNT_N}" -c 64 -m POST -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d '{"title":"c"}' "${PB}/api/collections/cbench/records" >/dev/null
cyan "[H] c=64 count over ${CNT_N} rows (op=aggregate vs perPage=1 totalItems)"
CNT_BODY='{"db_id":"main","operation":{"op":"aggregate","resource":"cbench","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}}'
R[one,count,64]=$(q "${ONE}" 64 "${CNT_BODY}")
R[nano,count,64]=$(q "${NANO}" 64 "${CNT_BODY}")
R[pb,count,64]=$(oha -z "${DUR}" -c 64 -H "Authorization: ${PB_TOKEN}" \
  "${PB}/api/collections/cbench/records?perPage=1" | parse)

# ── RSS under c=64 insert load (historical comparability) ────────────────────
cyan "[H] RSS under c=64 insert load"
( sleep 3; docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' p-nano p-one p-pb > "${WORK}/rss.txt" ) &
SAMPLER=$!
oha -z 7s -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${NANO}/data/v1/query" >/dev/null &
P1=$!
oha -z 7s -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${ONE}/data/v1/query" >/dev/null &
P2=$!
oha -z 7s -c 64 -m POST -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" >/dev/null &
P3=$!
wait "${SAMPLER}" "${P1}" "${P2}" "${P3}"
NANO_RSS=$(awk '/p-nano/{print $2}' "${WORK}/rss.txt")
ONE_RSS=$(awk '/p-one/{print $2}' "${WORK}/rss.txt")
PB_RSS=$(awk '/p-pb/{print $2}' "${WORK}/rss.txt")

# ── BIG_N-row insert + disk after ────────────────────────────────────────────
cyan "[H] ${BIG_N}-row insert run (c=64) × 3"
NANO_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${NANO}/data/v1/query" | parse)
ONE_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${ONE}/data/v1/query" | parse)
PB_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" | parse)
NANO_DISK=$(docker run --rm -v p-nano-data:/d public.ecr.aws/docker/library/alpine:3.20 du -sk /d | awk '{printf "%.1f MB", $1/1024}')
ONE_DISK=$(docker run --rm -v p-one-data:/d public.ecr.aws/docker/library/alpine:3.20 du -sk /d | awk '{printf "%.1f MB", $1/1024}')
PB_DISK=$(docker exec p-pb du -sk /pb/pb_data | awk '{printf "%.1f MB", $1/1024}')

# ── boot-to-first-200 ────────────────────────────────────────────────────────
boot_ms(){ # container url
  docker restart "$1" >/dev/null
  local t0; t0=$(date +%s%N)
  while ! curl -sf "$2" >/dev/null 2>&1; do sleep 0.01; done
  awk -v d=$(( $(date +%s%N) - t0 )) 'BEGIN{printf "%.0f", d/1000000}'
}
cyan "[H] boot-to-first-200 × 3"
NANO_BOOT=$(boot_ms p-nano "${NANO}/v1/health")
ONE_BOOT=$(boot_ms p-one "${ONE}/v1/health")
PB_BOOT=$(boot_ms p-pb "${PB}/api/health")

# ── report ───────────────────────────────────────────────────────────────────
cell(){ # sys op c → "RPS p99" or —
  local v="${R[$1,$2,$3]:-}"
  if [[ -z "$v" ]]; then printf '%8s %7s' "—" "—"; else
    local a=($v); printf '%8s %7s' "${a[0]}" "${a[3]}"; fi
}
row(){ # label op c
  printf '  %-22s %s   %s   %s\n' "$1" "$(cell nano "$2" "$3")" "$(cell one "$2" "$3")" "$(cell pb "$2" "$3")"
}
echo
green "── PARITY MATRIX: nano vs one vs PocketBase v${PB_VERSION} (oha ${DUR}; RPS + p99 ms) ──"
printf '  %-22s %-16s   %-16s   %-16s\n' "" "── nano ──" "── one ──" "── PocketBase ──"
printf '  %-22s %8s %7s   %8s %7s   %8s %7s\n' "op @ c" "RPS" "p99" "RPS" "p99" "RPS" "p99"
for op in ins list get upd login file; do
  for c in 1 16 64; do
    case "$op" in
      ins) lbl="insert" ;; list) lbl="list 30" ;; get) lbl="get by id" ;;
      upd) lbl="update by id" ;; login) lbl="auth login" ;; file) lbl="file serve 12KB" ;;
    esac
    row "${lbl} @ c=${c}" "$op" "$c"
  done
done
row "count @ c=64" count 64
NB=(${NANO_BIG}); OB=(${ONE_BIG}); PBB=(${PB_BIG})
printf '  %-22s %8s %7s   %8s %7s   %8s %7s\n' "${BIG_N} rows @ c=64" "${NB[0]}" "${NB[3]}" "${OB[0]}" "${OB[3]}" "${PBB[0]}" "${PBB[3]}"
printf '  %-22s %16s   %16s   %16s\n' "RSS under load" "${NANO_RSS}" "${ONE_RSS}" "${PB_RSS}"
printf '  %-22s %16s   %16s   %16s\n' "disk after big run" "${NANO_DISK}" "${ONE_DISK}" "${PB_DISK}"
printf '  %-22s %13s ms   %13s ms   %13s ms\n' "boot → first 200" "${NANO_BOOT}" "${ONE_BOOT}" "${PB_BOOT}"
echo

mkdir -p artifacts
python3 - "$PB_VERSION" "$DUR" "$BIG_N" <<EOF > "${OUT}"
import json, sys, datetime
R = {
$(for key in "${!R[@]}"; do echo "  \"${key}\": \"${R[$key]}\","; done)
}
def unpack(s):
    rps, p50, p95, p99 = s.split()
    return {"rps": float(rps), "p50_ms": float(p50), "p95_ms": float(p95), "p99_ms": float(p99)}
out = {
  "generated": datetime.datetime.utcnow().isoformat() + "Z",
  "pocketbase_version": sys.argv[1], "duration": sys.argv[2], "big_n": int(sys.argv[3]),
  "sweep": {k.replace(",", "/"): unpack(v) for k, v in R.items()},
  "big_run": {"nano": unpack("${NANO_BIG}"), "one": unpack("${ONE_BIG}"), "pocketbase": unpack("${PB_BIG}")},
  "rss_under_load": {"nano": "${NANO_RSS}", "one": "${ONE_RSS}", "pocketbase": "${PB_RSS}"},
  "disk_after_big": {"nano": "${NANO_DISK}", "one": "${ONE_DISK}", "pocketbase": "${PB_DISK}"},
  "boot_ms": {"nano": ${NANO_BOOT}, "one": ${ONE_BOOT}, "pocketbase": ${PB_BOOT}},
}
print(json.dumps(out, indent=2))
EOF
green "→ ${OUT}"
