#!/usr/bin/env bats
# gen-local-env.sh derives seven BaaS keys in ./.env.local from apps/grobase/.env. When
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
  printf 'JWT_SECRET=jwt-A\nANON_KEY=anon-A\nSERVICE_ROLE_KEY=svc-A\nADAPTER_REGISTRY_SERVICE_TOKEN=adapter-A\n' > "$GRO_ENV"
  cat > "$OUT" <<'LOCAL'
# header comment stays
JWT_SECRET=jwt-A
ANON_KEY=anon-A
SERVICE_ROLE_KEY=svc-A
KONG_PUBLIC_API_KEY=anon-A
KONG_SERVICE_API_KEY=svc-A
SB_KONG_KEY=anon-A
ADAPTER_REGISTRY_SERVICE_TOKEN=adapter-A
VITE_BAAS_REALTIME_TOKEN=rt-tenant-token
OSIONOS_BRIDGE_EMAIL_HASH_SALT=salt-keep
VITE_BAAS_URL=https://localhost:3001
LOCAL
  chmod 600 "$OUT"
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
