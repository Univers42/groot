#!/bin/sh
# Prints, one per line and sorted, every audit event type the auth gateway can write.
# Usage: audit-event-writers.sh <opposite-osiris dir>
#
# Reads scripts/auth-gateway.mjs and scripts/auth/*.mjs. Six call shapes feed the audit RPC:
# audit('x') / flowAudit('x'), a ternary inside one of those calls, `${action}_suffix` expanded
# over every protectedAction(request, response, 'a', sendMessage(..., 'x'), signedLink(..., 'x')
# and revoke(record, 'x').
#
# Caveat: regex over those six shapes, not a parser. A name routed through a seventh helper
# (a new wrapper that forwards its last argument to audit) is missed, so the result under-reports;
# a quoted name in a comment on an audit line is over-reported. The escape hatch is a new shape
# here plus a fixture in auth-audit-event-types.bats.
set -eu

src=${1:?usage: audit-event-writers.sh <opposite-osiris dir>}
files="$src/scripts/auth-gateway.mjs"
for f in "$src"/scripts/auth/*.mjs; do [ -f "$f" ] && files="$files $f"; done
[ -f "$src/scripts/auth-gateway.mjs" ] || { echo "no auth-gateway.mjs under $src" >&2; exit 2; }

# shellcheck disable=SC2086 # $files is a space-separated list of paths without spaces
code=$(cat $files)
names() { grep -oE "'[a-z][a-z0-9_]*'" | tr -d "'"; }

{
  printf '%s\n' "$code" | grep -oE "[aA]udit\(\s*'[a-z][a-z0-9_]*'" | names
  printf '%s\n' "$code" | grep -oE "[aA]udit\([^?{]*\?\s*'[a-z0-9_]+'\s*:\s*'[a-z0-9_]+'" | names
  printf '%s\n' "$code" | grep -oE "(sendMessage|signedLink)\([^;]*,\s*'[a-z0-9_]+'\)" | grep -oE ",\s*'[a-z0-9_]+'\)[^']*$" | names
  printf '%s\n' "$code" | grep -oE "revoke\([^,]+,\s*'[a-z0-9_]+'" | grep -oE "'[a-z0-9_]+'$" | names
  actions=$(printf '%s\n' "$code" | grep -oE "protectedAction\(request, response, '[a-z0-9_]+'" | names | grep -vx protectedAction || true)
  # shellcheck disable=SC2016 # the backticks and ${action} are literal JS template text
  suffixes=$(printf '%s\n' "$code" | grep -oE '`\$\{action\}[a-z_]+`' | sed 's/^`${action}//; s/`$//')
  for suffix in $suffixes; do
    for action in $actions; do printf '%s%s\n' "$action" "$suffix"; done
  done
} | sort -u
