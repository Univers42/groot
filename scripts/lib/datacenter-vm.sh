# shellcheck shell=bash
# datacenter-vm.sh — what groot reads from the data center VM and what it may do about it. grobase
# runs only inside the VM; groot asks born2root to install or start it, because a bare `make up` in
# /opt/grobase starts the wrong edition and its _rm-stale can remove containers. Autostart keeps the
# VM up and groot waits for it; groot builds it only when it provably does not exist
# (datacenter-build.sh).
# Sourced by scripts/datacenter.sh, which defines note, die, REPO, CONF, STATE_DIR and vm_ssh.
#
# Caveat: the waits are upper bounds taken from born2root's own (autostart.sh:189, 180 s for QEMU;
# install_grobase.sh:711, 300 s for the WAF). A boot slower than that stops make all, and running it
# again resumes the wait. DATACENTER_WAIT_SCALE=0 skips them, for the tests.
# Caveat: the auto-start block is read from the crontab, so a machine with linger, which uses systemd
# units instead, reports "no auto-start" while its VM is down (over-reports; only the message is wrong).

ALIAS=""
VM_PATH=""
VM_NAME=""
VM_CONFIG=""
VM_SECRETS=""
REMOTE_DIR=/opt/grobase
# Every service that is not retired, on this machine's VM only. It lives here and not in grobase's
# PACKAGE_max or born2root's server profile because production deploys those: playground and vault42
# must not reach it, and a change here cannot.
LOCAL_GROBASE_ADDONS="observability engines ops studio control playground secrets mysql8 vault42"

# autostart_value NAME — NAME's value in the b2b-autostart block of the crontab.
autostart_value() {
  crontab -l 2>/dev/null | sed -n '/b2b-autostart .* begin/,/b2b-autostart .* end/p' |
    grep -oE "(^|[[:space:]])$1=[^[:space:]]+" | head -n 1 | sed 's/^[[:space:]]*[A-Z0-9_]*=//'
}

load_vm_paths() {
  VM_PATH=$(autostart_value VM_PATH)
  VM_NAME=$(autostart_value VM_NAME)
  VM_CONFIG=$(autostart_value B2B_CONFIG)
  VM_SECRETS=$(autostart_value B2B_SECRETS)
  [ -n "$VM_NAME" ] || VM_NAME=$(born2root_value VM_NAME)
  [ -n "$VM_PATH" ] || VM_PATH=$(born2root_value VM_PATH)
}

