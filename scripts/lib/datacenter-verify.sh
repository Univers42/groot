# shellcheck shell=bash
# datacenter-verify.sh — make all's proof that what it brought up works, so it cannot print success
# over a stack that merely started. It adds what link-healthcheck and born2root's health do not
# cover: the plan's whole service list, the pages they skip, bind mounts, and a real browser.
# Sourced by scripts/datacenter.sh.
#
# Caveat: a bind mount counts as broken when its source is missing or an empty directory, which is
# what Docker leaves for a missing file. A mount that is meant to start empty over-reports; name it
# in DATACENTER_EMPTY_BINDS.
# Caveat: skips are read from Playwright's summary line, so a reporter that prints another format
# reads as none (under-reports). The pr* mail specs never appear there: run.sh refuses them on a
# remote backend so test users do not land on the VM, and it says so in the log.
# Caveat: the browsers run only with a terminal or DATACENTER_VERIFY_BROWSERS=1, and print SKIP
# otherwise: POST /rebuild runs this make all, and a page must not be able to start them.

DATACENTER_EMPTY_BINDS="${DATACENTER_EMPTY_BINDS:-}"
COMPOSE_PROJECT=track-binocle

# The plan is read from the VM, the one record of what it was installed with.
grobase_health() {
  vm_ssh "$ALIAS" "bash -c '. /etc/b2b/grobase.conf && make --no-print-directory -C $REMOTE_DIR health HEALTH_WAIT=\${1:-0} PACKAGE=\"\$GROBASE_PACKAGE\" ADDONS=\"\$GROBASE_ADDONS\"' _ ${1:-0}"
}

# published_port NAME DEFAULT — host-ports.sh moves a port another process holds, so Mail's bridge
# leaves 4100 when an `osionos connect` to production listens there.
published_port() { get_env "$REPO/.env.ports" "$1" 2>/dev/null || printf '%s\n' "$2"; }

# Reachable is the promise for Mail and Calendar: their Google sign-in is not configured here.
verify_pages() {
  local url code bad=0
  for url in "https://localhost:$(published_port MAIL_HOST_PORT 3002)/" \
    "https://localhost:$(published_port CALENDAR_HOST_PORT 3003)/" \
    "https://localhost:$(published_port MAIL_BRIDGE_HOST_PORT 4100)/health" \
    "https://localhost:$(published_port CALENDAR_BRIDGE_HOST_PORT 4200)/health"; do
    code=$(curl --noproxy '*' --cacert "$CA_CERT" -s -o /dev/null -m 15 -w '%{http_code}' "$url") || code=000
    [ "$code" = 200 ] || {
      note "$url answered $code"
      bad=1
    }
  done
  return "$bad"
}

# bind_sources — one source per line for every bind of a running container of this stack.
bind_sources() {
  docker ps -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" |
    xargs -r docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' |
    sed '/^$/d' | sort -u
}

verify_binds() {
  local source bad=0
  while IFS= read -r source; do
    case " $DATACENTER_EMPTY_BINDS " in *" $source "*) continue ;; esac
    if [ ! -e "$source" ]; then
      note "bind mount source is missing: $source"
      bad=1
    elif [ -d "$source" ] && [ -z "$(ls -A -- "$source" 2>/dev/null)" ]; then
      note "bind mount source is an empty directory, so a file may be missing: $source"
      bad=1
    fi
  done < <(bind_sources)
  return "$bad"
}

# browser_suite ARGS — a run that fails, or that passes by skipping, is not a pass.
browser_suite() {
  local log
  log=$(mktemp) || die "no temp file for the browser run"
  bash "$REPO/tests/e2e/run.sh" "$@" 2>&1 | tee "$log" >&2
  local rc=${PIPESTATUS[0]} skipped
  skipped=$(sed -n 's/^ *\([0-9][0-9]*\) skipped.*/\1/p' "$log" | tail -n 1)
  rm -f "$log"
  [ "$rc" = 0 ] || return 1
  [ -z "$skipped" ] || {
    note "$skipped browser tests were skipped, so this run proves less than it says"
    return 1
  }
}

verify_browsers() {
  if [ ! -t 0 ] && [ "${DATACENTER_VERIFY_BROWSERS:-0}" != 1 ]; then
    note "SKIP browsers: no terminal, so nothing proved the pages in a real browser"
    return 0
  fi
  E2E_REACH_BACKEND=1 browser_suite -c reach.config.ts || die "the front doors fail in a browser (tests/e2e/reach)"
  browser_suite || die "the end-to-end specs fail (tests/e2e/specs)"
}

cmd_verify() {
  ALIAS=$(cmd_setting)
  [ -n "$ALIAS" ] || die "this machine has no data center"
  grobase_health 180 >&2 || die "grobase in the VM is not healthy on its plan. From groot: make dc-health"
  verify_pages || die "a page does not answer 200 over verified TLS"
  verify_binds || die "a container holds a broken bind mount"
  verify_browsers
  note "verified: the plan, the pages, the mounts and the browsers"
}
