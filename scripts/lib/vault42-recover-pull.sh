# shellcheck shell=bash
# vault42-recover-pull.sh — the pull half of scripts/vault42-recover-dumps.sh, sourced by it:
# fetch each dump's stored copies newest first until one is the file today's secrets/SHA256SUMS
# lists, and quarantine the newest copy, labelled, when none is.
#
# Only today's SHA256SUMS decides what enters secrets/: it is pinned at the start and re-hashed
# before every placement, so a concurrent pull rewriting it stops the run. An older epoch's key
# cannot be checked against a published key (only the current one is published), so a copy
# that does not match is unauthenticated: it lives under .vault42/recovered/…/secrets/ — ignored
# by both .vault42/ and the bare `secrets` rule — with a label saying so, never in secrets/.
# Every copy is tried before one is quarantined.

SUMS_PINNED=""
REPORT=""
SEEN=""
FETCH_FAILED=0
NEWEST=()
failures=0
placed=0
unverified=0

fail() {
	note "✗ $1"
	failures=$((failures + 1))
}

object_store_part() { in_env "$ENV_NAME" secret get "$1" 2>/dev/null; }

# The >4 MiB dumps are chunked into the object store; its key stays in the environment.
load_object_store_key() {
	[ -n "${FT_S3_KEY:-}" ] || FT_S3_KEY="$(object_store_part infra/S3_KEY)" || true
	[ -n "${FT_S3_SECRET:-}" ] || FT_S3_SECRET="$(object_store_part infra/S3_SECRET)" || true
	[ -n "${FT_S3_KEY:-}" ] && [ -n "${FT_S3_SECRET:-}" ] ||
		die "env secret infra/S3_KEY + infra/S3_SECRET unreadable: the chunked dumps cannot come back — nothing pulled"
	export FT_S3_KEY FT_S3_SECRET
	note "✓ object-store credential loaded (memory only)"
}

file_sum() {
	local line
	line="$(sha256sum <"$1")" && printf '%s' "${line%% *}"
}
listed_sum() { [ -f "$1" ] && awk -v f="$2" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1; exit }' "$1"; }

# vault42-pull-everything.sh swaps files in secrets/: the gate would move under us.
# Caveat: matches the script run by bash (`make`, `./scripts/…`, `bash -x …`) and nothing else —
# so an editor holding the file open does not block, and a run under another shell is missed.
refuse_concurrent_pull() {
	! pgrep -f '(^|/)bash( -[^ ]+)* [^ ]*vault42-pull-everything\.sh( |$)' >/dev/null ||
		die "vault42-pull-everything.sh is running — it replaces files in ./secrets; run this once it ends"
}
pin_todays_sums() {
	[ -f "$REPO/secrets/SHA256SUMS" ] || die "no ./secrets/SHA256SUMS to verify against"
	SUMS_PINNED="$(file_sum "$REPO/secrets/SHA256SUMS")"
}
sums_unchanged() {
	[ "$(file_sum "$REPO/secrets/SHA256SUMS")" = "$SUMS_PINNED" ] ||
		die "./secrets/SHA256SUMS changed during the run — something else is writing ./secrets; stopped, staging (plaintext) kept in $STAGE"
}

# 42ctl holds a file whole in memory: it needs twice its size free, and the disk its size.
room_for() {
	local size="$1" disk dest mem
	disk="$(df --output=avail -B1 "$WORK" | tail -n 1)"
	dest="$(df --output=avail -B1 "$REPO" | tail -n 1)"
	mem=$(($(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo) * 1024))
	[ "$size" -lt "$disk" ] && [ "$size" -lt "$dest" ] && [ $((size * 2)) -lt "$mem" ]
}

# One file per new empty 0700 directory: --at/--epoch refuse any other target.
pull_one() {
	local epoch="$1" rev="$2" dir="$3" path="$4"
	mkdir -m 700 "$dir" || return 1
	(cd "$dir" && watched 3600 0 "$AT_CTL" env pull --epoch "$epoch" --at "$rev" --only "$path" --apply \
		--org "$ORG" --project "$PROJECT" --env "$ENV_NAME" </dev/null) >"$dir.log" 2>&1 && [ -f "$dir/$path" ]
}

