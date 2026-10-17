#!/usr/bin/env bats
# The public-site deployment (ADR 0013, devil PUB-1..16): the compose file's shape, the
# scripts' syntax and lint, and the pieces that run offline (env-init.sh against a fake
# terminal, the serve-config diff against synthetic JSON, the argument guards). The VM, the
# funnel and the images are not exercised here; deploy.sh's own post-checks cover those.
# Each negative is proved by planting the violation on a copy and watching the check fail.
#
# Run: docker run --rm -v "$PWD:/code" -v /goinfre/dlesieur/groot/.git:/goinfre/dlesieur/groot/.git:ro \
#        -w /code --entrypoint sh bats/bats:1.11.1 -c 'apk add -q --no-cache make coreutils \
#        findutils git jq shellcheck docker-cli docker-cli-compose && bats scripts/tests/public-b2b.bats'
# Compose rendering skips when `docker compose` is missing; shellcheck falls back to the
# koalaman/shellcheck image when a docker daemon answers, and skips otherwise.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/../.."
  COMPOSE="$ROOT/infrastructure/compose/public-b2b.yml"
  SCRIPTS="$ROOT/scripts/public-b2b"
  W="$BATS_TEST_TMPDIR"
}

# Renders the compose file with throwaway inputs, from a cwd outside the repo and with an
# explicit --env-file, so neither the user's ./.env nor a real secret can be read.
render() { # compose-file -> JSON on stdout
  mkdir -p "$W/render" && printf 'SENTINEL_FROM_ENV_FILE=1\n' > "$W/render/secrets.env"
  printf 'PUBLIC_SITE_IMAGE=prismatica-public/site:test0000000a\nPUBLIC_GATEWAY_IMAGE=prismatica-public/auth-gateway:test0000000a\nPUBLIC_ENV_FILE=%s\n' \
    "$W/render/secrets.env" > "$W/render/images.env"
  (cd "$W/render" && docker compose --env-file images.env -f "$1" -p prismatica-public config --format json)
}

need_compose() {
  docker compose version > /dev/null 2>&1 || skip "docker compose is not installed in this runner (apk add docker-cli-compose)"
}

good_json() {
  need_compose
  render "$COMPOSE" > "$W/good.json"
}

prop() { jq -e "$2" "$1" > /dev/null; } # json-file jq-program

# The program ran and answered false/null (jq exit 1). A typo in a planted edit makes jq exit
# 2 or 5, or hands it an empty file name, and must not count as "the check caught it".
refuses() {
  local status=0
  jq -e "$2" "$1" > /dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ]
}

mutate() { jq "$2" "$1" > "$W/mutated.json" && echo "$W/mutated.json"; } # json-file jq-edit

# One program per property; each test runs it on the good render, then on a planted violation.
P_NO_BUILD='[.services[] | has("build")] | any | not'
P_TAGGED='[.services[].image] | all(test(":[^/:]+$") and (endswith(":latest") | not))'
P_LOOPBACK_ONLY='([.services | to_entries[] | select(.value.ports) | .key] == ["public-site"]) and ([.services["public-site"].ports[] | .host_ip] | all(. == "127.0.0.1"))'
P_HOPS='.services["public-auth-gateway"].environment.AUTH_TRUSTED_PROXY_HOPS == "2"'
P_BYPASS='.services["public-auth-gateway"].environment.TURNSTILE_BYPASS_LOCAL == "false"'
P_VERIFY='.services["public-auth-gateway"].environment | (.AUTH_REQUIRE_EMAIL_VERIFICATION == "true" and .PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION == "true")'
P_NO_DEMO='[.services[].environment // {} | has("AUTH_DEMO_INSECURE")] | any | not'
P_WAF='.services["public-site"].environment.OO_BAAS_UPSTREAM == "http://mini-baas-waf:80"'
P_OWN_REDIS='.services["public-auth-gateway"].environment.REDIS_URL == "redis://public-redis:6379"'
P_EXTERNAL_NET='.networks["mini-baas"] | (.external == true and .name == "mini-baas_mini-baas")'
P_KONG='.services["public-auth-gateway"].environment.PUBLIC_BAAS_URL == "http://mini-baas-kong:8000"'
P_NO_BRIDGE_SECRET='.services["public-auth-gateway"].environment.OSIONOS_BRIDGE_SHARED_SECRET == ""'
P_REDIS_UNREACHABLE_FROM_PROD='.services["public-redis"].networks | keys == ["default"]'

@test "compose file parses with throwaway inputs and is project prismatica-public" {
  good_json
  prop "$W/good.json" '.name == "prismatica-public"'
  prop "$W/good.json" '(.services | keys) == ["public-auth-gateway","public-redis","public-site"]'
}

