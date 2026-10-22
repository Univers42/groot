# shellcheck disable=SC2317,SC2329
check_c125() {
  U="66666666-6666-4666-8666-666666666666"
  W="66666666-eeee-4eee-8eee-666666666666"
  q "INSERT INTO auth.users (id) VALUES ('${U}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W}','${U}','w','w-${U}') ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W}','${U}','owner',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null

  run_commit_test() {
    printf "BEGIN;\nDELETE FROM public.osionos_workspace_members WHERE workspace_id='%s' AND user_id='%s';\nSELECT pg_sleep(2);\nCREATE TEMP TABLE _mc_t AS SELECT clock_timestamp() AS t;\nCOMMIT;\nSELECT (SELECT sessions_valid_after FROM public.auth_session_cutoffs WHERE user_id='%s') >= (SELECT t FROM _mc_t);\nDROP TABLE _mc_t;\n" "${W}" "${U}" "${U}" | psql_q | grep -v '^$' | tail -1
  }

  res="$(run_commit_test)"
  [ "${res}" = "t" ] || { printf 'FAIL c125 commit-stamp  expected t, got %s\n' "${res}" >&2; return 1; }

  # revert proof: stamp with now() -> should FAIL (f)
  q "CREATE OR REPLACE FUNCTION public.osionos_membership_cutoff_stamp() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM public.osionos_workspaces w WHERE w.id = OLD.workspace_id) THEN RETURN NULL; END IF; INSERT INTO public.auth_session_cutoffs (user_id, sessions_valid_after) SELECT OLD.user_id, now() WHERE EXISTS (SELECT 1 FROM auth.users u WHERE u.id = OLD.user_id) ON CONFLICT (user_id) DO UPDATE SET sessions_valid_after = EXCLUDED.sessions_valid_after; RETURN NULL; END \$\$;" >/dev/null
  # re-seed member
  q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W}','${U}','owner',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
  q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
  res="$(run_commit_test)"
  if [ "${res}" = "t" ]; then
    printf 'FAIL c125 revert-proof   now() stamp still passed (expected fail)\n' >&2
    apply "${MODELS}/osionos-membership-cutoff-migration.sql" >/dev/null
    return 1
  fi
  printf '[c125] revert-proof: now() stamp gave %s (expected f)\n' "${res}" >&2
  # restore
  apply "${MODELS}/osionos-membership-cutoff-migration.sql" >/dev/null || return 1
  return 0
}
