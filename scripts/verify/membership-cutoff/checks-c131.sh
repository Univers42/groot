# shellcheck disable=SC2317,SC2329
check_c131() {
  snap1="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.osionos_workspace_members'::regclass AND tgname IN ('osionos_membership_cutoff_update','osionos_membership_cutoff_delete');")"
  apply "${MODELS}/osionos-membership-cutoff-migration.sql" >/dev/null || return 1
  apply "${MODELS}/osionos-membership-cutoff-migration.sql" >/dev/null || return 1
  snap2="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.osionos_workspace_members'::regclass AND tgname IN ('osionos_membership_cutoff_update','osionos_membership_cutoff_delete');")"
  [ "${snap1}" = "${snap2}" ] || { printf 'FAIL c131 idempotent  trigger count changed (%s -> %s)\n' "${snap1}" "${snap2}" >&2; return 1; }
  [ "${snap2}" = "2" ] || { printf 'FAIL c131 idempotent  expected 2 triggers, got %s\n' "${snap2}" >&2; return 1; }
  # DOWN block
  q "DROP TRIGGER IF EXISTS osionos_membership_cutoff_update ON public.osionos_workspace_members;" >/dev/null
  q "DROP TRIGGER IF EXISTS osionos_membership_cutoff_delete ON public.osionos_workspace_members;" >/dev/null
  q "DROP FUNCTION IF EXISTS public.osionos_membership_cutoff_stamp();" >/dev/null
  tcount="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.osionos_workspace_members'::regclass AND tgname IN ('osionos_membership_cutoff_update','osionos_membership_cutoff_delete');")"
  [ "${tcount}" = "0" ] || { printf 'FAIL c131 down  triggers remain: %s\n' "${tcount}" >&2; return 1; }
  fcount="$(q "SELECT count(*) FROM pg_proc WHERE proname = 'osionos_membership_cutoff_stamp';")"
  [ "${fcount}" = "0" ] || { printf 'FAIL c131 down  function remains: %s\n' "${fcount}" >&2; return 1; }
  # restore
  apply "${MODELS}/osionos-membership-cutoff-migration.sql" >/dev/null || return 1
  return 0
}
