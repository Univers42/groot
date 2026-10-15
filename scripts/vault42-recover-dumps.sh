#!/usr/bin/env bash
# vault42-recover-dumps.sh all|build|probe|pull — bring back the engine dumps today's tree of
# univers42/groot/prod no longer names, from any older push revision of any key epoch the
# operator can still open. `make vault42-recover-dumps [PHASE=…]`.
#
#   $WORK   RECOVER_DIR, else .groot-vault42-recover beside the checkout: the toolchain cache,
#           the 42ctl clone, the probe listings and the staging, all 0700, outside any git tree.
#   build   clone 42ctl 4ee32f6 into $WORK, apply scripts/vault42-recover/42ctl-epoch.patch
#           (`env files|pull --at --epoch`), check the baseline test results are unchanged and
#           the new tests pass, then build $WORK/bin/42ctl-epoch — never on PATH.
#   probe   learn the current key epoch, list every push revision of every epoch, and write
#           each dump's stored copies, newest first, to $WORK/candidates.tsv.
#   pull    per dump, fetch copies newest first, each into its own empty directory, until one
#           matches today's secrets/SHA256SUMS: that one joins secrets/. A dump no copy matches
#           has its newest copy quarantined under .vault42/recovered/ (lib/vault42-recover-pull.sh).
#   all     build (unless the binary exists), probe, pull.
#
# Why: `env push` publishes only what is on the pusher's disk, so a teammate without the dumps
# drops them from the newest tree, and a key rotation carries only the newest tree forward. The
# bytes stay stored under the older revision, in the older epoch; stock 42ctl reads neither.
# Read-only on vault42. The patched binary runs only `env files` and `env pull`; the installed
# one only `version`, `env secret get infra/S3_*` and the session verbs of vault42-session.sh.
# Values are never printed; the passphrase and object-store key live in the environment only.
# Nothing is loaded into a database: that is `make vault-restore`, a separate decision.
# Caveat: copies are deduplicated on (epoch, path, stored Rev). A rotation re-seals the newest
# copy into the next epoch under a new Rev, so the same bytes can be fetched twice: slower,
# never wrong.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${RECOVER_REPO:-$(dirname "$HERE")}"
# Beside the checkout, not under $HOME: a 42 home is a few-GiB quota the toolchain alone fills
# (measured 2026-10-15: 4.7G, full at the first build), and on the checkout's filesystem the
# final move into secrets/ is a rename, never a second copy of a dump.
WORK="${RECOVER_DIR:-$(dirname "$REPO")/.groot-vault42-recover}"
BUILD_ROOM=$((4 * 1024 * 1024 * 1024))
SRC="$WORK/42ctl"
PATCH="$HERE/vault42-recover/42ctl-epoch.patch"
CTL_SOURCE=https://github.com/Univers42/42ctl.git
BASE_REV=4ee32f6
IMAGE="${RECOVER_IMAGE:-public.ecr.aws/docker/library/rust:1.96-alpine}"
AT_CTL="$WORK/bin/42ctl-epoch"
DEVIL="$REPO/.claude/bin/devil"
ORG="${VAULT42_ORG:-univers42}"
PROJECT="${VAULT42_PROJECT:-groot}"
ENV_NAME="${VAULT42_ENV:-prod}"
MAX_REV=500
NEW_TESTS=11
DUMPS="inception-wordpress.tar.gz minio.tar.gz mongo-rs-keyfile.tar.gz mongo.archive.gz mssql-all.tar.gz mysql-all.sql.gz postgres-all.sql.gz redis.rdb sqlite-data.tar.gz vite-gourmand-data.tar.gz"
CTL="${CTL_BIN:-42ctl}"
CTL_CFG_DIR="${CTL_CFG_DIR:-$HOME/.config/42ctl}"
export FT_CONFIG="${FT_CONFIG:-$CTL_CFG_DIR/config.json}"
export FT_KEYSTORE="${FT_KEYSTORE:-$CTL_CFG_DIR/keystore.v42}"
TTY_DEV="${VAULT42_TTY:-/dev/tty}"
LOG_TAG=recover-dumps
STAGE="$WORK/stage"
RECOVERED="$REPO/.vault42/recovered"
CURRENT=""

# shellcheck source=scripts/lib/envfile.sh
. "$HERE/lib/envfile.sh"
# shellcheck source=scripts/lib/git-ignored.sh
. "$HERE/lib/git-ignored.sh"
# shellcheck source=scripts/lib/vault42-session.sh
. "$HERE/lib/vault42-session.sh"
# shellcheck source=scripts/lib/vault42-recover-pull.sh
. "$HERE/lib/vault42-recover-pull.sh"

