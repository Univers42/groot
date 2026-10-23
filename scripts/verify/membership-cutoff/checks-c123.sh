# shellcheck disable=SC2317,SC2329
U1="11111111-1111-4111-8111-111111111111"
U2="22222222-2222-4222-8222-222222222222"
# A fresh user for the user_id change: it has an auth.users row (so the cut-off
# table's foreign key holds) and NO row in W1 (so the update cannot hit the
# primary key of the members table).
U3="88888888-8888-4888-8888-888888888888"
W1="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
W2="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

seed_c123() {
  q "INSERT INTO auth.users (id) VALUES ('${U1}'),('${U2}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W1}','${U1}','w1','w1-${U1}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W2}','${U2}','w2','w2-${U2}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W1}','${U1}','owner',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W1}','${U2}','viewer',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
}

check_c123() {
  seed_c123
  # owner upserts as sign-in does -> 0 rows
  q "SELECT public.osionos_bridge_upsert_workspace('prismatica','${U1}','h','name');" >/dev/null
  q "SELECT public.osionos_bridge_upsert_workspace('prismatica','${U1}','h','name');" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "0" ] || { printf 'FAIL c123 owner-upsert  expected 0 cutoff rows, got %s\n' "${c}" >&2; return 1; }
  # env-admin merge-duplicates style upsert (role included) -> 0 rows
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W1}','${U2}','admin',ARRAY['read']) ON CONFLICT ON CONSTRAINT osionos_workspace_members_pkey DO UPDATE SET role='admin', permissions=EXCLUDED.permissions, updated_at=now();" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "0" ] || { printf 'FAIL c123 envadmin-upsert expected 0, got %s\n' "${c}" >&2; return 1; }
  # role change -> 0
  q "UPDATE public.osionos_workspace_members SET role='viewer' WHERE workspace_id='${W1}' AND user_id='${U1}';" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "0" ] || { printf 'FAIL c123 role-change expected 0, got %s\n' "${c}" >&2; return 1; }
  # delete -> 1
  q "DELETE FROM public.osionos_workspace_members WHERE workspace_id='${W1}' AND user_id='${U2}';" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "1" ] || { printf 'FAIL c123 delete expected 1, got %s\n' "${c}" >&2; return 1; }
  # workspace_id change -> 1 (new row)
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W1}','${U2}','viewer',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "UPDATE public.osionos_workspace_members SET workspace_id='${W2}' WHERE workspace_id='${W1}' AND user_id='${U2}';" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "1" ] || { printf 'FAIL c123 ws-change expected 1, got %s\n' "${c}" >&2; return 1; }
  # user_id change -> 1 row, and it is the OLD user's (U2): the row moved to U3, so
  # U2 is the one who lost the membership. U3 is fresh (an auth.users row, no row
  # in W1), so the update cannot hit the primary key of the members table.
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
  q "INSERT INTO auth.users (id) VALUES ('${U3}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W1}','${U2}','viewer',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "UPDATE public.osionos_workspace_members SET user_id='${U3}' WHERE workspace_id='${W1}' AND user_id='${U2}';" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "1" ] || { printf 'FAIL c123 user-change expected 1 cutoff row, got %s\n' "${c}" >&2; return 1; }
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs WHERE user_id='${U2}';")"
  [ "${c}" = "1" ] || { printf 'FAIL c123 user-change expected the row of the OLD user, got %s\n' "${c}" >&2; return 1; }
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs WHERE user_id='${U3}';")"
  [ "${c}" = "0" ] || { printf 'FAIL c123 user-change wrote %s row(s) for the NEW user\n' "${c}" >&2; return 1; }
  # Revert proof: rewrite trigger as AFTER UPDATE OF role -> upsert test FAILS
  q "DROP TRIGGER IF EXISTS osionos_membership_cutoff_update ON public.osionos_workspace_members;" >/dev/null
  q "CREATE CONSTRAINT TRIGGER osionos_membership_cutoff_update AFTER UPDATE OF role ON public.osionos_workspace_members DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.osionos_membership_cutoff_stamp();" >/dev/null
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
  # owner upsert should now produce a cutoff row
  q "SELECT public.osionos_bridge_upsert_workspace('prismatica','${U1}','h','name');" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  if [ "${c}" = "0" ]; then
    printf 'FAIL c123 revert-proof   column-list trigger did NOT fire (expected failure of upsert test)\n' >&2
    apply "${MODELS}/osionos-membership-cutoff-migration.sql" >/dev/null
    return 1
  fi
  printf '[c123] revert-proof: column-list trigger fired, %s cutoff rows (upsert test fails as required)\n' "${c}" >&2
  # restore
  apply "${MODELS}/osionos-membership-cutoff-migration.sql" >/dev/null || return 1
  return 0
}
