#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# gen-local-env.sh derives eight BaaS keys in ./.env.local from apps/grobase/.env. When
# that source changes under an existing .env.local (vault pull, JWT rotation, LOCAL-mode
# regeneration) the frontends and `make healthcheck` present a key Kong no longer knows.
# `--check` must name the drifted KEYS (never a value) and `--sync` must rewrite only
# those keys, in place, leaving minted secrets, hand edits and comments alone. These
# tests use synthetic files only — no real env file is read.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/gen-local-env.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../gen-local-env.sh"
  export GRO_ENV="$BATS_TEST_TMPDIR/grobase.env"
  export OUT="$BATS_TEST_TMPDIR/local.env"
  export MEDIA_ENV="$BATS_TEST_TMPDIR/osionos-app.env"
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\nADAPTER_REGISTRY_SERVICE_TOKEN=adapter-A\n' > "$GRO_ENV"
  cat > "$OUT" <<'LOCAL'
# header comment stays
JWT_SECRET=jwt-A
ANON_KEY=anon-A
SERVICE_ROLE_KEY=svc-A
KONG_PUBLIC_API_KEY=anon-A
KONG_SERVICE_API_KEY=svc-A
SB_KONG_KEY=anon-A
VITE_BAAS_KONG_KEY=anon-A
ADAPTER_REGISTRY_SERVICE_TOKEN=adapter-A
VITE_BAAS_REALTIME_TOKEN=rt-tenant-token
OSIONOS_BRIDGE_EMAIL_HASH_SALT=salt-keep
DEMO_LOGIN_PASSWORD=demo-keep
OSIONOS_IDE_TOKEN_SECRET=ide-secret-keep
AUTH_LINK_SIGNING_KEY=link-key-keep
VITE_BAAS_URL=https://localhost:3001
OSIONOS_ALLOWED_ORIGIN=https://localhost:3001
OSIONOS_APP_URL=https://localhost:3001
PUBLIC_OSIONOS_APP_URL=https://localhost:3001
LOCAL
  chmod 600 "$OUT"
  # openssl stub: minting needs randomness, not a real binary (the CI bats image has none).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0\\n"\n' > "$BATS_TEST_TMPDIR/bin/openssl"
  chmod +x "$BATS_TEST_TMPDIR/bin/openssl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

val() { sed -n "s/^$2=//p" "$1" | head -1; }
stale_kong() { sed -i 's/^SB_KONG_KEY=.*/SB_KONG_KEY=anon-OLD/' "$OUT"; }

@test "--check: in sync exits 0 and prints no value" {
  run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
  [[ "$output" != *"anon-A"* ]]
}

@test "--check: a stale SB_KONG_KEY exits 1 and names the key, not the value" {
  stale_kong
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift SB_KONG_KEY"* ]]
  [[ "$output" == *"--sync"* ]]
  [[ "$output" != *"anon-OLD"* ]]
  [[ "$output" != *"anon-A"* ]]
}

@test "--check: absent .env.local exits 1" {
  rm "$OUT"
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
}

@test "--sync: rewrites only the drifted key, in place, every other line untouched" {
  stale_kong
  before_lines=$(wc -l < "$OUT")
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "anon-A" ]
  [ "$(val "$OUT" OSIONOS_BRIDGE_EMAIL_HASH_SALT)" = "salt-keep" ]
  [ "$(wc -l < "$OUT")" -eq "$before_lines" ]
  [ "$(sed -n '1p' "$OUT")" = "# header comment stays" ]
  [ "$(sed -n '7p' "$OUT")" = "SB_KONG_KEY=anon-A" ]
  [ "$(stat -c %a "$OUT")" = "600" ]
  [[ "$output" == *"SB_KONG_KEY"* ]]
  [[ "$output" != *"anon-A"* ]]
  run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
}

@test "--sync: in sync writes nothing and exits 0" {
  before=$(cat "$OUT")
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to write"* ]]
  [ "$(cat "$OUT")" = "$before" ]
}

@test "--sync: a missing derived key is appended" {
  sed -i '/^KONG_PUBLIC_API_KEY=/d' "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$OUT")" = "KONG_PUBLIC_API_KEY=anon-A" ]
}

@test "--sync: never writes an empty source value, still fixes what it can, exits 1" {
  sed -i '/^ADAPTER_REGISTRY_SERVICE_TOKEN=/d' "$GRO_ENV"
  stale_kong
  run bash "$SCRIPT" --sync
  [ "$status" -eq 1 ]
  [ "$(val "$OUT" ADAPTER_REGISTRY_SERVICE_TOKEN)" = "adapter-A" ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "anon-A" ]
  [[ "$output" == *"ADAPTER_REGISTRY_SERVICE_TOKEN"* ]]
}

