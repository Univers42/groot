#!/usr/bin/env bash
# What the frontends bind from this checkout and read as a user other than the container root.
# Sourced by scripts/datacenter.sh, which defines note, die, REPO and cmd_setting.
#
# On an NFS checkout under rootless Docker those users are subuids the NFS server refuses: the
# bridge's node gets EACCES on the roster and nginx's worker answers 403 on /docs/ and
# /openapi.json, while container root reads both (measured on /sgoinfre, 2026-11-05). Those
# sources get a copy on the disk Docker runs from, and GROOT_READ_BINDS points compose at it. Both
# pipelines fill it: `binds` with the VM's roster, `local-binds` with the checkout's.
#
# Caveat: only nfs is detected, so another network filesystem keeps the checkout's paths: on a data
# center verify_roster or verify_pages then stops the run, and the local pipeline serves the 403
# with nothing to stop it. A file deleted from the repo stays in the copy until the directory is
# removed by hand, since the copy is only ever added to. A Docker daemon that does not answer reads
# as rootful, so a make run started before it keeps the checkout's paths.
# Caveat: the copy is as fresh as the last `make all` or `make frontends-up`. A target that starts
# the bridge or the edge before either has run (public-up, mail-up) binds directories Docker makes
# in the copy, which serve nothing until the next frontends-up repairs them.

READ_BIND_DIRS="infrastructure/tls/api-docs apps/grobase/infra/config/openapi"
ROSTER_FILE=tools/seeds/.agency-people.env

# cmd_read_binds — the copy's directory, or nothing when the checkout's paths are readable.
cmd_read_binds() {
  if [ -n "${GROOT_READ_BINDS:-}" ]; then
    # . is what compose defaults to, so naming the checkout means no copy: cp refuses it onto itself.
    [ "$(realpath -m -- "$GROOT_READ_BINDS")" = "$(realpath -m -- "$REPO")" ] || printf '%s\n' "$GROOT_READ_BINDS"
    return 0
  fi
  case $(stat -f -c %T "$REPO" 2>/dev/null) in nfs*) ;; *) return 0 ;; esac
  case $(docker info --format '{{.SecurityOptions}}' 2>/dev/null) in *rootless*) ;; *) return 0 ;; esac
  local root
  root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
  [ -z "$root" ] || printf '%s/groot-read-binds\n' "${root%/*}"
}

# Copied over, never swapped: a running container binds these inodes.
copy_read_binds() {
  local copy=$1 dir
  for dir in $READ_BIND_DIRS; do
    mkdir -p "$copy/$dir" || die "could not create $copy/$dir"
    cp -R "$REPO/$dir/." "$copy/$dir/" || die "could not copy $dir to $copy"
    chmod -R a+rX "$copy/$dir"
  done
  mkdir -p "$copy/${ROSTER_FILE%/*}" || die "could not create $copy/${ROSTER_FILE%/*}"
}

# Docker makes a directory where a bind's source is missing, and the bridge keeps binding that
# directory after the file appears, so it goes too.
remove_docker_made_roster_dir() {
  [ -d "$1" ] || return 0
  rmdir -- "$1" || die "$1 is a directory holding files. Move it, then make all"
  docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
    --filter label=com.docker.compose.service=osionos-bridge | xargs -r docker rm -f >/dev/null
}

# agency_uuids — email|id for each agency account in the VM, read-only.
agency_uuids() {
  vm_ssh "$ALIAS" "docker exec mini-baas-postgres psql -U postgres -tA -c \"select email || '|' || id from auth.users where email like '%@agency.local'\"" 2>/dev/null
}

# Without this file Docker binds an empty directory, and the bridge answers every people list with
# nothing while its health stays green. Written in place: a running bridge binds the inode.
write_roster() {
  # shellcheck source=tools/seeds/agency-roster.sh
  . "$REPO/tools/seeds/agency-roster.sh"
  local out=$1 rows email uuid entry
  local -A UUID_OF=()
  rows=$(agency_uuids) || die "could not read the agency accounts in the VM"
  while IFS='|' read -r email uuid; do [ -z "$email" ] || UUID_OF[$email]=$uuid; done <<<"$rows"
  for entry in "${ROSTER[@]}"; do
    [ -n "${UUID_OF[${entry%%|*}]:-}" ] ||
      die "the VM has no account for ${entry%%|*}, so the people lists would be empty. From born2root: make set_seeds"
  done
  remove_docker_made_roster_dir "$out"
  write_agency_snapshot "${UUID_OF[owner@agency.local]}" >"$out"
  chmod a+r "$out"
}

cmd_binds() {
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center"
  local copy
  copy=$(cmd_read_binds)
  [ -z "$copy" ] || copy_read_binds "$copy"
  write_roster "${copy:-$REPO}/$ROSTER_FILE"
}

# The local pipeline's roster comes from seed_agency_people.sh, into the checkout. Without one the
# copy still needs a file: a missing source would become a directory Docker makes. Written in
# place: a running bridge binds the inode.
cmd_local_binds() {
  local copy checkout_roster=$REPO/$ROSTER_FILE out
  copy=$(cmd_read_binds)
  [ -n "$copy" ] || return 0
  out=$copy/$ROSTER_FILE
  copy_read_binds "$copy"
  remove_docker_made_roster_dir "$out"
  if [ -f "$checkout_roster" ]; then
    cat -- "$checkout_roster" >"$out" || die "could not copy the roster to $out"
  else
    : >"$out" || die "could not write $out"
  fi
  chmod a+r "$out"
}
