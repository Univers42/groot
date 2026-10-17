#!/usr/bin/env bats
# The IDE sandbox's login launcher (osio-login) and its chsh shim, with the validation they
# share (osio-shell.sh). Runs the real scripts from infrastructure/docker/osionos/ide-sandbox
# against a throwaway $HOME. The launcher refuses to start a saved shell that fails a check and
# falls back to /bin/bash -l; chsh applies the same checks before it writes anything.
#
# Needs root in a disposable container (the scripts are installed at their image paths, which
# the "itself" check compares against), and bash for the fallback. Caveat: busybox ash (the
# bats image) and dash (Debian, the sandbox image's /bin/sh) both run it; other POSIX shells
# are not exercised.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#   -c 'apk add -q --no-cache bash && bats scripts/tests/ide-login-shell.bats'

bats_require_minimum_version 1.5.0

SRC="$BATS_TEST_DIRNAME/../../infrastructure/docker/osionos/ide-sandbox"

setup_file() {
  [ -w /usr/local/bin ] && [ -w /etc ] || skip "needs a disposable root container"
  install -D -m 0644 "$SRC/osio-shell.sh" /usr/local/lib/osio-shell.sh
  install -D -m 0755 "$SRC/osio-login.sh" /usr/local/bin/osio-login
  install -D -m 0755 "$SRC/osio-chsh.sh" /usr/local/bin/chsh
  # The image ships this file (ADR 0009); osio-login reads it and never writes it.
  printf 'root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\ncoder:x:10001:10001::/home/coder:/bin/bash\n' > /etc/passwd.base
  # A box runs as its owner's own uid (ADR 0011); osio-login reads it with `id -u`. This container is
  # root, so a shim stands in for the uid runc would have set.
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 20042; exit 0; }\nexec /usr/bin/id "$@"\n' > /usr/local/bin/id
  chmod 0755 /usr/local/bin/id
  touch /etc/shells
  grep -qxF /bin/sh /etc/shells || echo /bin/sh >> /etc/shells
  grep -qxF /bin/bash /etc/shells || echo /bin/bash >> /etc/shells
}

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  CONF="$HOME/.config/osio/login-shell"
  rm -rf /tmp/.osio /tmp/pwned-by-osio-user
  mkdir -p /tmp/.osio
  cp /etc/passwd.base /tmp/.osio/passwd
  # Prints what the launcher started, then leaves.
  PROBE='if shopt -q login_shell 2>/dev/null; then echo BASH-LOGIN; fi; exit'
}

save() { mkdir -p "$(dirname "$CONF")"; printf '%s\n' "$1" > "$CONF"; }

chosen_shell() {
  printf '#!/bin/sh\necho "CHOSEN $*"\n' > "$HOME/mysh"
  chmod 755 "$HOME/mysh"
}

launch() { printf '%s\n' "$PROBE" | /usr/local/bin/osio-login; }

@test "no saved shell: starts bash as a login shell, silently" {
  run --separate-stderr launch
  [ "$status" -eq 0 ]
  [ "$output" = "BASH-LOGIN" ]
  [ -z "$stderr" ]
}

@test "a saved executable under HOME is started with -l" {
  chosen_shell
  save "$HOME/mysh"
  run launch
  [ "$output" = "CHOSEN -l" ]
}

@test "a saved shell listed in /etc/shells is started" {
  save /bin/sh
  run --separate-stderr launch
  [ -z "$stderr" ]
  ! [ "$output" = "BASH-LOGIN" ]
}

@test "only the first line is read" {
  chosen_shell
  printf '%s\n/bin/not-a-shell\n' "$HOME/mysh" | { mkdir -p "$(dirname "$CONF")"; cat > "$CONF"; }
  run launch
  [ "$output" = "CHOSEN -l" ]
}

@test "a valid second line does not rescue an invalid first line" {
  chosen_shell
  printf 'relative/sh\n%s\n' "$HOME/mysh" | { mkdir -p "$(dirname "$CONF")"; cat > "$CONF"; }
  run --separate-stderr launch
  [ "$output" = "BASH-LOGIN" ]
  [[ "$stderr" == *"not-absolute"* ]]
}

# One refusal per row: the saved text, the token it must report. Each falls back to bash.
refused() {
  save "$1"
  run --separate-stderr launch
  [ "$status" -eq 0 ]
  [ "$output" = "BASH-LOGIN" ]
  [[ "$stderr" == *"saved login shell ignored ($2)"* ]]
}

