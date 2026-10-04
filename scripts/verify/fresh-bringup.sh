#!/usr/bin/env bash
# fresh-bringup.sh — the pinned defense bring-up, run end to end with evidence.
#
# Usage:
#   bash scripts/verify/fresh-bringup.sh [--clone DIR] [--with-optional] [--out DIR] [TAG]
#
#   (default)        verify the checkout you are standing in (git toplevel of $PWD)
#   --clone DIR      first clone git@github.com:Univers42/groot.git into DIR
#   --with-optional  also make mail-up calendar-up so DW10 runs, then stop them
#   --out DIR        evidence directory (default ~/fresh-bringup-logs/<tag>-<time>)
#   TAG              release to check out (default: latest tag on origin/main,
#                    `git describe --tags --abbrev=0 origin/main`)
#
# Steps: preflight → checkout TAG → submodule update --init --recursive →
# make all SKIP_SYNC=1 → make healthcheck → make e2e → submodule drift check.
# The evidence directory gets every log plus SUMMARY.txt; the exit status is
# non-zero when any check in SUMMARY.txt is non-zero.
#
# Bash, not the login shell: on a born2root VM that is hellish, so call it as
# `bash scripts/verify/...` (or `bash -c '...'` over ssh).
#
# Ponytail: preflight checks free ports with ss on the host. A port that a QEMU
# hostfwd or another netns holds is not seen, and a port held by any Docker
# container is only warned about, assuming it is this stack. The RAM peak is a
# 10 s sample of `free -m`, so a spike shorter than that is missed (under-reports).
set -u

readonly REPO_URL=git@github.com:Univers42/groot.git
# An 8 GB VM reports ~7.8 GiB MemTotal after the kernel's reservation.
readonly MIN_RAM_MIB=7680
# README.md "Prerequisites": images + build cache measured at ~23 GB; under
# 10 GiB free a cold build is likely to fill the disk.
readonly MIN_DOCKER_FREE_GIB=10
# grobase's Kong publishes this outside docker-compose.yml
# (apps/grobase/orchestrators/compose/base/gateway.yml).
readonly EXTRA_PORTS="8000/tcp"

fail=0
log() { printf '[fresh-bringup] %s\n' "$*"; }
warn() { printf '[fresh-bringup] WARN: %s\n' "$*" >&2; }
die() {
  printf '[fresh-bringup] FAIL: %s\n' "$*" >&2
  exit 1
}

check_docker() {
  docker info >/dev/null 2>&1 || die "docker is not reachable (is the daemon running, are you in the docker group?)"
  log "docker $(docker version --format '{{.Server.Version}}') reachable"
}

check_github_ssh() {
  local out
  out=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com 2>&1)
  case $out in
  *"successfully authenticated"*) log "GitHub SSH authenticates" ;;
  *"Host key verification failed"*)
    die "github.com is not in known_hosts — run 'ssh -T git@github.com' once and check the fingerprint"
    ;;
  *) die "ssh -T git@github.com did not authenticate (submodules use SSH URLs): $out" ;;
  esac
}

compose_ports() {
  docker compose --profile '*' config --format json |
    jq -r '[.services[].ports[]? | select(.published) | "\(.published)/\(.protocol)"] | unique | .[]'
  printf '%s\n' "$EXTRA_PORTS"
}

docker_held_ports() {
  docker ps -q | xargs -r -n1 docker port 2>/dev/null | sed -nE 's#^[0-9]+/[a-z]+ -> .*:([0-9]+)$#\1#p'
}

# Run inside the checked-out TAG: the port list comes from its docker-compose.yml.
check_ports() {
  local ports held spec port proto flag busy=0 ours=0
  ports=$(compose_ports) || die "docker compose config failed — cannot read the port list"
  held=$(docker_held_ports | sort -u)
  for spec in $ports; do
    port=${spec%/*} proto=${spec#*/}
    flag=-Hltn
    [ "$proto" = udp ] && flag=-Hlun
    [ -z "$(ss "$flag" "sport = :$port")" ] && continue
    if grep -qx "$port" <<<"$held"; then
      ours=$((ours + 1))
    else
      printf '[fresh-bringup] port %s/%s is in use by a non-Docker process:\n' "$port" "$proto" >&2
      ss "$flag"p "sport = :$port" >&2
      busy=1
    fi
  done
  [ "$busy" = 0 ] || die "required ports are taken (a QEMU VM forwarding them? another stack?)"
  [ "$ours" = 0 ] || warn "$ours required ports are held by running containers (assumed this stack; make all recreates them)"
  log "required ports: none held by a non-Docker process"
}

