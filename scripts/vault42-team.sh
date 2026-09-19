#!/bin/sh
# vault42-team.sh push|pull [--apply] [--only PATTERN] [--backup]
#
# The TEAM half of the vault42 workflow. Everything it sends is sealed to the
# ENVIRONMENT's key, so every member granted the project can open it — unlike the
# personal `push`/`pull`, which seal to the caller alone and leave a teammate with
# "no manifest for project groot" however much admin they hold in the org.
#
# The transfer itself is NOT reimplemented here: apps/grobase/scripts/vault/ctl-env.sh
# already owns profile seeding, the hidden passphrase read, the object-store
# credential lookup, the liveness heartbeat and the shared-environment argv. This
# script adds the one thing that layer cannot know about — the root ./.env.local.
#
# WHY THE OVERLAY EXISTS
#
#   ./.env.local is ALWAYS private in a shared environment ("*.local" is private,
#   flag or not), so a teammate never receives the owner's copy. scripts/gen-local-env.sh
#   rebuilds it from the shared apps/grobase/.env — but it MINTS the osionos-only
#   secrets fresh, and two kinds of line must instead match the seeded data:
#
#     OSIONOS_BRIDGE_EMAIL_HASH_SALT  salts the email_hash column of
#       osionos_bridge_identities (bridge-api.mjs:254). A fresh salt hashes the same
#       address to a different value, so every restored identity becomes unfindable
#       and seeded logins fail in a way that reads as "wrong password".
#     VITE_BAAS_*                     name tenants, mounts and tables INSIDE the
#       restored database; freshly minted ones point at nothing.
#
#   So the owner publishes exactly those lines as one environment secret
#   (team/env-local) and a teammate's pull lays them over the generated file.
#   Absent, the pull still succeeds and says loudly what will be broken.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORG="${VAULT42_ORG:-univers42}"
PROJECT="${VAULT42_PROJECT:-groot}"
ENVNAME="${VAULT42_ENV:-prod}"
CTL_IMAGE="${CTL_IMAGE:-docker.io/dlesieur/42ctl:latest}"
CTL_CFG_DIR="${CTL_CFG_DIR:-$HOME/.config/42ctl}"
OVERLAY_SECRET="${VAULT42_TEAM_ENV_LOCAL:-team/env-local}"
ENV_LOCAL="$REPO/.env.local"

note() { printf '[vault42-team] %s\n' "$1" >&2; }

[ "$#" -ge 1 ] || {
	printf 'usage: vault42-team.sh push|pull [--apply] [--only PATTERN] [--backup]\n' >&2
	exit 2
}
verb="$1"
shift
case "$verb" in
push | pull) ;;
*)
	printf 'vault42-team.sh: unknown verb %s (push|pull)\n' "$verb" >&2
	exit 2
	;;
esac

# --apply anywhere in the argv decides whether the overlay runs afterwards.
apply=0
for _a in "$@"; do
	[ "$_a" = "--apply" ] && apply=1
done

[ "$verb" = push ] && note "publishing this checkout to $ORG/$PROJECT/$ENVNAME — every teammate's next pull gets this tree"
# A pull backup (`--backup` writes the displaced file aside as .bak) of a private file is
# not itself `*.local`, so a push would publish it to every member — measured on the first
# team push: .env.local.bak went out SHARED. Every .bak stays private, whatever it backs up.
[ "$verb" = push ] && set -- "$@" --private '*.bak'

VAULT_ENV_ORG="$ORG" VAULT_ENV_PROJECT="$PROJECT" VAULT_ENV_NAME="$ENVNAME" \
	REPO_DIR="$REPO" CTL_IMAGE="$CTL_IMAGE" CTL_CFG_DIR="$CTL_CFG_DIR" \
	sh "$REPO/apps/grobase/scripts/vault/ctl-env.sh" "$verb" "$@"

# Only an applied PULL needs a local .env.local rebuilt and overlaid.
if [ "$verb" != pull ] || [ "$apply" -ne 1 ]; then
	exit 0
fi

# gen-local-env.sh is idempotent: it leaves an existing ./.env.local alone, so the
# owner (whose private copy the pull restored) keeps theirs untouched.
bash "$REPO/scripts/gen-local-env.sh" || note "gen-local-env.sh did not run — .env.local left as found"
# The pulled apps/grobase/.env may be newer than an .env.local this machine already had:
# refresh the seven derived BaaS keys in place so Kong's key and the frontends' key agree.
bash "$REPO/scripts/gen-local-env.sh" --sync || note "derived keys not all refreshed — inspect: bash scripts/gen-local-env.sh --check"
[ -f "$ENV_LOCAL" ] || {
	note "no .env.local to overlay — skipping"
	exit 0
}

# One 42ctl invocation, shared with the ad-hoc calls (scripts/vault42-ctl.sh): same
# image, keystore and passphrase handling. Quiet: an absent overlay is a normal outcome.
ctl() {
	CTL_IMAGE="$CTL_IMAGE" CTL_CFG_DIR="$CTL_CFG_DIR" sh "$REPO/scripts/vault42-ctl.sh" "$@" 2>/dev/null </dev/null || true
}

overlay="$(ctl env secret get --org "$ORG" --project "$PROJECT" --env "$ENVNAME" "$OVERLAY_SECRET")"
count="$(printf '%s\n' "$overlay" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' || true)"

if [ "${count:-0}" -eq 0 ]; then
	note "no $OVERLAY_SECRET in this environment — .env.local keeps its freshly minted values"
	note "  WARNING: a fresh OSIONOS_BRIDGE_EMAIL_HASH_SALT cannot match the restored"
	note "  osionos_bridge_identities rows, so seeded logins fail. Ask the owner to publish it:"
	note "  grep -E '^(OSIONOS_BRIDGE_EMAIL_HASH_SALT|OSIONOS_BAAS_API_KEY|VITE_BAAS_[A-Z_]+)=' .env.local |"
	note "    42ctl env secret set --org $ORG --project $PROJECT --env $ENVNAME $OVERLAY_SECRET"
	exit 0
fi

# One awk pass: drop every line the overlay redefines, then append the team block.
# Appending (rather than editing in place) keeps the team values last, so they win
# for any consumer that takes the final assignment.
_tmp="$(mktemp "${TMPDIR:-/tmp}/env-local.XXXXXX")"
trap 'rm -f "$_tmp"' EXIT INT TERM
umask 077
awk -v ov="$overlay" -v envname="$ENVNAME" '
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
		print "# --- team values from the shared environment (vault42 " envname ") ---"
		print "# Published by the owner; they must match the restored data, not be re-minted."
		for (i = 1; i <= n; i++) print team[seq[i]]
	}
}
' "$ENV_LOCAL" >"$_tmp"

cat "$_tmp" >"$ENV_LOCAL"
chmod 600 "$ENV_LOCAL"
note "laid $count team key(s) over .env.local"
