#!/usr/bin/env bats
# scripts/verify/ai-public-providers.sh against fixture rendered configs (no docker).
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache jq && bats scripts/tests/ai-public-providers.bats'

SCRIPT="$BATS_TEST_DIRNAME/../verify/ai-public-providers.sh"

# fixture <PUBLIC_MODE> <providers json or empty>
fixture() {
  jq -n --arg mode "$1" --arg providers "$2" '{services:{
    "osionos-ai":{environment:{OSIONOS_AI_PUBLIC_MODE:$mode,OSIONOS_AI_PLATFORM_PROVIDERS:$providers}},
    "osionos-ai-llm":{}}}' > "$BATS_TEST_TMPDIR/c.json"
}

@test "internal host in providers fails" {
  fixture on '[{"id":"p","baseUrl":"http://osionos-ai-llm:8080/v1","apiKeyEnv":"OSIONOS_AI_KEY_P"}]'
  run sh "$SCRIPT" --json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"compose service"* ]]
}

@test "missing PUBLIC_MODE fails" {
  fixture "" ''
  run sh "$SCRIPT" --json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PUBLIC_MODE"* ]]
}

@test "keyless provider fails" {
  fixture on '[{"id":"p","baseUrl":"https://api.example.com/v1"}]'
  run sh "$SCRIPT" --json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"apiKeyEnv"* ]]
}

@test "clean config passes, with zero providers or one keyed provider" {
  fixture on ''
  run sh "$SCRIPT" --json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 0 ]
  fixture on '[{"id":"p","baseUrl":"https://api.example.com/v1","apiKeyEnv":"OSIONOS_AI_KEY_P"}]'
  run sh "$SCRIPT" --json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 0 ]
}
