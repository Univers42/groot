#!/bin/sh
# vault42-ctl.sh — run one 42ctl command against this machine's keystore, in the same
# container and with the same environment the make targets use (ctl-env.sh,
# vault42-team.sh). For the ad-hoc calls a team push needs around it: sealing
# infra/S3_* and team/env-local into the shared environment, listing its files, grants
# and keys. Pasting the docker invocation by hand is how `-v` loses its argument.
#
#   scripts/vault42-ctl.sh env secret get --org univers42 --project groot --env prod infra/S3_KEY
#   grep '^X=' .env.local | scripts/vault42-ctl.sh env secret set --org univers42 --project groot --env prod team/env-local
#
# Passphrase: honours FT_PASSPHRASE (or VAULT42_PASSPHRASE) so a shell that exported it
# once runs many commands; otherwise ONE hidden prompt on the terminal — read from
# /dev/tty, so stdin stays free for the value being sealed. Never echoed, never in argv.
set -eu

CTL_IMAGE="${CTL_IMAGE:-docker.io/dlesieur/42ctl:latest}"
CTL_CFG_DIR="${CTL_CFG_DIR:-$HOME/.config/42ctl}"
# CTL_USER is the uid:gid the container runs as. Default: the caller, so files it writes are
# theirs. On ROOTLESS Docker the caller's uid has no mapping inside the container ("cannot
# setuid to unmapped uid") and the image's own user (65532) cannot read the 700 identity dir;
# there CTL_USER=0:0 is the equivalent, since container root IS the caller outside.

[ -d "$CTL_CFG_DIR" ] || {
	printf 'vault42-ctl: no keystore directory at %s\n' "$CTL_CFG_DIR" >&2
	exit 1
}
[ "$#" -ge 1 ] || {
	printf 'usage: vault42-ctl.sh <42ctl args...>\n' >&2
	exit 2
}

if [ -z "${FT_PASSPHRASE:-}" ] && [ -n "${VAULT42_PASSPHRASE:-}" ]; then
	FT_PASSPHRASE="$VAULT42_PASSPHRASE"
fi
if [ -z "${FT_PASSPHRASE:-}" ]; then
	[ -c /dev/tty ] || {
		printf 'vault42-ctl: no terminal to ask for the passphrase — export FT_PASSPHRASE first\n' >&2
		exit 1
	}
	printf 'vault42 keystore passphrase: ' >/dev/tty
	stty -echo </dev/tty 2>/dev/null || true
	trap 'stty echo </dev/tty 2>/dev/null || true' EXIT INT TERM
	read -r FT_PASSPHRASE </dev/tty
	stty echo </dev/tty 2>/dev/null || true
	printf '\n' >/dev/tty
fi
export FT_PASSPHRASE

exec docker run --rm -i --user "${CTL_USER:-$(id -u):$(id -g)}" \
	-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 -e FT_PASSPHRASE \
	-v "$CTL_CFG_DIR:/cfg" "$CTL_IMAGE" "$@"
