#!/usr/bin/env bash
# host-ports.sh — choose a free host port for every ${NAME_HOST_PORT:-N} the compose files
# publish, and record the choice in .env.ports at the repo root.
#
# WHY this exists (measured 2026-10-21): nothing chose those ports. After a reboot a QEMU VM
# forward took 127.0.0.1:8444 first and local-https-proxy exited 255 ("address already in use");
# a standalone dev server held 4322 and the same proxy could not start. The numbers were also
# copied as literals into make variables and scripts, so even a manual override
# (OPPOSITE_OSIRIS_HOST_PORT=4324) left the health checks and the printed URLs pointing at the
# old port. This script moves the port; every consumer follows it.
#
#   list     print every NAME=default scraped from the compose files (sorted, unique).
#   resolve  choose a port per NAME and write .env.ports (git-ignored) — the record every
#            consumer reads — and infrastructure/tls/host-ports.d/osionos-origin.conf
#            (git-ignored), the osionos origin the tracked nginx.conf includes.
#
# Precedence, per NAME: an explicit environment value wins and is never moved (warned about when
# it is busy); then the default when it is free; then the value already in .env.ports (a moved
# port stays put while its default is taken, so bookmarks and bundles keep working); then the
# first free port in default+1 .. default+50.
#
# Caveat: the probe is a snapshot — a port bound between the probe and `docker compose up` still
# collides — and it only sees this network namespace: a listener inside a rootless container's
# own netns is invisible to `ss`, so it is not seen as busy either.
set -euo pipefail

root="${HOST_PORTS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
listeners_cmd="${HOST_PORTS_LISTENERS:-ss -Hltnp}"
docker_cmd="${HOST_PORTS_DOCKER:-docker}"
ports_file="${HOST_PORTS_FILE:-$root/.env.ports}"
bind_addr="${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}"
project="${COMPOSE_PROJECT_NAME:-track-binocle}"
window=50

declare -A defaults=()      # NAME -> the default port scraped from the compose files
declare -A default_files=() # NAME -> the file that default came from
declare -A previous=()      # NAME -> the value already recorded in .env.ports
declare -A chosen=()        # NAME -> the port this run picked
declare -A pinned=()        # NAME -> 1, when the caller pinned the port in the environment
declare -A reserved=()      # port -> 1, taken by a NAME of this run

# ── the compose files ──────────────────────────────────────────────────────────
# Every docker-compose*.yml at the repo root; the names are SCRAPED from them, never
# written here, so a new compose file (or a new port) needs no change in this script.
compose_files() {
  local f
  for f in "$root"/docker-compose*.yml; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f#"$root"/}"
  done
}

# scrape — fill `defaults` from the compose files. The same NAME with two different
# defaults is a contradiction the caller has to fix: exit 2, naming both files.
scrape() {
  local file line name def
  for file in $(compose_files); do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      name="${line%%=*}"
      def="${line#*=}"
      if [ -n "${defaults[$name]:-}" ] && [ "${defaults[$name]}" != "$def" ]; then
        printf 'host-ports: %s has two defaults — %s in %s, %s in %s. Fix the compose files.\n' \
          "$name" "${defaults[$name]}" "${default_files[$name]}" "$def" "$file" >&2
        exit 2
      fi
      defaults[$name]="$def"
      default_files[$name]="$file"
    done < <(grep -hoE '\$\{[A-Za-z0-9_]+_HOST_PORT:-[0-9]+\}' "$root/$file" 2>/dev/null |
      sed -e 's/^\${//' -e 's/:-/=/' -e 's/}$//' || true)
  done
}

# sorted_names — the scraped names, sorted.
sorted_names() {
  printf '%s\n' "${!defaults[@]}" | LC_ALL=C sort
}

# ── the host's listeners ───────────────────────────────────────────────────────
# listener_table — "address<TAB>port<TAB>process" per listening socket, from the
# ss -Hltnp-shaped command (HOST_PORTS_LISTENERS).
listener_table() {
  bash -c "$listeners_cmd" 2>/dev/null | awk '
    NF >= 4 {
      addr = $4
      if (addr !~ /:[0-9]+$/) next
      port = addr; sub(/^.*:/, "", port)
      addr = addr; sub(/:[0-9]+$/, "", addr)
      gsub(/^\[/, "", addr); gsub(/\]$/, "", addr)
      proc = ""
      if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
      print addr "\t" port "\t" proc
    }' || true
}

# own_ports — the host ports published by THIS compose project (a running groot keeps
# its own ports instead of walking away from itself). Returns non-zero if docker fails.
own_ports() {
  bash -c "$docker_cmd ps --filter label=com.docker.compose.project=$project --format '{{.Ports}}'" \
    2>/dev/null | tr ',' '\n' | sed -n 's/.*:\([0-9][0-9]*\)->.*/\1/p' | LC_ALL=C sort -u
}