@test "image tags are required: rendering without them fails" {
  need_compose
  mkdir -p "$W/bare" && : > "$W/bare/empty.env"
  run bash -c "cd '$W/bare' && docker compose --env-file empty.env -f '$COMPOSE' -p prismatica-public config -q 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PUBLIC_"*"_IMAGE"* ]]
}

@test "no service has a build: section (PUB-6)" {
  good_json
  prop "$W/good.json" "$P_NO_BUILD"
  refuses "$(mutate "$W/good.json" '.services["public-site"].build = {context: "."}')" "$P_NO_BUILD"
}

@test "no image is :latest or untagged (PUB-6)" {
  good_json
  prop "$W/good.json" "$P_TAGGED"
  refuses "$(mutate "$W/good.json" '.services["public-redis"].image = "redis:latest"')" "$P_TAGGED"
  refuses "$(mutate "$W/good.json" '.services["public-site"].image = "prismatica-public/site"')" "$P_TAGGED"
}

@test "the only published port is the site's, on 127.0.0.1 (PUB-5)" {
  good_json
  prop "$W/good.json" "$P_LOOPBACK_ONLY"
  refuses "$(mutate "$W/good.json" '.services["public-site"].ports[0].host_ip = "0.0.0.0"')" "$P_LOOPBACK_ONLY"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].ports = [{host_ip:"127.0.0.1",target:8787,published:"8787"}]')" "$P_LOOPBACK_ONLY"
  refuses "$(mutate "$W/good.json" '.services["public-redis"].ports = [{host_ip:"127.0.0.1",target:6379,published:"6379"}]')" "$P_LOOPBACK_ONLY"
}

@test "the gateway trusts 2 proxy hops (PUB-1), also when the source file is edited" {
  good_json
  prop "$W/good.json" "$P_HOPS"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.AUTH_TRUSTED_PROXY_HOPS = "1"')" "$P_HOPS"
  sed 's/AUTH_TRUSTED_PROXY_HOPS: 2/AUTH_TRUSTED_PROXY_HOPS: 1/' "$COMPOSE" > "$W/planted.yml"
  run ! cmp -s "$COMPOSE" "$W/planted.yml"
  render "$W/planted.yml" > "$W/planted.json"
  refuses "$W/planted.json" "$P_HOPS"
}

@test "Turnstile is not bypassed, verification is on, AUTH_DEMO_INSECURE is absent (PUB-8)" {
  good_json
  prop "$W/good.json" "$P_BYPASS"
  prop "$W/good.json" "$P_VERIFY"
  prop "$W/good.json" "$P_NO_DEMO"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.TURNSTILE_BYPASS_LOCAL = "true"')" "$P_BYPASS"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.AUTH_REQUIRE_EMAIL_VERIFICATION = "false"')" "$P_VERIFY"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION = "false"')" "$P_VERIFY"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.AUTH_DEMO_INSECURE = "true"')" "$P_NO_DEMO"
}

@test "the site's /api upstream is the WAF, not Kong (PUB-2)" {
  good_json
  prop "$W/good.json" "$P_WAF"
  refuses "$(mutate "$W/good.json" '.services["public-site"].environment.OO_BAAS_UPSTREAM = "http://mini-baas-kong:8000"')" "$P_WAF"
}

@test "the gateway uses its own redis, never mini-baas-redis (PUB-4)" {
  good_json
  prop "$W/good.json" "$P_OWN_REDIS"
  prop "$W/good.json" "$P_REDIS_UNREACHABLE_FROM_PROD"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.REDIS_URL = "redis://mini-baas-redis:6379"')" "$P_OWN_REDIS"
  refuses "$(mutate "$W/good.json" '.services["public-redis"].networks["mini-baas"] = null')" "$P_REDIS_UNREACHABLE_FROM_PROD"
}

@test "mini-baas_mini-baas is external and mail goes to Kong with no bridge secret (PUB-5, PUB-11)" {
  good_json
  prop "$W/good.json" "$P_EXTERNAL_NET"
  prop "$W/good.json" "$P_KONG"
  prop "$W/good.json" "$P_NO_BRIDGE_SECRET"
  refuses "$(mutate "$W/good.json" '.networks["mini-baas"].external = false')" "$P_EXTERNAL_NET"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.PUBLIC_BAAS_URL = "http://mini-baas-waf:80"')" "$P_KONG"
  refuses "$(mutate "$W/good.json" '.services["public-auth-gateway"].environment.OSIONOS_BRIDGE_SHARED_SECRET = "x"')" "$P_NO_BRIDGE_SECRET"
}

@test "the new gateway switches are wired" {
  good_json
  prop "$W/good.json" '.services["public-auth-gateway"].environment | (.AUTH_LOGIN_EMAIL_OTP == "true" and .AUTH_LOGIN_APPROVE_LINK == "true" and .AUTH_MAIL_DAILY_CAP == "200")'
  prop "$W/good.json" '.services["public-auth-gateway"].environment.SENTINEL_FROM_ENV_FILE == "1"'
}

