#!/usr/bin/env bash
# What the frontends bind from this checkout and read as a user other than the container root.
# Sourced by scripts/datacenter.sh, which defines note, die, REPO and cmd_setting.
#
# On an NFS checkout under rootless Docker those users are subuids the NFS server refuses: the
# bridge's node gets EACCES on the roster and nginx's worker answers 403 on /docs/ and
# /openapi.json, while container root reads both (measured on /sgoinfre, 2026-11-05). Those
# sources get a copy on the disk Docker runs from, and GROOT_READ_BINDS points compose at it.
#
# Caveat: only nfs is detected, so another network filesystem keeps the checkout's paths, and
# verify_roster or verify_pages then stops the run. A file deleted from the repo stays in the copy
# until the directory is removed by hand, since the copy is only ever added to.

READ_BIND_DIRS="infrastructure/tls/api-docs apps/grobase/infra/config/openapi"

# cmd_read_binds — the copy's directory, or nothing when the checkout's paths are readable.
cmd_read_binds() {
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
  if [ -d "$out" ]; then
    rmdir -- "$out" || die "$out is a directory holding files. Move it, then make all"
    # It still binds the directory it started with.
    docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
      --filter label=com.docker.compose.service=osionos-bridge | xargs -r docker rm -f >/dev/null
  fi
  write_agency_snapshot "${UUID_OF[owner@agency.local]}" >"$out"
  chmod a+r "$out"
}

cmd_binds() {
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center"
  local copy
  copy=$(cmd_read_binds)
  if [ -n "$copy" ]; then
    copy_read_binds "$copy"
    mkdir -p "$copy/tools/seeds" || die "could not create $copy/tools/seeds"
  fi
  write_roster "${copy:-$REPO}/tools/seeds/.agency-people.env"
}
