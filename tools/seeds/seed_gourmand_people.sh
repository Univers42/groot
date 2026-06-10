#!/usr/bin/env bash
# **************************************************************************** #
#  seed_gourmand_people.sh — Vite & Gourmand staff mirroring                   #
#                                                                              #
#  Mirrors the restaurant's REAL staff (their "User" ⋈ "Role" rows, roles      #
#  superadmin/admin/employee — customers are NEVER mirrored) into osionos:    #
#    1) roster queried live from the client DB THROUGH THE GATEWAY (the       #
#       gourmand-db mount provisioned by gourmand-tenant.sh)                  #
#    2) gotrue accounts (their real emails, generated passwords — the owner   #
#       distributes them; gotrue recovery flows stay available)               #
#    3) bridge identities + private workspaces (osionos_bridge_upsert_…)      #
#    4) the shared org workspace "Vite & Gourmand" + members with mapped      #
#       roles: CompanyOwner→owner, superadmin/admin→admin, employee→editor    #
#    5) roster + credentials snapshot → tools/seeds/.gourmand-people.env      #
#       (gitignored — contains passwords)                                     #
#                                                                              #
#  Idempotent: accounts resolved from auth.users, SQL upsert-shaped,          #
#  existing accounts keep their passwords (only NEW accounts get one).        #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INFRA_ROOT="${REPO_ROOT}/apps/baas/mini-baas-infra"
PG_CTN="${GOURMAND_PG_CONTAINER:-track-binocle-postgres-1}"
BRIDGE_CTN="${GOURMAND_BRIDGE_CONTAINER:-track-binocle-osionos-bridge-1}"
ORG_WS_ID="c2b1d2f6-0000-4000-a000-000000000002"
ORG_WS_NAME="Vite & Gourmand"
ORG_WS_SLUG="vite-gourmand"
OUT_ENV="${SCRIPT_DIR}/.gourmand-people.env"
STATE_ENV="${INFRA_ROOT}/.gourmand-tenant.env"
APP_ENV_FILE="${APP_ENV_FILE:-${REPO_ROOT}/apps/osionos/app/.env}"

