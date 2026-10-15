#!/usr/bin/env bash
# vault42-pull-everything.sh [--yes] — pull everything vault42 keeps for univers42/groot with
# the native 42ctl and the operator's own account, then prove the engine dumps arrived whole.
# Every environment is previewed first; nothing is written before one "y" (or --yes).
#
#   main environment (VAULT42_ENV, prod)  → this checkout: *.env*, *.secrets, secrets/ dumps
#   every other environment with files    → .vault42/env/<env>/
#   the project's notes                    → .vault42/notes/<path>
#   team/handbook.html                     → groot-vault42-handbook.team.html
#
# Each environment lands in an empty staging directory beside the checkout, in a directory pinned
# as its own git repository root so 42ctl cannot write elsewhere, and is verified there, so a file already in the checkout can never pass for one the
# pull delivered (one with a problem is kept in .vault42/staging/<env>). Only then is the main
# environment moved in: a file that differs is swapped and the old one kept as
# <file>.bak-<stamp>; a dump failing SHA256SUMS is never moved. Everything runs under umask 077.
# Last, every ENGINE_SEEDS dump in ./secrets is proven against the SHA256SUMS the pull delivered
# and against ./secrets/SHA256SUMS, which the restore checks.
#
# `42ctl pull` (personal tree) answers "no manifest": the tree is in the shared environment.
# Sign-in: scripts/lib/vault42-session.sh. The object-store key is never written to disk.
# Loading the dumps INTO databases is a separate, destructive step (make vault-restore).
# Exit: 0 this checkout holds everything listed and it checks (the last line says when the tree
# itself is damaged); 1 something missing, corrupt or refused; 2 usage.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORG="${VAULT42_ORG:-univers42}"
PROJECT="${VAULT42_PROJECT:-groot}"
MAIN_ENV="${VAULT42_ENV:-prod}"
CTL="${CTL_BIN:-42ctl}"
CTL_CFG_DIR="${CTL_CFG_DIR:-$HOME/.config/42ctl}"
export FT_CONFIG="${FT_CONFIG:-$CTL_CFG_DIR/config.json}"
export FT_KEYSTORE="${FT_KEYSTORE:-$CTL_CFG_DIR/keystore.v42}"
TTY_DEV="${VAULT42_TTY:-/dev/tty}"
LOG_TAG=pull-everything
SANDBOX="$REPO/.vault42"
HANDBOOK="$REPO/groot-vault42-handbook.team.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
ENVS=()
WORK=""
failures=0
assume_yes=0

# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"
# shellcheck source=scripts/lib/git-ignored.sh
. "$REPO/scripts/lib/git-ignored.sh"
# shellcheck source=scripts/lib/seed-check.sh
. "$REPO/scripts/lib/seed-check.sh"
# shellcheck source=scripts/lib/vault42-pull-verify.sh
. "$REPO/scripts/lib/vault42-pull-verify.sh"
# shellcheck source=scripts/lib/vault42-session.sh
. "$REPO/scripts/lib/vault42-session.sh"

# in_env ENV VERB… runs `42ctl env VERB…` scoped to ORG/PROJECT/ENV.
in_env() { "$CTL" env "${@:2}" --org "$ORG" --project "$PROJECT" --env "$1"; }
rel() { printf './%s' "${1#"$REPO"/}"; }
fail() {
	note "✗ $1"
	failures=$((failures + 1))
}
# Both lookups' errors stay in $WORK/secret.err, so a refusal can say why.
vault_secret() { in_env "$MAIN_ENV" secret get "$1" 2>"$WORK/secret.err" || "$CTL" vault get "$1" 2>>"$WORK/secret.err"; }

# Fatal before any write: without it the >4 MiB archives cannot come back, and a tree without
# its volumes is not a restore. A contract left on a replaced keystore is rebound, then retried.
load_object_store_key() {
	fetch_object_store_key || ! grep -q 'contract not bound to this key' "$WORK/secret.err" ||
		{ rebind_contract && fetch_object_store_key; } || true
	[ -n "${FT_S3_KEY:-}" ] && [ -n "${FT_S3_SECRET:-}" ] ||
		die "no infra/S3_KEY + infra/S3_SECRET in $ORG/$PROJECT/$MAIN_ENV nor in your vault ($(tr '\n' ' ' <"$WORK/secret.err")): the large dumps cannot come back — nothing written"
	export FT_S3_KEY FT_S3_SECRET
	note "✓ object-store credential loaded (memory only)"
}
fetch_object_store_key() {
	[ -z "${FT_S3_KEY:-}" ] || [ -z "${FT_S3_SECRET:-}" ] || return 0
	FT_S3_KEY="$(vault_secret infra/S3_KEY)" && FT_S3_SECRET="$(vault_secret infra/S3_SECRET)"
}

