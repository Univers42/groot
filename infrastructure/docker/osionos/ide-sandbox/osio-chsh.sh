#!/bin/sh
# chsh -- the box's replacement for the setuid /usr/bin/chsh, which cannot work here
# (read-only /etc, no-new-privileges). `chsh -s <path>` saves the choice under
# ~/.config/osio for osio-login; `chsh` alone prints the shell the next terminal will start.
# It never touches /etc. The rules are osio-shell.sh's, shared with the launcher.
#
# Caveat: only `chsh` and `chsh -s <path>` exist. Any other flag or a user argument is
# refused, since there is no other account to change in a one-user box.

. "$(dirname "$0")/../lib/osio-shell.sh"

usage() {
  echo "chsh: only 'chsh' and 'chsh -s <absolute path>' are supported" >&2
  exit 2
}

print_current() {
  if saved=$(osio_read_saved_shell) && osio_shell_refusal "$saved" >/dev/null; then
    printf '%s\n' "$saved"
  else
    echo /bin/bash
  fi
}

save_shell() {
  if ! reason=$(osio_shell_refusal "$1"); then
    echo "chsh: $1 refused ($reason): it must be an executable file under \$HOME or listed in /etc/shells" >&2
    exit 1
  fi
  mkdir -p "$OSIO_SHELL_CONF_DIR" || exit 1
  tmp=$(mktemp "$OSIO_SHELL_CONF_DIR/.login-shell.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$OSIO_SHELL_CONF" || exit 1
  trap - EXIT
}

case $# in
  0) print_current ;;
  2) [ "$1" = -s ] || usage; save_shell "$2" ;;
  *) usage ;;
esac
