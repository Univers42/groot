#!/usr/bin/env bash
# docker-run.sh — what every one-shot `docker run` in this repo needs to agree on: whose uid
# the container runs as, and where the local CA it must trust lives.
#
#   docker_run_user_args     Print `--user` and `UID:GID` on two lines, or nothing under rootless
#                            Docker. Read it with `mapfile -t user_args < <(docker_run_user_args)`.
#   local_ca_file ROOT       Print the local CA path: $LOCAL_CA_FILE when set (a worktree has no
#                            apps/grobase checkout of its own), else the one under groot ROOT.
#                            Exit 1 when it is not readable; the caller decides if that is fatal.
#
# Sourced by tests/e2e/run.sh and scripts/tools.sh; tested alone in scripts/tests/docker-run.bats.

# Rootless Docker maps the host user to the container's root and nothing else, so --user fails
# there ("cannot setuid to unmapped uid"); root inside already is this user outside, and files
# written to a bind mount come back owned by them either way.
docker_run_user_args() {
	if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
		return 0
	fi
	printf '%s\n' --user "$(id -u):$(id -g)"
}

local_ca_file() {
	local ca="${LOCAL_CA_FILE:-$1/apps/grobase/certs/track-binocle-local-ca.pem}"
	[[ -r "$ca" ]] || return 1
	printf '%s\n' "$ca"
}
