#!/usr/bin/env bash
# public-verify-appcontainers.sh — the checks of the RUNNING mail-web and calendar-web containers,
# read from `docker inspect` (no exec, no env binary in the image): the variable names they hold
# and the locked-down shape compose gave them.
# Sourced by lib/public-verify.sh after public-verify-apps.sh, which provides apps_absent; the
# project's svc_container comes from scripts/public-funnel.sh. Prints names and property names,
# never a value from the environment.
#
# Caveat: this reads the container's configured env, not what a process later exported. docker
# lists no tmpfs mount in .Mounts on this host (measured 2026-10-18), so "tmpfs mounts only" means
# no bind and no volume; an empty list passes.

# MC13: variable names that must not exist in a static container.
APPS_FORBIDDEN_ENV='^(SMTP_|GOOGLE_|VAULT_|KONG_)|^(SERVICE_ROLE_KEY|JWT_SECRET)$'

# Variable names of a container, from its config: needs neither exec nor an env binary in the
# image. Fails when docker cannot read it.
container_env_names() {
  local env
  env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null) || return 1
  cut -d= -f1 <<<"$env"
}

# MC13: names only, from the config of each static container. An env that cannot be read, or has
# no name at all, is a FAIL: a real container always has PATH, so empty means the read failed.
check_appenv() {
  local svc c names bad="" unread="" n=0
  for svc in mail-web calendar-web; do
    c=$(svc_container "$svc")
    [ -n "$c" ] || {
      apps_absent appenv "$svc is not running" || true
      return
    }
    if ! names=$(container_env_names "$c") || [ -z "$names" ]; then
      unread+=" $svc"
      continue
    fi
    n=$((n + $(grep -c . <<<"$names" || true)))
    bad+=$(grep -E "$APPS_FORBIDDEN_ENV" <<<"$names" | sed "s/^/ $svc:/" | paste -sd' ' - || true)
  done
  if [ -n "$unread" ]; then
    fail appenv "environment unreadable or empty for:$unread (docker inspect)"
    return
  fi
  expect appenv "mail-web and calendar-web hold $n variables, none of SMTP_ GOOGLE_ VAULT_ KONG_ SERVICE_ROLE_KEY JWT_SECRET" "forbidden variable(s) present (values withheld):$bad" [ -z "$bad" ]
}

# MC10: mem_limit 64m, the largest a static container may be given.
APPS_STATIC_MEMORY_MAX=67108864
APPS_SHAPE_FORMAT='ro={{.HostConfig.ReadonlyRootfs}} mem={{.HostConfig.Memory}} nets={{range $name, $_ := .NetworkSettings.Networks}}{{$name}},{{end}} mounts={{range .Mounts}}{{.Type}},{{end}}'

# Properties of container $1 that are not the static shape, space-joined; empty when it is.
appshape_problems() {
  local shape ro mem nets mounts net="${PROJECT}_apps-static-net" bad=""
  shape=$(docker inspect -f "$APPS_SHAPE_FORMAT" "$1" 2>/dev/null) || {
    printf 'unreadable'
    return
  }
  read -r ro mem nets mounts <<<"$shape"
  [ "$ro" = ro=true ] || bad+=" rootfs-writable"
  mem=${mem#mem=}
  { [[ "$mem" =~ ^[0-9]+$ ]] && [ "$mem" -ge 1 ] && [ "$mem" -le "$APPS_STATIC_MEMORY_MAX" ]; } || bad+=" memory-not-in-1..$APPS_STATIC_MEMORY_MAX"
  [ "$nets" = "nets=$net," ] || bad+=" network-not-only-$net"
  [[ "$mounts" =~ ^mounts=(tmpfs,)*$ ]] || bad+=" mounts-not-tmpfs-only"
  printf '%s' "${bad# }"
}

# MC10: the running static containers are read-only, memory-capped, on the one internal network,
# and mount nothing from the host or a volume.
check_appshape() {
  local svc c problems bad=""
  for svc in mail-web calendar-web; do
    c=$(svc_container "$svc")
    [ -n "$c" ] || {
      apps_absent appshape "$svc is not running" || true
      return
    }
    problems=$(appshape_problems "$c")
    [ -z "$problems" ] || bad+=" $svc:$problems;"
  done
  expect appshape "mail-web and calendar-web: read-only rootfs, memory <= 64 MiB, only ${PROJECT}_apps-static-net, tmpfs mounts only" "not the locked-down shape:$bad" [ -z "$bad" ]
}
