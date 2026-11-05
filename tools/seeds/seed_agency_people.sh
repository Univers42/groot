#!/usr/bin/env bash
# **************************************************************************** #
#  seed_agency_people.sh — Binocle Intelligence Agency identity seeding        #
#                                                                              #
#  Creates the agency owner + 20 employees against the RUNNING root stack:    #
#    1) gotrue accounts (signup; 3 via the real /invite path so Mailpit       #
#       holds assertable invitation emails, then an admin password set so     #
#       those accounts stay usable)                                           #
#    2) bridge identities + private workspaces via the same SQL function      #
#       the bridge itself calls (osionos_bridge_upsert_workspace)             #
#    3) the shared org workspace "Binocle Intelligence Agency" + 21 members   #
#    4) roster snapshot to tools/seeds/.agency-people.env (uuid/role/dept/    #
#       clearance/region per person) for the data + policy seeders            #
#                                                                              #
#  Idempotent: existing accounts are resolved from auth.users, all SQL is     #
#  upsert-shaped. Secrets are read from the running containers, never from    #
#  the caller's shell (lib-live-tenant.sh discipline).                        #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_CTN="${AGENCY_PG_CONTAINER:-track-binocle-postgres-1}"
BRIDGE_CTN="${AGENCY_BRIDGE_CONTAINER:-track-binocle-osionos-bridge-1}"
# shellcheck source=tools/seeds/agency-roster.sh
. "${SCRIPT_DIR}/agency-roster.sh"
ORG_WS_NAME="Binocle Intelligence Agency"
ORG_WS_SLUG="binocle-intelligence-agency"
OUT_ENV="${SCRIPT_DIR}/.agency-people.env"

