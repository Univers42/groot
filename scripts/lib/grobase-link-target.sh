#!/usr/bin/env bash
# grobase-link-target.sh — how grobase-link.sh turns GROBASE_TARGET into "<mode> <target>":
# the parsers (ssh_args, url_hostport), the probes (local daemon, `docker ps` over ssh, a
# TCP/TLS connect from a container), the relay's addresses for a direct target
# (resolve_ipv4, kong_addr, direct_routes) and the resolvers (explicit scheme, bare host, auto).
# Sourced by scripts/grobase-link.sh, which defines note, die, TARGET, SOCAT_IMG and REPO
# before sourcing; define-only, sets no shell option. Tested alone by
# scripts/tests/grobase-link.bats (parsers and resolve: no ssh, no docker, no network).
#
# Ponytail: `auto` probes candidates one by one with a 5 s connect timeout; a down host
# costs 5 s, and the first match wins, not the nearest. Ponytail: a bare host is tried as
# ssh, then http://host:8000, then https://host, so a Kong on another port needs the URL.

# One-off ssh with the user's config but none of its forwards; "$@" = [-p port] dest cmd.
ssh_once() { ssh -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR "$@"; }
local_has_grobase() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mini-baas-kong; }
# ssh://[user@]host[:port] -> "dest" or "dest -p port" (also accepts alias, user@host, host).
ssh_args() {
  local t=${1#ssh://} hostpart
  hostpart=${t##*@}
  case "$hostpart" in
  *:*) printf '%s -p %s\n' "${t%:*}" "${hostpart##*:}" ;;
  *) printf '%s\n' "$t" ;;
  esac
}
# shellcheck disable=SC2046 # ssh_args output is a dest and an optional -p port, never spaces
remote_has_grobase() { ssh_once $(ssh_args "$1") 'docker ps --format {{.Names}}' 2>/dev/null | grep -qx mini-baas-kong; }
url_hostport() { # http(s)://host[:port][/...] -> "host port"
  local hp=${1#*://} port=80
  hp=${hp%%/*}
  case "$1" in https://*) port=443 ;; esac
  case "$hp" in *:*) port=${hp##*:} ;; esac
  printf '%s %s\n' "${hp%%:*}" "$port"
}
# Ponytail: IPv4 only; an IPv6-only name is passed through unresolved, and the relay's Docker
# DNS (no /etc/hosts, no mDNS) must resolve it. A name resolving to 127.x here points the
# relay at itself: on the data center host use local mode.
resolve_ipv4() { # HOST -> its first IPv4 address, or HOST itself when getent knows none
  local ip
  ip=$(getent ahostsv4 "$1" | awk 'NR == 1 { print $1 }') || true
  printf '%s\n' "${ip:-$1}"
}
# api_url TARGET EXPLICIT -> the HTTPS URL clients call for the grobase API (the WAF):
# EXPLICIT when set, else TARGET's own URL, else the loopback WAF; exit 1 when it has none.
api_url() {
  local url=${2:-}
  if [ -z "$url" ]; then
    case "$1" in
    http://* | https://*) url=$1 ;;
    local) url=https://127.0.0.1:8443 ;;
    *) return 1 ;;
    esac
  fi
  printf '%s\n' "${url%/}"
}
url_reachable() { # from a container of this daemon, where the frontends run
  local host port ip addr
  read -r host port < <(url_hostport "$1")
  ip=$(resolve_ipv4 "$host")
  case "$1" in
  https://*) addr="OPENSSL:$ip:$port,verify=0,snihost=$host" ;; # a reachability probe, not a trust decision
  *) addr="TCP:$ip:$port" ;;
  esac
  docker run --rm "$SOCAT_IMG" -T5 /dev/null "$addr,connect-timeout=5" >/dev/null 2>&1
}
# kong_addr URL CAFILE -> the relay's socat address for Kong. The name is resolved HERE and
# the relay connects to that IP: its Docker DNS reads neither /etc/hosts nor mDNS, so a LAN
# name would not resolve there. The certificate is still verified against the URL's own name
# (commonname and snihost), which is what its SAN covers, not against the IP.
kong_addr() {
  local host port ip
  read -r host port < <(url_hostport "$1")
  ip=$(resolve_ipv4 "$host")
  case "$1" in
  https://*) printf 'OPENSSL:%s:%s,verify=1,cafile=%s,commonname=%s,snihost=%s\n' "$ip" "$port" "$2" "$host" "$host" ;;
  *) printf 'TCP:%s:%s\n' "$ip" "$port" ;;
  esac
}
# The relay reads "<listen port> <socat address>" per line, one socat per line. Redis and
# Mailpit go to stand-in containers on THIS machine (grobase-link-redis and
# grobase-link-mailpit; another unit adds them), so sessions and captured mail stay local.
direct_routes() {
  local addr
  addr=$(kong_addr "$1" "$2")
  printf '%s\n' "8000 $addr" \
    '6379 TCP:grobase-link-redis:6379' \
    '8025 TCP:grobase-link-mailpit:8025' \
    '1025 TCP:grobase-link-mailpit:1025'
}

# Every ~/.ssh/config alias, then every born2root VM whose ports.env records an ssh forward.
ssh_candidates() {
  awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' ~/.ssh/config 2>/dev/null
  local marker port
  for marker in "$REPO"/vendor/born2root/disk_images/.vm_path.* ${B2B_DIR:+"$B2B_DIR"/disk_images/.vm_path.*}; do
    [ -f "$marker" ] || continue
    port=$(awk -F= '$1 == "ssh" { print $2 }' "$(cat "$marker")/${marker##*.vm_path.}/ports.env" 2>/dev/null)
    [ -n "$port" ] && printf 'ssh://%s@127.0.0.1:%s\n' "$USER" "$port"
  done
}

# Prints "<mode> <target>" for TARGET; the scheme is the kind of connection, so an explicit
# scheme is taken as given and only `auto` and a bare host are probed.
resolve() {
  case "$TARGET" in
  local) printf 'local local\n' ;;
  ssh://*) printf 'ssh %s\n' "$TARGET" ;;
  http://* | https://*) printf 'direct %s\n' "$TARGET" ;;
  auto) resolve_auto ;;
  *) resolve_host "$TARGET" ;;
  esac
}
resolve_auto() {
  local c
  if local_has_grobase; then
    printf 'local local\n'
    return
  fi
  while read -r c; do
    [ -n "$c" ] || continue
    note "probing $c"
    if remote_has_grobase "$c"; then
      printf 'ssh %s\n' "$c"
      return
    fi
  done < <(ssh_candidates)
  die "no grobase found here, on an ssh alias or a born2root VM; set GROBASE_TARGET (see --help)"
}
resolve_host() { # a bare host or alias: ssh first, then Kong's plain port, then https
  if remote_has_grobase "$1"; then
    printf 'ssh %s\n' "$1"
  elif url_reachable "http://$1:8000"; then
    printf 'direct http://%s:8000\n' "$1"
  elif url_reachable "https://$1"; then
    printf 'direct https://%s\n' "$1"
  else
    die "$1: ssh shows no mini-baas-kong there and neither http://$1:8000 nor https://$1 answers from a container"
  fi
}
# publish_env MODE ENV_LOCAL — where the bridge publishes realtime events. ssh and local reach
# the gateway by name (empty = docker-compose.yml's default); direct mode has only the edge,
# whose /realtime/v1/publish admits the service_role key alone (grobase kong.yml).
publish_env() {
  local url="" key=""
  if [ "$1" = direct ]; then
    url=http://mini-baas-kong:8000/realtime
    key=$(get_env "$2" SERVICE_ROLE_KEY) || key=""
  fi
  put_env "$2" REALTIME_PUBLISH_URL "$url"
  put_env "$2" REALTIME_PUBLISH_APIKEY "$key"
}