cyan()  { printf '\033[0;36m[vg-people] %s\033[0m\n' "$*"; }
fail()  { printf '\033[0;31m[vg-people] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

docker inspect "${PG_CTN}" >/dev/null 2>&1 || fail "postgres container ${PG_CTN} not running (root stack)"
docker inspect "${BRIDGE_CTN}" >/dev/null 2>&1 || fail "bridge container ${BRIDGE_CTN} not running"
[[ -f "${STATE_ENV}" ]] || fail "run apps/baas/mini-baas-infra/scripts/seed/gourmand-tenant.sh first"
# shellcheck disable=SC1090
source "${STATE_ENV}"
DB_ID="${GOURMAND_DB_ID:?}"
KONG="${GOURMAND_KONG_URL:?}"

_env() { docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$2=" | head -1 | cut -d= -f2-; }
EMAIL_SALT="$(_env "${BRIDGE_CTN}" OSIONOS_BRIDGE_EMAIL_HASH_SALT)"
[[ -n "${EMAIL_SALT}" ]] || EMAIL_SALT="$(_env "${BRIDGE_CTN}" OSIONOS_BRIDGE_SHARED_SECRET)"
[[ -n "${EMAIL_SALT}" ]] || fail "email hash salt not found on bridge container"
ANON_KEY="$(docker inspect mini-baas-kong --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^KONG_PUBLIC_API_KEY=' | cut -d= -f2-)"
APP_KEY="${BAAS_API_KEY:-$(sed -n 's/^VITE_BAAS_API_KEY=//p' "${APP_ENV_FILE}" | head -1)}"
[[ "${APP_KEY}" == mbk_* ]] || fail "no app key"

PSQL() { docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
gwq() { # $1 table, $2 body → stdout json
  curl -fsS -X POST "${KONG}/query/v1/${DB_ID}/tables/$1" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${APP_KEY}" \
    -H 'Content-Type: application/json' -d "$2"
}

# ── 1) the REAL staff roster, straight from their database ───────────────────
cyan "querying the client's staff roster (User ⋈ Role, staff roles only)"
ROLES_JSON="$(gwq Role '{"op":"list","limit":50}')" || fail "Role list failed"
USERS_JSON="$(gwq User '{"op":"list","limit":500}')" || fail "User list failed"
OWNERS_JSON="$(gwq CompanyOwner '{"op":"list","limit":50}')" || fail "CompanyOwner list failed"
ROSTER_TSV="$(python3 - "$ROLES_JSON" "$USERS_JSON" "$OWNERS_JSON" <<'PY'
import json, sys
roles = {r["id"]: r["name"] for r in json.loads(sys.argv[1])["rows"]}
users = json.loads(sys.argv[2])["rows"]
owners = {o["user_id"] for o in json.loads(sys.argv[3])["rows"] if str(o.get("role", "")).lower() == "owner"}
STAFF = {"superadmin", "admin", "employee"}
out = []
for u in users:
    role = roles.get(u.get("role_id"), "")
    if role not in STAFF:
        continue  # customers are never mirrored
    name = " ".join(p for p in [u.get("first_name"), u.get("last_name")] if p) or u["email"]
    if u["id"] in owners:
        ws = "owner"
    elif role in ("superadmin", "admin"):
        ws = "admin"
    else:
        ws = "editor"
    out.append((ws != "owner", u["email"], name.replace("|", " "), role, ws))
out.sort()  # owner first, stable order
if not any(row[4] == "owner" for row in out):
    # no CompanyOwner row → promote the first superadmin/admin
    for i, row in enumerate(out):
        if row[3] in ("superadmin", "admin"):
            out[i] = (row[0], row[1], row[2], row[3], "owner")
            break
for _, email, name, role, ws in out:
    print(f"{email}|{name}|{role}|{ws}")
PY
)" || fail "roster extraction failed"
[[ -n "${ROSTER_TSV}" ]] || fail "no staff rows found in the client User table"
STAFF_COUNT="$(printf '%s\n' "${ROSTER_TSV}" | wc -l | tr -d ' ')"
cyan "mirroring ${STAFF_COUNT} staff member(s)"

# ── 2) gotrue accounts (existing accounts untouched; new get generated pw) ───
gen_pw() { printf 'Vg%s!9' "$(openssl rand -hex 6 2>/dev/null || date +%s%N | tail -c 12)"; }
declare -A PW_OF
# Reuse previously generated passwords so re-runs don't rotate them silently.
if [[ -f "${OUT_ENV}" ]]; then
  while IFS='|' read -r email pw; do
    [[ -n "${email}" && -n "${pw}" ]] && PW_OF["${email}"]="${pw}"
  done < <(sed -n 's/^GOURMAND_CRED_[0-9]*=//p' "${OUT_ENV}" | awk -F'|' '{print $1"|"$5}')
fi
ROSTER_WITH_PW=""
while IFS='|' read -r email name role ws; do
  pw="${PW_OF[${email}]:-$(gen_pw)}"
  PW_OF["${email}"]="${pw}"
  ROSTER_WITH_PW+="${email}|${name}|${pw}"$'\n'
done <<<"${ROSTER_TSV}"

cyan "ensuring gotrue accounts (idempotent; new accounts only get passwords)"
docker exec -i -e ROSTER="${ROSTER_WITH_PW}" "${BRIDGE_CTN}" node - <<'JS' || fail "gotrue account creation failed"
const GOTRUE = 'http://track-binocle-gotrue-1:9999';
const KEY = process.env.SERVICE_ROLE_KEY;
const rows = process.env.ROSTER.trim().split('\n').map((l) => l.split('|'));
const auth = { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` };
async function find(email) {
  const r = await fetch(`${GOTRUE}/admin/users?filter=${encodeURIComponent(email)}&per_page=10`, { headers: auth });
  if (!r.ok) return null;
  const b = await r.json().catch(() => null);
  return (b?.users ?? []).find((u) => u.email === email) ?? null;
}
const run = async () => {
  for (const [email, name, password] of rows) {
    let user = await find(email);
    if (!user) {
      const r = await fetch(`${GOTRUE}/signup`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password, data: { name } }),
      });
      if (!r.ok) throw new Error(`signup ${email}: ${r.status} ${await r.text()}`);
      const b = await r.json();
      user = b.user ?? b;
    }
    if (!user?.id) throw new Error(`no uuid for ${email}`);
    console.log(`OK ${email} ${user.id}`);
  }
};
run().catch((e) => { console.error('ERR', e.message); process.exit(1); });
JS

# ── 3) uuids from auth.users + bridge identities + private workspaces ────────
cyan "upserting bridge identities + private workspaces"
declare -A UUID_OF
while IFS='|' read -r email uuid; do
  email="${email// /}"; uuid="${uuid// /}"
  [[ -n "${email}" && -n "${uuid}" ]] && UUID_OF["${email}"]="${uuid}"
done < <(PSQL -At -F'|' -c "SELECT email, id FROM auth.users")
{
  while IFS='|' read -r email name _role _ws; do
    uuid="${UUID_OF[${email}]:-}"
    [[ -n "${uuid}" ]] || { echo "-- missing ${email}" ; continue; }
    printf "SELECT public.osionos_bridge_upsert_workspace('prismatica', '%s'::uuid, encode(hmac('%s', :'salt', 'sha256'), 'hex'), '%s');\n" \
      "${uuid}" "${email}" "${name//\'/\'\'}"
  done <<<"${ROSTER_TSV}"
} | PSQL -q -v salt="${EMAIL_SALT}" >/dev/null || fail "bridge identity upsert failed"

# ── 4) org workspace + members with mapped roles ─────────────────────────────
OWNER_EMAIL="$(printf '%s\n' "${ROSTER_TSV}" | awk -F'|' '$4=="owner"{print $1; exit}')"
OWNER_UUID="${UUID_OF[${OWNER_EMAIL}]:-}"
[[ -n "${OWNER_UUID}" ]] || fail "owner uuid not resolved (${OWNER_EMAIL})"
cyan "upserting org workspace '${ORG_WS_NAME}' (owner ${OWNER_EMAIL}) + ${STAFF_COUNT} members"
{
  cat <<SQL
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug, source, settings)
VALUES ('${ORG_WS_ID}', '${OWNER_UUID}', '${ORG_WS_NAME}', '${ORG_WS_SLUG}', 'bridge',
        jsonb_build_object('bridgeProvider', 'prismatica', 'org', true, 'client', 'vite-gourmand'))
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, slug = EXCLUDED.slug,
  owner_id = EXCLUDED.owner_id, settings = EXCLUDED.settings, updated_at = now();
SQL
  while IFS='|' read -r email _name _role ws; do
    uuid="${UUID_OF[${email}]:-}"; [[ -n "${uuid}" ]] || continue
    case "${ws}" in
      owner|admin) perms="ARRAY['create','read','update','delete','admin']" ;;
      editor)      perms="ARRAY['create','read','update','delete']" ;;
      *)           perms="ARRAY['read']" ;;
    esac
    cat <<SQL
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
VALUES ('${ORG_WS_ID}', '${uuid}', '${ws}', ${perms})
ON CONFLICT ON CONSTRAINT osionos_workspace_members_pkey
DO UPDATE SET role = EXCLUDED.role, permissions = EXCLUDED.permissions, updated_at = now();
SQL
  done <<<"${ROSTER_TSV}"
} | PSQL -q >/dev/null || fail "org workspace/member upsert failed"

# ── 5) snapshot (contains the generated passwords — gitignored, mode 600) ────
cyan "writing ${OUT_ENV}"
{
  echo "# generated by seed_gourmand_people.sh — $(date -Iseconds)"
  echo "GOURMAND_ORG_WORKSPACE_ID=${ORG_WS_ID}"
  echo "GOURMAND_OWNER_UUID=${OWNER_UUID}"
  echo "GOURMAND_OWNER_EMAIL=${OWNER_EMAIL}"
  echo "GOURMAND_STAFF_COUNT=${STAFF_COUNT}"
  i=0
  while IFS='|' read -r email name role ws; do
    echo "GOURMAND_CRED_${i}=${email}|${UUID_OF[${email}]:-}|${name}|${ws}|${PW_OF[${email}]}"
    i=$((i + 1))
  done <<<"${ROSTER_TSV}"
} > "${OUT_ENV}"
chmod 600 "${OUT_ENV}"
cyan "OK — ${STAFF_COUNT} staff mirrored into '${ORG_WS_NAME}' (${ORG_WS_ID})"
