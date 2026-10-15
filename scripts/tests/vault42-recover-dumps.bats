#!/usr/bin/env bats
# scripts/vault42-recover-dumps.sh against a stub 42ctl (lib/stub-42ctl) and a throwaway
# repository: which stored copy reaches secrets/, what is quarantined, and every refusal.
# The world: prod is at key epoch 3. Epoch 3 holds today's tree (the 3 dumps still pushed) and an
# older small tree with an outdated mongo-rs-keyfile; epoch 2 cannot be opened with our key;
# epoch 1 holds two backup generations of all 13 dumps.

DUMPS="inception-wordpress.tar.gz minio.tar.gz mongo-rs-keyfile.tar.gz mongo.archive.gz mssql-all.tar.gz mysql-all.sql.gz postgres-all.sql.gz redis.rdb sqlite-data.tar.gz vite-gourmand-data.tar.gz"
PRESENT="dynamodb-all.tar.gz grobase-certs.tar.gz inception-mariadb.tar.gz"

setup() {
	T="$BATS_TEST_TMPDIR"
	SCRIPT="$BATS_TEST_DIRNAME/../vault42-recover-dumps.sh"
	export STUB_DIR="$T/stub" RECOVER_REPO="$T/repo" RECOVER_DIR="$T/work" CTL_BIN="$T/bin/42ctl"
	export CTL_CFG_DIR="$T/cfg" FT_PASSPHRASE=stub-pass VAULT42_TTY=/dev/null STUB_CURRENT=3
	mkdir -p "$STUB_DIR" "$T/bin" "$CTL_CFG_DIR" "$RECOVER_DIR/bin" "$RECOVER_REPO/secrets"
	install -m 755 "$BATS_TEST_DIRNAME/lib/stub-42ctl" "$CTL_BIN"
	install -m 700 "$BATS_TEST_DIRNAME/lib/stub-42ctl" "$RECOVER_DIR/bin/42ctl-epoch"
	: >"$CTL_CFG_DIR/keystore.v42"
	git -C "$RECOVER_REPO" init -q
	# HEAD's rule: the bare `secrets` ignores a secrets/ directory at any depth.
	printf 'secrets\n' >"$RECOVER_REPO/.gitignore"
}

