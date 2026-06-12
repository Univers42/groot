#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m47-one-hardening.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M47 — Phase I gate: hardening.
#   1. kill -9 under write load → restart → PRAGMA integrity_check == ok,
#      no committed row lost (post-restart count ≥ pre-kill snapshot), and
#      the server keeps serving reads + writes;
#   2. system maintenance loop observable (ONE_MAINTENANCE_SECS=2 → a
#      "maintenance tick" debug line within 15 s);
#   3. poison recovery + maintenance + orphan-sweep + filter-depth unit tests
#      green (targeted filters — the full suite runs in the workspace lane);
#   4. clippy wall: `--workspace --all-features -- -D warnings` is clean.
#
# Inputs: ONE_IMAGE (binocle-one), SKIP_CLIPPY=1 to skip lane 4 (e.g. when the
# workspace lane already ran it in the same CI job).

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M47] $*"; }
ok(){ green "  ✓ $*"; }
fail(){ red "[M47] FAIL — $*"; cleanup; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROUTER="${INFRA}/docker/services/data-plane-router"
ONE_IMAGE="${ONE_IMAGE:-binocle-one}"
NAME="m47-one-$$"
PORT="${M47_PORT:-18949}"
BASE="http://127.0.0.1:${PORT}"
KEY="m47-admin-$(date +%s)-deterministic"
VOL="m47-data-$$"

cleanup(){
  docker rm -fv "${NAME}" >/dev/null 2>&1 || true
  docker volume rm -f "${VOL}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker image inspect "${ONE_IMAGE}" >/dev/null 2>&1 || fail "build first: make one-build"

raw(){ # raw "<sql>" -> response body
  curl -s -X POST "${BASE}/nano/v1/raw" -H "X-Baas-Api-Key: ${KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"db_id\":\"main\",\"statement\":$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1"),\"expect_rows\":${2:-false}}"
}
wait_up(){
  for i in $(seq 1 40); do
    curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

# ── 1. kill -9 durability ────────────────────────────────────────────────────
step "kill -9 under write load → restart → integrity + no committed loss"
docker run -d --name "${NAME}" -p "${PORT}:8090" -e NANO_ADMIN_KEY="${KEY}" \
  -e ONE_MAINTENANCE_SECS=2 -e RUST_LOG=debug -v "${VOL}:/data" "${ONE_IMAGE}" >/dev/null
wait_up || fail "boot"
raw "CREATE TABLE IF NOT EXISTS m47 (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, n INTEGER)" >/dev/null

# Sustained write load in the background (sequential curl inserts).
(
  i=0
  while :; do
    i=$((i+1))
    curl -s -o /dev/null -X POST "${BASE}/data/v1/query" -H "X-Baas-Api-Key: ${KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"db_id\":\"main\",\"operation\":{\"op\":\"insert\",\"resource\":\"m47\",\"data\":{\"id\":\"w${i}-$$\",\"n\":${i}}}}" || true
  done
) & LOAD_PID=$!
sleep 3
SNAP=$(curl -s -X POST "${BASE}/data/v1/query" -H "X-Baas-Api-Key: ${KEY}" -H "Content-Type: application/json" \
  -d '{"db_id":"main","operation":{"op":"aggregate","resource":"m47","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['rows'][0]['n'])")
[[ "${SNAP}" -gt 0 ]] || fail "no writes landed before the kill (snapshot=${SNAP})"
docker kill -s KILL "${NAME}" >/dev/null
kill "${LOAD_PID}" >/dev/null 2>&1 || true
wait "${LOAD_PID}" 2>/dev/null || true
docker start "${NAME}" >/dev/null
wait_up || fail "restart after kill -9"

INTEG=$(raw "PRAGMA integrity_check" true | python3 -c "import sys,json;print(json.load(sys.stdin)['rows'][0]['integrity_check'])")
[[ "${INTEG}" == "ok" ]] || fail "integrity_check returned '${INTEG}'"
ok "integrity_check ok after kill -9"

COUNT=$(curl -s -X POST "${BASE}/data/v1/query" -H "X-Baas-Api-Key: ${KEY}" -H "Content-Type: application/json" \
  -d '{"db_id":"main","operation":{"op":"aggregate","resource":"m47","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['rows'][0]['n'])")
[[ "${COUNT}" -ge "${SNAP}" ]] || fail "committed rows lost: pre-kill ${SNAP} → post-restart ${COUNT}"
ok "no committed row lost (${SNAP} → ${COUNT})"

POST=$(curl -s -X POST "${BASE}/data/v1/query" -H "X-Baas-Api-Key: ${KEY}" -H "Content-Type: application/json" \
  -d '{"db_id":"main","operation":{"op":"insert","resource":"m47","data":{"id":"post-restart","n":1}}}' \
  -o /dev/null -w '%{http_code}')
[[ "${POST}" == "200" ]] || fail "post-restart write returned ${POST}"
ok "server serves writes after restart"

# ── 2. maintenance loop observable ──────────────────────────────────────────
step "maintenance tick observable at ONE_MAINTENANCE_SECS=2"
TICKED=0
for i in $(seq 1 15); do
  # grep -c (not -q): -q exits at first match, docker logs takes SIGPIPE and
  # pipefail turns the MATCHING pipeline into a failure. -c reads to EOF.
  if [[ "$(docker logs "${NAME}" 2>&1 | grep -c "maintenance tick")" -gt 0 ]]; then TICKED=1; break; fi
  sleep 1
done
[[ "${TICKED}" == "1" ]] || fail "no maintenance tick within 15 s"
ok "maintenance loop ticks"

# ── 3. targeted unit tests ──────────────────────────────────────────────────
step "hardening unit tests (poison recovery, maintain, orphan sweep, filter depth)"
CARGO="docker run --rm --cpus 6 -v ${ROUTER}:/work -w /work \
  -v mini-baas-cargo-registry:/usr/local/cargo/registry \
  -v mini-baas-cargo-git:/usr/local/cargo/git \
  -v mini-baas-dpr-target-pbtotal:/work/target mini-baas-rust-toolchain cargo"
${CARGO} test -q -p data-plane-server --no-default-features --features one \
  -- poisoned_lock_recovers maintain_purges orphan_sweep >/dev/null || fail "server hardening tests"
${CARGO} test -q -p data-plane-core rejects_nesting_beyond_depth_limit >/dev/null || fail "filter depth test"
ok "unit tests green"

# ── 4. clippy wall ──────────────────────────────────────────────────────────
if [[ "${SKIP_CLIPPY:-0}" != "1" ]]; then
  step "clippy --workspace --all-features -D warnings"
  # The base toolchain image ships without the clippy component; derive a
  # tagged image once (idempotent, cached).
  if ! docker image inspect mini-baas-rust-toolchain-clippy >/dev/null 2>&1; then
    printf 'FROM mini-baas-rust-toolchain\nRUN rustup component add clippy\n' \
      | docker build -t mini-baas-rust-toolchain-clippy - >/dev/null
  fi
  CLIPPY="${CARGO/mini-baas-rust-toolchain cargo/mini-baas-rust-toolchain-clippy cargo}"
  ${CLIPPY} clippy --workspace --all-features --quiet -- -D warnings || fail "clippy wall"
  ok "clippy clean"
fi

green "[M47] PASS — hardening verified"
