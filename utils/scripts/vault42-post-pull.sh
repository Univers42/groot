#!/bin/sh
# vault42-post-pull.sh — what `vault42 pull --apply` leaves undone: a usable ./.env.local.
# Run by vault42 as the `post_pull` hook of utils/vault42.conf, after its lock is released, with
# FT_PASSPHRASE as the only credential. The same three steps as the tail of scripts/vault42-team.sh
# (the old path, still the verified one); keep the two in step until that path is retired.
#
# ./.env.local is always private in a shared env ("*.local"), so a teammate never receives the
# owner's copy. gen-local-env.sh rebuilds it from the pulled apps/grobase/.env but MINTS the
# osionos-only secrets, and OSIONOS_BRIDGE_EMAIL_HASH_SALT / VITE_BAAS_* must match the restored
# database instead. The owner publishes those lines as env secret team/env-local; this lays them
# over the generated file. Absent, the pull still succeeds and says what will be broken.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OVERLAY_SECRET="${VAULT42_TEAM_ENV_LOCAL:-team/env-local}"
ENV_LOCAL="$REPO/.env.local"

note() { printf '[vault42-post-pull] %s\n' "$1" >&2; }

cd "$REPO"

# Idempotent: an existing ./.env.local (the owner's restored private copy) is left alone.
bash scripts/gen-local-env.sh || note "gen-local-env.sh did not run — .env.local left as found"
# The pulled apps/grobase/.env may be newer than an .env.local this machine already had.
bash scripts/gen-local-env.sh --sync || note "derived keys not all refreshed — inspect: bash scripts/gen-local-env.sh --check"
[ -f "$ENV_LOCAL" ] || {
	note "no .env.local to overlay — skipping"
	exit 0
}

_tmp="$(mktemp "${TMPDIR:-/tmp}/env-local.XXXXXX")"
_err="$(mktemp "${TMPDIR:-/tmp}/env-local-err.XXXXXX")"
trap 'rm -f "$_tmp" "$_err"' EXIT INT TERM
umask 077

# An absent secret is a normal outcome, so a failure is reported and not fatal; the reason is
# shown so a lock or a missing credential is not mistaken for "the owner never published it".
if overlay="$(bash vendor/scripts/vault42/vault42.sh --config utils/vault42.conf --target secrets \
	secret get "$OVERLAY_SECRET" 2>"$_err" </dev/null)"; then
	:
else
	overlay=""
	note "could not read $OVERLAY_SECRET: $(head -n 1 "$_err")"
fi
count="$(printf '%s\n' "$overlay" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' || true)"

if [ "${count:-0}" -eq 0 ]; then
	note "no $OVERLAY_SECRET in this environment — .env.local keeps its freshly minted values"
	note "  WARNING: a fresh OSIONOS_BRIDGE_EMAIL_HASH_SALT cannot match the restored"
	note "  osionos_bridge_identities rows, so seeded logins fail. Ask the owner to publish it:"
	note "  grep -E '^(OSIONOS_BRIDGE_EMAIL_HASH_SALT|OSIONOS_BAAS_API_KEY|VITE_BAAS_[A-Z_]+)=' .env.local |"
	note "    make vault42-secret-set KEY=$OVERLAY_SECRET"
	exit 0
fi

# Appending (not editing in place) keeps the team values last, so they win for any consumer that
# takes the final assignment.
awk -v ov="$overlay" '
BEGIN {
	m = split(ov, lines, "\n")
	for (i = 1; i <= m; i++) {
		if (lines[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
			eq = index(lines[i], "=")
			k = substr(lines[i], 1, eq - 1)
			team[k] = lines[i]
			seq[++n] = k
		}
	}
}
{
	eq = index($0, "=")
	if (eq > 1) {
		k = substr($0, 1, eq - 1)
		if (k in team) next
	}
	print
}
END {
	if (n) {
		print ""
		print "# --- team values from the shared environment (vault42) ---"
		print "# Published by the owner; they must match the restored data, not be re-minted."
		for (i = 1; i <= n; i++) print team[seq[i]]
	}
}
' "$ENV_LOCAL" >"$_tmp"

cat "$_tmp" >"$ENV_LOCAL"
chmod 600 "$ENV_LOCAL"
note "laid $count team key(s) over .env.local"