# vm_stop_reason — why waiting cannot help, or nothing. These do not resolve themselves: the tick
# skips a held VM and cannot open KVM without the seat's session.
vm_stop_reason() {
  local dir hold boot
  [ -n "$VM_NAME" ] || {
    printf 'born2root does not say where the VM (%s) lives: vendor/born2root is missing or broken' "$ALIAS"
    return
  }
  dir="$VM_PATH/$VM_NAME"
  hold=$(cat "$dir/.autostart-hold" 2>/dev/null) || hold=""
  boot=$(cat "${B2B_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null) || boot=""
  if [ -n "$hold" ] && [ "$hold" = "$boot" ]; then
    printf 'Stopped on purpose; autostart stays off until the host reboots. From born2root: make qemu_start B2B_CONFIG=%s' "${VM_CONFIG:-profiles/server.toml}"
    return
  fi
  [ -f "$dir/$VM_NAME.qcow2" ] || {
    printf 'no VM disk can be read at %s/%s.qcow2, and it is not provably absent: nothing is built over it. Read the path, or for an alias other than %s, build there' "$dir" "$VM_NAME" "$DEFAULT_ALIAS"
    return
  }
  [ -f "$dir/.installed" ] || {
    printf 'the VM disk at %s has no .installed mark: an install was interrupted. Read it, then from born2root: make all B2B_CONFIG=%s' "$dir" "${VM_CONFIG:-profiles/server.toml}"
    return
  }
  [ -w "${B2B_KVM_DEVICE:-/dev/kvm}" ] || printf '/dev/kvm is not writable: it is granted to the session holding this seat, so the VM starts within a minute of a login here'
}

qemu_running() { pgrep -f "qemu-system.*-name $VM_NAME" >/dev/null 2>&1; }
ssh_answers() { vm_ssh "$ALIAS" true >/dev/null 2>&1; }
waf_running() {
  local names
  names=$(vm_ssh "$ALIAS" 'docker ps --format "{{.Names}}"' 2>/dev/null) || return 1
  grep -qx mini-baas-waf <<<"$names"
}
grobase_installed() { vm_ssh "$ALIAS" "test -d $REMOTE_DIR/.git" >/dev/null 2>&1; }

# wait_for WHAT SECONDS CHECK — poll CHECK until it passes or SECONDS run out.
wait_for() {
  local what=$1 limit=$(($2 * ${DATACENTER_WAIT_SCALE:-1})) waited=0
  shift 2
  "$@" && return 0
  note "waiting for $what (up to ${limit}s)"
  while [ "$waited" -lt "$limit" ]; do
    sleep 5
    waited=$((waited + 5))
    "$@" && return 0
  done
  return 1
}

await_vm() {
  local reason
  ssh_answers && return 0
  if vm_absent; then
    build_vm
    return
  fi
  reason=$(vm_stop_reason)
  [ -z "$reason" ] || die "$reason"
  repair_autostart
  wait_for "the VM to start" 180 qemu_running ||
    die "the VM ($ALIAS) did not start within 180 s. See $VM_PATH/$VM_NAME/autostart.log"
  wait_for "the VM's ssh" 300 ssh_answers ||
    die "the VM ($ALIAS) runs but ssh does not answer after 300 s. See $VM_PATH/$VM_NAME/serial.log"
}

# Writes to the VM need someone at a terminal: POST /rebuild, the Update button, is unauthenticated
# with CORS * (dev-rebuild-server.py), and it runs this make all with no terminal on stdin.
writes_allowed() { [ -t 0 ] || [ "${DATACENTER_ALLOW_WRITES:-0}" = 1 ]; }
require_writes() { writes_allowed || die "$1 needs a write to the VM, and only make all from a terminal may do that. Nothing was written."; }

# born2root_value NAME — NAME as born2root's Makefile resolves it for this profile.
born2root_value() {
  env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES -u MAKELEVEL make --no-print-directory -C "$REPO/vendor/born2root" \
    --eval 'print-%: ; @echo $($*)' "print-$1" "B2B_CONFIG=${VM_CONFIG:-profiles/server.toml}" 2>/dev/null | tail -n 1
}

born2root_make() {
  env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES -u MAKELEVEL make --no-print-directory -C "$REPO/vendor/born2root" \
    "$@" "B2B_CONFIG=${VM_CONFIG:-profiles/server.toml}" ${VM_PATH:+"VM_PATH=$VM_PATH"} ${VM_NAME:+"VM_NAME=$VM_NAME"} \
    ${VM_SECRETS:+"B2B_SECRETS=$VM_SECRETS"}
}

# require_born2root TARGET — the pinned commit has TARGET, else stop naming the commit: the targets
# groot drives land in born2root first, and groot's pin follows.
require_born2root() {
  born2root_make -n "$1" >/dev/null 2>&1 ||
    die "vendor/born2root at $(git -C "$REPO/vendor/born2root" rev-parse --short HEAD 2>/dev/null) has no make $1; groot's pin has to move to the commit that adds it"
}

# pinned_grobase_ref — the commit born2root's profile runs; nothing when it follows a branch.
pinned_grobase_ref() {
  sed -n 's/^grobase_ref *= *"\([0-9a-f]\{40\}\)".*/\1/p' "$REPO/vendor/born2root/${VM_CONFIG:-profiles/server.toml}" 2>/dev/null
}

grobase_at_pin() {
  local pinned head
  pinned=$(pinned_grobase_ref)
  [ -n "$pinned" ] || return 0
  head=$(vm_ssh "$ALIAS" "git -C $REMOTE_DIR rev-parse HEAD" 2>/dev/null)
  [ "$head" = "$pinned" ]
}

grobase_on_plan() {
  local addons
  addons=$(vm_ssh "$ALIAS" 'cat /etc/b2b/grobase.conf' 2>/dev/null | sed -n 's/^GROBASE_ADDONS=//p' | tr -d "\"'")
  [ "$addons" = "$LOCAL_GROBASE_ADDONS" ]
}

# Only this user's own VM on the default alias. Another alias can name a grobase serving production,
# which groot may read and must never reinstall, whatever state it is in.
is_own_vm() {
  local endpoint
  [ "$ALIAS" = "$DEFAULT_ALIAS" ] || return 1
  endpoint=$(ssh -G "$ALIAS" | awk '$1 == "hostname" { h = $2 } $1 == "port" { p = $2 } END { print h, p }')
  case "$endpoint" in
  127.* | "localhost "*) own_vm_listens "${endpoint##* }" ;;
  *) return 1 ;;
  esac
}

