# shellcheck shell=bash
# vault42-session.sh — a live, unlocked vault42 session from the native 42ctl, asking the
# terminal only for what the operator's credential files do not hold.
#
#   load_credentials   fill FT_PASSPHRASE (alias VAULT42_PASSPHRASE), FT_PASSWORD,
#                      FT_LOGIN_EMAIL (alias FT_EMAIL), FT_TENANT, FT_REGISTER_TOKEN (alias
#                      VAULT42_REGISTER_TOKEN), FT_S3_KEY, FT_S3_SECRET from every file under
#                      $CTL_CFG_DIR/secret*. A value already set wins. Names are printed,
#                      never values.
#   ensure_session     `auth me` plus a contract, else sign_in (`auth login --password`).
#   rebind_contract    after a keystore change, sign_in again once the terminal says y.
#   ensure_unlocked    the keystore opens with FT_PASSPHRASE, else offer `keys recover`.
#
# The caller sets CTL (the 42ctl binary), CTL_CFG_DIR, FT_KEYSTORE, TTY_DEV (where prompts
# are read; /dev/tty outside tests) and LOG_TAG, and sources scripts/lib/envfile.sh first.
# Caveat: only plain `KEY=value` lines are read (envfile.sh get_env): an `export KEY=…` line
# or a value spread over several lines is missed, and the run then asks the terminal.

CREDENTIALS="FT_PASSPHRASE:VAULT42_PASSPHRASE FT_PASSWORD FT_LOGIN_EMAIL:FT_EMAIL FT_TENANT
FT_REGISTER_TOKEN:VAULT42_REGISTER_TOKEN FT_S3_KEY FT_S3_SECRET"
CRED_FILES=()

note() { printf '[%s] %s\n' "${LOG_TAG:-vault42}" "$1" >&2; }
die() {
	note "✗ $1"
	exit 1
}
has_tty() { (: <"$TTY_DEV") 2>/dev/null; }
confirm() {
	local answer
	has_tty || return 1
	printf '%s [y/N] ' "$1" >&2
	read -r answer <"$TTY_DEV" || return 1
	[ "$answer" = y ] || [ "$answer" = Y ]
}
# A child that needs no vault access never inherits the credentials.
without_credentials() {
	env -u FT_PASSPHRASE -u VAULT42_PASSPHRASE -u FT_PASSWORD -u FT_REGISTER_TOKEN \
		-u VAULT42_REGISTER_TOKEN -u FT_S3_KEY -u FT_S3_SECRET "$@"
}

# find_credential NAME [ALIAS]: the first value of NAME, else ALIAS, across CRED_FILES.
find_credential() {
	local file key
	for file in "${CRED_FILES[@]}"; do
		for key in "$@"; do
			if get_env "$file" "$key"; then
				note "loaded $1 from ${file#"$CTL_CFG_DIR"/}"
				return 0
			fi
		done
	done
	return 1
}

load_credentials() {
	local pair name alias value
	FT_PASSPHRASE="${FT_PASSPHRASE:-${VAULT42_PASSPHRASE:-}}"
	mapfile -t CRED_FILES < <(find "$CTL_CFG_DIR" -maxdepth 2 -path "$CTL_CFG_DIR/secret*" -type f 2>/dev/null | sort)
	if [ "${#CRED_FILES[@]}" -eq 0 ]; then
		note "no credential file under $CTL_CFG_DIR/secret* — missing values are asked instead"
		return 0
	fi
	for pair in $CREDENTIALS; do
		IFS=: read -r name alias <<<"$pair"
		[ -z "${!name:-}" ] || continue
		value="$(find_credential "$name" ${alias:+"$alias"})" || continue
		printf -v "$name" '%s' "$value"
	done
}

# `auth status` reads only the token files and says "logged in" for a session the server has
# expired (2026-10-12, ctl-env.sh require_session); `auth me` asks the server.
ensure_session() {
	if "$CTL" auth me >/dev/null 2>&1 && "$CTL" auth status 2>/dev/null | grep -q contract; then
		note "✓ session and contract live"
		return 0
	fi
	sign_in
}

sign_in() {
	if [ -z "${FT_LOGIN_EMAIL:-}" ]; then
		has_tty || die "no live session and no FT_LOGIN_EMAIL to sign in with"
		read -rp 'vault42 account email: ' FT_LOGIN_EMAIL <"$TTY_DEV"
	fi
	[ -n "${FT_TENANT:-}" ] || note "! no FT_TENANT: the login takes a session but no contract, and team verbs need both"
	note "signing in (a second factor emails a code here)…"
	# Exported in this subshell only: the password never reaches argv or a later child.
	(
		[ -z "${FT_PASSWORD:-}" ] || export FT_PASSWORD
		[ -z "${FT_REGISTER_TOKEN:-}" ] || export FT_REGISTER_TOKEN
		exec "$CTL" auth login --password --email "$FT_LOGIN_EMAIL" ${FT_TENANT:+--tenant "$FT_TENANT"}
	) || die "sign-in failed — see the error above"
	"$CTL" auth me >/dev/null || die "signed in, yet the server still refuses the session"
}

# After `keys recover` or `keys init --force` the contract still names the old key ("contract not
# bound to this key"); a password sign-in binds it to this keystore (42ctl help keys). That moves it
# off the old key for every machine still using it, so it takes its own "y" — never a blanket --yes.
rebind_contract() {
	confirm "your contract is bound to another key: sign in again to bind it to this keystore?" ||
		die "contract bound to another key — run: $CTL auth login --password --email <you> --tenant <tenant>"
	sign_in
}

recover_keystore() {
	[ -n "${FT_LOGIN_EMAIL:-}" ] || die "set FT_LOGIN_EMAIL, then: $CTL keys recover --email <you>"
	confirm "replace $FT_KEYSTORE with your escrowed identity (emailed code; the old one is kept)?" ||
		die "keystore still locked: fix FT_PASSPHRASE, or run $CTL keys recover --email <you>"
	cp -p "$FT_KEYSTORE" "$FT_KEYSTORE.bak-$(date +%Y%m%d-%H%M%S)"
	"$CTL" keys recover --email "$FT_LOGIN_EMAIL" <"$TTY_DEV" || die "keys recover failed — see the error above"
	"$CTL" auth whoami >/dev/null || die "the recovered keystore does not open with this passphrase either"
}

ask_passphrase() {
	has_tty || die "the keystore needs a passphrase (FT_PASSPHRASE unset or refused) and there is no terminal to ask"
	read -rsp 'vault42 keystore passphrase: ' FT_PASSPHRASE <"$TTY_DEV"
	printf '\n' >&2
	export FT_PASSPHRASE
}

# Caveat: `auth whoami` is the unlock probe because it needs the keystore; a failure whose text
# does not mention unlocking is reported as is, never treated as a wrong passphrase.
unlock_probe() {
	local err
	if err="$("$CTL" auth whoami 2>&1 >/dev/null)"; then
		note "✓ keystore unlocked"
		return 0
	fi
	case "$err" in
	*unlock*) note "keystore did not open: $err" ;;
	*) die "auth whoami failed: $err" ;;
	esac
	return 1
}

# A wrong passphrase gets one more try on the terminal before the keystore itself is suspected.
ensure_unlocked() {
	[ -f "$FT_KEYSTORE" ] || die "no keystore at $FT_KEYSTORE — on a new machine: $CTL keys recover --email <you>"
	[ -n "${FT_PASSPHRASE:-}" ] || ask_passphrase
	export FT_PASSPHRASE
	unlock_probe && return 0
	ask_passphrase
	unlock_probe || recover_keystore
}
