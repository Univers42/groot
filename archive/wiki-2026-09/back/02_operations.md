# 02 — Operations

Day-to-day commands. All paths are relative to the repo root.

## Profiles

The compose file is profile-gated so you only pay for what you use.

| Profile | What it brings up |
|---|---|
| `control-plane` | adapter-registry-go, permission-engine, pg-meta, supavisor, studio, webhook-dispatcher |
| `data-plane` | data-plane-router-rust, query-router, debezium, realtime, minio, iceberg-rest |
| `rust-data-plane` | data-plane-router-rust only |
| `background` | outbox-relay, email/AI/analytics/GDPR/newsletter/session/log, webhook-dispatcher |
| `realtime` | realtime WebSocket fan-out (opt-in; the rest of BaaS works without it) |
| `functions` | functions-runtime (edge functions MVP) |
| `backups` / `ops` | pg-backup |
| `extras` / `storage` | MinIO, supavisor, studio, iceberg-rest |
| `analytics` | iceberg-rest, minio-iceberg-init |

## Common make targets

```sh
make -C infrastructure baas-up           # full kitchen-sink stack
make -C infrastructure baas-up-lean      # control + data + rust-data plane only
make -C infrastructure baas-down-lean    # tear down the lean profile
make -C infrastructure baas-verify-all   # run m1-m19 verify scripts
```

`BAAS_LEAN_PROFILES_EXTRA="backups,functions"` adds more profiles to the lean
stack without editing the makefile.

## Verify scripts

`apps/baas/mini-baas-infra/scripts/verify/m*-*.sh` — each script is a
self-contained smoke test for one slice (e.g. `m12-tenancy.sh`,
`m18-rust-data-plane.sh`).

```sh
cd apps/baas/mini-baas-infra
scripts/verify/m18-rust-data-plane.sh             # one slice
BAAS_VERIFY_LIVE=1 make -C ../../../infrastructure baas-verify-all   # all slices
```

`parity-probe.sh` runs verify-all twice: once in TS-only mode, once with
Rust forwarding enabled, then diffs the results. Use this before deleting
a TS engine.

## Logs

```sh
docker logs -f mini-baas-data-plane-router-rust
docker logs -f mini-baas-webhook-dispatcher
docker logs -f mini-baas-functions
docker logs -f mini-baas-pg-backup
```

Loki + Grafana run under the `extras` profile if you prefer centralized
logging: http://localhost:3000 (grafana) — datasource is preconfigured.

## Restart a single service

```sh
docker compose restart data-plane-router-rust
docker compose up -d --force-recreate --no-deps webhook-dispatcher
```

## When the dev DB gets weird

```sh
docker compose down                  # keeps volumes
docker compose down -v               # WIPES the postgres/mongo/redis/minio volumes
docker compose up -d postgres        # come back up clean; db-bootstrap reruns migrations
```

## Health endpoints

Every service exposes `/health/live` (liveness) and `/health/ready` (touches
its DB). The Rust router additionally exposes `/v1/capabilities` and
`/v1/metrics` (Prometheus format).

## Where the secrets live

`.env` at the project root holds dev defaults. Production should mount these
from Vault (`apps/baas/mini-baas-infra/docker/services/vault/`). See
`project-vault-setup` in your memory file for the Fly.io token rotation.