human() { numfmt --to=iec --suffix=B "$1"; }
rel() { printf './%s' "${1#"$REPO"/}"; }
in_env() { "$CTL" env "${@:2}" --org "$ORG" --project "$PROJECT" --env "$1" </dev/null; }
at_env() { "$AT_CTL" env "$@" --org "$ORG" --project "$PROJECT" --env "$ENV_NAME" </dev/null; }
# Caveat: without the kit's watchdog only the hard timeout holds (coreutils `timeout`, 0 = none):
# a step that hangs silently is killed at TIMEOUT, not after IDLE.
watched() {
	local timeout="$1" idle="$2"
	shift 2
	if [ -x "$DEVIL" ]; then "$DEVIL" watch --timeout "$timeout" --idle "$idle" -- "$@"; else timeout "$timeout" "$@"; fi
}
forget_credentials() {
	unset FT_PASSPHRASE VAULT42_PASSPHRASE FT_PASSWORD FT_REGISTER_TOKEN VAULT42_REGISTER_TOKEN FT_S3_KEY FT_S3_SECRET
}

# ---- build ------------------------------------------------------------------------------------

# The patch is written against 4ee32f6 and nothing else: a tree that is not exactly that plus
# the patch is refused rather than built.
prepare_source() {
	if [ ! -d "$SRC/.git" ]; then
		note "cloning 42ctl $BASE_REV into $SRC…"
		if ! { git clone -q "$CTL_SOURCE" "$SRC" && git -C "$SRC" checkout -q --detach "$BASE_REV" &&
			git -C "$SRC" apply "$PATCH"; }; then
			die "could not prepare 42ctl $BASE_REV + the patch in $SRC"
		fi
	fi
	if [ "$(git -C "$SRC" rev-parse --short=7 HEAD 2>/dev/null)" != "$BASE_REV" ] ||
		! git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
		die "$SRC is not 42ctl $BASE_REV + scripts/vault42-recover/42ctl-epoch.patch — delete it and re-run"
	fi
}

check_installed_ctl() {
	local version
	command -v docker >/dev/null || die "docker is needed to build with the pinned toolchain"
	version="$("$CTL" version 2>&1 | head -n 1)"
	case "$version" in
	*0.1.16*) note "✓ patch base $BASE_REV; installed: $version" ;;
	*) die "installed 42ctl says '$version', not 0.1.16 — the patch must be rebased onto it first" ;;
	esac
}

# in_rust SRC BUILD CMD…: only the source and $WORK/target are mounted — no 42ctl config,
# keystore or credential. Each tree builds in its own target: both mount at /src, and cargo's
# mtime fingerprint would take files edited before another tree's build for built.
in_rust() {
	local src="$1" build="$2"
	shift 2
	watched 5400 900 docker run --rm -v "$src:/src" -v "$WORK/target:/target" -w /src \
		-e CARGO_HOME=/target/cargo -e CARGO_TARGET_DIR="/target/$build" -e FT_GIT_SHA="$BASE_REV+at-epoch" \
		"$IMAGE" sh -c '[ -f /usr/lib/crt1.o ] || apk add --no-cache -q musl-dev gcc; exec "$@"' sh "$@"
}

test_results() { sed -n 's/^test \(.*\) \.\.\. \(ok\|FAILED\|ignored\)$/\1 \2/p' "$1" | sort -u; }

# The patch may add tests, never change the result of one that exists.
compare_tests() {
	local base="$WORK/tests-base.txt" patched="$WORK/tests-epoch.txt" changed added ok
	test_results "$WORK/test-base.log" >"$base"
	test_results "$WORK/test-epoch.log" >"$patched"
	[ -s "$base" ] || die "the baseline ran no test — see $WORK/test-base.log"
	changed="$(comm -23 "$base" "$patched")"
	[ -z "$changed" ] || die "the patch changed baseline results: $(tr '\n' ';' <<<"$changed")"
	added="$(comm -13 "$base" "$patched")"
	! grep -v -e ' ok$' -e '^$' <<<"$added" >/dev/null ||
		die "new tests do not pass: $(grep -v -e ' ok$' -e '^$' <<<"$added" | tr '\n' ';')"
	ok="$(grep -c ' ok$' <<<"$added")"
	[ "$ok" -ge "$NEW_TESTS" ] || die "only $ok of the $NEW_TESTS scope_at tests ran — see $WORK/test-epoch.log"
	note "✓ tests: $(wc -l <"$base") baseline results unchanged, $ok new ones pass"
}

