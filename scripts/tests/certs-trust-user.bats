#!/usr/bin/env bats
# scripts/certs-trust-user.sh trusts the local CA in this user's browser NSS stores. Every
# `make certs` on a fresh tree mints a new CA, so a copy from an older tree leaves a red
# padlock on a stack curl is happy with. These tests cover what decides that: which stores are
# found, how a store reads (current, stale, missing), what an import deletes and adds, and the
# exits without certutil or without a store. certutil and openssl are directory-backed stubs
# (lib/nss-stubs.bash) on a PATH limited to the stubs and /usr/bin:/bin — no browser, no real
# NSS, no apt-get, nothing outside $BATS_TEST_TMPDIR is touched.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/certs-trust-user.bats

load lib/nss-stubs

DN='CN=Track Binocle Local Development CA,O=Track Binocle'

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../certs-trust-user.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME" "$BIN"
  export PATH="$BIN:/usr/bin:/bin"
  export CERTUTIL_LOG="$BATS_TEST_TMPDIR/certutil.log"
  : >"$CERTUTIL_LOG"
  CA="$BATS_TEST_TMPDIR/ca.pem"
  printf '%s\nv2\n' "$DN" >"$CA"
  printf '%s\nv1\n' "$DN" >"$BATS_TEST_TMPDIR/old.pem"
  printf 'CN=Other,O=Elsewhere\nx\n' >"$BATS_TEST_TMPDIR/other.pem"
}

stubs() {
  stub_certutil "$BIN"
  stub_openssl "$BIN"
}

# A store holding FILE under NICK (certutil's db marked initialised).
put() { # <dir> <nickname> <file>
  mkdir -p "$1/certs"
  : >"$1/cert9.db"
  cp "$3" "$1/certs/$2#1"
}

firefox_profile() { mkdir -p "$1" && : >"$1/prefs.js"; }

@test "discovery: chrome, snap chromium and Firefox profiles are found, other dirs skipped" {
  stubs
  mkdir -p "$HOME/.pki/nssdb" "$HOME/snap/chromium/current" "$HOME/.mozilla/firefox/Crash Reports"
  firefox_profile "$HOME/snap/firefox/common/.mozilla/firefox/a.default"
  mkdir -p "$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox/b.default"
  : >"$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox/b.default/times.json"
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL chrome   $HOME/.pki/nssdb  missing"* ]]
  [[ "$output" == *"FAIL chrome   $HOME/snap/chromium/current/.pki/nssdb  missing"* ]]
  [[ "$output" != *"snap/chromium/common"* ]] # snap Chromium's HOME is the revision dir, not common
  [[ "$output" == *"FAIL firefox  $HOME/snap/firefox/common/.mozilla/firefox/a.default  missing"* ]]
  [[ "$output" == *"FAIL firefox  $HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox/b.default  missing"* ]]
  [[ "$output" != *"Crash Reports"* ]]
}

@test "discovery: an empty HOME has no store, a note, exit 0 in both modes" {
  stubs
  mkdir -p "$HOME/snap/chromium" # installed but never launched: no current revision, no store yet
  run bash "$SCRIPT" "$CA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no browser store under $HOME"* ]]
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to trust"* ]]
}

@test "--check: current, stale (browser-chosen nickname) and missing, exact lines, exit 1" {
  stubs
  put "$HOME/.pki/nssdb" "Track Binocle Local Development CA" "$CA"
  put "$HOME/.mozilla/firefox/s.default" "My imported CA" "$BATS_TEST_TMPDIR/old.pem"
  firefox_profile "$HOME/.mozilla/firefox/s.default"
  put "$HOME/.mozilla/firefox/m.default" "Other" "$BATS_TEST_TMPDIR/other.pem"
  firefox_profile "$HOME/.mozilla/firefox/m.default"
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ok   chrome   $HOME/.pki/nssdb  current"* ]]
  [[ "$output" == *"FAIL firefox  $HOME/.mozilla/firefox/s.default  stale"* ]]
  [[ "$output" == *"FAIL firefox  $HOME/.mozilla/firefox/m.default  missing"* ]]
  [[ "$output" == *"2 browser store(s) do not hold the current CA"* ]]
}

@test "--check: every store current exits 0" {
  stubs
  put "$HOME/.pki/nssdb" "Track Binocle Local Development CA" "$CA"
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   chrome   $HOME/.pki/nssdb  current"* ]]
}

@test "import: stale store is deleted then re-added, current one untouched, uninitialised one created" {
  stubs
  put "$HOME/.pki/nssdb" "Track Binocle Local Development CA" "$CA"
  put "$HOME/.mozilla/firefox/s.default" "My imported CA" "$BATS_TEST_TMPDIR/old.pem"
  firefox_profile "$HOME/.mozilla/firefox/s.default"
  mkdir -p "$HOME/.mozilla/firefox/n.default"
  : >"$HOME/.mozilla/firefox/n.default/times.json"
  : >"$CERTUTIL_LOG"
  run bash "$SCRIPT" "$CA"
  [ "$status" -eq 0 ]
  stale="sql:$HOME/.mozilla/firefox/s.default"
  fresh="sql:$HOME/.mozilla/firefox/n.default"
  grep -qxF -- "-D -n My imported CA -d $stale" "$CERTUTIL_LOG"
  grep -qxF -- "-A -n Track Binocle Local Development CA -t C,, -i $CA -d $stale" "$CERTUTIL_LOG"
  grep -qxF -- "-N --empty-password -d $fresh" "$CERTUTIL_LOG"
  grep -qF -- "-A -n Track Binocle Local Development CA -t C,, -i $CA -d $fresh" "$CERTUTIL_LOG"
  # bash's `!` never fails a bats test, so count the writes to the current store instead.
  [ "$(grep -F -- "-d sql:$HOME/.pki/nssdb" "$CERTUTIL_LOG" | grep -cE -- '^-(D|A) ')" -eq 0 ]
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

@test "no certutil: --check fails with the trust line, import warns and exits 0" {
  stub_openssl "$BIN"
  mkdir -p "$HOME/.pki/nssdb"
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL trust    certutil (libnss3-tools) is not installed: 1 browser store(s) unread"* ]]
  run bash "$SCRIPT" "$CA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"certutil (libnss3-tools) not found"* ]]
}

@test "misuse: two positional arguments exit 1, --help exits 0" {
  stubs
  run bash "$SCRIPT" "$CA" "$CA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "--check: a copy without the C flag is untrusted, a stale copy stacked under the current nickname is stale; one import repairs both" {
  stubs
  put "$HOME/.pki/nssdb" 'Track Binocle Local Development CA' "$CA"
  mkdir -p "$HOME/.pki/nssdb/trust"
  printf ',,' >"$HOME/.pki/nssdb/trust/Track Binocle Local Development CA#1"
  p="$HOME/snap/firefox/common/.mozilla/firefox/c.default"
  firefox_profile "$p"
  put "$p" 'Track Binocle Local Development CA' "$CA"
  cp "$BATS_TEST_TMPDIR/old.pem" "$p/certs/Track Binocle Local Development CA#2"
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL chrome   $HOME/.pki/nssdb  untrusted"* ]]
  [[ "$output" == *"FAIL firefox  $p  stale"* ]]
  run bash "$SCRIPT" "$CA"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "-D -n Track Binocle Local Development CA -d sql:$p" "$CERTUTIL_LOG")" -eq 3 ] # two copies, then the miss that ends the loop
  run bash "$SCRIPT" --check "$CA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   chrome   $HOME/.pki/nssdb  current"* ]]
  [[ "$output" == *"ok   firefox  $p  current"* ]]
}
