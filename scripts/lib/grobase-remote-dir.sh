# shellcheck shell=bash
# grobase-remote-dir.sh — where a remote machine's grobase lives, asked of grobase itself rather
# than assumed: the compose working directory its Kong was started from. Sourced by
# scripts/grobase-link.sh; define-only. Tested alone by scripts/tests/grobase-remote-dir.bats.

# remote_grobase_dir RUN... — RUN is how to execute one shell command on the target (`mux x`).
# Prints that directory, or born2root's install path /opt/grobase when it cannot be read. Only a
# plain absolute path is taken: callers splice it into remote commands.
# Caveat: a Kong that is down, or that was started without compose, yields /opt/grobase; a
# grobase elsewhere then needs GROBASE_REMOTE_DIR, and the error that follows names it.
remote_grobase_dir() {
  local dir
  dir=$("$@" "docker inspect -f '{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}' mini-baas-kong" 2>/dev/null) || dir=""
  [[ "$dir" =~ ^/[A-Za-z0-9._/-]+$ ]] || dir=/opt/grobase
  printf '%s\n' "$dir"
}