@test "a missing secrets file stops compose instead of starting a gateway without keys" {
  need_compose
  good_json
  rm "$W/render/secrets.env"
  run bash -c "cd '$W/render' && docker compose --env-file images.env -f '$COMPOSE' -p prismatica-public config -q 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets.env"* ]]
}

@test "text guard: the file itself holds no build: and no :latest (PUB-6)" {
  run ! grep -nE '^[[:space:]]+build:' "$COMPOSE"
  run ! grep -n ':latest' "$COMPOSE"
  printf '    build:\n      context: .\n' > "$W/plant.yml"
  run grep -nE '^[[:space:]]+build:' "$W/plant.yml"
  [ "$status" -eq 0 ]
}

check_no_mini_baas_writes() { # file: every `-p mini-baas` use must be a read-only `ps`
  ! grep -nE -e '-p mini-baas( |$)' "$1" | grep -vE -e '-p mini-baas ps ' | grep -q .
}

@test "scripts only read mini-baas, and never reset the serve config (PUB-9, PUB-10)" {
  for f in deploy.sh rollback.sh build-images.sh lib.sh env-init.sh; do
    check_no_mini_baas_writes "$SCRIPTS/$f"
  done
  run ! grep -hE '^[^#]*tailscale serve reset' "$SCRIPTS"/*.sh
  printf 'docker compose -p mini-baas up -d waf\n' > "$W/plant.sh"
  run ! check_no_mini_baas_writes "$W/plant.sh"
  printf 'tailscale serve reset\n' > "$W/plant2.sh"
  run grep -hE '^[^#]*tailscale serve reset' "$W/plant2.sh"
  [ "$status" -eq 0 ]
}

@test "every script passes bash -n" {
  for f in "$SCRIPTS"/*.sh; do bash -n "$f"; done
  printf 'if then\n' > "$W/broken.sh"
  run ! bash -n "$W/broken.sh"
}

@test "every script passes shellcheck" {
  if command -v shellcheck > /dev/null; then
    run shellcheck -x -P SCRIPTDIR "$SCRIPTS"/*.sh
  elif docker info > /dev/null 2>&1; then
    run docker run --rm -v "$ROOT:/mnt" -w /mnt koalaman/shellcheck:stable -x -P SCRIPTDIR scripts/public-b2b/lib.sh scripts/public-b2b/deploy.sh scripts/public-b2b/rollback.sh scripts/public-b2b/build-images.sh scripts/public-b2b/env-init.sh
  else
    skip "no shellcheck binary and no docker daemon in this runner"
  fi
  [ "$status" -eq 0 ]
}

@test "deploy.sh and build-images.sh refuse a missing argument" {
  run bash "$SCRIPTS/deploy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: deploy.sh"* ]]
  run bash "$SCRIPTS/build-images.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: build-images.sh"* ]]
}

@test "build-images.sh refuses a dirty worktree before building" {
  mkdir -p "$W/oo/docker/services/web"
  : > "$W/oo/docker/services/web/Dockerfile"
  git -C "$W/oo" init -q
  git -C "$W/oo" -c user.name=t -c user.email=t@t add -A
  git -C "$W/oo" -c user.name=t -c user.email=t@t commit -q -m init
  : > "$W/oo/uncommitted"
  run bash "$SCRIPTS/build-images.sh" "$W/oo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "build-images.sh refuses missing build inputs" {
  mkdir -p "$W/oo/docker/services/web"
  : > "$W/oo/docker/services/web/Dockerfile"
  git -C "$W/oo" init -q
  git -C "$W/oo" -c user.name=t -c user.email=t@t add -A
  git -C "$W/oo" -c user.name=t -c user.email=t@t commit -q -m init
  printf 'PUBLIC_BAAS_ANON_KEY=a\n' > "$W/build.env"
  PUBLIC_BUILD_ENV_FILE="$W/build.env" run bash "$SCRIPTS/build-images.sh" "$W/oo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PUBLIC_TURNSTILE_SITE_KEY missing"* ]]
}

# Serve-config diff (PUB-9, PUB-13) against synthetic JSON, with bash standing in for ssh.
serve_fixtures() {
  cat > "$W/before.json" << 'JSON'
{"TCP":{"443":{"HTTPS":true}},"Web":{"baas.tail10f2ea.ts.net:443":{"Handlers":{"/":{"Proxy":"https+insecure://127.0.0.1:8443"}}},"dlesieur42-1-1.tail10f2ea.ts.net:443":{"Handlers":{"/":{"Proxy":"https+insecure://127.0.0.1:8443"}}}},"AllowFunnel":{"baas.tail10f2ea.ts.net:443":true,"dlesieur42-1-1.tail10f2ea.ts.net:443":true}}
JSON
  jq '.TCP["10000"]={"HTTPS":true}
    | .Web["baas.tail10f2ea.ts.net:10000"]={"Handlers":{"/":{"Proxy":"http://127.0.0.1:10080"}}}
    | .AllowFunnel["baas.tail10f2ea.ts.net:10000"]=true' "$W/before.json" > "$W/after.json"
}

@test "serve diff accepts exactly the three :10000 keys" {
  serve_fixtures
  . "$SCRIPTS/lib.sh"
  B2B=(bash -c)
  serve_adds_only_funnel_keys "$W/before.json" "$W/after.json"
}

@test "serve diff rejects a changed :443 host, a missing AllowFunnel, and no change" {
  serve_fixtures
  . "$SCRIPTS/lib.sh"
  B2B=(bash -c)
  jq '.Web["baas.tail10f2ea.ts.net:443"].Handlers["/"].Proxy = "http://elsewhere"' "$W/after.json" > "$W/moved.json"
  jq 'del(.AllowFunnel["baas.tail10f2ea.ts.net:10000"])' "$W/after.json" > "$W/closed.json"
  jq '.Web["extra.example:443"] = {}' "$W/after.json" > "$W/extra.json"
  run ! serve_adds_only_funnel_keys "$W/before.json" "$W/moved.json"
  run ! serve_adds_only_funnel_keys "$W/before.json" "$W/closed.json"
  run ! serve_adds_only_funnel_keys "$W/before.json" "$W/extra.json"
  run ! serve_adds_only_funnel_keys "$W/before.json" "$W/before.json"
}

@test "serve_equal passes only for an identical config (rollback)" {
  serve_fixtures
  . "$SCRIPTS/lib.sh"
  B2B=(bash -c)
  serve_equal "$W/before.json" "$W/before.json"
  run ! serve_equal "$W/before.json" "$W/after.json"
}

# env-init.sh with a fake terminal (fd 3 reads a file) and a scratch directory.
run_env_init() { # tty-file
  PRISMATICA_PUBLIC_DIR="$W/vm" GROBASE_ENV_FILE="$W/grobase.env" PRISMATICA_TTY="$1" bash "$SCRIPTS/env-init.sh"
}

env_init_setup() {
  mkdir -p "$W/vm"
  printf 'ANON_KEY="anon-secret-1"\nSERVICE_ROLE_KEY=service-secret-1\n' > "$W/grobase.env"
}

@test "env-init writes a mode-600 file, prints names only, and mints the link key once" {
  env_init_setup
  printf 'turnstile-secret-1\nwork.example,a@b.example\n' > "$W/tty"
  run run_env_init "$W/tty"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$W/vm/.env")" = 600 ]
  for name in SERVICE_ROLE_KEY PUBLIC_BAAS_ANON_KEY AUTH_LINK_SIGNING_KEY TURNSTILE_SECRET_KEY AUTH_SIGNUP_ALLOWLIST; do
    [[ "$output" == *"$name set"* ]]
  done
  grep -q '^PUBLIC_BAAS_ANON_KEY=anon-secret-1$' "$W/vm/.env"
  grep -q '^SERVICE_ROLE_KEY=service-secret-1$' "$W/vm/.env"
  # positive control for the leak check below: the secret really is in the file
  grep -qF turnstile-secret-1 "$W/vm/.env"
  run ! grep -E 'anon-secret-1|service-secret-1|turnstile-secret-1' <<< "$output"
  link_key=$(sed -n 's/^AUTH_LINK_SIGNING_KEY=//p' "$W/vm/.env")
  [ "${#link_key}" -ge 64 ]
  printf '\n\n' > "$W/tty2"
  run_env_init "$W/tty2" > /dev/null 2>&1
  [ "$(sed -n 's/^AUTH_LINK_SIGNING_KEY=//p' "$W/vm/.env")" = "$link_key" ]
  grep -qF turnstile-secret-1 "$W/vm/.env"
  [ "$(stat -c %a "$W/vm/.env")" = 600 ]
}

@test "env-init refuses an empty allowlist, an unsafe value, and AUTH_DEMO_INSECURE" {
  env_init_setup
  printf 'turnstile-secret-1\n\n' > "$W/tty"
  run run_env_init "$W/tty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AUTH_SIGNUP_ALLOWLIST is required"* ]]
  printf 'has$dollar\nx@y.example\n' > "$W/tty"
  run run_env_init "$W/tty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"compose would mangle it"* ]]
  printf 'AUTH_DEMO_INSECURE=true\n' >> "$W/vm/.env"
  printf 'turnstile-secret-1\nx@y.example\n' > "$W/tty"
  run run_env_init "$W/tty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AUTH_DEMO_INSECURE is in"* ]]
}
