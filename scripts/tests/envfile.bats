#!/usr/bin/env bats
# scripts/lib/envfile.sh — put_env is the one primitive that edits ./.env.local in place
# (gen-local-env.sh --sync and ensure-live-data-access.sh both call it). It must touch only
# the named key, keep every other byte, keep the file's mode, never echo the value, and
# never leave a temp file behind. get_env reads the same line put_env would rewrite
# (grobase-link.sh reads its settings and state with it). Synthetic files only.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/envfile.bats

setup() {
  . "$BATS_TEST_DIRNAME/../lib/envfile.sh"
  F="$BATS_TEST_TMPDIR/x.env"
  printf '# c\nA=1\n  B = 2\nA=old-dup\nC=3\n' > "$F"
  chmod 640 "$F"
}

@test "rewrites the first live line in place and drops later duplicates" {
  put_env "$F" A new
  [ "$(sed -n 2p "$F")" = "A=new" ]
  [ "$(grep -c '^A=' "$F")" -eq 1 ]
  [ "$(wc -l < "$F")" -eq 4 ]
}

@test "appends a missing key" {
  put_env "$F" D 4
  [ "$(tail -1 "$F")" = "D=4" ]
  [ "$(wc -l < "$F")" -eq 6 ]
}

@test "keeps the file's mode" {
  put_env "$F" A x
  [ "$(stat -c %a "$F")" = "640" ]
}

@test "creates a missing file as 0600" {
  rm "$F"
  put_env "$F" A x
  [ "$(stat -c %a "$F")" = "600" ]
  [ "$(cat "$F")" = "A=x" ]
}

@test "leaves comments and other lines byte-for-byte" {
  put_env "$F" C 9
  [ "$(sed -n 1p "$F")" = "# c" ]
  [ "$(sed -n 3p "$F")" = "  B = 2" ]
  [ "$(sed -n 5p "$F")" = "C=9" ]
}

@test "a commented-out key is not a live line" {
  printf '#A=zz\n' > "$F"
  put_env "$F" A 1
  [ "$(sed -n 1p "$F")" = "#A=zz" ]
  [ "$(sed -n 2p "$F")" = "A=1" ]
}

@test "a value holding '=' and '%' survives intact" {
  put_env "$F" A 'a=b%c'
  [ "$(sed -n 's/^A=//p' "$F")" = "a=b%c" ]
}

@test "prints nothing — the value is never echoed" {
  run put_env "$F" A secret-value
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no temp file is left beside the target" {
  put_env "$F" A x
  [ "$(ls -A "$BATS_TEST_TMPDIR" | wc -l)" -eq 1 ]
}

@test "get_env: first live value, blanks around name and value dropped, '=' in the value kept" {
  [ "$(get_env "$F" A)" = 1 ]
  [ "$(get_env "$F" B)" = 2 ]
  printf '#A=zz\nX=a=b\n' > "$F"
  [ "$(get_env "$F" X)" = "a=b" ]
}

@test "get_env: a commented-out or absent key, or a missing file, prints nothing and exits 1" {
  printf '#A=zz\n' > "$F"
  run get_env "$F" A
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run get_env "$BATS_TEST_TMPDIR/none" A
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
