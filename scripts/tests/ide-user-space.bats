#!/usr/bin/env bats
# The sandbox image's login defaults (user-space.profile.sh -> /etc/profile.d/10-user-space.sh)
# and micromamba's system rc (conda.condarc). Two layers: the files alone, always; and the
# built image under the box's real flags, only when IDE_SANDBOX_IMAGE names one.
#
# Caveat: the image layer needs a docker CLI and daemon, which the stock bats image lacks, so
# it is skipped (not passed) without IDE_SANDBOX_IMAGE. The file layer cannot see wiring
# (a COPY that is missing from the Dockerfile); the image layer can.
#
# Run (files only): docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#   -c 'apk add -q --no-cache bash && bats scripts/tests/ide-user-space.bats'
# Run (with image): same, plus -v "$XDG_RUNTIME_DIR/docker.sock:/var/run/docker.sock" -e
#   IDE_SANDBOX_IMAGE=osionos-ide-sandbox:c1-test, and `apk add docker-cli` in the -c string.

bats_require_minimum_version 1.5.0

SRC="$BATS_TEST_DIRNAME/../../infrastructure/docker/osionos/ide-sandbox"

# A login shell's view: a clean environment, the profile sourced the way /etc/profile does.
login_env() {
  env -i HOME=/home/box PATH=/usr/bin:/bin "$@" bash --noprofile --norc -c ". '$SRC/user-space.profile.sh'; $PROBE"
}

setup() { PROBE='env | sort; echo "PATH_IS=$PATH"'; }

@test "~/.local/bin leads PATH, then cargo and go bins, then the system PATH" {
  run login_env
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH_IS=/home/box/.local/bin:/home/box/.cargo/bin:/home/box/go/bin:/usr/bin:/bin"* ]]
}

@test "every toolchain default points under HOME" {
  run login_env
  [[ "$output" == *"NPM_CONFIG_PREFIX=/home/box/.local"* ]]
  [[ "$output" == *"PYTHONUSERBASE=/home/box/.local"* ]]
  [[ "$output" == *"PIP_BREAK_SYSTEM_PACKAGES=1"* ]]
  [[ "$output" == *"GOPATH=/home/box/go"* ]]
  [[ "$output" == *"CARGO_HOME=/home/box/.cargo"* ]]
  [[ "$output" == *"RUSTUP_HOME=/home/box/.rustup"* ]]
  [[ "$output" == *"MAMBA_ROOT_PREFIX=/home/box/micromamba"* ]]
}

@test "locale defaults to C.UTF-8" {
  run login_env
  [[ "$output" == *"LANG=C.UTF-8"* && "$output" == *"LC_ALL=C.UTF-8"* ]]
}

@test "PIP_USER stays unset (it breaks pip inside a virtualenv)" {
  run login_env
  run ! grep -q '^PIP_USER=' <<< "$output"
}

@test "a value the user already exports wins" {
  run login_env GOPATH=/work/go LANG=fr_FR.UTF-8
  [[ "$output" == *"GOPATH=/work/go"* && "$output" == *"LANG=fr_FR.UTF-8"* ]]
  [[ "$output" == *"PATH_IS=/home/box/.local/bin:/home/box/.cargo/bin:/work/go/bin:"* ]]
}

@test "sourcing twice does not duplicate PATH entries" {
  PROBE=". '$SRC/user-space.profile.sh'; echo \"PATH_IS=\$PATH\""
  run login_env
  [ "$output" = "PATH_IS=/home/box/.local/bin:/home/box/.cargo/bin:/home/box/go/bin:/usr/bin:/bin" ]
}

@test "no HOME: PATH and tool variables are left alone, locale still set" {
  run env -i PATH=/usr/bin:/bin bash --noprofile --norc -c ". '$SRC/user-space.profile.sh'; env | sort; echo \"PATH_IS=\$PATH\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH_IS=/usr/bin:/bin"* && "$output" == *"LC_ALL=C.UTF-8"* ]]
  run ! grep -q 'GOPATH=' <<< "$output"
}

@test "the profile script leaves no helper function behind" {
  PROBE='declare -F osio_prepend_path'
  run ! login_env
}

