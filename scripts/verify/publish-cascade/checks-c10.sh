# shellcheck shell=sh

# publish-cascade/checks-c10.sh — c10 the hot-path cost: the pages trigger adds
# a WHEN clause to every row of every content save; the whole trigger (WHEN
# false) is what the 1.10x budget has to cover.
#
# Sourced by scripts/verify/publish-cascade.sh, which calls this check: the
# linter reads one file at a time and calls it unreachable.
# shellcheck disable=SC2317,SC2329

# Timed inside the server with clock_timestamp(): an earlier wall-clock version
# also timed docker exec + psql start-up, and running every "with" sample
# before every "without" one charged the trigger for warm-up and for the page's
# growing HOT chain (measured 1.12x on a WHEN that never matches). Samples now
# alternate, the trigger toggled with DISABLE/ENABLE.
# Caveat: a shared CI runner can still stall one sample; the median of 7 per
# side absorbs up to 3 stalls per side, not a runner busy for the whole check.
BENCH_FN="
CREATE OR REPLACE FUNCTION pg_temp.c10_bench(target uuid) RETURNS numeric
LANGUAGE plpgsql AS \$\$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
  FOR i IN 1..5000 LOOP
    UPDATE public.osionos_pages
       SET content = CASE WHEN content = '[]'::jsonb THEN '[1]'::jsonb ELSE '[]'::jsonb END
     WHERE id = target;
  END LOOP;
  RETURN round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
END \$\$;"

# bench_once <enable|disable> — one 5,000-UPDATE sample, printed in ms.
bench_once() {
	q "ALTER TABLE public.osionos_pages $1 TRIGGER osionos_publish_unhold;
${BENCH_FN}
SELECT pg_temp.c10_bench('${PBM}');" | tail -n 1
}

median7() {
	printf '%s\n' "$@" | sort -n | sed -n '4p'
}

check_c10() {
	bench_once enable >/dev/null
	bench_once disable >/dev/null
	with_runs=""
	without_runs=""
	for _ in 1 2 3 4 5 6 7; do
		with_runs="${with_runs} $(bench_once enable)"
		without_runs="${without_runs} $(bench_once disable)"
	done

	# Restore before judging, win or lose: the migration file is the truth.
	q "ALTER TABLE public.osionos_pages ENABLE TRIGGER osionos_publish_unhold" >/dev/null
	undo_stream || return 1

	# shellcheck disable=SC2086 # word-splitting the run lists is the point
	with_median="$(median7 ${with_runs})"
	# shellcheck disable=SC2086
	without_median="$(median7 ${without_runs})"
	ratio="$(awk -v w="${with_median}" -v o="${without_median}" 'BEGIN {
		if (o <= 0) { print "9007199254740992" }
		else { printf "%.2f", w / o }
	}')"
	note "c10 runs with the trigger:${with_runs} ms; without:${without_runs} ms"
	if awk -v w="${with_median}" -v o="${without_median}" 'BEGIN { exit (o <= 0 || w / o > 1.10) ? 0 : 1 }'; then
		printf 'FAIL c10 hot-path      with %s ms, without %s ms, ratio %s (limit 1.10)\n' \
			"${with_median}" "${without_median}" "${ratio}"
		return 1
	fi
	printf 'PASS c10 hot-path      with %s ms, without %s ms, ratio %s (limit 1.10)\n' \
		"${with_median}" "${without_median}" "${ratio}"
	return 0
}