check_resources() {
  local ram_mib root free_gib
  ram_mib=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  [ "$ram_mib" -ge "$MIN_RAM_MIB" ] || warn "RAM is ${ram_mib} MiB; make all peaked at ~6.5 GB on an 8 GB VM"
  root=$(docker info --format '{{.DockerRootDir}}')
  free_gib=$(df -BG --output=avail "$root" | tail -1 | tr -dc 0-9)
  [ "$free_gib" -ge "$MIN_DOCKER_FREE_GIB" ] ||
    warn "only ${free_gib} GiB free under $root; if the build fills it: docker builder prune -f"
  log "RAM ${ram_mib} MiB, ${free_gib} GiB free under $root"
}

resolve_tag() {
  git fetch --quiet --tags origin || die "git fetch origin failed"
  if [ -n "$TAG" ]; then return; fi
  TAG=$(git describe --tags --abbrev=0 origin/main) || die "no tag reachable from origin/main"
}

checkout_tag() {
  git checkout --quiet "$TAG" || die "git checkout $TAG failed (uncommitted changes?)"
  git submodule update --init --recursive || die "git submodule update failed"
  log "checked out $TAG ($(git rev-parse --short HEAD))"
}

sample_memory() {
  while sleep 10; do free -m | awk 'NR==2{print $3}'; done >"$OUT/mem-used.log"
}

# Runs one make target, logs it, returns its status.
run_make() {
  local name=$1
  shift
  log "make $* → $OUT/$name.log"
  make "$@" >"$OUT/$name.log" 2>&1
}

run_optional() {
  [ "$WITH_OPTIONAL" = 1 ] || return 0
  run_make mail-up mail-up
  rc_mail=$?
  run_make calendar-up calendar-up
  rc_cal=$?
}

stop_optional() {
  [ "$WITH_OPTIONAL" = 1 ] || return 0
  run_make optional-down mail-down calendar-down || warn "mail-down/calendar-down failed, see $OUT/optional-down.log"
}

write_summary() {
  local line
  line="tag=$TAG make_all=$rc_all secs=$secs healthcheck=$rc_hc e2e=$rc_e2e drift=$drift"
  [ "$WITH_OPTIONAL" = 1 ] && line="$line mail_up=$rc_mail calendar_up=$rc_cal"
  line="$line dlesieur_images=$dl peak_used_MiB=$peak"
  printf '%s\n' "$line" | tee "$OUT/SUMMARY.txt"
  for v in "$rc_all" "$rc_hc" "$rc_e2e" "$drift" "$dl" "$rc_mail" "$rc_cal"; do
    [ "$v" = 0 ] || fail=1
  done
}

parse_args() {
  CLONE_DIR="" WITH_OPTIONAL=0 OUT="" TAG=""
  while [ $# -gt 0 ]; do
    case $1 in
    --clone) CLONE_DIR=${2:?--clone needs a directory} && shift ;;
    --with-optional) WITH_OPTIONAL=1 ;;
    --out) OUT=${2:?--out needs a directory} && shift ;;
    -h | --help)
      sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//;/^set -u/d'
      exit 0
      ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) TAG=$1 ;;
    esac
    shift
  done
}

enter_checkout() {
  if [ -n "$CLONE_DIR" ]; then
    [ -e "$CLONE_DIR" ] && die "$CLONE_DIR already exists; --clone wants a new directory"
    git clone --recursive "$REPO_URL" "$CLONE_DIR" || die "git clone failed"
    cd "$CLONE_DIR" || die "cannot enter $CLONE_DIR"
  else
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout (or use --clone DIR)"
    cd "$top" || die "cannot enter $top"
  fi
}

main() {
  parse_args "$@"
  check_docker
  check_github_ssh
  check_resources
  enter_checkout
  resolve_tag
  OUT=${OUT:-$HOME/fresh-bringup-logs/$TAG-$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$OUT" || die "cannot create $OUT"
  log "evidence → $OUT"
  { hostname && pwd; } >"$OUT/host.txt"
  free -m >"$OUT/free-start.txt"
  df -h / "$(docker info --format '{{.DockerRootDir}}')" >"$OUT/df-start.txt"
  checkout_tag
  check_ports
  git submodule status --recursive >"$OUT/sub-before.txt"

  sample_memory &
  local mem_pid=$! t0 rc_all rc_hc rc_e2e rc_mail=0 rc_cal=0 drift dl peak secs
  t0=$(date +%s)
  run_make make-all all SKIP_SYNC=1
  rc_all=$?
  secs=$(($(date +%s) - t0))
  kill "$mem_pid"
  run_make healthcheck healthcheck
  rc_hc=$?
  run_optional
  run_make e2e e2e
  rc_e2e=$?
  stop_optional
  git submodule status --recursive | diff "$OUT/sub-before.txt" - >"$OUT/drift.diff"
  drift=$?
  dl=$(docker images --format '{{.Repository}}' | grep -c '^dlesieur/')
  peak=$(sort -n "$OUT/mem-used.log" | tail -1)
  write_summary
  exit "$fail"
}

main "$@"
