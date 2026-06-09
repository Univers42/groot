#!/usr/bin/env bash
# ===========================================================================
# Migrate your existing osionos account + workspaces/pages from the running
# Docker stack's Postgres into the NATIVE edition's one-time import slot.
#
#   1. bash apps/osionos-electron/native-migrate.sh   (Docker stack's postgres comes up)
#   2. launch the native app — it imports on first launch (after gotrue) — then log in.
#
# Dumps gotrue's auth.users/identities (your password) + public.users + your
# osionos workspaces/pages as data-only INSERTs. The native firstrun loads them
# with FK triggers relaxed, then marks the file done.
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$REPO"
DATA_DIR="${OSIONOS_NATIVE_DATA:-$HOME/.config/osionos/native}"
mkdir -p "$DATA_DIR"
OUT="$DATA_DIR/import.sql"

echo "==> ensuring the Docker stack's postgres is up…"
docker compose up -d postgres >/dev/null 2>&1
docker compose exec -T postgres sh -c 'for i in $(seq 1 30); do pg_isready -U postgres -q && exit 0; sleep 0.5; done' >/dev/null 2>&1

echo "==> dumping account + data -> $OUT"
docker compose exec -T postgres pg_dump -U postgres -d postgres \
  --data-only --no-owner --column-inserts \
  -t 'auth.users' -t 'auth.identities' \
  -t 'public.users' \
  -t 'public.osionos_workspaces' -t 'public.osionos_workspace_members' \
  -t 'public.osionos_pages' -t 'public.osionos_page_configurations' \
  -t 'public.osionos_bridge_identities' \
  > "$OUT"

echo "==> wrote $(wc -l < "$OUT") lines ($(du -h "$OUT" | cut -f1))."
echo "    accounts: $(grep -c 'INSERT INTO auth.users' "$OUT" 2>/dev/null || echo '?'); pages: $(grep -c 'INSERT INTO public.osionos_pages' "$OUT" 2>/dev/null || echo '?')"
echo "Next: launch the native app (it imports on first launch), then log in with your account."
