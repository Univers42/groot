#!/usr/bin/env bash
# tools.sh — run one command from the groot-tools image (infrastructure/docker/tools), so nothing is
# installed on the host (docs/redesign/DECISIONS.md D-004). The repo is mounted at its own path
# and the working directory is kept, so a file argument means the same inside as outside;
# --network host reaches the local stack; the local CA is trusted when it exists. Only the repo is
# mounted: a path outside it (/tmp, $HOME) does not exist inside, so inputs and outputs live
# under the repo.
#
#   scripts/tools.sh <command> [args...]   e.g. scripts/tools.sh ffmpeg -version
#   scripts/tools.sh --build               build the image if this definition has none; print its tag
#   scripts/tools.sh --tag                 print the tag, build nothing
#
# The tag is a hash of the files that define the image, so an edit to either rebuilds on the next
# run and two checkouts of the same tree run the same image. Build output goes to stderr only:
# the browser MCP servers speak JSON-RPC on stdout.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/docker-run.sh
. "$REPO/scripts/lib/docker-run.sh"
DEF="$REPO/infrastructure/docker/tools"
ENTRY_DIR="$REPO/tests/e2e" # docker-entrypoint.sh, shared with the e2e image

tools_tag() { cat "$DEF/Dockerfile" "$ENTRY_DIR/docker-entrypoint.sh" | sha256sum | cut -c1-12; }
image="${TOOLS_IMAGE:-groot-tools:$(tools_tag)}"

ensure_image() {
	docker image inspect "$image" >/dev/null 2>&1 && return 0
	echo "[tools] building $image (first use of this definition)…" >&2
	docker build --progress=plain -t "$image" --build-context e2e="$ENTRY_DIR" "$DEF" >&2
}

case "${1:-}" in
--tag)
	printf '%s\n' "$image"
	exit 0
	;;
--build)
	ensure_image
	printf '%s\n' "$image"
	exit 0
	;;
'')
	sed -n '9,11p' "$0" >&2
	exit 2
	;;
esac

ensure_image
mapfile -t user_args < <(docker_run_user_args)
ca_args=()
if ca="$(local_ca_file "$REPO")"; then ca_args=(-v "$ca:/certs/local-ca.pem:ro"); fi
tty_args=(-i)
if [[ -t 0 && -t 1 ]]; then tty_args=(-it); fi
workdir="$REPO"
case "$PWD/" in "$REPO"/*) workdir="$PWD" ;; esac
exec docker run --rm --init --network host --ipc host "${tty_args[@]}" "${user_args[@]}" \
	-e HOME=/tmp/tools-home "${ca_args[@]}" -v "$REPO:$REPO" -w "$workdir" "$image" "$@"
