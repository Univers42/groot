# shellcheck disable=SC2317,SC2329
check_c130() {
  # seed 5000 rows
  q "INSERT INTO auth.users (id) SELECT ('10000000-0000-4000-8000-' || lpad(g::text,12,'0'))::uuid FROM generate_series(1,5000) g ON CONFLICT DO NOTHING;" >/dev/null
  q "INSERT INTO public.auth_session_cutoffs (user_id, sessions_valid_after) SELECT ('10000000-0000-4000-8000-' || lpad(g::text,12,'0'))::uuid, now() FROM generate_series(1,5000) g ON CONFLICT DO NOTHING;" >/dev/null
  c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
  [ "${c}" -ge 5000 ] || { printf 'FAIL c130 seed  only %s rows\n' "${c}" >&2; return 1; }

  svc="$(mint_jwt service_role)"
  out="$(JWT="${svc}" PGRST_PORT="${PGRST_PORT}" python3 - <<'PY'
import json, os, time, urllib.request
base = "http://127.0.0.1:%s" % os.environ["PGRST_PORT"]
jwt = os.environ["JWT"]
headers = {"Accept": "application/json", "apikey": jwt, "Authorization": "Bearer " + jwt}
total_bytes = 0
received = 0
total = None
cursor = None
t0 = time.time()
while True:
    url = base + "/auth_session_cutoffs?select=user_id,sessions_valid_after&order=user_id.asc&limit=500"
    h = dict(headers)
    if cursor is not None:
        url += "&user_id=gt." + cursor
    else:
        h["Prefer"] = "count=exact"
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req) as r:
        data = r.read()
        total_bytes += len(data)
        cr = r.headers.get("Content-Range")
        rows = json.loads(data)
    if cursor is None and cr:
        total = int(cr.split("/")[-1])
    received += len(rows)
    if len(rows) < 500:
        break
    cursor = rows[-1]["user_id"]
t1 = time.time()
ms = (t1 - t0) * 1000.0
print("C130 ms_per_tick=%.1f rows=%d total=%s bytes_per_reload=%d command=python3-urllib-paginated" % (ms, received, total, total_bytes))
PY
)"
  printf '%s\n' "${out}" >&2
  printf '%s\n' "${out}"
  echo "${out}" | grep -q "rows=5000" || { printf 'FAIL c130 reload  did not load 5000 rows\n' >&2; return 1; }
  return 0
}