# make_rev EPOCH N GEN [DIR] NAME…: revision N of EPOCH holds DIR/NAME ("gen-GEN:NAME") with
# that generation's SHA256SUMS beside them, a decoy elsewhere and a non-secret file.
make_rev() {
	local dir="$STUB_DIR/e$1/rev-$2" gen="$3" sub="secrets" name
	shift 3
	[[ "$1" == */* || "$1" == secrets ]] && { sub="$1" && shift; }
	mkdir -p "$dir/$sub" "$dir/other"
	for name in "$@"; do printf 'gen-%s:%s' "$gen" "$name" >"$dir/$sub/$name"; done
	sums_of "$gen" >"$dir/$sub/SHA256SUMS"
	printf 'decoy' >"$dir/other/minio.tar.gz"
	printf 'A=1\n' >"$dir/.env.local"
}

newest_is() { rm -rf "$STUB_DIR/e$1/rev-0" && cp -r "$STUB_DIR/e$1/rev-$2" "$STUB_DIR/e$1/rev-0"; }

sums_of() {
	local name
	for name in $DUMPS $PRESENT; do
		printf '%s  %s\n' "$(printf 'gen-%s:%s' "$1" "$name" | sha256sum | cut -d' ' -f1)" "$name"
	done
}

today_is_gen() {
	local name
	sums_of "$1" >"$RECOVER_REPO/secrets/SHA256SUMS"
	for name in $PRESENT; do printf 'gen-%s:%s' "$1" "$name" >"$RECOVER_REPO/secrets/$name"; done
}

the_world() {
	make_rev 3 1 0 mongo-rs-keyfile.tar.gz grobase-certs.tar.gz
	make_rev 3 2 2 secrets/secrets $PRESENT
	newest_is 3 2
	mkdir -p "$STUB_DIR/e2/rev-1" && : >"$STUB_DIR/e2/unreadable"
	make_rev 1 1 1 $DUMPS $PRESENT
	make_rev 1 2 2 $DUMPS $PRESENT
	newest_is 1 2
	today_is_gen 2
}

# said NAME TEXT: the per-dump report has one line for NAME, and it reads TEXT.
said() { grep -F -- "$1" <<<"$output" | grep -qF -- "$2"; }

probe_and_pull() {
	run bash "$SCRIPT" probe
	[ "$status" -eq 0 ] || { echo "$output" && return 1; }
	run bash "$SCRIPT" pull
}

@test "probe walks every epoch, skips the unreadable one, lists copies newest first" {
	the_world
	run bash "$SCRIPT" probe
	[ "$status" -eq 0 ] || { echo "$output" && false; }
	[[ "$output" == *"prod is at key epoch 3"* ]]
	[[ "$output" == *"key epoch 2 skipped: Error: could not open the scope key"* ]]
	[[ "$output" == *"epochs searched: 3 1; skipped or empty: 2"* ]]
	[ "$(awk -F '\t' '$1 == "mongo-rs-keyfile.tar.gz" { printf "%s.%s ", $2, $3 }' "$RECOVER_DIR/candidates.tsv")" = "3.1 1.2 1.1 " ]
	grep -q -- '--filter Private=false' "$STUB_DIR/argv.log"
}

@test "pull places every dump today's SHA256SUMS lists, older epochs included, 0600" {
	the_world
	probe_and_pull
	[ "$status" -eq 0 ] || { echo "$output" && false; }
	(cd "$RECOVER_REPO/secrets" && sha256sum -c SHA256SUMS)
	[ "$(stat -c %a "$RECOVER_REPO/secrets/redis.rdb")" = 600 ]
	said mongo-rs-keyfile.tar.gz "placed in ./secrets from epoch 1 revision 2"
	[ ! -e "$RECOVER_DIR/stage" ] && [ ! -e "$RECOVER_REPO/.vault42" ]
}

@test "no secret value ever reaches argv or the output" {
	the_world
	probe_and_pull
	[ "$status" -eq 0 ]
	! grep -e stub-pass -e stub-value-of "$STUB_DIR/argv.log"
	[[ "$output" != *stub-value-of* && "$output" != *stub-pass* ]]
}

@test "a dump no copy matches is quarantined, labelled, under an ignored secrets/ directory" {
	the_world
	today_is_gen 9
	probe_and_pull
	[ "$status" -ne 0 ]
	local q="$RECOVER_REPO/.vault42/recovered/prod-e1-r2/secrets"
	[ "$(cat "$q/redis.rdb")" = "gen-2:redis.rdb" ] && [ "$(stat -c %a "$q/redis.rdb")" = 600 ]
	[ -f "$RECOVER_REPO/.vault42/recovered/prod-e3-r1/secrets/mongo-rs-keyfile.tar.gz" ]
	grep -q "UNAUTHENTICATED" "$q/RECOVERED.txt"
	grep -q "yes: that revision's own secrets/SHA256SUMS lists this hash" "$q/RECOVERED.txt"
	[ -z "$(git -C "$RECOVER_REPO" status --porcelain -- .vault42)" ]
	[ ! -e "$RECOVER_REPO/secrets/redis.rdb" ]
	[[ "$output" == *"QUARANTINED in ./.vault42/recovered/prod-e1-r2/secrets/redis.rdb (no match among fetched)"* ]]
}

@test "a fetch failure is said, never hidden behind 'no match'" {
	the_world
	STUB_FAIL_EPOCH=1 probe_and_pull
	[ "$status" -ne 0 ]
	said mongo-rs-keyfile.tar.gz "QUARANTINED in ./.vault42/recovered/prod-e3-r1/secrets/mongo-rs-keyfile.tar.gz (no match among fetched; 2 failed to fetch)"
	said "redis.rdb " "NOT FOUND — none of its 2 stored copies could be fetched"
	[[ "$output" == *"kept for inspection"* ]]
}

@test "an existing file is never fetched over" {
	the_world
	printf 'mine' >"$RECOVER_REPO/secrets/minio.tar.gz"
	probe_and_pull
	[ "$(cat "$RECOVER_REPO/secrets/minio.tar.gz")" = mine ]
	said "minio.tar.gz " "already in ./secrets — not fetched"
}

@test "SHA256SUMS changing mid-run stops before anything is placed" {
	the_world
	STUB_TOUCH_SUMS=1 probe_and_pull
	[ "$status" -ne 0 ]
	[[ "$output" == *"SHA256SUMS changed during the run"* ]]
	[ ! -e "$RECOVER_REPO/secrets/redis.rdb" ]
}

@test "pull refuses to run beside vault42-pull-everything" {
	the_world
	run bash "$SCRIPT" probe
	printf 'sleep 30\n' >"$T/vault42-pull-everything.sh"
	bash "$T/vault42-pull-everything.sh" 3>&- &
	local sleeper=$!
	run bash "$SCRIPT" pull
	kill "$sleeper"
	[ "$status" -ne 0 ]
	[[ "$output" == *"vault42-pull-everything.sh is running"* ]]
}

@test "a file named like the pull script, open elsewhere, does not block" {
	the_world
	run bash "$SCRIPT" probe
	printf 'sleep 30\n' >"$T/vault42-pull-everything.sh"
	tail -f "$T/vault42-pull-everything.sh" 3>&- >/dev/null &
	local viewer=$!
	run bash "$SCRIPT" pull
	kill "$viewer" 2>/dev/null || true
	[ "$status" -eq 0 ] || { echo "$output" && false; }
}

@test "probe stops when the server ignores --at" {
	the_world
	STUB_IGNORE_AT=1 run bash "$SCRIPT" probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"no end after 500 revisions"* ]]
}

@test "probe stops when the server ignores --epoch" {
	the_world
	rm "$STUB_DIR/e2/unreadable"
	STUB_IGNORE_EPOCH=1 run bash "$SCRIPT" probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"the server ignores --epoch"* ]]
}

@test "probe stops when an epoch's newest tree is not its last revision" {
	the_world
	newest_is 1 1
	run bash "$SCRIPT" probe
	[ "$status" -ne 0 ]
	[[ "$output" == *"key epoch 1: revision 2 is not its newest tree"* ]]
}

@test "pull refuses a staging directory that already exists" {
	the_world
	run bash "$SCRIPT" probe
	mkdir -p "$RECOVER_DIR/stage"
	run bash "$SCRIPT" pull
	[ "$status" -ne 0 ]
	[[ "$output" == *"already exists"* ]]
}

@test "a work directory that is a symlink stops the run before 42ctl is ever called" {
	the_world
	mkdir -p "$T/elsewhere/bin" && install -m 700 "$BATS_TEST_DIRNAME/lib/stub-42ctl" "$T/elsewhere/bin/42ctl-epoch"
	ln -s "$T/elsewhere" "$T/planted"
	RECOVER_DIR="$T/planted" run bash "$SCRIPT" all
	[ "$status" -ne 0 ]
	[[ "$output" == *"is not a directory this account owns (or is a symlink)"* ]]
	[ ! -e "$STUB_DIR/argv.log" ]
}

@test "usage" {
	run bash "$SCRIPT" nonsense
	[ "$status" -eq 2 ]
}
