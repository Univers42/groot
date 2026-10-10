#!/usr/bin/env bash
# Stand-ins for certutil (NSS) and openssl, for the tests of scripts/certs-trust-user.sh.
# Why stubs: the bats image has neither tool, and the script's logic (discovery, the
# subject/fingerprint comparison, delete-then-add) needs a store it can read and change, not
# real X.509. A "certificate" here is any text whose first line is the DN; a store is a
# directory (DIR/cert9.db marks an initialised db, DIR/certs/<nickname>#<n> one cert each).
# A cert's trust token lives in DIR/trust/<nickname>#<n> (absent = C,,), and `-L -n -a`
# returns every copy under the nickname wrapped in PEM markers, as NSS does for one subject.
# Ponytail: the stubs model only the calls certs-trust-user.sh makes (-L, -L -n -a, -N, -D,
# -A, -t); a script change that uses another flag or real X.509 parsing is not caught here.

# The first half of the certutil stub: argument parsing and the call log.
_certutil_parse() {
  cat <<'STUB'
#!/bin/sh
[ -z "${CERTUTIL_LOG:-}" ] || echo "$*" >>"$CERTUTIL_LOG"
op='' dir='' nick='' file='' trust='C,,'
while [ $# -gt 0 ]; do
  case $1 in
  -L | -N | -D | -A) op=$1 ;;
  -d) dir=${2#sql:} && shift ;;
  -n) nick=$2 && shift ;;
  -t) trust=$2 && shift ;;
  -i) file=$2 && shift ;;
  esac
  shift
done
STUB
}

# The second half: one branch per operation, exit 255 where certutil fails.
_certutil_ops() {
  cat <<'STUB'
first() { for f in "$dir/certs/$nick#"*; do [ -f "$f" ] && echo "$f" && return 0; done; return 1; }
if [ "$op" = -N ]; then mkdir -p "$dir/certs" && : >"$dir/cert9.db" && exit 0; fi
[ -f "$dir/cert9.db" ] || exit 255
case $op in
-L)
  if [ -n "$nick" ]; then
    first >/dev/null || exit 255
    for f in "$dir/certs/$nick#"*; do printf -- '-----BEGIN CERTIFICATE-----\n'; cat "$f"; printf -- '-----END CERTIFICATE-----\n'; done
    exit 0
  fi
  printf 'header\n\nCertificate Nickname   Trust Attributes\n\n'
  for f in "$dir/certs/"*; do
    [ -f "$f" ] || continue
    b=${f##*/}
    t='C,,'; [ ! -f "$dir/trust/$b" ] || t=$(cat "$dir/trust/$b")
    printf '%-50s %s  \n' "${b%#*}" "$t"
  done
  ;;
-D) f=$(first) && rm -f "$f" "$dir/trust/${f##*/}" || exit 255 ;;
-A)
  n=1
  while [ -e "$dir/certs/$nick#$n" ]; do n=$((n + 1)); done
  mkdir -p "$dir/trust" && cp "$file" "$dir/certs/$nick#$n" && printf '%s' "$trust" >"$dir/trust/$nick#$n"
  ;;
esac
STUB
}

stub_certutil() { # <dir>
  mkdir -p "$1"
  {
    _certutil_parse
    _certutil_ops
  } >"$1/certutil"
  chmod +x "$1/certutil"
}

stub_openssl() { # <dir>
  mkdir -p "$1"
  cat >"$1/openssl" <<'STUB'
#!/bin/sh
in=''
want=''
for a in "$@"; do
  [ "$in" = next ] && in=$a && continue
  case $a in
  -in) in=next ;;
  -subject | -fingerprint) want=$a ;;
  esac
done
[ -n "$in" ] || in=/dev/stdin
case $want in
-subject) printf 'subject=%s\n' "$(grep -v '^-----' "$in" | head -n 1)" ;;
-fingerprint) printf 'sha256 Fingerprint=%s\n' "$(grep -v -E '^-----|^$' "$in" | sha256sum | cut -d' ' -f1)" ;;
esac
STUB
  chmod +x "$1/openssl"
}