@test "refuses: empty first line" { refused "" empty; }
@test "refuses: relative path" { refused "bin/sh" not-absolute; }
@test "refuses: a path that does not exist" { refused "$HOME/missing" not-a-regular-file; }
@test "refuses: a directory" { refused "$HOME" not-a-regular-file; }
@test "refuses: a file that is not executable" {
  printf '#!/bin/sh\n' > "$HOME/noexec"
  refused "$HOME/noexec" not-executable
}
@test "refuses: dot-dot components even when the target is fine" { refused "$HOME/../home/mysh" dot-dot; }
@test "refuses: an executable outside HOME and not in /etc/shells" { refused /bin/cat not-under-home-or-listed; }
@test "refuses: the launcher itself, also through a symlink under HOME" {
  ln -s /usr/local/bin/osio-login "$HOME/loop"
  refused "$HOME/loop" launcher-itself
  refused /usr/local/bin/osio-login launcher-itself
}
@test "refuses: control characters, without echoing them" {
  save "$(printf '%s/\033[31mx' "$HOME")"
  run --separate-stderr launch
  [ "$output" = "BASH-LOGIN" ]
  [[ "$stderr" == *"(control-character)"* ]]
  run ! grep -q "$(printf '\033')" <<<"$stderr"
}
@test "refuses: an oversized first line, without reading all of it" {
  mkdir -p "$(dirname "$CONF")"
  head -c 6000 /dev/zero | tr '\0' 'a' | sed "s|^|$HOME/|" > "$CONF"
  run --separate-stderr launch
  [ "$output" = "BASH-LOGIN" ]
  [[ "$stderr" == *"saved login shell ignored"* ]]
}

@test "never evaluates the saved text" {
  # Names that pass every check (regular, executable, under HOME) yet carry shell syntax: an
  # eval or sh -c anywhere between the file and the exec would run the touch in the cwd.
  cd "$BATS_TEST_TMPDIR"
  for name in 'x;touch pwned' 'y$(touch pwned)'; do
    printf '#!/bin/sh\necho "CHOSEN $*"\n' > "$HOME/$name"
    chmod 755 "$HOME/$name"
    save "$HOME/$name"
    run launch
    [ "$output" = "CHOSEN -l" ]
  done
  save '$(touch pwned)'
  run launch
  run ! test -e pwned
}

@test "chsh with no argument prints bash, then the saved choice" {
  run chsh
  [ "$output" = "/bin/bash" ]
  chosen_shell
  chsh -s "$HOME/mysh"
  run chsh
  [ "$output" = "$HOME/mysh" ]
}

@test "chsh -s writes the one-line file, atomically, leaving no temp file" {
  chosen_shell
  run chsh -s "$HOME/mysh"
  [ "$status" -eq 0 ]
  [ "$(cat "$CONF")" = "$HOME/mysh" ]
  [ "$(ls -A "$(dirname "$CONF")")" = "login-shell" ]
}

@test "chsh -s then the launcher starts that shell" {
  chosen_shell
  chsh -s "$HOME/mysh"
  run launch
  [ "$output" = "CHOSEN -l" ]
}

@test "chsh -s refuses what the launcher would refuse and writes nothing" {
  run -1 chsh -s /bin/cat
  [[ "$output" == *"not-under-home-or-listed"* ]]
  run -1 chsh -s relative
  run -1 chsh -s "$HOME/missing"
  run -1 chsh -s /usr/local/bin/osio-login
  run ! test -e "$CONF"
}

@test "chsh -s keeps the previous choice when the new one is refused" {
  chosen_shell
  chsh -s "$HOME/mysh"
  run -1 chsh -s /bin/cat
  [ "$(cat "$CONF")" = "$HOME/mysh" ]
}

@test "chsh refuses other arguments with status 2" {
  run -2 chsh -s
  run -2 chsh bash
  run -2 chsh -s /bin/sh extra
  run -2 chsh -l
}

@test "the safe shell still runs commands when ~/.bashrc and ~/.profile exit 1" {
  command -v bash >/dev/null || skip "needs bash"
  printf 'exit 1\n' > "$HOME/.bashrc"
  printf 'exit 1\n' > "$HOME/.profile"
  run bash -c 'echo "echo 42" | /bin/bash --noprofile --norc'
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
  # The same files do kill the shells that read them, so the 42 above is not vacuous.
  run bash -c 'echo "echo 42" | /bin/bash -l'
  [ -z "$output" ]
  run bash -c 'echo "echo 42" | /bin/bash -i 2>/dev/null'
  [ -z "$output" ]
}

