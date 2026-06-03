# 07 — Backups

The `pg-backup` container runs nightly `pg_dump` against the control-plane
Postgres and uploads compressed dumps to a MinIO bucket. Optional weekly
`pg_basebackup` provides PITR-ready physical backups when WAL archiving is
enabled on the server.

Lives in `apps/baas/mini-baas-infra/docker/services/pg-backup/`.

## Bring it up

```sh
docker compose --profile backups up -d pg-backup
docker logs -f mini-baas-pg-backup
```

The container installs a cron entry at startup based on `PG_BACKUP_SCHEDULE`
(default `0 3 * * *` — daily at 03:00 UTC).

## Configuration

| Env | Default | Meaning |
|---|---|---|
| `DATABASE_URL` / `PG_BACKUP_DATABASE_URL` | dev defaults | source DB |
| `MINIO_ENDPOINT` | `http://minio:9000` | object store URL |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | `minioadmin` / `minioadmin` | credentials |
| `PG_BACKUP_BUCKET` | `backups` | bucket to upload into (auto-created) |
| `PG_BACKUP_PREFIX` | `postgres` | key prefix inside the bucket |
| `PG_BACKUP_SCHEDULE` | `0 3 * * *` | crontab expression |
| `PG_BACKUP_RETAIN_DAYS` | `14` | older artifacts are pruned |
| `PG_BACKUP_PHYSICAL` | `0` | set `1` to also run `pg_basebackup` |

## Object layout

```
backups/postgres/logical/postgres-20260601T030000Z.dump
backups/postgres/logical/postgres-20260602T030000Z.dump
backups/postgres/physical/base-20260601T030000Z/base.tar.gz
backups/postgres/physical/base-20260601T030000Z/pg_wal.tar.gz
```

`logical/` is `pg_dump -Fc` (custom format, compressed, parallel-restore
capable). `physical/` is a tar+gzip stream from `pg_basebackup`.

## On-demand backup

```sh
docker compose run --rm pg-backup once
```

## Restore

The restore script downloads an artifact from MinIO and applies it to a
**separate** target DB (`RESTORE_DATABASE_URL`) — it deliberately refuses
to overwrite the source.

```sh
docker compose run --rm \
  -e RESTORE_DATABASE_URL="postgres://postgres:postgres@host.docker.internal:5433/staging" \
  pg-backup restore postgres-20260601T030000Z.dump
```

Without an explicit key, the container lists what's available:

```sh
docker compose run --rm pg-backup restore
```

## PITR (optional)

For point-in-time recovery you need WAL archiving on the Postgres server.
Add to `postgresql.conf`:

```
wal_level = replica
archive_mode = on
archive_command = 'mc cp %p baas/backups/postgres/wal/%f'
```

Then set `PG_BACKUP_PHYSICAL=1` so the container takes a base backup that
the WAL stream can be replayed against.

## What's NOT included

- Per-tenant exports — `pg_dump` is whole-DB. For tenant data export use
  the GDPR service (NestJS) which produces a tenant-scoped JSON bundle.
- MongoDB / MySQL backups — there's no equivalent container yet. The
  pattern is the same (mongodump / mysqldump + mc). PR-welcome.
- Cross-region replication — MinIO has bucket replication but it's not
  configured here; treat the current setup as single-region.
- Encryption at rest of the dumps — uploaded objects use MinIO's
  server-side encryption only if you configure it in the MinIO server.