# is_wildcard — 0 for an address that binds every interface (0.0.0.0, *, ::).
is_wildcard() {
  case "$1" in
  0.0.0.0 | '*' | :: | '::0') return 0 ;;
  *) return 1 ;;
  esac
}

# addr_conflicts — 0 when a listener on ADDRESS blocks a bind on $bind_addr.
addr_conflicts() {
  is_wildcard "$1" && return 0
  is_wildcard "$bind_addr" && return 0
  [ "$1" = "$bind_addr" ]
}

# holder_of PORT — the name of the process holding PORT at the bind address, or
# nothing when the port is free. "another process" when the name is not visible.
holder_of() {
  local port="$1" addr listen_port proc
  while IFS=$'\t' read -r addr listen_port proc; do
    [ "$listen_port" = "$port" ] || continue
    addr_conflicts "$addr" || continue
    [ -n "$proc" ] || proc="another process"
    printf '%s\n' "$proc"
    return 0
  done < <(printf '%s\n' "$LISTENER_TABLE")
  return 1
}

# is_own_port PORT — 0 when this compose project publishes PORT.
is_own_port() {
  local port="$1" p
  while read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "$port" ] && return 0
  done < <(printf '%s\n' "$OWN_PORTS")
  return 1
}

# port_free PORT — 0 when PORT can be bound: nobody listens on it at the bind
# address, or the listener is one of this project's own containers.
port_free() {
  local port="$1"
  is_own_port "$port" && return 0
  ! holder_of "$port" >/dev/null
}

# ── the commands ───────────────────────────────────────────────────────────────
cmd_list() {
  scrape
  local name
  while read -r name; do
    [ -n "$name" ] || continue
    printf '%s=%s\n' "$name" "${defaults[$name]}"
  done < <(sorted_names)
}

# read_previous — the values already recorded in .env.ports.
read_previous() {
  local key value
  [ -f "$ports_file" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
    '' | '#'*) continue ;;
    esac
    previous[$key]="$value"
  done <"$ports_file"
}