# Caveat: 4 GiB is an estimate (two debug targets and one release of 42ctl came to ~3 GiB) and
# measures $WORK only. The ~1 GiB toolchain image lands in docker's own storage — under rootless
# docker possibly a quota'd $HOME — which is checked only while the image is not pulled yet. A
# toolchain or dependency bump can need more, and the build then fails on a full disk.
check_build_room() {
	local free root
	free="$(df --output=avail -B1 "$WORK" | tail -n 1)"
	[ "$free" -ge "$BUILD_ROOM" ] ||
		die "$(human "$free") free under $WORK; the build needs ~$(human "$BUILD_ROOM") — set RECOVER_DIR to a bigger disk"
	! docker image inspect "$IMAGE" >/dev/null 2>&1 || return 0
	root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" && [ -d "$root" ] || return 0
	free="$(df --output=avail -B1 "$root" | tail -n 1)"
	[ "$free" -ge $((2 * 1024 * 1024 * 1024)) ] ||
		die "$(human "$free") free in docker's storage ($root); the ~1 GiB toolchain image would not fit — free space there first"
}

build() {
	check_installed_ctl
	mkdir -p "$WORK/target" "$WORK/bin" && chmod 700 "$WORK"
	check_build_room
	prepare_source
	if [ ! -s "$WORK/test-base.log" ]; then
		rm -rf "$WORK/base" && mkdir "$WORK/base"
		git -C "$SRC" archive "$BASE_REV" | tar -x -C "$WORK/base" || die "could not export $BASE_REV"
		note "baseline tests on $BASE_REV (the first run pulls $IMAGE and compiles everything: minutes)…"
		in_rust "$WORK/base" base cargo test --locked --no-fail-fast >"$WORK/test-base.log" 2>&1 ||
			note "baseline exit $? — compared, not fatal"
	fi
	note "patched tests…"
	in_rust "$SRC" epoch cargo test --locked --no-fail-fast >"$WORK/test-epoch.log" 2>&1 ||
		note "patched exit $? — compared, not fatal"
	compare_tests
	note "release build…"
	in_rust "$SRC" epoch cargo build --release --locked >"$WORK/build.log" 2>&1 ||
		die "build failed — last lines of $WORK/build.log: $(tail -n 5 "$WORK/build.log")"
	install -m 700 "$WORK/target/epoch/release/42ctl" "$AT_CTL" || die "no binary came out of the build"
	"$AT_CTL" env pull --help 2>&1 | grep -q -- '--epoch' || die "$AT_CTL has no --epoch"
	note "✓ $AT_CTL: $("$AT_CTL" version 2>&1 | head -n 1)"
}

# ---- probe ------------------------------------------------------------------------------------

open_vault() {
	command -v "$CTL" >/dev/null || die "$CTL is not on PATH"
	[ -x "$AT_CTL" ] || die "no $AT_CTL — run: $0 build"
	load_credentials
	ensure_session
	ensure_unlocked
}

# An epoch past the current one is refused with the current one's number in the message.
learn_current_epoch() {
	local said
	said="$(at_env files --epoch 4294967295 2>&1 >/dev/null)"
	CURRENT="$(sed -n 's/.*is at key epoch \([0-9][0-9]*\).*/\1/p' <<<"$said" | head -n 1)"
	[ -n "$CURRENT" ] || die "could not learn the current key epoch: $(head -n 1 <<<"$said")"
	note "✓ $ENV_NAME is at key epoch $CURRENT"
}

# Private files are filtered out: today's tree merges yours in, an older one never does.
list_rev() {
	at_env files --epoch "$1" --at "$2" --filter Private=false --format '{{.Size}} {{.Rev}} {{.Path}}' \
		>"$WORK/rev/$1-$2.files" 2>"$WORK/rev/$1-$2.err"
}

# Listed trees only: an empty listing would count as one more tree and hide an ignored flag.
distinct_trees() {
	local listing
	for listing in "$@"; do
		[ ! -s "$listing" ] || sort "$listing" | md5sum
	done | sort -u | wc -l
}

# The last revision must be the epoch's newest tree, and several revisions must differ.
check_epoch_head() {
	local epoch="$1" head="$2" n listings=()
	list_rev "$epoch" 0 || die "key epoch $epoch: its newest tree does not list: $(head -n 1 "$WORK/rev/$epoch-0.err")"
	cmp -s <(sort "$WORK/rev/$epoch-$head.files") <(sort "$WORK/rev/$epoch-0.files") ||
		die "key epoch $epoch: revision $head is not its newest tree — --at ignored, a gap, or a private file shadowing a shared one"
	for ((n = 1; n <= head; n++)); do listings+=("$WORK/rev/$epoch-$n.files"); done
	[ "$head" -eq 1 ] || [ "$(distinct_trees "${listings[@]}")" -gt 1 ] ||
		die "key epoch $epoch: all $head revisions list the same tree — the server ignores --at"
	printf '%s\tsearched\t%s revision(s)\n' "$epoch" "$head" >>"$WORK/epochs.tsv"
	note "✓ key epoch $epoch: $head push revision(s)"
}

