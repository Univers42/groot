# osio-shell.sh -- sourced by osio-login and chsh: the ONE place that decides whether a saved
# login shell may run. Not executable on its own; installed at /usr/local/lib/osio-shell.sh.
#
# The saved shell is the first line of ~/.config/osio/login-shell. It is a path and nothing
# else: it is compared and exec'd, never eval'd and never handed to `sh -c`.
#
# Caveat: this checks the path at launch, not what the file does. A regular executable under
# $HOME that crashes still ends the terminal at once, and the next terminal picks it again; the
# way out is a safe terminal (bash --noprofile --norc), which never reads this file. A symlink
# under $HOME counts as under $HOME wherever it points, since the user owns it.

OSIO_SHELL_CONF_DIR="${HOME:-/nonexistent}/.config/osio"
OSIO_SHELL_CONF="$OSIO_SHELL_CONF_DIR/login-shell"
OSIO_SHELL_MAX_BYTES=4096

# Prints the first line of the saved-shell file (at most OSIO_SHELL_MAX_BYTES bytes read).
# Returns 1 when there is no regular file, which is the normal "never chose one" state.
osio_read_saved_shell() {
  [ -f "$OSIO_SHELL_CONF" ] || return 1
  head -c "$OSIO_SHELL_MAX_BYTES" -- "$OSIO_SHELL_CONF" | head -n 1
}

osio_path_is_under_home() {
  case "${HOME:-}" in /?*) ;; *) return 1 ;; esac
  case $1 in "$HOME"/*) return 0 ;; esac
  return 1
}

osio_path_is_listed_shell() {
  grep -qxF -- "$1" /etc/shells 2>/dev/null
}

# Prints one fixed reason token and returns 1 when $1 may not be a login shell; prints nothing
# and returns 0 when it may. The token never echoes the path, so a hostile file cannot put
# escape sequences on the user's terminal.
osio_shell_refusal() {
  case $1 in
    "") echo empty; return 1 ;;
    *[[:cntrl:]]*) echo control-character; return 1 ;;
    /*) ;;
    *) echo not-absolute; return 1 ;;
  esac
  case $1 in */../* | */..) echo dot-dot; return 1 ;; esac
  [ -f "$1" ] || { echo not-a-regular-file; return 1; }
  [ -x "$1" ] || { echo not-executable; return 1; }
  if [ "$1" -ef /usr/local/bin/osio-login ]; then echo launcher-itself; return 1; fi
  if osio_path_is_under_home "$1" || osio_path_is_listed_shell "$1"; then return 0; fi
  echo not-under-home-or-listed
  return 1
}