# Never over an existing file, never where git would take it.
place() {
	local file="$1" dest="$2"
	sums_unchanged
	[ ! -e "$dest" ] || { fail "$(rel "$dest") exists — left as is; the fetched copy stays in staging" && return 1; }
	is_git_ignored "$dest" || { fail "$(rel "$dest") is not git-ignored — not placed" && return 1; }
	if mkdir -p "$(dirname "$dest")" && mv -n "$file" "$dest" && [ ! -e "$file" ] && chmod 600 "$dest"; then
		return 0
	fi
	fail "could not move $(basename "$file") to $(rel "$dest") — the fetched copy stays in staging"
	return 1
}

report_line() { REPORT+="$(printf '    %-28s %s' "$1" "$2")"$'\n'; }

# own_sums EPOCH REV PATH NAME SUM: does the SHA256SUMS beside PATH in that revision list SUM?
own_sums() {
	local epoch="$1" rev="$2" name="$4" sum="$5" sums dir listed
	sums="${3%/*}/SHA256SUMS"
	awk -v p="$sums" 'substr($0, length($1) + length($2) + 3) == p { found = 1 } END { exit !found }' \
		"$WORK/rev/$epoch-$rev.files" || { printf 'that revision holds no %s' "$sums" && return; }
	dir="$STAGE/sums-e$epoch-r$rev"
	[ -f "$dir/$sums" ] || pull_one "$epoch" "$rev" "$dir" "$sums" ||
		{ printf 'that revision'"'"'s %s could not be fetched' "$sums" && return; }
	listed="$(listed_sum "$dir/$sums" "$name")"
	case "$listed" in
	"$sum") printf 'yes: that revision'"'"'s own %s lists this hash' "$sums" ;;
	"") printf 'no: that revision'"'"'s own %s does not list %s' "$sums" "$name" ;;
	*) printf 'no: that revision'"'"'s own %s lists another hash' "$sums" ;;
	esac
}

label() {
	local name="$1" epoch="$2" rev="$3" stored="$4" size="$5" sum="$6" path="$7"
	printf '%s\n' "== $name (stored as $path)" \
		"key epoch $epoch, push revision $rev, stored Rev $stored, $size bytes" "sha256 $sum" \
		"own SHA256SUMS: $(own_sums "$epoch" "$rev" "$path" "$name" "$sum")" \
		"every stored copy seen, newest first:" "${SEEN%$'\n'}" \
		"NOT TODAY'S: groot's current secrets/SHA256SUMS does not list this copy." \
		"UNAUTHENTICATED: the key of epoch $epoch was not compared with any published key (only the" \
		"current epoch's is published), and any member of the scope at any epoch could have written" \
		"this file. Check its provenance before restoring it into any database." ""
}

# No fetched copy matched today's sums: the newest goes beside ./secrets, labelled.
quarantine() {
	local name="$1" listed="$2" file epoch rev stored size sum path dir why
	if [ "${#NEWEST[@]}" -eq 0 ]; then
		why="none of its $listed stored copies could be fetched"
		[ "$listed" -gt 0 ] || why="not stored in any readable epoch ($(epochs_summary))"
		fail "$name: $why" && report_line "$name" "NOT FOUND — $why"
		return
	fi
	file="${NEWEST[0]}" epoch="${NEWEST[1]}" rev="${NEWEST[2]}" stored="${NEWEST[3]}"
	size="${NEWEST[4]}" sum="${NEWEST[5]}" path="${NEWEST[6]}"
	dir="$RECOVERED/$ENV_NAME-e$epoch-r$rev/secrets"
	place "$file" "$dir/$name" || { report_line "$name" "FAILED to quarantine — see above" && return; }
	label "$name" "$epoch" "$rev" "$stored" "$size" "$sum" "$path" >>"$dir/RECOVERED.txt" && chmod 600 "$dir/RECOVERED.txt"
	unverified=$((unverified + 1))
	why="no match among fetched"
	[ "$FETCH_FAILED" -eq 0 ] || why="$why; $FETCH_FAILED failed to fetch"
	report_line "$name" "QUARANTINED in $(rel "$dir")/$name ($why) — read RECOVERED.txt beside it"
}

