#!/usr/bin/env bats
# grobase-import-remote.sh hands VERB, ID and DEST's path to a remote shell unquoted; parse_args
# is the only thing between a typo (or a hostile ID) and that shell. Refusals must happen
# before rsync or ssh run; a valid call sends exactly the reviewed tools and the verb.
# rsync and ssh are stubs that record their arguments.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-import-remote.bats

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts" "$ROOT/apps/grobase" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../grobase-import-remote.sh" "$ROOT/scripts/"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  for tool in rsync ssh; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$CALLS"\n' "$tool" >"$BATS_TEST_TMPDIR/bin/$tool"
    chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
  done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset GROBASE_IMPORT_DEST
}

refused() { # ARGS... — exit 2 and neither rsync nor ssh ran
  run bash "$ROOT/scripts/grobase-import-remote.sh" "$@"
  [ "$status" -eq 2 ]
  [ ! -e "$CALLS" ]
}

@test "an unknown verb or a missing id is a usage error" {
  refused restore seeds-1 --dest b2b:/var/lib/grobase-import
  refused apply
}

@test "an id outside [A-Za-z0-9._-], or one starting with a dot, is refused" {
  refused apply 'seeds;reboot' --dest b2b:/var/lib/grobase-import
  refused apply '..' --dest b2b:/var/lib/grobase-import
  refused apply 'a b' --dest b2b:/var/lib/grobase-import
}

@test "DEST must be HOST:/PATH with a safe path; it may come from GROBASE_IMPORT_DEST" {
  refused apply seeds-1
  refused apply seeds-1 --dest b2b
  refused apply seeds-1 --dest -oProxyCommand=x:/tmp
  refused apply seeds-1 --dest 'b2b:/var/lib/$(id)'
  GROBASE_IMPORT_DEST='b2b:/tmp/a b' refused apply seeds-1
}

@test "a valid call syncs the tools to DEST/.tools, then runs the verb there with absent flags as -" {
  run bash "$ROOT/scripts/grobase-import-remote.sh" apply seeds-1 --dest b2b:/var/lib/grobase-import --confirm
  [ "$status" -eq 0 ]
  grep -q '^rsync .*scripts/ops/grobase-import-apply.sh .* b2b:/var/lib/grobase-import/.tools/$' "$CALLS"
  grep -q '^ssh -o ClearAllForwardings=yes -o LogLevel=ERROR b2b sh -s -- /var/lib/grobase-import apply seeds-1 --confirm -$' "$CALLS"
}
