# shellcheck shell=bash
# seed-check.sh — judge a pulled seed directory (secrets/) against the SHA256SUMS captured in it.
#
#   seed_report DIR LISTED     one line per SHA256SUMS entry: STATUS MODE SIZE NAME. STATUS is
#                              ok (the file is then narrowed to owner-only), CORRUPT (renamed
#                              NAME.corrupt so nothing installs it), missing (LISTED, a file of
#                              names relative to DIR, holds NAME but DIR does not) or private
#                              (not in LISTED: sealed to its pusher, it never reaches a teammate).
#   seeds_uncovered DIR NAME…  print each NAME that SHA256SUMS does not list or DIR does not hold.
#   seed_problems DIR LISTED [REQUIRED…]  both of the above as one verdict (below).

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

seeds_uncovered() {
	local dir="$1" name
	shift
	for name in "$@"; do
		if ! awk -v f="$name" '{ n = $2; sub(/^\*/, "", n) } n == f { hit = 1 } END { exit !hit }' "$dir/SHA256SUMS" ||
			{ [ ! -f "$dir/$name" ] && [ ! -f "$dir/$name.corrupt" ]; }; then
			printf '%s\n' "$name"
		fi
	done
}

# seed_problems DIR LISTED [REQUIRED…]: the seed_report table on stderr, one line per problem on
# stdout — a CORRUPT file, a REQUIRED name seeds_uncovered names, or no SHA256SUMS when any
# file is required.
seed_problems() {
	local dir="$1" listed="$2" status mode size name
	shift 2
	if [ ! -f "$dir/SHA256SUMS" ]; then
		[ "$#" -eq 0 ] || printf "SHA256SUMS: absent, the required dumps cannot be verified\n"
		return 0
	fi
	while read -r status mode size name; do
		printf "  %-8s %4s %6s  %s\n" "$status" "$mode" "$size" "$name" >&2
		[ "$status" != CORRUPT ] || printf "%s: does not match SHA256SUMS, kept aside as .corrupt\n" "$name"
	done < <(seed_report "$dir" "$listed")
	seeds_uncovered "$dir" "$@" | sed "s/\$/: required, but not delivered or not in SHA256SUMS/"
}
