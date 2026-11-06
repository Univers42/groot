#!/usr/bin/env bats
# remote_grobase_dir asks the target where its grobase lives; whatever it answers is spliced
# into remote commands, so only a plain absolute path may come back. RUN is a stand-in here.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-remote-dir.bats

setup() {
  # shellcheck source=scripts/lib/grobase-remote-dir.sh
  . "$BATS_TEST_DIRNAME/../lib/grobase-remote-dir.sh"
}
answers() { printf '%s\n' "$ANSWER"; }
fails() { return 1; }

@test "the directory Kong was started from is taken" {
  ANSWER=/srv/grobase-prod
  run remote_grobase_dir answers
  [ "$output" = /srv/grobase-prod ]
}

@test "the probe is the compose working_dir label of mini-baas-kong" {
  records() { printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/cmd"; printf '/opt/x\n'; }
  run remote_grobase_dir records
  grep -q 'com.docker.compose.project.working_dir' "$BATS_TEST_TMPDIR/cmd"
  grep -q 'mini-baas-kong$' "$BATS_TEST_TMPDIR/cmd"
}

@test "no Kong (the command fails) falls back to /opt/grobase" {
  run remote_grobase_dir fails
  [ "$output" = /opt/grobase ]
}

@test "an empty label (Kong not started by compose) falls back" {
  ANSWER=""
  run remote_grobase_dir answers
  [ "$output" = /opt/grobase ]
}

@test "a path that could break out of a remote command is refused" {
  for ANSWER in "/opt/g'; rm -rf ~" '/opt/$(id)' 'relative/dir' '/opt/a b'; do
    run remote_grobase_dir answers
    [ "$output" = /opt/grobase ]
  done
}