@test "--sync: after a JWT rotation every derived key follows apps/grobase/.env" {
  printf 'JWT_SECRET=jwt-B\nANON_KEY=anon-B\nSERVICE_ROLE_KEY=svc-B\nADAPTER_REGISTRY_SERVICE_TOKEN=adapter-B\n' > "$GRO_ENV"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" JWT_SECRET)" = "jwt-B" ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "anon-B" ]
  [ "$(val "$OUT" KONG_SERVICE_API_KEY)" = "svc-B" ]
  [ "$(val "$OUT" OSIONOS_BRIDGE_EMAIL_HASH_SALT)" = "salt-keep" ]
  [ "$(val "$OUT" VITE_BAAS_REALTIME_TOKEN)" = "rt-tenant-token" ]
}

@test "--sync: a value containing '=' survives intact" {
  sed -i 's/^ANON_KEY=.*/ANON_KEY=abc=def==/' "$GRO_ENV"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "abc=def==" ]
}

@test "no flag: an existing .env.local is left exactly as found" {
  stale_kong
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "anon-OLD" ]
}

@test "unknown flag exits 2" {
  run bash "$SCRIPT" --frobnicate
  [ "$status" -eq 2 ]
}

@test "--sync: an owner-published team block is left untouched" {
  stale_kong
  printf '\n# --- team values from the shared environment (vault42 prod) ---\nVITE_BAAS_REALTIME_TOKEN=owner-rt\nOSIONOS_BRIDGE_EMAIL_HASH_SALT=owner-salt\nOSIONOS_BAAS_API_KEY=mbk_owner\n' >> "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "anon-A" ]
  [ "$(tail -3 "$OUT" | head -1)" = "VITE_BAAS_REALTIME_TOKEN=owner-rt" ]
  [ "$(tail -1 "$OUT")" = "OSIONOS_BAAS_API_KEY=mbk_owner" ]
}

@test "a duplicated source key resolves to the LATER value (assemble-env: later wins)" {
  printf 'ANON_KEY=anon-LATER\n' >> "$GRO_ENV"
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" ANON_KEY)" = "anon-LATER" ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "anon-LATER" ]
}

@test "--sync: SB_KONG_KEY follows what Kong runs (KONG_PUBLIC_API_KEY) before ANON_KEY" {
  printf 'KONG_PUBLIC_API_KEY=kong-K\n' >> "$GRO_ENV"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" SB_KONG_KEY)" = "kong-K" ]
  [ "$(val "$OUT" KONG_PUBLIC_API_KEY)" = "kong-K" ]
  [ "$(val "$OUT" ANON_KEY)" = "anon-A" ]
}

@test "--sync: an .env.local without DEMO_LOGIN_PASSWORD gets one minted, named, never printed" {
  sed -i '/^DEMO_LOGIN_PASSWORD=/d' "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"minted DEMO_LOGIN_PASSWORD"* ]]
  minted="$(val "$OUT" DEMO_LOGIN_PASSWORD)"
  [[ "$minted" =~ ^[A-Za-z0-9]{24}$ ]]
  [[ "$output" != *"$minted"* ]]
  [ "$(val "$OUT" OSIONOS_BRIDGE_EMAIL_HASH_SALT)" = salt-keep ]
}

@test "--sync: an EMPTY DEMO_LOGIN_PASSWORD is replaced, not kept" {
  sed -i 's/^DEMO_LOGIN_PASSWORD=.*/DEMO_LOGIN_PASSWORD=/' "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ -n "$(val "$OUT" DEMO_LOGIN_PASSWORD)" ]
  [ "$(grep -c '^DEMO_LOGIN_PASSWORD=' "$OUT")" -eq 1 ]
}

@test "--sync: an existing DEMO_LOGIN_PASSWORD is never re-minted" {
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" DEMO_LOGIN_PASSWORD)" = demo-keep ]
}

@test "--check: a missing DEMO_LOGIN_PASSWORD exits 1 and names it" {
  sed -i '/^DEMO_LOGIN_PASSWORD=/d' "$OUT"
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing DEMO_LOGIN_PASSWORD"* ]]
}

@test "generate: a fresh .env.local carries a 24-char DEMO_LOGIN_PASSWORD" {
  rm -f "$OUT"
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\n' > "$GRO_ENV"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(val "$OUT" DEMO_LOGIN_PASSWORD)" =~ ^[A-Za-z0-9]{24}$ ]]
}

