# shellcheck shell=bash
# datacenter-build.sh — build the VM through born2root, only when it provably does not exist.
# A false positive here puts a new install beside live data, so "absent" is several independent
# negatives, and everything else (a held VM, a booting one, an unreadable path) stops or waits.
# Sourced by scripts/datacenter.sh, after datacenter-gate.sh and datacenter-vm.sh.
#
# Caveat: the first-boot wait reads features.status, written when a feature ends, so one feature
# that runs past FIRST_BOOT_LIMIT reads as stuck. Running make all again resumes the wait, because
# the disk then exists and has .installed.
# Caveat: a machine that restores a backup instead of seeding has to run born2root's make restore
# itself: a backup repository stops the build here, because seeds older than it would overwrite it.

FIRST_BOOT_LIMIT=7200
VM_PORTS="4242 8443"

# Only ENOENT counts. `[ ! -f ]` is also true for EACCES, which is what an expired Kerberos ticket
# gives on the NFS that holds the disks, about 24 h after the last login on a seat.
path_is_absent() { [[ $(LC_ALL=C stat -- "$1" 2>&1 >/dev/null) == *'No such file or directory'* ]]; }

nearest_ancestor_lists() {
  local dir=$1
  while path_is_absent "$dir"; do dir=$(dirname "$dir"); done
  ls -- "$dir" >/dev/null 2>&1
}

ports_are_free() {
  local port
  for port in $VM_PORTS; do
    [ -z "$(ss -ltnH "sport = :$port" 2>/dev/null)" ] || return 1
  done
}

vm_absent() {
  local disk="$VM_PATH/$VM_NAME/$VM_NAME.qcow2"
  [ "$ALIAS" = "$DEFAULT_ALIAS" ] && [ -n "$VM_NAME" ] && [ -n "$VM_PATH" ] || return 1
  path_is_absent "$disk" && nearest_ancestor_lists "$VM_PATH" && ports_are_free && ! qemu_running
}

first_boot_finished() {
  vm_ssh "$ALIAS" 'test "$(grep -c first-boot-setup /etc/crontab)" = 0 && grep -q "^dc-gateway ok" /etc/b2b/features.status' >/dev/null 2>&1
}

# Seeds are older than any backup, and set_seeds --auto exits 0 without loading when one exists,
# which would leave this run waiting for a seed that never comes.
refuse_backup_repository() {
  local dest
  dest=$(cd "$REPO/vendor/born2root" && B2B_CONFIG="${VM_CONFIG:-profiles/server.toml}" bash setup/host/backup_pull.sh --where 2>/dev/null) || dest=""
  [ -z "$dest" ] || [ ! -e "$dest/repo/config" ] ||
    die "a backup repository exists at $dest and is newer than any seed, so a build here would not load it. Build from born2root, then make restore, or move it away"
}

# Caveat: a checkout path with a space cuts the match short, so that block reads as dangling and
# is reinstalled from this clone (over-reports). Harmless: the block is the same but for its path.
autostart_dir() {
  crontab -l 2>/dev/null | sed -n '/b2b-autostart .* begin/,/b2b-autostart .* end/p' |
    sed -En 's/^([^ ]+ +){5}cd ([^ ]+) .*/\2/p' | head -n 1
}

autostart_dangling() {
  local dir
  dir=$(autostart_dir)
  [ -n "$dir" ] && [ ! -d "$dir" ]
}

# Called on every path that finds a built VM with no way to come back at login. A block whose
# checkout was deleted is that too: cron fails on the cd every minute and nobody reads it.
repair_autostart() {
  [ -n "$(autostart_value VM_NAME)" ] && ! autostart_dangling && return 0
  require_writes "installing the VM's auto-start"
  born2root_make autostart || die "make autostart failed. From born2root: make autostart"
  [ -n "$(autostart_value VM_NAME)" ] || die "make autostart finished, but the crontab has no block"
}

# A terminal, never DATACENTER_ALLOW_WRITES: POST /rebuild inherits this environment, and it is
# unauthenticated with CORS *, so a variable could not tell an operator from a web page.
build_vm() {
  [ -t 0 ] || die "this machine has no VM ($VM_NAME under $VM_PATH): run make all at a terminal to build it. Nothing was written"
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/vm-build.lock"
  flock -n 9 || die "another make all is building the VM"
  vault_readable || die "a VM can only be built from secrets vault42 can read"
  refuse_backup_repository
  require_born2root secrets_pull
  require_born2root all
  note "no VM here: born2root builds it (about 30 min, needs ~18 GB free under $VM_PATH)"
  born2root_make secrets_pull APPLY=1 || die "born2root could not pull its secrets from vault42"
  # born2root's all exits 0 when grobase, the seed or autostart failed, so its status is a note
  # and the state below is the verdict.
  # -dc-tunnel here, not in the profile: production builds from it and keeps cloudflared.
  FIRST_BOOT_TIMEOUT=$FIRST_BOOT_LIMIT born2root_make all "FEATURES=$(born2root_value FEATURES) -dc-tunnel" || note "make all in born2root failed; checking what it left"
  [ -f "$VM_PATH/$VM_NAME/$VM_NAME.qcow2" ] ||
    die "born2root stopped before it created a VM disk: its error is above. make all again starts over"
  ssh_answers || die "born2root finished, but ssh $ALIAS does not answer. See $VM_PATH/$VM_NAME/serial.log"
  wait_for "the VM's first boot" "$FIRST_BOOT_LIMIT" first_boot_finished ||
    die "the VM's first boot did not finish. In the VM: tail /etc/b2b/features.status"
  repair_autostart
}