# build_arg_users NAME... — the services whose build args use one of those NAMEs
# (scraped from docker-compose.yml: the VITE_* args are baked at build time).
build_arg_users() {
  local wanted=" $* " service name
  awk '
    /^[ \t]*#/ { next }
    /^  [A-Za-z0-9_.-]+:[ \t]*$/ {
      service = $1; sub(/:$/, "", service); in_args = 0; next
    }
    /^[ \t]*args:[ \t]*$/ { in_args = 1; args_indent = match($0, /[^ \t]/); next }
    in_args {
      if (match($0, /[^ \t]/) <= args_indent) { in_args = 0; next }
      rest = $0
      while (match(rest, /\$\{[A-Za-z0-9_]+_HOST_PORT/)) {
        print service " " substr(rest, RSTART + 2, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }' "$root/docker-compose.yml" 2>/dev/null | while read -r service name; do
    case "$wanted" in
    *" $name "*) printf '%s\n' "$service" ;;
    esac
  done | LC_ALL=C sort -u
}

# render_ports_file — write .env.ports atomically, and NOT at all when the content
# would not change: make re-executes itself when an included file is remade, and a
# touched mtime would restart the whole run for nothing.
render_ports_file() {
  local content tmp name
  content="# Generated by scripts/host-ports.sh resolve — do not edit by hand.
# The host ports this clone publishes; re-run the resolver after any change.
"
  while read -r name; do
    [ -n "$name" ] || continue
    content+="$name=${chosen[$name]}"$'\n'
  done < <(sorted_names)
  tmp="$(mktemp "$ports_file.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  if [ -f "$ports_file" ] && cmp -s "$tmp" "$ports_file"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$ports_file"
}

# render_origin_override — write infrastructure/tls/host-ports.d/osionos-origin.conf
# with the chosen OSIONOS_APP_HOST_PORT, atomically, and only when the content
# changes (same rule as .env.ports). When the chosen port is 3001 it still writes
# it (one code path). It never writes any tracked file.
render_origin_override() {
  local port="${chosen[OSIONOS_APP_HOST_PORT]:-}"
  [ -n "$port" ] || return 0
  local out="$root/infrastructure/tls/host-ports.d/osionos-origin.conf"
  local tmp content
  content="# Generated by scripts/host-ports.sh resolve — do not edit by hand.
set \$osionos_origin https://localhost:$port;
"
  tmp="$(mktemp "$out.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$out"
}

cmd_resolve() {
  scrape
  read_previous

  # Probe the listener table and this project's own ports ONCE.
  LISTENER_TABLE="$(listener_table)"
  # Capture docker output and status separately to avoid set -e exiting on failure.
  local own_ports_out own_ports_status
  set +e
  own_ports_out="$(own_ports 2>/dev/null)"
  own_ports_status=$?
  set -e
  OWN_PORTS="$own_ports_out"
  if [ $own_ports_status -ne 0 ]; then
    printf 'host-ports: cannot list this project'\''s containers (%s ps failed); a running groot'\''s own ports look busy\n' "$docker_cmd" >&2
  fi

  local names=() name default env_value file_value port holder holder_port
  while read -r name; do
    [ -n "$name" ] || continue
    names+=("$name")
  done < <(sorted_names)

  # 1. an explicit environment value (never moved) and the defaults.
  for name in "${names[@]}"; do
    default="${defaults[$name]}"
    env_value="${!name-}"
    file_value="${previous[$name]:-}"
    if [ -n "$env_value" ] && [ "$env_value" != "$file_value" ]; then
      chosen[$name]="$env_value"
      pinned[$name]=1
      reserved[$env_value]=1
      continue
    fi
    if [ -z "${reserved[$default]:-}" ] && port_free "$default"; then
      chosen[$name]="$default"
      reserved[$default]=1
    fi
  done

  # 2. the value already recorded, while it is free (a moved port stays put).
  for name in "${names[@]}"; do
    [ -n "${chosen[$name]:-}" ] && continue
    file_value="${previous[$name]:-}"
    [ -n "$file_value" ] || continue
    if [ -z "${reserved[$file_value]:-}" ] && port_free "$file_value"; then
      chosen[$name]="$file_value"
      reserved[$file_value]=1
    fi
  done

  # 3. the window above the default.
  for name in "${names[@]}"; do
    [ -n "${chosen[$name]:-}" ] && continue
    default="${defaults[$name]}"
    port=$((default + 1))
    while [ "$port" -le $((default + window)) ]; do
      if [ -z "${reserved[$port]:-}" ] && port_free "$port"; then
        chosen[$name]="$port"
        reserved[$port]=1
        break
      fi
      port=$((port + 1))
    done
    if [ -z "${chosen[$name]:-}" ]; then
      holder="$(holder_of "$default" || true)"
      printf 'host-ports: %s default %s is held by %s, and no free port in %s..%s. Free one, or pin %s=<port>.\n' \
        "$name" "$default" "${holder:-another process}" "$((default + 1))" "$((default + window))" "$name" >&2
      exit 1
    fi
  done

  # The stderr lines: one per NAME that does not end on its default.
  for name in "${names[@]}"; do
    default="${defaults[$name]}"
    port="${chosen[$name]}"
    holder="$(holder_of "$default" || true)"
    holder_port="$(holder_of "$port" || true)"
    if [ "$port" = "$default" ] && [ -z "${pinned[$name]:-}" ]; then
      continue
    fi
    if [ -n "$holder" ]; then
      printf 'host-ports: %s default %s is held by %s; using %s' "$name" "$default" "$holder" "$port"
      if [ -n "$holder_port" ]; then
        printf ' (also held by %s)' "$holder_port"
      fi
    elif [ -n "$holder_port" ]; then
      printf 'host-ports: %s default %s is free; pinned to %s (held by %s)' "$name" "$default" "$port" "$holder_port"
    else
      printf 'host-ports: %s default %s is free; pinned to %s' "$name" "$default" "$port"
    fi
    if [ "$name" = "OSIONOS_APP_HOST_PORT" ]; then
      printf '; add https://localhost:%s to grobase'\''s allowed origins (born2root: make grobase_cors)' "$port"
    fi
    printf '\n' >&2
  done

  local before="" name
  [ -f "$ports_file" ] && before="$(cat "$ports_file")"
  render_ports_file
  render_origin_override

  # A moved port that a build arg bakes in needs the image rebuilt.
  local changed=() service
  while read -r name; do
    [ -n "$name" ] || continue
    file_value="${previous[$name]:-}"
    [ "$file_value" = "${chosen[$name]}" ] && continue
    changed+=("$name")
  done < <(sorted_names)
  if [ "${#changed[@]}" -gt 0 ] && [ "$before" != "$(cat "$ports_file")" ]; then
    # For each changed NAME, find the services that bake it; print one line per service
    # listing the specific NAMEs that service uses.
    declare -A service_changed_names=()
    for name in "${changed[@]}"; do
      while read -r service; do
        [ -n "$service" ] || continue
        service_changed_names["$service"]+=" $name"
      done < <(build_arg_users "$name")
    done
    for service in "${!service_changed_names[@]}"; do
      printf 'host-ports: %s bakes changed host ports(%s) — rebuild it: docker compose up -d --build %s\n' \
        "$service" "${service_changed_names[$service]}" "$service" >&2
    done
  fi
}

usage() {
  printf 'usage: host-ports.sh list | resolve\n' >&2
}

case "${1:-}" in
list) cmd_list ;;
resolve) cmd_resolve ;;
*)
  usage
  exit 2
  ;;
esac
