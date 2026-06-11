#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m39-scale.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Multi-tenant scale gate (program phase A6/B5). Provisions SCALE tenants, then
# drives load spread across them and asserts the plane stays healthy:
#   * provisioning succeeds (control-plane crypto bounds hold — no OOM restarts)
#   * p99 under tenant fan-out ≤ p99_factor × single-tenant baseline
#   * zero 5xx, data-plane RSS within budget, pool-eviction not thrashing
#
# verify-all auto-discovers this → default SCALE = budgets.json .scale
# .smoke_tenants (200, ~15s to seed). The 10K headline run is on-demand:
#   make verify-m39 SCALE=10000   (after `docker compose -f … -f
#   docker-compose.scale.yml up -d` to raise PG max_connections + pools).
# SKIPs (exit 0) when the stack is down.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

green(){ printf '\033[0;32m[M39] %s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m[M39] FAIL: %s\033[0m\n' "$*"; }
cyan(){ printf '\033[0;36m[M39] %s\033[0m\n' "$*"; }
skip(){ printf '\033[1;33m[M39] SKIP: %s\033[0m\n' "$*"; exit 0; }

BUDGETS="${ROOT}/scripts/bench/budgets.json"
SCALE="${SCALE:-$(jq -r '.scale.smoke_tenants' "${BUDGETS}")}"
P99_FACTOR="$(jq -r '.scale.p99_factor' "${BUDGETS}")"
RSS_BAR="$(jq -r '.scale.data_plane_rss_mib' "${BUDGETS}")"
PREFIX="m39"

docker inspect mini-baas-data-plane-router-rust >/dev/null 2>&1 || skip "data plane not up"
[[ "$(docker inspect --format '{{.State.Health.Status}}' mini-baas-tenant-control 2>/dev/null)" == "healthy" ]] || skip "tenant-control not healthy"

DP="mini-baas-data-plane-router-rust"
TC="mini-baas-tenant-control"
AR="mini-baas-adapter-registry-go"
rss_mib(){ docker stats --no-stream --format '{{.MemUsage}}' "$1" 2>/dev/null | awk '{print $1}' | sed 's/MiB//;s/GiB/*1024/' | bc 2>/dev/null | cut -d. -f1; }
restarts(){ docker inspect --format '{{.RestartCount}}' "$1" 2>/dev/null || echo 0; }
metric(){ # $1 metric-substring → value
	local port; port="$(docker port "${DP}" 4011/tcp 2>/dev/null | head -1 | sed 's/.*://')"
	curl -s "http://127.0.0.1:${port}/metrics" 2>/dev/null | grep "$1" | awk '{print $2}' | head -1
}

cyan "scale gate: ${SCALE} tenants (p99 ≤ ${P99_FACTOR}× baseline, RSS ≤ ${RSS_BAR}MiB, 0×5xx, no OOM)"

R_TC0="$(restarts ${TC})"; R_AR0="$(restarts ${AR})"
EV0="$(metric 'pool_events_total{service="data-plane-router",event="evicted"' || echo 0)"; EV0="${EV0:-0}"

# ── seed ────────────────────────────────────────────────────────────────────
cyan "seeding ${SCALE} tenants…"
make -C "${ROOT}" scale-seed SCALE="${SCALE}" PREFIX="${PREFIX}" >/tmp/m39-seed.txt 2>&1 || { tail -5 /tmp/m39-seed.txt; red "seed failed"; make -C "${ROOT}" scale-teardown SCALE="${SCALE}" >/dev/null 2>&1 || true; exit 1; }
trap 'make -C "'"${ROOT}"'" scale-teardown SCALE="'"${SCALE}"'" >/dev/null 2>&1 || true' EXIT
SEEDED="$(grep -c '"status":"created"\|"status":"exists"' "${ROOT}/artifacts/scale/tenants-${SCALE}.jsonl" 2>/dev/null || echo 0)"
ERRORED="$(grep -c '"status":"error"' "${ROOT}/artifacts/scale/tenants-${SCALE}.jsonl" 2>/dev/null || echo 0)"
cyan "seeded ok=${SEEDED} errors=${ERRORED}"

# ── crypto-OOM guard: provisioning must not restart the control plane ────────
R_TC1="$(restarts ${TC})"; R_AR1="$(restarts ${AR})"
fail=0
(( R_TC1 > R_TC0 )) && { red "tenant-control restarted ${R_TC0}→${R_TC1} during seed (crypto OOM regression)"; fail=1; }
(( R_AR1 > R_AR0 )) && { red "adapter-registry restarted ${R_AR0}→${R_AR1} during seed (crypto OOM regression)"; fail=1; }
(( ERRORED > 0 )) && { red "${ERRORED} provisions errored"; fail=1; }

# ── multi-tenant load ────────────────────────────────────────────────────────
cyan "driving load across ${SEEDED} tenants…"
PREFIX="${PREFIX}" SCALE="${SCALE}" bash "${ROOT}/scripts/bench/multitenant.sh" >/tmp/m39-load.txt 2>&1 || { tail -8 /tmp/m39-load.txt; red "multitenant load failed"; exit 1; }
tail -3 /tmp/m39-load.txt
MT_ART="${ROOT}/artifacts/bench/multitenant-${SCALE}.json"
[[ -f "${MT_ART}" ]] || { red "no multitenant artifact"; exit 1; }

P99="$(jq -r '.http.p99' "${MT_ART}")"
ERR5XX="$(jq -r '.server_errors' "${MT_ART}")"
RSS="$(rss_mib ${DP})"; RSS="${RSS:-0}"
EV1="$(metric 'pool_events_total{service="data-plane-router",event="evicted"' || echo 0)"; EV1="${EV1:-0}"

# Single-tenant baseline p99 (the load artifact, same workload) for the factor.
BASE_ART="${ROOT}/artifacts/bench/load-essential-crud.json"
if [[ -f "${BASE_ART}" ]]; then
	BASE_P99="$(jq -r '.median.http.p99' "${BASE_ART}")"
	LIMIT="$(awk -v b="${BASE_P99}" -v f="${P99_FACTOR}" 'BEGIN{printf "%.1f", b*f}')"
	awk -v a="${P99}" -v b="${LIMIT}" 'BEGIN{exit !(a>b)}' && { red "fan-out p99 ${P99}ms > ${P99_FACTOR}× baseline (${LIMIT}ms)"; fail=1; }
	cyan "fan-out p99 ${P99}ms vs baseline ${BASE_P99}ms × ${P99_FACTOR} = ${LIMIT}ms"
else
	cyan "no single-tenant baseline artifact — skipping p99-factor check (run bench-load essential first)"
fi

(( ERR5XX > 0 )) && { red "${ERR5XX} server (5xx) errors under fan-out"; fail=1; }
(( RSS > RSS_BAR )) && { red "data-plane RSS ${RSS}MiB > ${RSS_BAR}MiB"; fail=1; }
cyan "data-plane RSS ${RSS}MiB ≤ ${RSS_BAR} · pool evictions during run: $(( EV1 - EV0 ))"

[[ "${fail}" == 0 ]] || exit 1
green "PASS — ${SEEDED} tenants: p99 ${P99}ms, 0×5xx, RSS ${RSS}MiB, no OOM (${MT_ART#${ROOT}/})"
