#!/usr/bin/env bash
# env-init.sh — create /opt/prismatica-public/.env (mode 600) on the b2b VM for the public site
# (ADR 0013). Runs ON the VM, human-run, interactive. From the groot checkout:
#   ssh -t b2b "echo $(base64 -w0 scripts/public-b2b/env-init.sh) | base64 -d | bash"
# The script travels as an argument and not on stdin (`bash -s <`) because `read` and `sudo`
# need the terminal: a script on stdin would be eaten by `read`. Prompts read fd 3, opened on /dev/tty.
#
# Copies SERVICE_ROLE_KEY and ANON_KEY (stored as PUBLIC_BAAS_ANON_KEY, the name the gateway
# reads) out of /opt/grobase/.env without printing them, mints AUTH_LINK_SIGNING_KEY once
# (48 random bytes, base64), and asks for TURNSTILE_SECRET_KEY (hidden) and
# AUTH_SIGNUP_ALLOWLIST (visible). Prints key names with set/unset only, never a value.
#
# scripts/lib/envfile.sh is not used: the VM has no groot checkout, so put_env below is a
# minimal copy of its atomic rewrite (temp file beside the target, then rename, mode kept).
#
# Caveat: `sudo` is used once, to create /opt/prismatica-public under the root-owned /opt, so
# it needs a terminal. A value holding `$`, a quote or a backslash is refused because compose
# interpolates env_file values. The grobase file is parsed with sed (last KEY= line, quotes
# stripped), so a multi-line or exported value there would be copied wrong.
set -euo pipefail
umask 077

DIR=${PRISMATICA_PUBLIC_DIR:-/opt/prismatica-public}
FILE=$DIR/.env
SRC=${GROBASE_ENV_FILE:-/opt/grobase/.env}
# The three overrides exist so scripts/tests/public-b2b.bats can run this with a fake terminal.
exec 3<"${PRISMATICA_TTY:-/dev/tty}"
fail() { echo "FAIL: $*" >&2; exit 1; }

put_env() {
	local tmp
	tmp=$(mktemp "$DIR/.env.XXXXXX")
	[[ ! -f "$FILE" ]] || cat "$FILE" >"$tmp"
	ENVFILE_KEY=$1 ENVFILE_VAL=$2 awk '
BEGIN { k = ENVIRON["ENVFILE_KEY"]; v = ENVIRON["ENVFILE_VAL"] }
{
	eq = index($0, "=")
	if ($0 !~ /^#/ && eq > 1 && substr($0, 1, eq - 1) == k) { if (!seen) print k "=" v; seen = 1; next }
	print
}
END { if (!seen) print k "=" v }' "$tmp" >"$tmp.new"
	chmod 600 "$tmp.new"
	mv "$tmp.new" "$FILE"
	rm -f "$tmp"
}

get_env() {
	[[ -f "$FILE" ]] || return 0
	sed -n "s/^$1=//p" "$FILE" | tail -1
}

source_value() {
	sed -n "s/^$1=//p" "$SRC" | tail -1 | tr -d "\"'"
}

refuse_unsafe() {
	case $2 in
	*'$'* | *\"* | *\'* | *\\*) fail "$1 holds \$, a quote or a backslash: compose would mangle it" ;;
	esac
}

prompt() {
	local name=$1 hidden=$2 current answer
	current=$(get_env "$name")
	if [[ -n "$current" ]]; then
		printf '%s is set; Enter keeps it, or type a new value: ' "$name" >&2
	else
		printf '%s: ' "$name" >&2
	fi
	if [[ "$hidden" = secret ]]; then
		read -r -s answer <&3
		echo >&2
	else
		read -r answer <&3
	fi
	answer=${answer:-$current}
	[[ -n "$answer" ]] || fail "$name is required"
	refuse_unsafe "$name" "$answer"
	put_env "$name" "$answer"
}

[[ -r "$SRC" ]] || fail "cannot read $SRC"
[[ -d "$DIR" ]] || sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 700 "$DIR"
[[ -f "$FILE" ]] || install -m 600 /dev/null "$FILE"
! grep -q '^AUTH_DEMO_INSECURE=' "$FILE" || fail "AUTH_DEMO_INSECURE is in $FILE: remove it (PUB-8)"

service_key=$(source_value SERVICE_ROLE_KEY)
anon_key=$(source_value ANON_KEY)
[[ -n "$service_key" ]] || fail "SERVICE_ROLE_KEY is empty in $SRC"
[[ -n "$anon_key" ]] || fail "ANON_KEY is empty in $SRC"
put_env SERVICE_ROLE_KEY "$service_key"
put_env PUBLIC_BAAS_ANON_KEY "$anon_key"
unset service_key anon_key

[[ -n "$(get_env AUTH_LINK_SIGNING_KEY)" ]] || put_env AUTH_LINK_SIGNING_KEY "$(head -c 48 /dev/urandom | base64 -w0)"
prompt TURNSTILE_SECRET_KEY secret
prompt AUTH_SIGNUP_ALLOWLIST visible

echo "$FILE mode $(stat -c %a "$FILE") (want 600)"
[[ "$(stat -c %a "$FILE")" = 600 ]] || fail "mode is not 600"
for name in SERVICE_ROLE_KEY PUBLIC_BAAS_ANON_KEY AUTH_LINK_SIGNING_KEY TURNSTILE_SECRET_KEY AUTH_SIGNUP_ALLOWLIST; do
	if [[ -n "$(get_env "$name")" ]]; then echo "  $name set"; else echo "  $name UNSET"; fi
done