@test "micromamba's only default channel is conda-forge, never Anaconda defaults" {
  grep -qx '  - conda-forge' "$SRC/conda.condarc"
  grep -qx '  - https://conda.anaconda.org/conda-forge' "$SRC/conda.condarc"
  run ! grep -Eiq '^[[:space:]]*-[[:space:]]*(defaults|main|r|anaconda)[[:space:]]*$|repo\.anaconda\.com' "$SRC/conda.condarc"
}

@test "the Dockerfile installs both files root-owned and not group/other writable" {
  grep -q 'COPY user-space.profile.sh /etc/profile.d/10-user-space.sh' "$SRC/Dockerfile"
  grep -q 'COPY conda.condarc /etc/conda/.condarc' "$SRC/Dockerfile"
  grep -q 'chmod 0644 /etc/profile.d/10-user-space.sh /etc/conda/.condarc' "$SRC/Dockerfile"
}

# --- the built image, under the box's real flags -------------------------------------------

box() {
  docker run --rm --name "buildC-$BATS_TEST_NUMBER-$$" --read-only \
    --tmpfs /tmp:exec,size=64m,mode=1777 --tmpfs /home/coder:exec,size=64m,uid=10001,gid=10001 \
    -e HOME=/home/coder --user 10001:10001 --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint bash "$IDE_SANDBOX_IMAGE" "$@"
}

image_required() {
  [ -n "${IDE_SANDBOX_IMAGE:-}" ] || skip "IDE_SANDBOX_IMAGE not set"
  command -v docker > /dev/null || skip "no docker CLI"
}

@test "image: a login shell sees every default" {
  image_required
  run box -l -c 'echo "$PATH"; for v in NPM_CONFIG_PREFIX PYTHONUSERBASE PIP_BREAK_SYSTEM_PACKAGES GOPATH CARGO_HOME RUSTUP_HOME MAMBA_ROOT_PREFIX LANG LC_ALL; do printf "%s=%s\n" $v "${!v}"; done'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == /home/coder/.local/bin:/home/coder/.cargo/bin:/home/coder/go/bin:* ]]
  [[ "$output" == *"NPM_CONFIG_PREFIX=/home/coder/.local"* ]]
  [[ "$output" == *"GOPATH=/home/coder/go"* && "$output" == *"CARGO_HOME=/home/coder/.cargo"* ]]
  [[ "$output" == *"RUSTUP_HOME=/home/coder/.rustup"* && "$output" == *"MAMBA_ROOT_PREFIX=/home/coder/micromamba"* ]]
  [[ "$output" == *"LC_ALL=C.UTF-8"* && "$output" == *"PIP_BREAK_SYSTEM_PACKAGES=1"* ]]
}

@test "image: the safe shell (--noprofile --norc) sees none of them" {
  image_required
  run box --noprofile --norc -c 'echo "$PATH"; env'
  [ "$status" -eq 0 ]
  run ! grep -Eq 'NPM_CONFIG_PREFIX|PYTHONUSERBASE|PIP_BREAK|^GOPATH|CARGO_HOME|RUSTUP_HOME|MAMBA_ROOT|/home/coder/\.local' <<< "$output"
}

@test "image: tmux, less and man are present and man finds a page" {
  image_required
  run box --noprofile --norc -c 'command -v tmux less man && man -w ls'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/share/man/man1/ls.1.gz" ]]
}

@test "image: /etc stays unwritable and the defaults files are root-owned 0644" {
  image_required
  run ! box --noprofile --norc -c 'touch /etc/profile.d/x'
  run box --noprofile --norc -c 'stat -c "%u %a" /etc/profile.d/10-user-space.sh /etc/conda/.condarc; : > /etc/profile.d/10-user-space.sh'
  [ "$status" -ne 0 ]
  [ "${lines[0]}" = "0 644" ] && [ "${lines[1]}" = "0 644" ]
}

@test "image: pip install falls back to a user install instead of failing on PEP 668" {
  image_required
  run box -l -c 'pip install --no-input six 2>&1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Defaulting to user installation"* ]]
}
