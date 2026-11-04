#!/usr/bin/env bash
# public-api.sh — show the public API module against a gateway you name: the documentation,
# the API key (401 without one, 401 with a wrong one, accepted with the right one) and the
# rate limit (a 429 once the route's limit is spent), printing the evidence of each step.
#
# Usage:
#   public-api.sh <base-url> --key <apikey> [--path /rest/v1/] [--max 30] [--docs-url URL]
#                 [--no-docs] [--insecure]
#   API_KEY=<apikey> public-api.sh https://localhost:8444
#
#   <base-url>   the gateway, e.g. https://localhost:8444 (the local TLS edge in front of Kong)
#   --path       a key-protected route (default /rest/v1/)
#   --max        hard cap on requests sent, docs included (default 30). The first keyed
#                response states the route's remaining allowance; when reaching the 429
#                would exceed the cap, the script stops there, so it never hammers a gateway.
#   --docs-url   where the OpenAPI document is (default <base-url>/openapi.json)
#   --no-docs    skip the documentation step (it prints SKIP, never PASS)
#   --insecure   do not verify TLS (a local CA the shell does not trust)
#
# Exit: 0 every step passed; 1 a step failed or the cap would be exceeded; 2 usage.
#
# Caveat: the remaining allowance is read from the first keyed response's RateLimit-Remaining,
# and it is a lower bound. Kong's counter lags a burst (against Kong 3.8.0 with 4 left, the 429
# came at request 15, not 9), and under the `local` policy each gateway node counts on its own.
# When the 429 has not come by --max the script stops with FAIL: raise --max on a gateway you
# own, or run it against one node. Another client spending the same IP's allowance
# meanwhile makes the 429 come early, which still passes.
set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

base='' key=${API_KEY:-} path=/rest/v1/ max=30 docs_url='' docs=1
curl_opts=(-s --max-time 15)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) key=${2:?--key needs a value}; shift 2 ;;
    --path) path=${2:?--path needs a value}; shift 2 ;;
    --max) max=${2:?--max needs a value}; shift 2 ;;
    --docs-url) docs_url=${2:?--docs-url needs a value}; shift 2 ;;
    --no-docs) docs=0; shift ;;
    --insecure) curl_opts+=(-k); shift ;;
    -h | --help) usage ;;
    -*) echo "public-api.sh: unknown flag $1" >&2; usage ;;
    *) [ -z "$base" ] || usage; base=${1%/}; shift ;;
  esac
done
[ -n "$base" ] || usage
[ -n "$key" ] || { echo "public-api.sh: an API key is required (--key or API_KEY)" >&2; exit 2; }
[[ "$max" =~ ^[0-9]+$ ]] || { echo "public-api.sh: --max must be a number" >&2; exit 2; }
docs_url=${docs_url:-$base/openapi.json}
url=$base$path
sent=0

pass() { printf 'PASS  %s\n' "$*"; }
skip() { printf 'SKIP  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

# One request, counted here rather than in a subshell. Sets `out`: the status code on the
# first line, then the headers, lower-cased and CR-free.
request() {
  [ "$sent" -lt "$max" ] || fail "request cap reached (--max $max)"
  sent=$((sent + 1))
  out=$(curl "${curl_opts[@]}" -o /dev/null -D - "$@" | tr -d '\r' |
    awk 'NR == 1 { print $2; next } { i = index($0, ":"); if (i) print tolower(substr($0, 1, i)) substr($0, i + 1) }') ||
    fail "GET ${*: -1}: no answer from the gateway"
}

header() { sed -n "s/^$1: *//p" <<<"$2" | head -n 1; }
ratelimit_headers() { grep -E '^(x-)?ratelimit-|^retry-after:' <<<"$1" | sed 's/^/        /' || true; }

echo "== Public API at $base (cap: $max requests)"

if [ "$docs" = 1 ]; then
  [ "$sent" -lt "$max" ] || fail "request cap reached (--max $max)"
  sent=$((sent + 1))
  spec=$(curl "${curl_opts[@]}" -f "$docs_url") || fail "documentation: GET $docs_url did not answer 2xx"
  ops=$(jq -r '[.paths[] | keys[] | select(test("^(get|post|put|patch|delete)$"))] | length' <<<"$spec") ||
    fail "documentation: $docs_url is not JSON"
  methods=$(jq -r '[.paths[] | keys[]] | map(ascii_upcase) | unique | join(" ")' <<<"$spec")
  [ "$ops" -ge 5 ] || fail "documentation lists $ops operations, fewer than 5"
  for m in GET POST PUT DELETE; do
    grep -qw "$m" <<<"$methods" || fail "documentation has no $m operation"
  done
  pass "documentation: $docs_url is $(jq -r '.openapi // "?"' <<<"$spec") with $ops operations ($methods)"
else
  skip "documentation (--no-docs)"
fi

request "$url"
[ "$(head -n 1 <<<"$out")" = 401 ] || fail "no key: GET $path answered $(head -n 1 <<<"$out"), not 401"
pass "no key: GET $path -> 401 (www-authenticate: $(header www-authenticate "$out"))"

request -H "apikey: not-a-key-$$" "$url"
[ "$(head -n 1 <<<"$out")" = 401 ] || fail "wrong key: GET $path answered $(head -n 1 <<<"$out"), not 401"
pass "wrong key: GET $path -> 401"

request -H "apikey: $key" "$url"
code=$(head -n 1 <<<"$out")
case "$code" in 401 | 403) fail "right key: GET $path answered $code; is the key valid for this gateway?" ;; esac
remaining=$(header ratelimit-remaining "$out")
[ -n "$remaining" ] || fail "right key: GET $path -> $code but no RateLimit-Remaining header (no rate limit on $path?)"
pass "right key: GET $path -> $code, limit $(header ratelimit-limit "$out"), $remaining left"
ratelimit_headers "$out"

[ "$code" = 429 ] || [ $((sent + remaining + 1)) -le "$max" ] ||
  fail "the 429 needs $((remaining + 1)) more requests; with $sent sent that exceeds --max $max (pick a route with a lower limit, or raise --max on a gateway you own)"

while [ "$code" != 429 ]; do
  request -H "apikey: $key" "$url"
  code=$(head -n 1 <<<"$out")
done
pass "rate limit: request $sent -> 429"
ratelimit_headers "$out"
echo "== $sent requests sent"
