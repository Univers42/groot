#!/usr/bin/env bash
# grobase-import-remote.sh — run grobase's import apply|rollback ON the data center, from here.
# The destructive half must run where the engines are, so this rsyncs this checkout's copy of
# the import tools to DEST/.tools (what runs is what was reviewed here, never whatever tree the
# target has checked out), then starts the verb there detached, logging to
# DEST/.tools/<verb>-<id>.log, and follows that log. A dropped ssh ends the follow, not the
# apply: killing apply mid-restore would leave its engines half-replayed.
#
#   grobase-import-remote.sh apply|rollback ID [--dest HOST:/PATH] [--confirm] [--force]
#
# DEST defaults to GROBASE_IMPORT_DEST (e.g. b2b:/var/lib/grobase-import), the root that
# `grobase-import.sh push` filled. Exit: the remote verb's code (0 done · 1 a step failed ·
# 2 refused before any change · 3 postgres counts differ), or 2 for a usage error here.
#
# Ponytail: the exit code travels through DEST/.tools/<verb>-<id>.rc; if the follow is cut
# (ssh drop) this exits 255 while the verb runs on — read that log and .rc on the target.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS=(scripts/ops/grobase-import.sh scripts/ops/grobase-import-apply.sh scripts/ops/grobase-import-rollback.sh
  scripts/ops/vault-restore.sh scripts/ops/pg-counts.sh scripts/lib/lib-packets.sh scripts/lib/lib-netseg.sh)
SSH_OPTS=(-o ClearAllForwardings=yes -o LogLevel=ERROR)
VERB="" ID="" DEST="${GROBASE_IMPORT_DEST:-}" CONFIRM=- FORCE=-

usage() {
  sed -n '9p' "${BASH_SOURCE[0]}" | sed 's/^#   /usage: /' >&2
  exit 2
}

# parse_args — every value that reaches the remote shell is checked against a closed
# character set here, which is what lets run_remote pass them unquoted.
parse_args() {
  [ "$#" -ge 2 ] || usage
  VERB="$1" ID="$2"
  shift 2
  case "$VERB" in apply | rollback) ;; *) usage ;; esac
  case "$ID" in '' | .* | *[!A-Za-z0-9._-]*) echo "error: invalid import id: ${ID}" >&2 && exit 2 ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --dest) DEST="${2:?--dest needs HOST:/PATH}" && shift ;;
    --confirm) CONFIRM=--confirm ;;
    --force) FORCE=--force ;;
    *) usage ;;
    esac
    shift
  done
  case "$DEST" in [!:/-]*:/?*) ;; *) echo "error: DEST must be HOST:/PATH (got '${DEST}')" >&2 && exit 2 ;; esac
  case "${DEST#*:}" in *[!A-Za-z0-9._/-]*) echo "error: DEST path has unsafe characters" >&2 && exit 2 ;; esac
}

# run_remote — the verb runs under setsid so the follow (tail --pid) is the only thing tied to
# this ssh session. `-` stands for an absent flag: ssh re-splits its arguments on the remote side,
# so an empty one would shift the rest.
run_remote() {
  ssh "${SSH_OPTS[@]}" "${DEST%%:*}" sh -s -- "${DEST#*:}" "$VERB" "$ID" "$CONFIRM" "$FORCE" <<'EOF'
cd "$1" || exit 2
base=".tools/$2-$3"
flags=""
for f in "$4" "$5"; do [ "$f" = - ] || flags="$flags $f"; done
rm -f "$base.rc"
IMPORT_ROOT="$PWD" setsid sh -c "bash .tools/scripts/ops/grobase-import-$2.sh $2 $3$flags; echo \$? >$base.rc" \
  >"$base.log" 2>&1 </dev/null &
tail -n +1 --pid=$! -f "$base.log"
exit "$(cat "$base.rc" 2>/dev/null || echo 1)"
EOF
}

main() {
  parse_args "$@"
  (cd "$REPO/apps/grobase" && rsync -R --chmod=D700,F600 -e "ssh ${SSH_OPTS[*]}" "${TOOLS[@]}" "${DEST}/.tools/")
  run_remote
}

main "$@"
