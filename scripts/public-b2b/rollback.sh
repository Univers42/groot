#!/usr/bin/env bash
# rollback.sh — take the public Prismatica site off b2b (ADR 0013, PUB-13). Human-run:
#   bash scripts/public-b2b/rollback.sh [<serve-before-*.json path on the VM>]
# Without an argument it uses the newest serve-before file deploy.sh saved.
#
# Order: funnel :10000 off -> the serve config must equal the saved one (so both :443 hosts
# are back as they were) -> `docker compose -p prismatica-public down`. Never
# `tailscale serve reset`, never `-v` (the redis volume stays; drop it by hand if wanted),
# never a mini-baas-* container.
#
# It does NOT undo what visitors did: accounts, public.users rows, newsletter opt-ins and sent
# mail stay in grobase prod. It prints the SQL that lists them; it does not run it.
#
# Caveat: the T0 in the printed SQL is the timestamp in the saved file's name (UTC, taken
# before the images were shipped), and auth_audit_events.created_at is a timestamp without
# time zone, so compare it with the database's own clock setting. Events of rejected
# (non-allowlisted) registrations are audit rows only; there is no account to delete.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib.sh
. "$root/scripts/public-b2b/lib.sh"

before_json=${1:-}
if [ -z "$before_json" ]; then
	before_json=$("${B2B[@]}" "ls -t $REMOTE_DIR/serve-before-*.json 2>/dev/null | head -1" || true)
fi
[ -n "$before_json" ] || fail "no saved serve config under $REMOTE_DIR: pass the path explicitly"
"${B2B[@]}" "test -s '$before_json'" || fail "$before_json is missing or empty on the VM"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
now_json=$REMOTE_DIR/serve-rollback-$stamp.json
t0=$(basename "$before_json" .json)
t0=${t0#serve-before-}

echo "== 1. funnel :$FUNNEL_PORT off (the :443 hosts are not touched)"
"${B2B[@]}" "tailscale funnel --https=$FUNNEL_PORT off" 2>&1 | sed 's/^/  /' || true
"${B2B[@]}" "tailscale serve status --json > $now_json && chmod 600 $now_json"
serve_equal "$before_json" "$now_json" ||
	fail "PUB-13: the serve config is not back to $before_json (compare with $now_json); do not reset it, fix the named keys by hand"
echo "  ok   serve config equals $before_json"

echo "== 2. docker compose -p $PROJECT down (no -v)"
down=(env PUBLIC_SITE_IMAGE=down PUBLIC_GATEWAY_IMAGE=down docker compose -p "$PROJECT" -f "$REMOTE_DIR/public-b2b.yml" down --remove-orphans)
if ! "${B2B[@]}" "set -o pipefail; ${down[*]} 2>&1 | tail -6"; then
	fail "compose down failed: remove the containers labelled com.docker.compose.project=$PROJECT by hand"
fi
left=$("${B2B[@]}" "docker ps -aq --filter label=com.docker.compose.project=$PROJECT | wc -l")
[ "$left" = 0 ] || fail "$left container(s) of $PROJECT remain"
echo "  ok   no $PROJECT container left (volume ${PROJECT}_public-redis-data kept)"
echo "  mini-baas for the human to compare with the deploy output: $("${B2B[@]}" "docker compose -p mini-baas ps -a -q | wc -l") containers, waf $("${B2B[@]}" "docker inspect mini-baas-waf --format '{{.State.StartedAt}}'")"

cat <<NOTE

== NOT undone
Accounts, public.users rows, newsletter opt-ins and the mail already sent stay in grobase prod.
List what happened since the deploy (T0 = $t0, UTC) and delete by hand if wanted:

  SELECT created_at, event_type, email, ip_address
    FROM public.auth_audit_events
   WHERE created_at >= '${t0:0:4}-${t0:4:2}-${t0:6:2} ${t0:9:2}:${t0:11:2}:${t0:13:2}'
   ORDER BY created_at;

Run it with your usual psql path to the prod database. Drop the redis volume only if the
lockouts and spent links it holds no longer matter:
  ssh b2b 'docker volume rm ${PROJECT}_public-redis-data'
NOTE
