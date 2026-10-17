#!/bin/sh
# osio-volume-init -- the ownership init (ADR 0011). Runs as root, with CHOWN, FOWNER and
# DAC_READ_SEARCH only, in a container that has no network and a read-only root, mounting the same
# two volumes at the same targets as the box. It makes each volume root, and everything below it,
# belong to $OSIO_UID:10001, and the root mode 700, so no other user's box can enter it.
#
# Order matters. Docker copies the image directory into an empty volume on first mount and resets
# its root to the image's owner, which is why this runs in the sandbox image at the real targets
# (the box then mounts with NoCopy). The contents are chowned first and the root last: a root that
# already reads $OSIO_UID:10001 700 therefore means an earlier run finished, and the walk is skipped.
#
# Hostile contents are the point. chown -h never follows a symlink; -P stops -R from following one
# into another volume's files; DAC_READ_SEARCH reads through the 0700 directories a previous uid
# left behind, which CHOWN alone cannot. Without CAP_FSETID the kernel clears setuid and setgid on
# every file it chowns.
#
# Caveat: a box of the same owner that is still running while this walks (a second workspace
# sharing the home volume) sees its files change owner under it until it is recreated. Hard links
# into a tree of this volume are chowned with their target, which is the same volume.

set -eu

BOX_GID=10001
uid=${OSIO_UID:-}
case $uid in
  [2-5][0-9][0-9][0-9][0-9]) ;;
  *) echo "osio-volume-init: OSIO_UID must be a 5-digit uid in 20000-59999" >&2; exit 2 ;;
esac

if [ "$#" -gt 0 ]; then dirs=$*; else dirs="/workspace /home/coder"; fi

for dir in $dirs; do
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    echo "osio-volume-init: $dir is not a directory" >&2
    exit 1
  fi
  if [ "$(stat -c '%u:%g:%a' "$dir")" = "$uid:$BOX_GID:700" ]; then continue; fi
  chown -R -h -P "$uid:$BOX_GID" "$dir"
  chmod 700 "$dir"
done
