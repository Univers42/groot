#!/bin/sh
# Runtime assertion for the IDE plane (devil K11/R1). Exit 0 when the isolated daemon's default
# runtime and a probe box's runtime both equal OSIONOS_IDE_REQUIRE_RUNTIME, 1 when either differs
# (the reason on stdout), 3 when the variable is unset (a skip: nothing is asserted, the plane
# behaves as before). Talks to whatever DOCKER_HOST names, so verify.sh points it at docker-ide.
#
# Usage: DOCKER_HOST=unix:///run/docker-ide.sock OSIONOS_IDE_REQUIRE_RUNTIME=runsc \
#          sh check-runtime.sh <probe-box-name>
#
# Caveat: this compares the runtime NAMES the daemon reports. A `runsc` entry in daemon.json that
# points at runc passes; only a probe inside a box (gVisor's own kernel strings) tells them apart,
# and that is not run here. An unreachable daemon or a missing box is a failure, never a pass.

required=${OSIONOS_IDE_REQUIRE_RUNTIME:-}
box=${1:-}
[ -n "$required" ] || { echo "OSIONOS_IDE_REQUIRE_RUNTIME is unset: no runtime asserted"; exit 3; }
[ -n "$box" ] || { echo "usage: check-runtime.sh <probe-box-name>"; exit 1; }

default=$(docker info --format '{{.DefaultRuntime}}' 2>/dev/null) || default=''
if [ "$default" != "$required" ]; then
  echo "daemon default runtime is '${default:-unknown}', the plane requires '$required'"
  exit 1
fi
actual=$(docker inspect --format '{{.HostConfig.Runtime}}' "$box" 2>/dev/null) || actual=''
if [ "$actual" != "$required" ]; then
  echo "probe box $box runs under '${actual:-unknown}', the plane requires '$required'"
  exit 1
fi
echo "default runtime and probe box both run under '$required'"