@test "--sync: an .env.local without OSIONOS_IDE_TOKEN_SECRET gets one minted, named, never printed" {
  sed -i '/^OSIONOS_IDE_TOKEN_SECRET=/d' "$OUT"
  printf 'OSIONOS_APP_SESSION_SECRET=app-secret-keep\n' >> "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"minted OSIONOS_IDE_TOKEN_SECRET"* ]]
  minted="$(val "$OUT" OSIONOS_IDE_TOKEN_SECRET)"
  [[ "$minted" =~ ^[A-Za-z0-9]{48}$ ]]
  [[ "$output" != *"$minted"* ]]
  [ "$minted" != "$(val "$OUT" OSIONOS_APP_SESSION_SECRET)" ]
  [ "$(val "$OUT" DEMO_LOGIN_PASSWORD)" = demo-keep ]
}

@test "--sync: an existing OSIONOS_IDE_TOKEN_SECRET is never re-minted" {
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" OSIONOS_IDE_TOKEN_SECRET)" = "ide-secret-keep" ]
}

@test "--check: a missing OSIONOS_IDE_TOKEN_SECRET exits 1 and names it" {
  sed -i '/^OSIONOS_IDE_TOKEN_SECRET=/d' "$OUT"
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing OSIONOS_IDE_TOKEN_SECRET"* ]]
}

@test "generate: a fresh .env.local carries a 48-char OSIONOS_IDE_TOKEN_SECRET" {
  rm -f "$OUT"
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\n' > "$GRO_ENV"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(val "$OUT" OSIONOS_IDE_TOKEN_SECRET)" =~ ^[A-Za-z0-9]{48}$ ]]
}

@test "--check/--sync: VITE_BAAS_KONG_KEY follows the linked grobase's Kong key" {
  sed -i 's/^VITE_BAAS_KONG_KEY=.*/VITE_BAAS_KONG_KEY=anon-TEAM/' "$OUT"
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift VITE_BAAS_KONG_KEY"* ]]
  [[ "$output" != *"anon-TEAM"* ]]
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" VITE_BAAS_KONG_KEY)" = "anon-A" ]
}

# --- media keys (UNSPLASH_ACCESS_KEY, PIXABAY_API) copied from apps/osionos/app/.env ---

media_source() { printf 'UNSPLASH_ACCESS_KEY=unsplash-SRC-9f3\nPIXABAY_API=pixabay-SRC-7c1\n' > "$MEDIA_ENV"; }

@test "--sync: a missing AUTH_LINK_SIGNING_KEY gets a generated key without printing it" {
  sed -i '/^AUTH_LINK_SIGNING_KEY=/d' "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"minted AUTH_LINK_SIGNING_KEY"* ]]
  [[ "$output" == *"restart auth-gateway"* ]]
  [[ "$output" != *"link-key-keep"* ]]
  minted="$(val "$OUT" AUTH_LINK_SIGNING_KEY)"
  [[ "$minted" =~ ^[A-Za-z0-9]{48}$ ]]
}

@test "--sync: an existing AUTH_LINK_SIGNING_KEY is never re-minted" {
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" AUTH_LINK_SIGNING_KEY)" = "link-key-keep" ]
  [[ "$output" != *"minted AUTH_LINK_SIGNING_KEY"* ]]
}

@test "--check: a missing AUTH_LINK_SIGNING_KEY exits 1 and names it" {
  sed -i '/^AUTH_LINK_SIGNING_KEY=/d' "$OUT"
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing AUTH_LINK_SIGNING_KEY"* ]]
}

@test "media --sync: keys absent from .env.local are copied" {
  media_source
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" UNSPLASH_ACCESS_KEY)" = "unsplash-SRC-9f3" ]
  [ "$(val "$OUT" PIXABAY_API)" = "pixabay-SRC-7c1" ]
  [[ "$output" == *"copied UNSPLASH_ACCESS_KEY"* ]]
}

@test "media --sync: keys present but empty are filled, once" {
  media_source
  printf 'UNSPLASH_ACCESS_KEY=\nPIXABAY_API=\n' >> "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" UNSPLASH_ACCESS_KEY)" = "unsplash-SRC-9f3" ]
  [ "$(grep -c '^PIXABAY_API=' "$OUT")" -eq 1 ]
}

@test "media --sync: a non-empty .env.local value is kept byte-identical, named in the output" {
  media_source
  printf 'UNSPLASH_ACCESS_KEY=unsplash-LOCAL=x==\n' >> "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" UNSPLASH_ACCESS_KEY)" = "unsplash-LOCAL=x==" ]
  [ "$(val "$OUT" PIXABAY_API)" = "pixabay-SRC-7c1" ]
  [[ "$output" == *"kept UNSPLASH_ACCESS_KEY"* ]]
}