# try_copy NAME WANT EPOCH REV SIZE STORED PATH DIR: 0 once the copy is today's and placed.
try_copy() {
	local name="$1" want="$2" epoch="$3" rev="$4" size="$5" stored="$6" path="$7" dir="$8" sum
	note "fetching $name from epoch $epoch revision $rev ($(human "$size"))…"
	if ! pull_one "$epoch" "$rev" "$dir" "$path"; then
		FETCH_FAILED=$((FETCH_FAILED + 1))
		SEEN+="  epoch $epoch revision $rev Rev $stored $size B: fetch failed: $(tail -n 1 "$dir.log")"$'\n'
		return 1
	fi
	sum="$(file_sum "$dir/$path")"
	SEEN+="  epoch $epoch revision $rev Rev $stored $size B: sha256 $sum"$'\n'
	if [ -n "$want" ] && [ "$sum" = "$want" ]; then
		place "$dir/$path" "$REPO/secrets/$name" || { report_line "$name" "FAILED to place — see above" && return 0; }
		placed=$((placed + 1))
		report_line "$name" "placed in ./secrets from epoch $epoch revision $rev — matches today's SHA256SUMS"
		return 0
	fi
	[ "${#NEWEST[@]}" -gt 0 ] || NEWEST=("$dir/$path" "$epoch" "$rev" "$stored" "$size" "$sum" "$path")
	return 1
}

recover_dump() {
	local name="$1" want k=0 epoch rev size stored path
	[ ! -e "$REPO/secrets/$name" ] || { report_line "$name" "already in ./secrets — not fetched" && return; }
	want="$(listed_sum "$REPO/secrets/SHA256SUMS" "$name")"
	SEEN="" FETCH_FAILED=0 NEWEST=()
	while IFS=$'\t' read -r _ epoch rev size stored path; do
		k=$((k + 1))
		if ! room_for "$size"; then
			fail "$name: $(human "$size") does not fit in free disk / half the free RAM"
			report_line "$name" "NOT FETCHED — $(human "$size") does not fit in free disk / half the free RAM"
			return
		fi
		try_copy "$name" "$want" "$epoch" "$rev" "$size" "$stored" "$path" "$STAGE/$name.$k" && return
	done < <(awk -F '\t' -v n="$name" '$1 == n' "$WORK/candidates.tsv")
	quarantine "$name" "$k"
}

final_check() {
	local status
	note "./secrets against today's SHA256SUMS:"
	(cd "$REPO/secrets" && sha256sum -c SHA256SUMS 2>&1) | sed 's/^/    /' >&2
	status="${PIPESTATUS[0]}"
	return "$status"
}

# Asserted, not assumed: a quarantined dump must stay one `git add -A` away from nothing.
quarantine_is_ignored() {
	[ -d "$RECOVERED" ] || return 0
	[ -z "$(git -C "$REPO" status --porcelain -- "${RECOVERED#"$REPO"/}" 2>&1)" ] ||
		fail "git would take files under $(rel "$RECOVERED") — ignore them before anything else"
}

# Staging holds plaintext: deleted once nothing failed, kept (and said) otherwise.
cleanup_stage() {
	local left
	left="$(find "$STAGE" -type f ! -name '*.log' | wc -l)"
	if [ "$failures" -gt 0 ]; then
		note "! $STAGE kept for inspection: $left plaintext file(s) — delete it when done"
	else
		rm -rf "$STAGE" && note "✓ deleted staging ($left older copies nothing kept)"
	fi
}

pull_all() {
	local name
	[ -f "$WORK/candidates.tsv" ] || die "no probe results — run: $0 probe"
	[ ! -e "$STAGE" ] || die "$STAGE already exists — inspect it, then remove it"
	refuse_concurrent_pull
	pin_todays_sums
	mkdir -m 700 "$STAGE" || die "cannot create $STAGE"
	! git -C "$STAGE" rev-parse --git-dir >/dev/null 2>&1 || die "$STAGE is inside a git repository"
	load_object_store_key
	for name in $DUMPS; do recover_dump "$name"; done
	forget_credentials
	quarantine_is_ignored
	final_check || note "! ./secrets does not pass its SHA256SUMS yet"
	cleanup_stage
	note "per dump:" && printf '%s' "$REPORT" >&2
	note "$placed placed in ./secrets, $unverified quarantined, $failures problem(s)"
	[ "$failures" -eq 0 ] && [ "$unverified" -eq 0 ] && final_check 2>/dev/null
}
