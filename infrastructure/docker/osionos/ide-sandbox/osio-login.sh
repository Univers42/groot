#!/bin/sh
# osio-login -- the IDE terminal's login launcher (the PTY Cmd). Starts the shell chosen with
# `chsh -s` (saved in ~/.config/osio/login-shell) when it still passes the same checks chsh
# applies, else /bin/bash -l. Validation lives in osio-shell.sh; this file only decides
# between the two. A missing file is the normal case and says nothing; a file that fails the
# checks costs one stderr line naming the reason.
#
# Caveat: a chosen shell that passes the checks but crashes is not caught, because exec
# replaces this process. The safe terminal (bash --noprofile --norc, which skips this
# launcher) is the way back in.
#
# It also names the user. OSIO_USER (set by the host bridge on the PTY exec Env) is re-validated
# here, because the box user controls this process's environment, and becomes the account name in
# /tmp/.osio/passwd, the file /etc/passwd links to. uid, gid and home never come from it (the uid is `id -u`): runc
# takes them from the numeric User and the create Env. A name that fails validation, or is one of
# the names in /etc/passwd.base, leaves the default coder file in place. The chosen shell gets `-l`; one that rejects the flag exits
# at once, and chsh -s /bin/bash undoes the choice.

. "$(dirname "$0")/../lib/osio-shell.sh"

FALLBACK_SHELL=/bin/bash
PASSWD_BASE=/etc/passwd.base
PASSWD_DIR=/tmp/.osio

osio_username_refusal() {
  case $1 in
    "") echo empty; return 1 ;;
    *[!a-z0-9_-]*) echo bad-character; return 1 ;;
    [!a-z_]*) echo bad-first-character; return 1 ;;
  esac
  [ "${#1}" -le 32 ] || { echo too-long; return 1; }
  if cut -d: -f1 "$PASSWD_BASE" 2>/dev/null | grep -qxF -- "$1"; then echo reserved; return 1; fi
  return 0
}

# Writes passwd.base with only the coder line renamed and given the box's uid. A unique temp file and an atomic rename keep
# two terminals opening at once from tearing each other's file. Never fatal: the box keeps whatever
# file it had, and the shell still starts.
osio_write_identity() {
  [ -r "$PASSWD_BASE" ] || return 1
  mkdir -p -m 0700 "$PASSWD_DIR" || return 1
  tmp=$(mktemp "$PASSWD_DIR/passwd.XXXXXX") || return 1
  # The uid is the box's own (ADR 0011), the one runc was started with, never a value from the environment.
  if sed "s/^coder:x:10001:/$1:x:$(id -u):/" "$PASSWD_BASE" > "$tmp" && chmod 0600 "$tmp" && mv -fT "$tmp" "$PASSWD_DIR/passwd"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

if [ -n "${OSIO_USER:-}" ]; then
  if reason=$(osio_username_refusal "$OSIO_USER"); then
    if osio_write_identity "$OSIO_USER"; then
      export USER="$OSIO_USER" LOGNAME="$OSIO_USER"
    else
      printf 'osio-login: account name not written; keeping coder\n' >&2
    fi
  else
    printf 'osio-login: OSIO_USER ignored (%s); keeping coder\n' "$reason" >&2
  fi
fi
unset OSIO_USER

if saved=$(osio_read_saved_shell); then
  if reason=$(osio_shell_refusal "$saved"); then
    exec "$saved" -l
  fi
  printf 'osio-login: saved login shell ignored (%s); starting %s\n' "$reason" "$FALLBACK_SHELL" >&2
fi
exec "$FALLBACK_SHELL" -l
