#!/usr/bin/env bash
# certs-trust-user.sh [--check] [CA] — trust the local CA in every browser store THIS user
# owns, no sudo: Chrome/Chromium's NSS db (~/.pki/nssdb, snap Chromium) and each Firefox
# profile (deb/tar, snap, flatpak). The system store is certs.mk's TRUST_LOCAL_CA (sudo).
# Every `make certs` on a fresh tree mints a NEW CA and a browser reads its store only at
# launch, so a copy left from an older tree is the usual cause of a red padlock on a stack
# curl --cacert is happy with (2026-10-08: six stores on one host, all stale). Old copies
# are matched by SUBJECT, not nickname: a CA imported through a browser's settings carries
# a nickname of the browser's choosing. Import = delete every copy with the CA's subject,
# then add the file. --check: one line per store (ok|FAIL kind path state), exit 1 when any
# is stale or missing, or when stores exist but certutil does not (UNKNOWN = FAIL); exit 0
# without a store. Without --check a missing certutil is extracted from libnss3-tools into
# ~/.cache/born2root/nss (born2root's own cache) and, failing that, warned about, exit 0.
# Ponytail: a profile is a directory holding prefs.js or times.json under one of four roots,
# so a profile elsewhere (a -profile DIR launch, a policy-defined root, flatpak Chrome) is
# missed (under-reports). NSS keeps one nickname per subject and `-L -n -a` returns every
# copy under it, so each copy is judged; the trust flags are read per nickname from the
# listing, so two copies with different flags share the first's. Nicknames come from the
# padded columns of `certutil -L`, so one ending in spaces is trimmed, then not found
# (under-reports). Brave, Edge and Vivaldi are not looked for. The import's nickname is the
# CA's CN, cut at the first comma, so a CN holding an escaped comma is truncated (cosmetic).
# A browser already running keeps its old view until relaunched: it says so, kills nothing.
set -eu

NSS_CACHE="$HOME/.cache/born2root/nss"
US=$(printf '\037') # listing(): between a nickname (which may hold spaces) and its trust
RS=$(printf '\036') # pem_blocks(): after each certificate
ROOTS="$HOME/.mozilla/firefox
$HOME/snap/firefox/common/.mozilla/firefox
$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox
$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox"

usage() {
  cat <<'USAGE'
usage: certs-trust-user.sh [--check] [CA]
  CA       the local CA (default apps/grobase/certs/track-binocle-local-ca.pem)
  --check  report every browser store: ok|FAIL <kind> <path>  current|stale|missing
exit 0 when every store holds the current CA (or there is no store); 1 when one is stale
or missing, when --check finds stores but no certutil, or on misuse.
USAGE
}

say() { printf '[certs] %s\n' "$*" >&2; }
die() {
  say "$*"
  exit 1
}

# The CA make minted: LOCAL_CA_CERT as common.mk defines it (relative to the repo), else
# grobase's default location.
ca_default() {
  local rel=${LOCAL_CA_CERT:-apps/grobase/certs/track-binocle-local-ca.pem}
  case $rel in
  /*) echo "$rel" ;;
  *) echo "$(cd "$(dirname "$0")/.." && pwd)/$rel" ;;
  esac
}

# certutil (libnss3-tools): PATH, then the copy born2root or an earlier run extracted, then,
# in import mode only, a bounded extraction of the .deb (no root: apt-get download + dpkg-deb).
find_certutil() { # <fetch|no>
  local tmp
  command -v certutil && return 0
  if [ -x "$NSS_CACHE/usr/bin/certutil" ]; then
    echo "$NSS_CACHE/usr/bin/certutil"
    return 0
  fi
  [ "$1" = fetch ] || return 1
  command -v apt-get >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1 || return 1
  # Ponytail: 120 s bounds the download; a slower mirror means no certutil this run (re-run).
  say "certutil not on PATH; extracting libnss3-tools into $NSS_CACHE (no root, 120 s bound)"
  tmp=$(mktemp -d)
  if (cd "$tmp" && timeout 120 apt-get download libnss3-tools >/dev/null 2>&1 &&
    mkdir -p "$NSS_CACHE" && dpkg-deb -x ./libnss3-tools_*.deb "$NSS_CACHE") &&
    [ -x "$NSS_CACHE/usr/bin/certutil" ]; then
    rm -rf "$tmp"
    echo "$NSS_CACHE/usr/bin/certutil"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

# Chrome and Chromium (deb) read ~/.pki/nssdb; a db that is not there yet counts when a
# browser binary says one will read it: it is created empty. Snap Chromium's HOME is the
# revision directory behind ~/snap/chromium/current (its launcher moves only .config/chromium
# to common), so its store MOVES at every snap refresh: the copy imported into the previous
# revision is gone from the browser's view (2026-10-08: refresh 3507 -> 3551, store missing
# again, ERR_CERT_AUTHORITY_INVALID) and the next --check says so. Nothing is imported
# before the first launch creates that directory: a real `current` would block snapd's link.
chrome_stores() {
  local bin
  if [ -d "$HOME/.pki/nssdb" ]; then
    printf 'chrome %s\n' "$HOME/.pki/nssdb"
  else
    for bin in google-chrome google-chrome-stable chromium chromium-browser; do
      bin=$(command -v "$bin" 2>/dev/null) || continue
      [ "$(readlink -f "$bin")" != /usr/bin/snap ] || continue # the snap reads its own store
      printf 'chrome %s\n' "$HOME/.pki/nssdb"
      break
    done
  fi
  [ ! -d "$HOME/snap/chromium/current" ] || printf 'chrome %s\n' "$HOME/snap/chromium/current/.pki/nssdb"
}

# Every Firefox profile: a directory under one of the roots that Firefox has initialised
# (prefs.js) or at least registered (times.json); "Crash Reports" and friends have neither.
firefox_stores() {
  local root dir
  while IFS= read -r root; do
    for dir in "$root"/*/; do
      dir=${dir%/}
      [ -f "$dir/prefs.js" ] || [ -f "$dir/times.json" ] || continue
      printf 'firefox %s\n' "$dir"
    done
  done <<<"$ROOTS"
}