@test "media --sync: an empty source value adds nothing" {
  printf 'UNSPLASH_ACCESS_KEY=\n' > "$MEDIA_ENV"
  before=$(cat "$OUT")
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = "$before" ]
}

@test "media --sync: a missing source file adds nothing and exits as before" {
  before=$(cat "$OUT")
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = "$before" ]
  stale_kong
  run bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
}

@test "media generate: a fresh .env.local gets the keys from the source" {
  media_source
  rm -f "$OUT"
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\n' > "$GRO_ENV"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(val "$OUT" UNSPLASH_ACCESS_KEY)" = "unsplash-SRC-9f3" ]
  [ "$(val "$OUT" PIXABAY_API)" = "pixabay-SRC-7c1" ]
}

@test "media generate: without a source file the keys exist, empty" {
  rm -f "$OUT"
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\n' > "$GRO_ENV"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'UNSPLASH_ACCESS_KEY=' "$OUT"
  grep -qx 'PIXABAY_API=' "$OUT"
}

@test "media: no mode ever prints a media value" {
  media_source
  printf 'UNSPLASH_ACCESS_KEY=unsplash-LOCAL-4d8\n' >> "$OUT"
  run bash "$SCRIPT" --check
  run ! grep -e SRC-9f3 -e SRC-7c1 -e LOCAL-4d8 <<< "$output"
  run bash "$SCRIPT" --sync
  run ! grep -e SRC-9f3 -e SRC-7c1 -e LOCAL-4d8 <<< "$output"
  rm -f "$OUT"
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\n' > "$GRO_ENV"
  run bash "$SCRIPT"
  run ! grep -e SRC-9f3 -e SRC-7c1 <<< "$output"
}

@test "media --check: exit status is identical with and without media drift" {
  run bash "$SCRIPT" --check
  clean=$status
  media_source
  printf 'UNSPLASH_ACCESS_KEY=unsplash-LOCAL-4d8\nPIXABAY_API=\n' >> "$OUT"
  run bash "$SCRIPT" --check
  [ "$status" -eq "$clean" ]
  stale_kong
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
}

@test "media --sync: exit status is identical with and without media drift" {
  stale_kong
  sed -i '/^ADAPTER_REGISTRY_SERVICE_TOKEN=/d' "$GRO_ENV"
  run bash "$SCRIPT" --sync
  without=$status
  stale_kong
  media_source
  printf 'UNSPLASH_ACCESS_KEY=unsplash-LOCAL-4d8\n' >> "$OUT"
  run bash "$SCRIPT" --sync
  [ "$status" -eq "$without" ]
  [ "$without" -eq 1 ]
}

@test "media --check: names a key whose non-empty values differ, exit unchanged" {
  media_source
  printf 'UNSPLASH_ACCESS_KEY=unsplash-LOCAL-4d8\n' >> "$OUT"
  run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"media UNSPLASH_ACCESS_KEY differs from"*"osionos-app.env"* ]]
  [[ "$output" != *"media PIXABAY_API"* ]]
}


@test "--check: a moved host port names all four port-derived keys" {
  run env OSIONOS_APP_HOST_PORT=4321 bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  for key in VITE_BAAS_URL OSIONOS_ALLOWED_ORIGIN OSIONOS_APP_URL PUBLIC_OSIONOS_APP_URL; do
    [[ "$output" == *"drift $key"* ]]
  done
  [[ "$output" != *"4321"* ]]
}

@test "--sync: a moved host port updates only the four port-derived keys" {
  before_jwt="$(val "$OUT" JWT_SECRET)"
  before_svc="$(val "$OUT" SERVICE_ROLE_KEY)"
  run env OSIONOS_APP_HOST_PORT=4321 bash "$SCRIPT" --sync
  [ "$status" -eq 0 ]
  for key in VITE_BAAS_URL OSIONOS_ALLOWED_ORIGIN OSIONOS_APP_URL PUBLIC_OSIONOS_APP_URL; do
    [ "$(val "$OUT" "$key")" = "https://localhost:4321" ]
  done
  [ "$(val "$OUT" JWT_SECRET)" = "$before_jwt" ]
  [ "$(val "$OUT" SERVICE_ROLE_KEY)" = "$before_svc" ]
  [[ "$output" == *"VITE_BAAS_URL"* ]]
  [[ "$output" == *"PUBLIC_OSIONOS_APP_URL"* ]]
}
