# 00 — Connecting to DynamoDB Local

DynamoDB Local is a Java process running in `mini-baas-dynamodb-local`. It has no `aws` CLI installed. You reach it through a disposable `amazon/aws-cli` sidecar container that you join to the same Docker network.

---

## Prerequisites

```bash
# Verify the backend stack is up
docker ps --format '{{.Names}}\t{{.Status}}' | grep dynamo
# Expected: mini-baas-dynamodb-local   Up X hours
```

```bash
# Verify the network exists
docker network ls | grep mini-baas
# Expected: ...   mini-baas_mini-baas   bridge   local
```

---

## The sidecar pattern

DynamoDB Local accepts any credentials, but the AWS CLI still requires them to be set. You must also supply a region — it is not optional for the CLI, even though Local ignores it.

```bash
docker run --rm \
  --network mini-baas_mini-baas \
  -e AWS_ACCESS_KEY_ID=local \
  -e AWS_SECRET_ACCESS_KEY=local \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli dynamodb list-tables \
  --endpoint-url http://mini-baas-dynamodb-local:8000
```

Expected output:

```json
{
    "TableNames": [
        "alerts",
        "device_events",
        "devices"
    ]
}
```

---

## The `ddb` helper function

Paste this into your shell session before running any example in these notes. It saves the 90-character prefix every time.

```bash
ddb() {
  docker run --rm -i \
    --network mini-baas_mini-baas \
    -e AWS_ACCESS_KEY_ID=local \
    -e AWS_SECRET_ACCESS_KEY=local \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli dynamodb "$@" \
    --endpoint-url http://mini-baas-dynamodb-local:8000
}
```

The `-i` flag keeps stdin open so you can pipe JSON into the container. After defining it:

```bash
ddb list-tables
ddb describe-table --table-name alerts
```

---

## Interactive sidecar shell

When you want to run several commands interactively or inspect the environment:

```bash
docker run --rm -it \
  --network mini-baas_mini-baas \
  -e AWS_ACCESS_KEY_ID=local \
  -e AWS_SECRET_ACCESS_KEY=local \
  -e AWS_DEFAULT_REGION=us-east-1 \
  --entrypoint /bin/bash \
  amazon/aws-cli
```

Inside, prefix every command with `aws dynamodb` and add `--endpoint-url http://mini-baas-dynamodb-local:8000`.

---

## Host endpoint vs in-network endpoint

| Access path | URL | When to use |
|---|---|---|
| Inside Docker network (sidecar) | `http://mini-baas-dynamodb-local:8000` | Always use this — DNS resolves by service name |
| Host machine | `http://localhost:8500` | Manual `curl` health checks only (port-mapped at 8500) |

The host endpoint requires a valid `Authorization` header even for DynamoDB Local. The sidecar approach handles this automatically because the CLI signs every request.

Quick host health check with curl:

```bash
curl -s http://localhost:8500/
# Returns an error JSON about missing auth token — that means the port is up and responding.
# {"__type":"...MissingAuthenticationToken","Message":"Request must..."}
```

---

## Scratch-table convention

Every `learn_*` table you create is a throwaway. Drop it when you're done:

```bash
ddb delete-table --table-name learn_orders
```

**Never run experiments against `alerts`, `device_events`, or `devices`** — those are live grobase tables.

---

## Scenario: verify connectivity from scratch

```bash
# 1. Pull the image (once; cached thereafter)
docker pull amazon/aws-cli

# 2. Define the helper
ddb() {
  docker run --rm -i \
    --network mini-baas_mini-baas \
    -e AWS_ACCESS_KEY_ID=local \
    -e AWS_SECRET_ACCESS_KEY=local \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli dynamodb "$@" \
    --endpoint-url http://mini-baas-dynamodb-local:8000
}

# 3. List tables
ddb list-tables

# 4. Check the host port (no CLI needed)
curl -s http://localhost:8500/
```

---

## Gotchas / Docker notes

- **The helper is session-only.** Re-paste it in every new terminal or add it to `~/.bashrc`.
- **`-i` matters.** Without `-i`, piping JSON via stdin hangs or fails silently (e.g., `echo '...' | ddb put-item --item file:///dev/stdin`). Keep `-i`; add `-t` only for interactive use.
- **`--network` must be exact.** The network is `mini-baas_mini-baas` (project name + network name, both `mini-baas`). Wrong network = `Could not connect to the endpoint URL`.
- **No region = no-go.** The CLI exits with `You must specify a region` if `AWS_DEFAULT_REGION` is missing. Local doesn't care which region, but the CLI enforcer does.
- **Image tag.** `amazon/aws-cli` (no tag) pulls `latest`. Pin to a version (e.g., `amazon/aws-cli:2.22.0`) in scripts that need reproducibility.
- **Container overhead.** Each `ddb` call starts and stops a container (~200–400 ms). For bulk work use `batch-write-item` or the interactive shell pattern above.

---

## See also

- [01-tables-indexes.md](01-tables-indexes.md) — creating and managing tables
- [02-crud-items.md](02-crud-items.md) — reading and writing items
- [03-query-scan.md](03-query-scan.md) — querying and scanning
- [04-security.md](04-security.md) — IAM and access control