cyan() { printf '\033[0;36m[people] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[people] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

docker inspect "${PG_CTN}" >/dev/null 2>&1 || fail "postgres container ${PG_CTN} not running"
docker inspect "${BRIDGE_CTN}" >/dev/null 2>&1 || fail "bridge container ${BRIDGE_CTN} not running"

_env() { docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$2=" | head -1 | cut -d= -f2-; }
EMAIL_SALT="$(_env "${BRIDGE_CTN}" OSIONOS_BRIDGE_EMAIL_HASH_SALT)"
[[ -n "${EMAIL_SALT}" ]] || EMAIL_SALT="$(_env "${BRIDGE_CTN}" OSIONOS_BRIDGE_SHARED_SECRET)"
[[ -n "${EMAIL_SALT}" ]] || fail "email hash salt not found on bridge container"

PSQL() { docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

DEFAULT_PASSWORD="${AGENCY_PASSWORD:-AgencyDemo1!}"
OWNER_PASSWORD="${AGENCY_OWNER_PASSWORD:-BinocleOwner1!}"

# ── 1) gotrue accounts (node inside the bridge container — it owns the net) ──
cyan "ensuring ${#ROSTER[@]} gotrue accounts (signup/invite, idempotent)"
ROSTER_LINES="$(printf '%s\n' "${ROSTER[@]}")"
docker exec -i \
  -e ROSTER="${ROSTER_LINES}" -e DEFAULT_PASSWORD="${DEFAULT_PASSWORD}" \
  -e OWNER_PASSWORD="${OWNER_PASSWORD}" \
  "${BRIDGE_CTN}" node - <<'JS' || fail "gotrue account creation failed"
// Container name, not the `gotrue` service alias: the bridge sits on both the
// root and mini-baas networks, and BOTH have a `gotrue` — the alias would
// round-robin into the wrong stack.
const GOTRUE = 'http://track-binocle-gotrue-1:9999';
const KEY = process.env.SERVICE_ROLE_KEY;
const rows = process.env.ROSTER.trim().split('\n').map((l) => l.split('|'));
const auth = { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` };

async function adminFindByEmail(email) {
  // gotrue admin list supports ?filter= on email
  const r = await fetch(`${GOTRUE}/admin/users?filter=${encodeURIComponent(email)}&per_page=10`, { headers: auth });
  if (!r.ok) return null;
  const b = await r.json().catch(() => null);
  const users = b?.users ?? [];
  return users.find((u) => u.email === email) ?? null;
}

async function ensure(email, name, mode, password) {
  let user = await adminFindByEmail(email);
  if (!user) {
    if (mode === 'invite') {
      const r = await fetch(`${GOTRUE}/invite`, { method: 'POST', headers: auth, body: JSON.stringify({ email, data: { name } }) });
      if (!r.ok) throw new Error(`invite ${email}: ${r.status} ${await r.text()}`);
      user = await r.json();
    } else {
      const r = await fetch(`${GOTRUE}/signup`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password, data: { name } }),
      });
      if (!r.ok) throw new Error(`signup ${email}: ${r.status} ${await r.text()}`);
      const b = await r.json();
      user = b.user ?? b;
    }
  }
  if (!user?.id) throw new Error(`no uuid for ${email}`);
  // invited users have no password — set one via admin so the account is usable
  if (mode === 'invite') {
    const r = await fetch(`${GOTRUE}/admin/users/${user.id}`, {
      method: 'PUT', headers: auth,
      body: JSON.stringify({ password, email_confirm: true }),
    });
    if (!r.ok) throw new Error(`admin password ${email}: ${r.status} ${await r.text()}`);
  }
  return user.id;
}

const run = async () => {
  for (const [email, name, , , , , , mode] of rows) {
    const password = email === 'owner@agency.local' ? process.env.OWNER_PASSWORD : process.env.DEFAULT_PASSWORD;
    const id = await ensure(email, name, mode, password);
    console.log(`OK ${email} ${id}`);
  }
};
run().catch((e) => { console.error('ERR', e.message); process.exit(1); });
JS

# ── 2) resolve uuids from auth.users (source of truth) ───────────────────────
cyan "resolving uuids from auth.users"
declare -A UUID_OF
while IFS='|' read -r email uuid; do
  email="${email// /}"
  uuid="${uuid// /}"
  [[ -n "${email}" && -n "${uuid}" ]] && UUID_OF["${email}"]="${uuid}"
done < <(PSQL -At -F'|' -c "SELECT email, id FROM auth.users WHERE email LIKE '%@agency.local'")
for entry in "${ROSTER[@]}"; do
  email="${entry%%|*}"
  [[ -n "${UUID_OF[${email}]:-}" ]] || fail "no auth.users row for ${email}"
done

# ── 3) bridge identities + private workspaces (the bridge's own upsert fn) ───
cyan "upserting bridge identities + private workspaces"
{
  for entry in "${ROSTER[@]}"; do
    IFS='|' read -r email name _rest <<<"${entry}"
    uuid="${UUID_OF[${email}]}"
    # email_hash matches scripts/bridge-api.mjs emailHash(): HMAC-SHA256(email, salt)
    printf "SELECT public.osionos_bridge_upsert_workspace('prismatica', '%s'::uuid, encode(hmac('%s', :'salt', 'sha256'), 'hex'), '%s');\n" \
      "${uuid}" "${email}" "${name//\'/\'\'}"
  done
} | PSQL -q -v salt="${EMAIL_SALT}" >/dev/null || fail "bridge identity upsert failed"

# ── 4) shared org workspace + members ────────────────────────────────────────
cyan "upserting org workspace '${ORG_WS_NAME}' + 21 members"
owner_key="owner@agency.local"
OWNER_UUID="${UUID_OF[$owner_key]}"
{
  cat <<SQL
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug, source, settings)
VALUES ('${AGENCY_ORG_WS_ID}', '${OWNER_UUID}', '${ORG_WS_NAME}', '${ORG_WS_SLUG}', 'bridge',
        jsonb_build_object('bridgeProvider', 'prismatica', 'org', true))
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, slug = EXCLUDED.slug,
  owner_id = EXCLUDED.owner_id, settings = EXCLUDED.settings, updated_at = now();
SQL
  for entry in "${ROSTER[@]}"; do
    IFS='|' read -r email _name _role _dept _clr _region ws_role _mode <<<"${entry}"
    uuid="${UUID_OF[${email}]}"
    case "${ws_role}" in
    owner | admin) perms="ARRAY['create','read','update','delete','admin']" ;;
    editor) perms="ARRAY['create','read','update','delete']" ;;
    *) perms="ARRAY['read']" ;;
    esac
    cat <<SQL
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
VALUES ('${AGENCY_ORG_WS_ID}', '${uuid}', '${ws_role}', ${perms})
ON CONFLICT ON CONSTRAINT osionos_workspace_members_pkey
DO UPDATE SET role = EXCLUDED.role, permissions = EXCLUDED.permissions, updated_at = now();
SQL
  done
} | PSQL -q >/dev/null || fail "org workspace/member upsert failed"

# ── 5) roster snapshot for the data + policy seeders ─────────────────────────
cyan "writing ${OUT_ENV}"
write_agency_snapshot "${OWNER_UUID}" >"${OUT_ENV}"

MEMBERS=$(PSQL -At -c "SELECT count(*) FROM public.osionos_workspace_members WHERE workspace_id='${AGENCY_ORG_WS_ID}'")
[[ "${MEMBERS}" == "21" ]] || fail "expected 21 org members, found ${MEMBERS}"
cyan "DONE: 21 accounts, 21 identities/private workspaces, org workspace ${AGENCY_ORG_WS_ID} (21 members)"