# "<nickname>US<trust>" per line from `certutil -L`: the nickname column is padded, the
# trust token (SSL,S/MIME,JAR fields) ends the line, one line per nickname; a store that
# does not exist yet lists nothing.
listing() { # <dir>
  "$CERTUTIL" -L -d "sql:$1" 2>/dev/null | tail -n +5 |
    sed -nE "s/[[:space:]]+([^[:space:]]*,[^[:space:]]*,[^[:space:]]*)[[:space:]]*\$/$US\\1/p" |
    awk -F"$US" '!seen[$1]++'
}

nick_pem() { "$CERTUTIL" -L -d "sql:$1" -n "$2" -a 2>/dev/null; } # <dir> <nickname>
# Every certificate under a nickname, RS-terminated: NSS answers -a with all copies that
# share the subject; input without PEM markers (a bare file) is one block.
pem_blocks() {
  awk -v rs="$RS" '/-----BEGIN /{b=""; p=1} {b=b $0 "\n"} /-----END /{printf "%s%s", b, rs; b=""}
    END{if (!p && b != "") printf "%s%s", b, rs}'
}
# C in the SSL field = trusted to issue server certificates; ",," is a copy the browser
# holds but does not trust (imported, then distrusted in its UI).
ssl_trusted() { case ${1%%,*} in *C*) return 0 ;; *) return 1 ;; esac; }
subject() { openssl x509 -noout -subject -nameopt RFC2253 "$@" 2>/dev/null | sed 's/^subject=//'; }
fingerprint() { openssl x509 -noout -fingerprint -sha256 "$@" 2>/dev/null | cut -d= -f2; }

# current | stale | untrusted | missing, over every copy carrying the CA's subject: a wrong
# fingerprint anywhere is stale (the browser could chain through either copy), the right
# one without the C flag is untrusted; both are repaired by delete-then-add.
store_state() { # <dir>
  local nick trust pem fresh=0 old=0 weak=0
  while IFS="$US" read -r nick trust; do
    [ -n "$nick" ] || continue
    while IFS= read -r -d "$RS" pem; do
      [ "$(subject <<<"$pem")" = "$CA_SUBJECT" ] || continue
      if [ "$(fingerprint <<<"$pem")" != "$CA_FP" ]; then old=$((old + 1))
      elif ssl_trusted "$trust"; then fresh=$((fresh + 1))
      else weak=$((weak + 1)); fi
    done < <(nick_pem "$1" "$nick" | pem_blocks)
  done < <(listing "$1")
  if [ "$old" -gt 0 ]; then echo stale
  elif [ "$weak" -gt 0 ]; then echo untrusted
  elif [ "$fresh" -gt 0 ]; then echo current
  else echo missing; fi
}