# Revision 1 failing means the epoch cannot be read with this key: reported, then skipped.
probe_epoch() {
	local epoch="$1" n said
	for ((n = 1; n <= MAX_REV; n++)); do
		list_rev "$epoch" "$n" && continue
		said="$(head -n 1 "$WORK/rev/$epoch-$n.err")"
		if [[ "$said" == *"holds no tree"* ]]; then
			[ "$n" -eq 1 ] || { check_epoch_head "$epoch" $((n - 1)) && return; }
			printf '%s\tempty\n' "$epoch" >>"$WORK/epochs.tsv" && note "key epoch $epoch holds no tree"
			return
		fi
		[ "$n" -gt 1 ] || { printf '%s\tskipped\t%s\n' "$epoch" "$said" >>"$WORK/epochs.tsv" && note "! key epoch $epoch skipped: $said" && return; }
		note "! key epoch $epoch revision $n: $said"
	done
	die "key epoch $epoch: no end after $MAX_REV revisions — the server ignores --at; nothing pulled"
}

# Several epochs whose newest trees are all alike mean the server ignores --epoch.
check_epochs_differ() {
	local newest=("$WORK"/rev/*-0.files) listed=0 listing
	for listing in "${newest[@]}"; do [ ! -s "$listing" ] || listed=$((listed + 1)); done
	[ "$listed" -le 1 ] || [ "$(distinct_trees "${newest[@]}")" -gt 1 ] ||
		die "all $listed key epochs list the same newest tree — the server ignores --epoch; nothing pulled"
}

epochs_summary() {
	awk -F '\t' '$2 == "searched" { s = s " " $1 } $2 != "searched" { k = k " " $1 }
		END { printf "epochs searched:%s", s ? s : " none"; if (k) printf "; skipped or empty:%s", k }' "$WORK/epochs.tsv"
}

# candidates: "name<TAB>epoch<TAB>rev<TAB>size<TAB>stored rev<TAB>path" for every copy of a dump
# under any secrets/ directory, newest first, one line per (name, epoch, path, stored rev).
list_candidates() {
	local listing base epoch rev
	for listing in "$WORK"/rev/*-*.files; do
		base="${listing##*/}" && base="${base%.files}" && epoch="${base%-*}" && rev="${base#*-}"
		[ "$rev" != 0 ] || continue
		awk -v e="$epoch" -v r="$rev" -v want=" $DUMPS " '
			{ path = substr($0, length($1) + length($2) + 3); name = path; sub(/.*\//, "", name) }
			index(want, " " name " ") && path ~ /(^|\/)secrets\/[^\/]+$/ { printf "%s\t%s\t%s\t%s\t%s\t%s\n", name, e, r, $1, $2, path }' "$listing"
	done | sort -t "$(printf '\t')" -k1,1 -k2,2nr -k3,3nr | awk -F '\t' '!seen[$1 FS $2 FS $6 FS $5]++'
}

report_coverage() {
	local name
	note "dump → stored copies ($(epochs_summary))"
	for name in $DUMPS; do
		awk -F '\t' -v n="$name" '$1 == n { c++; if (c == 1) newest = "epoch " $2 " revision " $3 }
			END { printf "    %-28s %s\n", n, c ? c " cop" (c > 1 ? "ies" : "y") ", newest in " newest : "none" }' \
			"$WORK/candidates.tsv" >&2
	done
}

probe() {
	local epoch
	rm -rf "$WORK/rev" "$WORK/epochs.tsv" && mkdir -m 700 "$WORK/rev"
	learn_current_epoch
	for ((epoch = CURRENT; epoch >= 1; epoch--)); do probe_epoch "$epoch"; done
	check_epochs_differ
	list_candidates >"$WORK/candidates.tsv"
	report_coverage
}

usage() {
	printf 'usage: %s all | build | probe | pull\n' "$0" >&2
	exit 2
}

# Beside a checkout in a world-writable /goinfre, another account could create $WORK first and
# plant bin/42ctl-epoch, which `all` would run with the passphrase exported: anything that is
# not a real directory owned by this account stops the run before a credential is loaded.
claim_work() {
	mkdir -p "$WORK" 2>/dev/null
	if [ ! -d "$WORK" ] || [ -L "$WORK" ] || [ ! -O "$WORK" ] || ! chmod 700 "$WORK"; then
		die "$WORK is not a directory this account owns (or is a symlink) — remove it, or set RECOVER_DIR"
	fi
}

main() {
	umask 077
	case "${1:-}" in all | build | probe | pull) claim_work ;; esac
	case "${1:-}" in
	build) build ;;
	probe) open_vault && probe ;;
	pull) open_vault && pull_all ;;
	all)
		[ -x "$AT_CTL" ] || build
		open_vault && probe && pull_all
		;;
	*) usage ;;
	esac
}

main "$@"
