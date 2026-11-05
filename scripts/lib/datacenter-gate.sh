# shellcheck shell=bash
# datacenter-gate.sh — make all's first step: prove the vault can be read before anything is built.
# The contract: vault42 credentials are the only input, so a machine that cannot read the vault
# stops here, naming what to set, instead of failing an hour later inside a build.
# Sourced by scripts/datacenter.sh, which defines note, die, machine_value, REPO and CTL_CFG_DIR.
#
#   vault readable                  go on
#   no credentials at all           the local pipeline (CI, a clean evaluation machine)
#   some credentials, not all       stop: a half-set machine must not silently go local
#   unreadable, hand-set files here go on, and a VM can no longer be built from this run
#   unreadable, nothing here        stop, naming the files and keys to set by hand
#
# Credentials stay on-demand and are not exported to make's environment: a child that needs no
# vault access never inherits them (vault42-session.sh without_credentials), and docker builds run
# under that environment. Each step that needs them reads them from the files here.
#
# Caveat: "readable" means the environment's file list came back. It proves the session, the
# contract and the grant, not that a given file decrypts; vault42-pull-everything.sh verifies that.
# Caveat: an account with a second factor mails a code, which only a terminal can answer; with no
# terminal the sign-in fails and the run reports the vault as unreadable.

GATE_KEYS="FT_PASSPHRASE:VAULT42_PASSPHRASE FT_PASSWORD FT_EMAIL:FT_LOGIN_EMAIL FT_TENANT"
CTL_INSTALLER=https://raw.githubusercontent.com/Univers42/42ctl/main/install.sh

# credential_value NAME [ALIAS] — from the environment first, as vault42-session.sh reads it.
credential_value() {
  local key
  for key in "$@"; do
    if [ -n "${!key:-}" ]; then
      printf '%s\n' "${!key}"
      return 0
    fi
    machine_value "$key" && return 0
  done
  return 1
}

missing_credentials() {
  local pair name alias
  for pair in $GATE_KEYS; do
    IFS=: read -r name alias <<<"$pair"
    credential_value "$name" ${alias:+"$alias"} >/dev/null || printf '%s ' "$name"
  done
}

any_credential() {
  local pair name alias
  for pair in $GATE_KEYS; do
    IFS=: read -r name alias <<<"$pair"
    credential_value "$name" ${alias:+"$alias"} >/dev/null && return 0
  done
  return 1
}

# The keystore travels in the credentials file on a new machine, and nothing else restores it
# before a VM build: born2root's set_seeds does, but only after the build.
ensure_keystore() {
  local keystore="$CTL_CFG_DIR/keystore.v42" encoded tmp
  [ -s "$keystore" ] && return 0
  encoded=$(machine_value FT_KEYSTORE_B64) || die "no keystore: put it at $keystore, or FT_KEYSTORE_B64 in $CTL_CFG_DIR/secrets/42admin.env"
  tmp=$(mktemp "$keystore.XXXXXX") || die "cannot write in $CTL_CFG_DIR"
  base64 -d <<<"$encoded" >"$tmp" 2>/dev/null && [ -s "$tmp" ] || {
    rm -f "$tmp"
    die "FT_KEYSTORE_B64 is not valid base64"
  }
  chmod 600 "$tmp" && mv -f "$tmp" "$keystore"
  note "restored the keystore from FT_KEYSTORE_B64"
}

# ensure_ctl — prints the 42ctl binary, installing it from its own installer when absent.
ensure_ctl() {
  local ctl installer
  ctl=$(command -v "${CTL_BIN:-42ctl}" 2>/dev/null) || ctl="$HOME/.local/bin/42ctl"
  if [ ! -x "$ctl" ]; then
    note "no 42ctl here: installing it"
    installer=$(mktemp) || return 1
    curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 "$CTL_INSTALLER" -o "$installer" &&
      env FT_BIN_DIR="$HOME/.local/bin" FT_NO_MODIFY_PATH=1 sh "$installer" >/dev/null 2>&1
    rm -f "$installer"
    ctl="$HOME/.local/bin/42ctl"
    [ -x "$ctl" ] || return 1
  fi
  printf '%s\n' "$ctl"
}

# vault_readable — a subshell because vault42-session.sh brings its own note and die. Never
# rebind_contract or recover_keystore: both move an identity, and each takes its own "y".
vault_readable() {
  local ctl
  ctl=$(ensure_ctl) || {
    note "42ctl is not installed and its installer failed"
    return 1
  }
  (
    CTL=$ctl
    LOG_TAG=gate
    TTY_DEV="${VAULT42_TTY:-/dev/tty}"
    export FT_CONFIG="${FT_CONFIG:-$CTL_CFG_DIR/config.json}"
    export FT_KEYSTORE="${FT_KEYSTORE:-$CTL_CFG_DIR/keystore.v42}"
    # shellcheck source=scripts/lib/vault42-session.sh
    . "$REPO/scripts/lib/vault42-session.sh"
    load_credentials
    [ -z "${FT_PASSPHRASE:-}" ] || export FT_PASSPHRASE
    ensure_session
    unlock_probe || exit 1
    "$CTL" env files --org "${VAULT42_ORG:-univers42}" --project "${VAULT42_PROJECT:-groot}" \
      --env "${VAULT42_ENV:-prod}" >/dev/null
  )
}

hand_set_files_present() {
  local file
  for file in $VAULT_FILES; do
    [ -s "$REPO/$file" ] || return 1
  done
}

cmd_gate() {
  local missing
  [ "$(machine_value GROBASE_DATACENTER)" != local ] || return 0
  any_credential || return 0
  missing=$(missing_credentials)
  [ -z "$missing" ] || die "vault42 credentials are incomplete, missing: ${missing% }. Set them in $CTL_CFG_DIR/secrets/42admin.env; GROBASE_DATACENTER=local in that file opts out"
  ensure_keystore
  if vault_readable; then
    note "vault42 is readable"
    return 0
  fi
  hand_set_files_present || die "vault42 cannot be read and these are not set by hand: $VAULT_FILES. Repair the sign-in above, or write those files from .env.example"
  note "vault42 cannot be read: using the hand-set $VAULT_FILES. A missing VM cannot be built from this run"
}
