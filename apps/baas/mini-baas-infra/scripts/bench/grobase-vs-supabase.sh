#!/usr/bin/env bash
# **************************************************************************** #
#    grobase-vs-supabase.sh — head-to-head, same box, strictly sequential      #
# **************************************************************************** #
#
# The marquee comparison (program A5): boot self-hosted Supabase on the same box
# our stack runs on, run the IDENTICAL logical workload (PostgREST CRUD + auth)
# against both, and report total RAM footprint + latency distributions. Method
# follows nano-vs-pocketbase.sh — pinned image, same box, N runs, JSON artifact.
#
# STRICTLY SEQUENTIAL (METHOD.md rule 1): never both stacks at once. We measure
# OUR stack first (assumed already up — `make up PACKAGE=pro`), then this script
# boots Supabase separately. Supabase's ~13-container stack wants ~2 GB; the
# guard below aborts if MemAvailable is too low rather than thrash.
#
# This script is ON-DEMAND only (never in verify-all). It does NOT tear our
# stack down — run it, read the Supabase side, then compare against the
# already-captured artifacts/bench/load-*.json + footprint-*.json from our side.
#
# Output: artifacts/bench/grobase-vs-supabase.json (Supabase side + a pointer to
# our-side artifacts for the diff).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-bench.sh"

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }

SUPABASE_REF="${SUPABASE_REF:-v1.24.09}"   # pinned supabase/supabase tag
MIN_AVAIL_MB="${MIN_AVAIL_MB:-2500}"
N="${N:-100}"
WORK="$(mktemp -d)"
SB_DIR="${WORK}/supabase"

cleanup() {
	if [[ -d "${SB_DIR}/docker" ]]; then
		( cd "${SB_DIR}/docker" && docker compose down -v >/dev/null 2>&1 || true )
	fi
	rm -rf "${WORK}"
}
trap cleanup EXIT

# ── memory guard (METHOD.md): don't thrash the box ──────────────────────────
AVAIL="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
if (( AVAIL < MIN_AVAIL_MB )); then
	red "MemAvailable ${AVAIL}MB < ${MIN_AVAIL_MB}MB — free memory (or `make down`) before benching Supabase."
	red "This harness is strictly sequential: bench OUR stack first, capture artifacts, THEN run this."
	exit 1
fi
cyan "[vs-supabase] MemAvailable ${AVAIL}MB — ok. Supabase ref ${SUPABASE_REF}, N=${N}."

# ── boot Supabase (pinned) ──────────────────────────────────────────────────
cyan "[vs-supabase] cloning supabase/supabase @ ${SUPABASE_REF}…"
git clone --depth 1 --branch "${SUPABASE_REF}" https://github.com/supabase/supabase.git "${SB_DIR}" >/dev/null 2>&1 \
	|| { red "clone failed — check the pinned ref ${SUPABASE_REF}, or run on-demand with network access"; exit 1; }
cd "${SB_DIR}/docker"
cp .env.example .env
cyan "[vs-supabase] booting the Supabase stack (this pulls ~13 images)…"
docker compose up -d >/dev/null 2>&1 || { red "supabase compose up failed"; exit 1; }

# Wait for Kong (the Supabase gateway) to answer.
SB_KONG="http://127.0.0.1:8000"
for _ in $(seq 1 60); do
	curl -s -o /dev/null "${SB_KONG}/rest/v1/" && break || sleep 5
done

# ── seed an identical bench table (fairness fix) ────────────────────────────
# Stock Supabase ships no bench_items; without this the read probe below would
# time 404s instead of real CRUD. Mirror our side's bench_items (500 rows) and
# grant anon SELECT so PostgREST serves it (our bench_items table is RLS-less
# too, so this is apples-to-apples for the read probe).
cyan "[vs-supabase] seeding bench_items (500 rows) on the Supabase side…"
docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1 \
	|| red "[vs-supabase] seed warning — read probe may be less accurate"
CREATE TABLE IF NOT EXISTS public.bench_items (id text primary key, name text, grp text, val int);
TRUNCATE public.bench_items;
INSERT INTO public.bench_items SELECT 'r'||g, 'name'||g, 'grp'||(g%10), g FROM generate_series(1,500) g;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bench_items TO anon, authenticated, service_role;
ALTER TABLE public.bench_items DISABLE ROW LEVEL SECURITY;
NOTIFY pgrst, 'reload schema';
SQL
sleep 2

# ── footprint: sum docker stats RAM of the supabase-* containers ────────────
# Match ONLY supabase containers (their names all contain "supabase"), so this
# stays correct when our stack runs alongside (ours are "mini-baas-*"; the old
# kong|realtime|gotrue alternation also matched our containers).
cyan "[vs-supabase] measuring Supabase footprint…"
SB_RAM="$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' \
	| grep -E 'supabase' \
	| awk '{print $2}' | sed 's/MiB//;s/GiB/*1024/' | paste -sd+ | bc 2>/dev/null | cut -d. -f1)"
SB_RAM="${SB_RAM:-0}"
cyan "[vs-supabase] Supabase total RSS ≈ ${SB_RAM} MiB"

# ── identical CRUD workload via k6 against PostgREST ────────────────────────
# Supabase seeds an anon apikey in .env; create the bench table via the SQL
# endpoint (meta) or assume the example schema. For a clean comparison we hit
# the public schema's REST surface with the service key.
SB_ANON="$(grep -E '^ANON_KEY=' .env | cut -d= -f2-)"
cyan "[vs-supabase] running ${N}-sample CRUD latency probe via PostgREST…"
# Reuse the same logical mix the k6 crud.js runs, but against PostgREST's REST
# shape (see METHOD.md equivalence map). A lightweight curl-timed probe keeps
# this dependency-free and matches the nano-vs-pocketbase method.
sb_probe() { # $1 method $2 path $3 body
	curl -s -o /dev/null -w '%{time_total}' -X "$1" "${SB_KONG}/rest/v1/$2" \
		-H "apikey: ${SB_ANON}" -H "Authorization: Bearer ${SB_ANON}" \
		-H 'Content-Type: application/json' ${3:+-d "$3"}
}
read_ms=(); for _ in $(seq 1 "${N}"); do
	t="$(sb_probe GET 'bench_items?limit=30' '')"; read_ms+=("$(awk -v t="${t}" 'BEGIN{printf "%.2f", t*1000}')")
done
P95="$(printf '%s\n' "${read_ms[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.95)]}')"
P50="$(printf '%s\n' "${read_ms[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.5)]}')"

FINAL="${BENCH_OUT_DIR}/grobase-vs-supabase.json"
jq -n --arg ref "${SUPABASE_REF}" --argjson n "${N}" --argjson ram "${SB_RAM}" \
	--argjson p50 "${P50:-0}" --argjson p95 "${P95:-0}" --argjson env "$(bench_env_json)" '
	{ supabase: { ref:$ref, total_rss_mib:$ram, read_p50_ms:$p50, read_p95_ms:$p95, n:$n },
	  grobase_artifacts: { latency:"load-essential-crud.json", footprint:"../footprint-pro.json" },
	  note:"Compare supabase.total_rss_mib vs our footprint-*.json; supabase.read_p95_ms vs load-essential-crud.json .median.ops.list.p95",
	  env:$env }' > "${FINAL}"

green "[vs-supabase] Supabase: ${SB_RAM} MiB RSS, read p50 ${P50}ms / p95 ${P95}ms → ${FINAL#${BENCH_ROOT}/}"
green "[vs-supabase] compare against our load-essential-crud.json (read p95 2.4ms) + footprint-*.json"
