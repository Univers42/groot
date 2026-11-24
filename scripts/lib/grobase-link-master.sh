# shellcheck shell=bash
# grobase-link-master.sh — the two ssh masters behind the control socket $CTL, both opened by
# pinned_master: the link's (ssh mode, and the IDE plane in direct mode) and the admin one (direct-mode
# bring-up). Sourced by grobase-link.sh, which defines CTL, LINK_DIR, CONF, the settings, note, die,
# mux, state_get, ssh_args and cmd_down_ssh.
# The user's ssh config is read for where the VM is, never for how to trust it: on the production host
# it says StrictHostKeyChecking no and ForwardAgent yes for an alias whose loopback port a stopped qemu
# leaves free (ruling LM-2, 2026-11-23). Only the host key pinned in the link's settings is accepted.

# One "<type> <base64>" pair: anything else could add a line, or a @cert-authority, to known_hosts.
HOST_KEY_RE='^[a-z0-9@.-]+ [A-Za-z0-9+/]+=*$'

# pinned_master NAME KEY DEST... — opens the master at $CTL to DEST (ssh arguments: an alias, or
# user@host -p port), accepting only KEY, filed under NAME in $LINK_DIR/<NAME minus grobase->_known_hosts.
# From `ssh -G DEST` it takes the host, port, user and key files and nothing else: the agent is neither
# used nor forwarded, and the alias's forwards and host-key policy do not apply.
# Caveat: `~` in an IdentityFile is read as $HOME, where ssh reads the passwd home; a key file named
# with ssh's % tokens, or held only in an agent, is not found, and the master then fails to authenticate.
pinned_master() {
  local name=$1 key=$2 cfg host port user file known="$LINK_DIR/${1#grobase-}_known_hosts"
  local -a ids=()
  shift 2
  cfg=$(ssh -G "$@" 2>/dev/null) || return 1
  read -r host port user < <(awk '$1 == "hostname" { h = $2 } $1 == "port" { p = $2 } $1 == "user" { u = $2 } END { print h, p, u }' <<<"$cfg")
  [ -n "$user" ] || return 1
  while IFS= read -r file; do
    file=${file/#\~/$HOME}
    [ ! -f "$file" ] || ids+=(-i "$file")
  done < <(awk '$1 == "identityfile" { sub(/^identityfile /, ""); print }' <<<"$cfg")
  printf '%s %s\n' "$name" "$key" >"$known"
  ssh -F /dev/null -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=yes -o ClearAllForwardings=yes \
    -o StreamLocalBindUnlink=yes -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 -o LogLevel=ERROR -o StrictHostKeyChecking=yes -o HostKeyAlias="$name" \
    -o UserKnownHostsFile="$known" -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    -o IdentityAgent=none -o ForwardAgent=no "${ids[@]}" -p "$port" -l "$user" -N -f "$host"
}

# Reuses a live master only when it goes to the same host under the same pin: the control socket has
# one path, so a new target would otherwise silently keep talking to the previous machine, and a master
# opened before the pin existed would keep trusting whatever key it met.
# shellcheck disable=SC2046 # see ssh_args
open_master() {
  local prev pinned
  [[ $LINK_HOST_KEY =~ $HOST_KEY_RE ]] ||
    die "an ssh link needs GROBASE_LINK_HOST_KEY=\"<type> <base64>\", the VM's host key (in the VM: cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub), set in $CONF"
  prev=$(state_get target 2>/dev/null || true)
  pinned=$(cat "$LINK_DIR/link_known_hosts" 2>/dev/null || true)
  if mux -O check x 2>/dev/null; then
    [ "$(ssh_args "$prev")" != "$(ssh_args "$1")" ] || [ "$pinned" != "grobase-link $LINK_HOST_KEY" ] || return 0
    note "closing the master to $prev"
    cmd_down_ssh
  fi
  pinned_master grobase-link "$LINK_HOST_KEY" $(ssh_args "$1") ||
    die "no ssh master to $1 presenting GROBASE_LINK_HOST_KEY; a rebuilt VM has a new host key: set the new one in $CONF"
}

# The alias says where the VM is and nothing else; a docker ssh:// transport would inherit its forwards
# (RemoteForward 9222 on b2b) and its `StrictHostKeyChecking no`.
open_admin_master() {
  [[ $ADMIN_SSH =~ ^[A-Za-z0-9][A-Za-z0-9._@:-]*$ ]] || die "GROBASE_ADMIN_SSH is not a plain ssh alias or user@host"
  [[ $ADMIN_HOST_KEY =~ $HOST_KEY_RE ]] || die "GROBASE_ADMIN_SSH needs GROBASE_ADMIN_HOST_KEY, the VM's host key"
  pinned_master grobase-admin "$ADMIN_HOST_KEY" "$ADMIN_SSH" ||
    die "no admin ssh to $ADMIN_SSH; a rebuilt VM has a new host key: remove GROBASE_ADMIN_HOST_KEY from ~/.config/42ctl/secrets/datacenter.env"
}
