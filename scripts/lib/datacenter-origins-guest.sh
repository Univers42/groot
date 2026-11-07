# shellcheck shell=bash
# datacenter-origins-guest.sh — runs INSIDE the guest, with KEY=VALUE arguments, after envfile.sh:
# scripts/lib/datacenter-ports.sh pipes the three to `bash -s` because the guest's login shell is
# hellish, and it would glob /**. GROBASE_DIR exists for the tests.
#
# Both files, because `make env` assembles .env with .env.local last, so a key only in .env is lost
# at the next one, and compose reads .env. `make env` itself is not run: it would drop what hands
# left in .env (seven keys on baas, 2026-10-13).
# The services are recreated with the compose invocation they were created with, read back from
# their labels, because grobase's `make up` re-resolves every published port and moves the WAF.
#
# Caveat: a recreate from the labels has none of what `make up` passes on its command line. On a
# pro-tier guest it refused a required variable that was in no .env file (2026-10-08). The caller
# then stops, the files keep the origins, and the next make all tries again.
# Caveat: --wait-timeout 120 is an estimate, not measured on a VM. A start slower than that stops
# make all although the origins took, and the next run reads them in effect and goes on.
set -eu
umask 077
cd "${GROBASE_DIR:-/opt/grobase}"
label() { docker inspect mini-baas-kong -f "{{index .Config.Labels \"com.docker.compose.$1\"}}"; }
project=$(label project)
files=$(label project.config_files)
workdir=$(label project.working_dir)
if [ -z "$project" ] || [ -z "$files" ]; then
  printf 'mini-baas-kong carries no compose labels, so it cannot be recreated as it was created\n' >&2
  exit 1
fi
for pair in "$@"; do
  for file in .env .env.local; do
    [ ! -f "$file" ] || put_env "$file" "${pair%%=*}" "${pair#*=}"
  done
done
COMPOSE_FILE="$files" COMPOSE_PATH_SEPARATOR=, docker compose -p "$project" --project-directory "${workdir:-$PWD}" \
  up -d --no-build --wait --wait-timeout 120 --no-deps kong gotrue realtime
