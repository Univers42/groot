#!/usr/bin/env bash
# public-verify-appcontainers.sh — the checks of the RUNNING mail-web and calendar-web containers,
# read from `docker inspect` (no exec, no env binary in the image): the variable names they hold.
# Sourced by lib/public-verify.sh after public-verify-apps.sh, which provides apps_absent; the
# project's svc_container comes from scripts/public-funnel.sh. Prints names and property names,
# never a value from the environment.
#
# Caveat: this reads the container's configured env, not what a process later exported.

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
