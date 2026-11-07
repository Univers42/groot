# shellcheck shell=bash
# e2e-urls.sh — point the browser suites at the ports this clone publishes. tests/e2e/lib/env.ts
# defaults to the compose defaults, so on a machine where host-ports.sh moved a port every spec went
# to the old one. An E2E_*_URL set by hand wins. Needs envfile.sh's get_env.
#
# Caveat: the map is by hand. A URL added to env.ts and not here stays on its default on a moved
# port, and fails there rather than passing elsewhere (:3007 stays out: it is literal loopback).
E2E_URL_PORTS="E2E_OSIONOS_URL OSIONOS_APP_HOST_PORT
E2E_MAIL_URL MAIL_HOST_PORT
E2E_CALENDAR_URL CALENDAR_HOST_PORT
E2E_PRISMATICA_URL OPPOSITE_OSIRIS_HOST_PORT
E2E_GATEWAY_URL AUTH_GATEWAY_HOST_PORT
E2E_BRIDGE_URL OSIONOS_BRIDGE_HOST_PORT
E2E_KONG_URL GROBASE_TLS_HOST_PORT"

# e2e_export_urls PORTS_FILE — no file, or no such name in it, leaves the default.
e2e_export_urls() {
  local url name port
  while read -r url name; do
    [ -z "${!url:-}" ] || continue
    port=$(get_env "$1" "$name" 2>/dev/null) || continue
    [ -z "$port" ] || export "$url=https://localhost:$port"
  done <<<"$E2E_URL_PORTS"
}
