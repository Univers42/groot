# shellcheck disable=SC2317,SC2329
check_c124() {
  # orphan member delete succeeds with 0 rows
  O="33333333-3333-4333-8333-333333333333"
  W="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W}','${O}','wo','wo-${O}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W}','${O}','viewer',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
  # orphan (no auth.users row) delete must succeed
  if ! q "DELETE FROM public.osionos_workspace_members WHERE workspace_id='${W}' AND user_id='${O}';" >/dev/null 2>&1; then
    printf 'FAIL c124 orphan-delete  delete of orphan member failed\n' >&2; return 1
  fi
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "0" ] || { printf 'FAIL c124 orphan-delete  expected 0, got %s\n' "${c}" >&2; return 1; }

  # workspace holding an orphan: delete succeeds
  O2="44444444-4444-4444-8444-444444444444"
  W2="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W2}','${O2}','wo2','wo2-${O2}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W2}','${O2}','viewer',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  if ! q "DELETE FROM public.osionos_workspaces WHERE id='${W2}';" >/dev/null 2>&1; then
    printf 'FAIL c124 ws-orphan-delete workspace delete with orphan failed\n' >&2; return 1
  fi

  # delete as postgres -> 1 row
  q "INSERT INTO auth.users (id) VALUES ('${U1:=11111111-1111-4111-8111-111111111111}') ON CONFLICT DO NOTHING;" >/dev/null
  W3="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W3}','${U1}','w3','w3-${U1}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W3}','${U1}','owner',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
  q "DELETE FROM public.osionos_workspace_members WHERE workspace_id='${W3}' AND user_id='${U1}';" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "1" ] || { printf 'FAIL c124 postgres-delete expected 1, got %s\n' "${c}" >&2; return 1; }

  # delete as service_role -> 1 row
  U2="22222222-2222-4222-8222-222222222222"
  q "INSERT INTO auth.users (id) VALUES ('${U2}') ON CONFLICT DO NOTHING;" >/dev/null
  W4="ffffffff-ffff-4fff-8fff-ffffffffffff"
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W4}','${U2}','w4','w4-${U2}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W4}','${U2}','owner',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
  if ! q "SET ROLE service_role; DELETE FROM public.osionos_workspace_members WHERE workspace_id='${W4}' AND user_id='${U2}'; RESET ROLE;" >/dev/null 2>&1; then
    printf 'FAIL c124 service-role-delete delete failed\n' >&2; return 1
  fi
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" = "1" ] || { printf 'FAIL c124 service-role-delete expected 1, got %s\n' "${c}" >&2; return 1; }

  # A forced insert failure aborts the delete. The CHECK has to be there: a
  # constraint that was never added would let the delete through, and the check
  # would prove nothing.
  U3="55555555-5555-4555-8555-555555555555"
  q "INSERT INTO auth.users (id) VALUES ('${U3}') ON CONFLICT DO NOTHING;" >/dev/null
  W5="99999999-9999-4999-8999-999999999999"
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W5}','${U3}','w5','w5-${U3}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W5}','${U3}','owner',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  if ! q "ALTER TABLE public.auth_session_cutoffs ADD CONSTRAINT mc_fail_check CHECK (false) NOT VALID;" >/dev/null; then
    printf 'FAIL c124 forced-failure  the CHECK constraint was not added: the delete would have gone through\n' >&2
    q "ALTER TABLE public.auth_session_cutoffs DROP CONSTRAINT IF EXISTS mc_fail_check;" >/dev/null
    return 1
  fi
  # delete should now fail
  if q "DELETE FROM public.osionos_workspace_members WHERE workspace_id='${W5}' AND user_id='${U3}';" >/dev/null 2>&1; then
    printf 'FAIL c124 forced-failure  delete succeeded despite failing insert\n' >&2
    q "ALTER TABLE public.auth_session_cutoffs DROP CONSTRAINT IF EXISTS mc_fail_check;" >/dev/null
    return 1
  fi
  q "ALTER TABLE public.auth_session_cutoffs DROP CONSTRAINT IF EXISTS mc_fail_check;" >/dev/null
  return 0
}
