# Login-shell defaults that make the sandbox behave like a computer where the user owns every
# toolchain: installers write under $HOME (a persistent volume), never under /etc or /usr,
# which stay read-only and root-owned. Installed at /etc/profile.d/10-user-space.sh.
#
# Only a login shell reads this. The safe terminal (`bash --noprofile --norc`) skips it on
# purpose, so a bad ~/.local/bin or a broken variable here cannot lock the user out.
#
# PIP_BREAK_SYSTEM_PACKAGES lifts bookworm's PEP 668 refusal so `pip install --user` works.
# It cannot touch /usr: the rootfs is read-only and the user is not root.
# PIP_USER is deliberately not set: it makes pip fail inside a virtualenv.
#
# Caveat: values are defaults, not enforcement. Each is `: ${V:=default}`-style, so an
# exported value the user already has wins, and the user can unset any of them.

osio_prepend_path() {
  case ":$PATH:" in *":$1:"*) return 0 ;; esac
  PATH="$1:$PATH"
}

if [ -n "${HOME:-}" ] && [ "$HOME" != / ]; then
  : "${NPM_CONFIG_PREFIX:=$HOME/.local}"
  : "${PYTHONUSERBASE:=$HOME/.local}"
  : "${PIP_BREAK_SYSTEM_PACKAGES:=1}"
  : "${GOPATH:=$HOME/go}"
  : "${CARGO_HOME:=$HOME/.cargo}"
  : "${RUSTUP_HOME:=$HOME/.rustup}"
  : "${MAMBA_ROOT_PREFIX:=$HOME/micromamba}"
  export NPM_CONFIG_PREFIX PYTHONUSERBASE PIP_BREAK_SYSTEM_PACKAGES GOPATH CARGO_HOME RUSTUP_HOME MAMBA_ROOT_PREFIX

  osio_prepend_path "$GOPATH/bin"
  osio_prepend_path "$CARGO_HOME/bin"
  osio_prepend_path "$HOME/.local/bin"
  export PATH
fi
unset -f osio_prepend_path 2>/dev/null || unset osio_prepend_path

: "${LANG:=C.UTF-8}"
: "${LC_ALL:=C.UTF-8}"
export LANG LC_ALL
