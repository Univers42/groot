#!/bin/sh
# osio-login -- the IDE terminal's login launcher (the PTY Cmd). Starts the shell chosen with
# `chsh -s` (saved in ~/.config/osio/login-shell) when it still passes the same checks chsh
# applies, else /bin/bash -l. Validation lives in osio-shell.sh; this file only decides
# between the two. A missing file is the normal case and says nothing; a file that fails the
# checks costs one stderr line naming the reason.
#
# Caveat: a chosen shell that passes the checks but crashes is not caught, because exec
# replaces this process. The safe terminal (bash --noprofile --norc, which skips this
# launcher) is the way back in. The chosen shell gets `-l`; one that rejects the flag exits
# at once, and chsh -s /bin/bash undoes the choice.

. "$(dirname "$0")/../lib/osio-shell.sh"

FALLBACK_SHELL=/bin/bash

if saved=$(osio_read_saved_shell); then
  if reason=$(osio_shell_refusal "$saved"); then
    exec "$saved" -l
  fi
  printf 'osio-login: saved login shell ignored (%s); starting %s\n' "$reason" "$FALLBACK_SHELL" >&2
fi
exec "$FALLBACK_SHELL" -l