@test "the sandbox image removes the setuid chsh and installs the shim" {
  run grep -E 'rm -f /usr/bin/chsh' "$SRC/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -E 'COPY osio-chsh.sh /usr/local/bin/chsh' "$SRC/Dockerfile"
  [ "$status" -eq 0 ]
}

# --- Identity (ADR 0009): OSIO_USER names the account in /tmp/.osio/passwd -----------------------

PASSWD=/tmp/.osio/passwd
IDENTITY_PROBE='echo "USER=$USER LOGNAME=$LOGNAME HOME=$HOME OSIO_USER=${OSIO_USER-unset}"; exit'

launch_as() { printf '%s\n' "$IDENTITY_PROBE" | OSIO_USER="$1" /usr/local/bin/osio-login; }
launch_plain() { printf '%s\n' "$IDENTITY_PROBE" | /usr/local/bin/osio-login; }

@test "a valid OSIO_USER renames only the coder line, giving it the box's uid, keeping gid, home and shell" {
  run --separate-stderr launch_as dylan
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(grep -c . "$PASSWD")" -eq "$(grep -c . /etc/passwd.base)" ]
  grep -qxF 'dylan:x:20042:10001::/home/coder:/bin/bash' "$PASSWD"
  run grep -q '^coder:' "$PASSWD"
  [ "$status" -ne 0 ]
  [ "$(grep -v '^dylan:' "$PASSWD")" = "$(grep -v '^coder:' /etc/passwd.base)" ]
  [ "$(stat -c %a "$PASSWD")" = 600 ]
}

@test "the shell gets USER and LOGNAME, keeps HOME untouched, and never sees OSIO_USER" {
  run launch_as dylan
  [ "$output" = "USER=dylan LOGNAME=dylan HOME=$HOME OSIO_USER=unset" ]
}

@test "an invalid or reserved OSIO_USER keeps the default file and names the reason" {
  local value reason
  while IFS='|' read -r value reason; do
    run --separate-stderr launch_as "$value"
    [ "$status" -eq 0 ] || { echo "shell did not start for [$value]"; return 1; }
    cmp -s "$PASSWD" /etc/passwd.base || { echo "file changed for [$value]"; return 1; }
    [[ "$stderr" == *"($reason)"* ]] || { echo "[$value]: stderr was [$stderr], wanted ($reason)"; return 1; }
  done <<'CASES'
x:0:0::/:|bad-character
../x|bad-character
Dylan|bad-character
a b|bad-character
$(touch /tmp/pwned-by-osio-user)|bad-character
9lives|bad-first-character
-rf|bad-first-character
root|reserved
daemon|reserved
coder|reserved
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|too-long
CASES
  [ ! -e /tmp/pwned-by-osio-user ]
}

@test "an embedded newline is rejected" {
  run --separate-stderr launch_as $'dylan\nroot'
  cmp -s "$PASSWD" /etc/passwd.base
  [[ "$stderr" == *"(bad-character)"* ]]
}

@test "an unset or empty OSIO_USER leaves the file alone, silently" {
  run --separate-stderr launch_plain
  [ -z "$stderr" ]
  cmp -s "$PASSWD" /etc/passwd.base
  run --separate-stderr launch_as ""
  [ -z "$stderr" ]
  cmp -s "$PASSWD" /etc/passwd.base
}

@test "a file that cannot be written does not stop the terminal" {
  rm -rf /tmp/.osio
  : > /tmp/.osio
  run --separate-stderr launch_as dylan
  [ "$status" -eq 0 ]
  [[ "$output" == *"OSIO_USER=unset"* ]]
  [[ "$output" != *"USER=dylan"* ]]
  [[ "$stderr" == *"account name not written"* ]]
  rm -f /tmp/.osio
}

@test "no temp file is left behind" {
  launch_as dylan >/dev/null
  [ "$(ls -A /tmp/.osio)" = "passwd" ]
}

@test "terminals opened at once never tear the file" {
  local n
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do launch_as "user$n" >/dev/null & done
  wait
  [ "$(grep -c . "$PASSWD")" -eq "$(grep -c . /etc/passwd.base)" ]
  grep -Eq '^user[0-9]+:x:20042:10001::/home/coder:/bin/bash$' "$PASSWD"
  [ "$(ls -A /tmp/.osio)" = "passwd" ]
}

@test "a failed rename removes its temp file and the terminal still starts" {
  rm -f "$PASSWD"
  mkdir -p "$PASSWD/occupied"
  run --separate-stderr launch_as dylan
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"account name not written"* ]]
  [ "$(ls -A /tmp/.osio)" = "passwd" ]
  rm -rf "$PASSWD"
}
