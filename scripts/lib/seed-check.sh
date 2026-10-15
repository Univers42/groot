# shellcheck shell=bash
# seed-check.sh — judge a pulled seed directory (secrets/) against the SHA256SUMS captured in it.
#
#   seed_report DIR LISTED     one line per SHA256SUMS entry: STATUS MODE SIZE NAME. STATUS is
#                              ok (the file is then narrowed to owner-only), CORRUPT (renamed
#                              NAME.corrupt so nothing installs it), missing (LISTED, a file of
#                              names relative to DIR, holds NAME but DIR does not) or private
#                              (not in LISTED: sealed to its pusher, it never reaches a teammate).
#   seeds_unverified DIR SUMS NAME…  "NAME: why" for each NAME that SUMS does not list, DIR does
#                              not hold, or whose bytes differ. Reads only: renames and chmods nothing.
#   seed_problems DIR LISTED   the seed_report table as a verdict (below).
#   engine_seeds REPO          the dumps restore-if-empty.sh needs; status 1 when it names none.

# Caveat: ENGINE_SEEDS is read with the env-file parser (envfile.sh, which the caller sources);
# should the line stop being a plain NAME="a b c" assignment it reads as absent, and every
# caller then fails rather than require nothing.
engine_seeds() { get_env "$1/scripts/restore-if-empty.sh" ENGINE_SEEDS; }

seed_sha256() {
	local out
	if command -v sha256sum >/dev/null; then out="$(sha256sum <"$1")"; else out="$(shasum -a 256 <"$1")"; fi
	printf '%s' "${out%% *}"
}

seed_status() {
	local dir="$1" listed="$2" sum="$3" name="$4"
	if [ ! -f "$dir/$name" ] && grep -qxF "$name" "$listed"; then
		printf missing
	elif [ ! -f "$dir/$name" ]; then
		printf private
	elif [ "$(seed_sha256 "$dir/$name")" = "$sum" ]; then
		chmod go-rwx "$dir/$name"
		printf ok
	else
		mv -f "$dir/$name" "$dir/$name.corrupt"
		printf CORRUPT
	fi
}

seed_report() {
	local dir="$1" listed="$2" sum name status mode size
	while read -r sum name; do
		name="${name#\*}"
		[ -n "$name" ] || continue
		status="$(seed_status "$dir" "$listed" "$sum" "$name")"
		mode="$(stat -c %a "$dir/$name" 2>/dev/null || printf -- -)"
		size="$(du -h "$dir/$name" 2>/dev/null | cut -f1 || true)"
		printf '%s %s %s %s\n' "$status" "$mode" "${size:--}" "$name"
	done <"$dir/SHA256SUMS"
}

seeds_unverified() {
	local dir="$1" sums="$2" name want
	shift 2
	for name in "$@"; do
		want="$(awk -v f="$name" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1; exit }' "$sums")"
		if [ -z "$want" ]; then
			printf '%s: not in SHA256SUMS\n' "$name"
		elif [ ! -f "$dir/$name" ]; then
			printf '%s: absent\n' "$name"
		elif [ "$(seed_sha256 "$dir/$name")" != "$want" ]; then
			printf '%s: does not match SHA256SUMS\n' "$name"
		fi
	done
}

# seed_problems DIR LISTED: the seed_report table on stderr, one line per CORRUPT file on stdout.
# A DIR without SHA256SUMS has nothing to judge; whether one was owed is the caller's question.
seed_problems() {
	local dir="$1" listed="$2" status mode size name
	[ -f "$dir/SHA256SUMS" ] || return 0
	while read -r status mode size name; do
		printf "  %-8s %4s %6s  %s\n" "$status" "$mode" "$size" "$name" >&2
		[ "$status" != CORRUPT ] || printf "%s: does not match SHA256SUMS, kept aside as .corrupt\n" "$name"
	done < <(seed_report "$dir" "$listed")
}