# Delete every copy carrying the CA's subject (one -D removes one copy; bounded at 5 per
# nickname), then add the file under NICK with C,,: trusted to sign servers, nothing else.
import_store() { # <dir>
  local nick
  if [ ! -f "$1/cert9.db" ]; then
    mkdir -p "$1" && "$CERTUTIL" -N --empty-password -d "sql:$1"
  fi
  while IFS="$US" read -r nick _; do
    [ -n "$nick" ] || continue
    [ "$(nick_pem "$1" "$nick" | subject)" = "$CA_SUBJECT" ] || continue
    # Ponytail: more than 5 copies under one nickname leaves the rest (2 is the most seen).
    for _ in 1 2 3 4 5; do "$CERTUTIL" -D -n "$nick" -d "sql:$1" >/dev/null 2>&1 || break; done
  done < <(listing "$1")
  "$CERTUTIL" -A -n "$NICK" -t 'C,,' -i "$CA" -d "sql:$1"
}

# ok|FAIL <kind> <path>  <state>, one line per store; exit 1 unless every one is current.
check_stores() { # <stores, "kind path" per line>
  local kind dir state fails=0
  while read -r kind dir; do
    state=$(store_state "$dir")
    if [ "$state" = current ]; then
      printf 'ok   %-8s %s  current\n' "$kind" "$dir"
    else
      printf 'FAIL %-8s %s  %s\n' "$kind" "$dir" "$state"
      fails=$((fails + 1))
    fi
  done <<<"$1"
  [ "$fails" -eq 0 ] || {
    say "$fails browser store(s) do not hold the current CA; run: make certs-trust-user, then relaunch the browser"
    return 1
  }
  say "every browser store holds the current CA ($CA_FP)"
}

# Browsers read their store at launch only: one that is running keeps the old CA in view.
# Ponytail: pgrep on three path patterns; a renamed or otherwise packaged browser gets no hint.
relaunch_hint() {
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -f '/firefox/firefox|/chrome/chrome|chromium' >/dev/null 2>&1 || return 0
  say "a browser is running: it trusts the new CA only after a relaunch (quit Firefox / Chrome and reopen; vendor/born2root/setup/host/restart_browsers.sh does it with session restore)"
}

import_stores() { # <stores, "kind path" per line>
  local kind dir state changed=0 fails=0
  while read -r kind dir; do
    state=$(store_state "$dir")
    if [ "$state" = current ]; then
      say "$kind $dir: current CA already trusted"
    elif import_store "$dir" >/dev/null; then
      say "$kind $dir: CA imported (was $state)"
      changed=$((changed + 1))
    else
      say "$kind $dir: import FAILED (certutil's error above)"
      fails=$((fails + 1))
    fi
  done <<<"$1"
  [ "$changed" -eq 0 ] || relaunch_hint
  [ "$fails" -eq 0 ]
}

# Subject and fingerprint are what the stores are compared against; the nickname a store
# gets is the CA's own CN, the name apps/grobase's scripts and the browsers' UI show.
load_ca() {
  CA_SUBJECT=$(subject -in "$CA")
  [ -n "$CA_SUBJECT" ] || die "$CA is not a certificate"
  CA_FP=$(fingerprint -in "$CA")
  NICK=${CA_SUBJECT#*CN=}
  NICK=${NICK%%,*}
  [ -n "$NICK" ] || NICK=$CA_SUBJECT
}

# In import mode the browsers' stores are left alone (the system store may serve), exit 0;
# --check cannot read them, so it fails: UNKNOWN = FAIL.
no_certutil() { # <mode> <stores>
  if [ "$1" = check ]; then
    printf 'FAIL trust    certutil (libnss3-tools) is not installed: %s browser store(s) unread\n' "$(wc -l <<<"$2")"
    exit 1
  fi
  say "certutil (libnss3-tools) not found and not fetchable: browser stores left as they are; install it, then: make certs-trust-user"
  exit 0
}

# "kind path" per line; exit 0 with a note when this user has no browser store at all.
discover_stores() {
  local stores
  stores=$(
    chrome_stores
    firefox_stores
  )
  [ -n "$stores" ] || {
    say "no browser store under $HOME (no Chrome/Chromium NSS db, no Firefox profile): nothing to trust"
    exit 0
  }
  echo "$stores"
}

main() {
  local mode=import fetch=fetch stores
  case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --check)
    mode=check fetch=no
    shift
    ;;
  esac
  [ $# -le 1 ] || {
    usage >&2
    exit 1
  }
  CA=${1:-$(ca_default)}
  [ -f "$CA" ] || die "no CA at $CA; run make certs first"
  stores=$(discover_stores)
  [ -n "$stores" ] || exit 0
  CERTUTIL=$(find_certutil "$fetch") || no_certutil "$mode" "$stores"
  load_ca
  if [ "$mode" = check ]; then check_stores "$stores"; else import_stores "$stores"; fi
}

main "$@"