# grobase_problem — what is wrong with the grobase in the VM, or nothing.
grobase_problem() {
  grobase_installed || {
    printf 'not installed'
    return
  }
  wait_for "grobase to come up" 300 waf_running || {
    printf 'not running'
    return
  }
  is_own_vm || return 0
  grobase_at_pin || {
    printf 'not at the pinned commit'
    return
  }
  grobase_on_plan || {
    printf 'not on the local plan'
    return
  }
  grobase_health >/dev/null 2>&1 || printf 'not healthy on its plan'
}

install_grobase_plan() { born2root_make grobase "GROBASE_ADDONS=$LOCAL_GROBASE_ADDONS"; }

# Re-read after `make grobase`: the state is the verdict, not its exit status.
ensure_grobase() {
  local problem
  problem=$(grobase_problem)
  [ -n "$problem" ] || return 0
  require_writes "repairing grobase in the VM"
  require_born2root grobase
  note "grobase is $problem in the VM: born2root installs and starts it"
  install_grobase_plan || note "make grobase failed; checking what it left"
  problem=$(grobase_problem)
  [ -z "$problem" ] || die "grobase is still $problem in the VM after make grobase. From born2root: make grobase_status"
}

tenant_rows() {
  vm_ssh "$ALIAS" "docker exec mini-baas-postgres psql -U postgres -tA -c 'select count(*) from public.tenants'" 2>/dev/null
}

# seeded: a platform with rows and a record is left alone. Rows with no record stop, because nothing
# says where they came from.
ensure_seeded() {
  local rows last
  rows=$(tenant_rows)
  case "$rows" in '' | *[!0-9]*) rows=0 ;; esac
  last=$(vm_ssh "$ALIAS" 'cat /etc/b2b/seeds.last 2>/dev/null' 2>/dev/null)
  if [ "$rows" -gt 0 ]; then
    [ -n "$last" ] || die "the VM holds $rows tenants and no record of a seed. If they are expendable, from born2root: make set_seeds FORCE=1"
    return 0
  fi
  require_writes "seeding the VM"
  require_born2root set_seeds
  note "the VM's platform is empty: loading the vault's seeds"
  born2root_make set_seeds || die "the seed failed. From born2root: make set_seeds"
  last=$(vm_ssh "$ALIAS" 'cat /etc/b2b/seeds.last 2>/dev/null' 2>/dev/null)
  [ -n "$last" ] || die "make set_seeds finished, but the VM has no record of it"
}

cmd_vm() {
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center (no vault42 credentials, no GROBASE_DATACENTER)"
  load_vm_paths
  await_vm
  ensure_grobase
  ensure_seeded
  note "grobase is running in the VM ($ALIAS)"
}

# dc-<target>. An allowlist, not a passthrough: bare `up` is the _rm-stale trap, and grobase's own
# targets include fclean, fly-destroy and newsletter-broadcast. CONFIRM is never forwarded.
cmd_dc() {
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center"
  load_vm_paths
  case "${1:-}" in
  ps | logs | health) admin_ssh "make -C $REMOTE_DIR ${1}" ;;
  up)
    require_born2root grobase
    install_grobase_plan
    ;;
  *) die "dc-${1:-} is refused: groot runs ps, logs, health and up in the VM. Anything else, from inside it: ssh $ALIAS" ;;
  esac
}