# Caveat: `env ls` takes no --org and reads the active profile's org, so a profile aimed at
# another org lists that org's environments; each then fails `env files` and is skipped by
# name, and an environment only univers42 has is missed. VAULT42_ENVS="prod dev" replaces it.
discover_environments() {
	local names="${VAULT42_ENVS:-}"
	if [ -z "$names" ]; then
		names="$("$CTL" env ls --project "$PROJECT" --format '{{.Name}}' 2>/dev/null)" ||
			note "! env ls failed: only $MAIN_ENV is pulled"
	fi
	printf '%s\n%s\n' "$MAIN_ENV" "$names" | tr -s '[:space:]' '\n' | awk 'NF && !seen[$0]++'
}

# An environment name becomes a directory: one that is not a plain name could escape .vault42.
read_manifests() {
	local env
	while IFS= read -r env; do
		if [[ ! "$env" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
			note "! environment refused (not a plain name): $env"
		elif in_env "$env" files -q >"$WORK/$env.files" 2>"$WORK/$env.err" && [ -s "$WORK/$env.files" ]; then
			ENVS+=("$env")
			note "$env: $(wc -l <"$WORK/$env.files" | tr -d ' ') file(s) listed"
		else
			note "! $env: nothing to pull ($(head -n 1 "$WORK/$env.err"))"
		fi
	done < <(discover_environments)
	[ "${ENVS[0]:-}" = "$MAIN_ENV" ] ||
		die "$ORG/$PROJECT/$MAIN_ENV lists no file you can read — check your grant (42ctl env keys ls)"
}

# .vault42 holds secrets in the clear: never let git see it.
guard_sandbox() {
	is_git_ignored "$SANDBOX/probe" ||
		die "$(rel "$SANDBOX") is not git-ignored: add '.vault42/' to .gitignore first — nothing written"
}

report_unignored() {
	local hits
	hits="$(list_not_ignored "$REPO" ".bak-$STAMP" <"$WORK/$MAIN_ENV.files" | tr "\n" " ")"
	[ -z "$hits" ] || note "! not git-ignored (or tracked), so a \`git add -A\` would take them or their backup: $hits"
}

# A directory that does not exist yet is previewed from an empty one, so the preview writes nothing.
preview_all() {
	local env dest
	mkdir "$WORK/empty"
	for env in "${ENVS[@]}"; do
		dest="$REPO"
		[ "$env" = "$MAIN_ENV" ] || dest="$WORK/empty"
		note "preview of $env — nothing is written yet:"
		(cd "$dest" && in_env "$env" pull) || die "preview of $env failed — nothing written"
	done
	report_unignored
	if [ "$assume_yes" -ne 1 ] && ! confirm "write all of the above (changed files kept as <file>.bak-$STAMP)?"; then
		note "nothing written. Re-run with --yes, or from a terminal, to apply."
		exit 0
	fi
}

# Moved, not copied, so each dump exists once on disk; a timestamped backup is never overwritten
# by a later run.
install_main() {
	local stage="$1" path written=0 same=0
	while IFS= read -r path; do
		[ -f "$stage/$path" ] || continue
		if [ -f "$REPO/$path" ] && cmp -s "$stage/$path" "$REPO/$path"; then
			same=$((same + 1))
			continue
		fi
		[ ! -e "$REPO/$path" ] || mv -f "$REPO/$path" "$REPO/$path.bak-$STAMP"
		mkdir -p "$(dirname "$REPO/$path")"
		mv -f "$stage/$path" "$REPO/$path"
		written=$((written + 1))
	done <"$WORK/$MAIN_ENV.files"
	note "✓ $MAIN_ENV → ./ : $written file(s) written, $same already identical"
}

install_env() {
	local env="$1" stage="$2"
	if [ "$env" = "$MAIN_ENV" ]; then
		install_main "$stage"
		return 0
	fi
	mkdir -p "$SANDBOX/env"
	rm -rf "$SANDBOX/env/$env.old"
	[ ! -d "$SANDBOX/env/$env" ] || mv "$SANDBOX/env/$env" "$SANDBOX/env/$env.old"
	mv "$stage" "$SANDBOX/env/$env"
	note "✓ $env → $(rel "$SANDBOX/env/$env")"
}

# One environment failing does not stop the next; a stage with a problem is kept in
# .vault42/staging/<env> (another environment's stage has by then become .vault42/env/<env>).
pull_all() {
	local env stage before kept
	for env in "${ENVS[@]}"; do
		stage="$WORK/staging/$env"
		kept="$SANDBOX/staging/$env"
		rm -rf "$kept"
		mkdir -p "$stage"
		before="$failures"
		(cd "$stage" && in_env "$env" pull --apply) || fail "$env: the pull stopped part-way"
		verify_listed "$env" "$stage"
		verify_dumps "$env" "$stage"
		install_env "$env" "$stage"
		[ "$failures" -ne "$before" ] || continue
		if [ -d "$stage" ]; then
			mkdir -p "$SANDBOX/staging"
			mv "$stage" "$kept"
		else
			kept="$SANDBOX/env/$env"
		fi
		note "✗ $env: $((failures - before)) problem(s); what it delivered is in $(rel "$kept")"
	done
	rmdir "$SANDBOX/staging" 2>/dev/null || true
}

# A note path is the server's word: one that could climb out of .vault42/notes (absolute, or with
# a `..` segment) is refused by name rather than written.
pull_notes() {
	local paths path dest count=0
	paths="$("$CTL" note ls --project "$PROJECT" -q 2>/dev/null)" || {
		note "! could not list the notes of $PROJECT"
		return 0
	}
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		case "/$path/" in */../* | //*) fail "note refused (unsafe path): $path" && continue ;; esac
		dest="$SANDBOX/notes/$path"
		if mkdir -p "$(dirname "$dest")" && "$CTL" note get "$path" --project "$PROJECT" >"$dest"; then
			count=$((count + 1))
		else
			rm -f "$dest"
			fail "note $path did not come back"
		fi
	done <<<"$paths"
	note "✓ $count note(s) in $(rel "$SANDBOX/notes")"
}

# An earlier handbook that differs is kept beside it, still under the *.team.html ignore.
save_handbook() {
	local part="$WORK/handbook"
	if ! in_env "$MAIN_ENV" secret get team/handbook.html >"$part" 2>/dev/null || [ ! -s "$part" ]; then
		note "no team/handbook.html in $MAIN_ENV — it was never sealed there"
		return 0
	fi
	if [ -f "$HANDBOOK" ] && ! cmp -s "$part" "$HANDBOOK"; then
		mv -f "$HANDBOOK" "${HANDBOOK%.team.html}.$STAMP.team.html"
	fi
	mv -f "$part" "$HANDBOOK"
	note "✓ handbook → $(rel "$HANDBOOK")"
}

# ./.env.local is private to its pusher, who gets it back as is. A teammate's is minted, then the
# owner-published team/env-local keys replace the minted salt and VITE_BAAS_* (they must match
# the restored rows: scripts/vault42-team.sh); --sync realigns the keys derived from apps/grobase/.env.
restore_env_local() {
	local env_local="$REPO/.env.local" line count=0
	if grep -qxF .env.local "$WORK/$MAIN_ENV.files"; then
		without_credentials bash "$REPO/scripts/gen-local-env.sh" --check || true
		return 0
	fi
	[ ! -f "$env_local" ] || cp -p "$env_local" "$env_local.bak-$STAMP"
	without_credentials bash "$REPO/scripts/gen-local-env.sh" || note "! gen-local-env.sh failed — .env.local left as found"
	while IFS= read -r line; do
		[[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
		put_env "$env_local" "${line%%=*}" "${line#*=}"
		count=$((count + 1))
	done <<<"$(vault_secret team/env-local || true)"
	note "laid $count team key(s) from team/env-local over .env.local"
	without_credentials bash "$REPO/scripts/gen-local-env.sh" --sync || note "! derived keys not all refreshed"
}

finish() {
	local names
	names="$("$CTL" vault ls -q 2>/dev/null | tr '\n' ' ' || true)"
	[ -z "${names// /}" ] || note "your personal vault (not project-scoped, not pulled) holds: $names"
	if [ "$failures" -gt 0 ]; then
		note "✗ $failures problem(s) above — the restore is NOT complete; fix them and re-run"
		exit 1
	fi
	if [ "$tree_damaged" -eq 1 ]; then
		note "✓ this checkout has everything it needs and it checks — but the tree is damaged${tree_kept:+ (only this checkout holds $tree_kept)}, and a teammate's pull of it fails. $REPUBLISH"
		return 0
	fi
	note "✓ everything listed for $ORG/$PROJECT arrived and checks. Loading the dumps into databases: make vault-restore (destructive)"
}

usage() { printf 'usage: %s [--yes]\n' "$0" >&2 && exit 2; }

main() {
	case "${1:-}" in --yes) assume_yes=1 ;; '') ;; *) usage ;; esac
	umask 077
	command -v "$CTL" >/dev/null || die "$CTL is not on PATH — https://github.com/Univers42/42ctl/releases"
	make_work
	load_credentials
	ensure_session
	ensure_unlocked
	load_object_store_key
	read_manifests
	guard_sandbox
	preview_all
	pull_all
	verify_required
	pull_notes
	save_handbook
	restore_env_local
	finish
}

main "$@"
