#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m51-pb-hooks.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M51 — Phase M gate: JS hooks (pb_hooks on QuickJS).
#   1. onRecordCreateRequest MUTATES a record server-side;
#   2. the same hook REJECTS a create (throw → 400 with the message);
#   3. routerAdd serves a custom endpoint;
#   4. hooksWatch: editing the file reloads handlers (~2 s);
#   5. cronAdd fires on the minute tick;
#   6. the m48 SDK suite stays green WITH hooks enabled;
#   7. budgets: one image ≤ 12 MB, idle RSS ≤ 15 MiB with hooks loaded.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M51] $*"; }
ok(){ green "  ✓ $*"; }
fail(){ red "[M51] FAIL — $*"; cleanup; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="${SCRIPT_DIR}/pb-sdk-suite"
ONE_IMAGE="${ONE_IMAGE:-binocle-one}"
PORT="${M51_PORT:-18968}"
BASE="http://127.0.0.1:${PORT}"
SU_EMAIL="su@local.dev"
SU_PASS="m51-su-pass-12345"
WORK="$(mktemp -d)"
NODE_IMG="public.ecr.aws/docker/library/node:22-slim"

cleanup(){
  docker rm -fv m51-one >/dev/null 2>&1 || true
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${WORK}/pb_hooks"
chmod 777 "${WORK}" "${WORK}/pb_hooks"
cat > "${WORK}/pb_hooks/main.pb.js" <<'EOF'
onRecordCreateRequest((e) => {
  if (e.record.title === "forbidden") {
    throw new Error("title is forbidden");
  }
  e.record.title = (e.record.title || "") + "-hooked";
}, "m51posts");

routerAdd("GET", "/api/custom/hello", (req) => {
  return { status: 200, body: { hello: "from-js" } };
});

cronAdd("jstick", "* * * * *", () => {
  console.log("jstick fired");
});
EOF

step "boot binocle-one with pb_hooks mounted"
docker run -d --name m51-one -p "${PORT}:8090" -e NANO_ADMIN_KEY="m51-$$" \
  -e ONE_SUPERUSER_EMAIL="${SU_EMAIL}" -e ONE_SUPERUSER_PASSWORD="${SU_PASS}" \
  -v "${WORK}/pb_hooks:/data/pb_hooks" "${ONE_IMAGE}" >/dev/null
for i in $(seq 1 40); do
  curl -sf "${BASE}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "boot"
  sleep 0.25
done
docker logs m51-one 2>&1 | grep -q "pb_hooks loaded" || fail "hooks did not load"
ok "hooks runtime loaded"

SU_TOKEN=$(curl -s -X POST "${BASE}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" -d "{\"identity\":\"${SU_EMAIL}\",\"password\":\"${SU_PASS}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -X POST "${BASE}/api/collections" -H "Authorization: ${SU_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"m51posts","type":"base","fields":[{"name":"title","type":"text"}],"listRule":"","viewRule":"","createRule":"","updateRule":"","deleteRule":""}' >/dev/null

step "hook mutates a record server-side"
TITLE=$(curl -s -X POST "${BASE}/api/collections/m51posts/records" -H "Content-Type: application/json" \
  -d '{"title":"x"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('title',''))")
[[ "${TITLE}" == "x-hooked" ]] || fail "expected 'x-hooked', got '${TITLE}'"
ok "create mutated by JS: ${TITLE}"

step "hook rejects a create (throw → 400)"
CODE=$(curl -s -o "${WORK}/rej.json" -w '%{http_code}' -X POST "${BASE}/api/collections/m51posts/records" \
  -H "Content-Type: application/json" -d '{"title":"forbidden"}')
[[ "${CODE}" == "400" ]] || fail "expected 400, got ${CODE}"
grep -q "forbidden" "${WORK}/rej.json" || fail "rejection message lost"
ok "create rejected with the hook's message"

step "routerAdd serves a custom endpoint"
HELLO=$(curl -s "${BASE}/api/custom/hello" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hello',''))")
[[ "${HELLO}" == "from-js" ]] || fail "custom route returned '${HELLO}'"
ok "GET /api/custom/hello → from-js"

step "hooksWatch reload on file change"
sed -i 's/-hooked/-hooked2/' "${WORK}/pb_hooks/main.pb.js"
sleep 4
TITLE2=$(curl -s -X POST "${BASE}/api/collections/m51posts/records" -H "Content-Type: application/json" \
  -d '{"title":"y"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('title',''))")
[[ "${TITLE2}" == "y-hooked2" ]] || fail "reload missed: got '${TITLE2}'"
ok "edited hook live after reload: ${TITLE2}"

step "cronAdd fires on the minute tick (waiting ≤70 s)"
TICKED=0
for i in $(seq 1 70); do
  if [[ "$(docker logs m51-one 2>&1 | grep -c 'jstick fired')" -gt 0 ]]; then TICKED=1; break; fi
  sleep 1
done
[[ "${TICKED}" == "1" ]] || fail "cron hook never fired"
ok "cron hook fired"

step "m48 SDK suite stays green with hooks enabled"
docker run --rm --network host -v "${SUITE}":/suite -w /suite "${NODE_IMG}" \
  sh -c "npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 \
    && node suite.mjs ${BASE} ${SU_EMAIL} ${SU_PASS}" > "${WORK}/sdk.json" \
  || { tail -5 "${WORK}/sdk.json"; fail "SDK suite failed with hooks enabled"; }
ok "SDK suite green alongside hooks"

step "budgets with the hooks engine in the binary"
SIZE_MB=$(docker image inspect "${ONE_IMAGE}" --format '{{.Size}}' | python3 -c "print(round(int(input())/1e6,2))")
python3 -c "import sys; sys.exit(0 if float('${SIZE_MB}') <= 12.0 else 1)" || fail "image ${SIZE_MB} MB > 12 MB"
RSS=$(docker stats --no-stream --format '{{.MemUsage}}' m51-one | awk '{print $1}')
python3 - "$RSS" <<'PY' || fail "idle RSS ${RSS} > 15 MiB"
import sys
raw = sys.argv[1]
v = float(raw.replace("MiB","").replace("KiB","e-3").replace("GiB","e3"))
sys.exit(0 if v <= 15.0 else 1)
PY
ok "image ${SIZE_MB} MB ≤ 12 MB; idle RSS ${RSS} ≤ 15 MiB (hooks loaded)"

green "[M51] PASS — JS hooks: mutate, reject, route, reload, cron — budgets intact"
