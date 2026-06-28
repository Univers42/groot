# MongoDB CLI — Docker Learning Notes

Everything here runs inside Docker against the `mini-baas-mongo` container (MongoDB 7.0.37). No host
MongoDB tools are needed or allowed — all access goes through `docker exec` or a `mongo:7` sidecar.

## Quick connect

```bash
# Interactive shell
docker exec -it mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'

# One-shot check
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet --eval "db.version()"'
# → 7.0.37
```

Credentials live in container env (`MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD`);
`authSource=admin` is required for the root user. Never hardcode either value — always resolve from
the container at runtime as shown above.

## Safety rule — use `learn_cli` for every exercise

MongoDB creates a database the moment you write to it. Use `learn_cli` as the scratch database for
all exercises; drop it when done:

```bash
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet --eval \
   "use(\"learn_cli\"); db.dropDatabase(); print(\"clean\")"'
```

Never touch `admin`, `config`, `local`, `mini_baas`, `mini_baas_ai`, or `mini_baas_analytics`.

## Concept files

| # | File | What you will learn |
|---|------|---------------------|
| 00 | [00-connect.md](00-connect.md) | Interactive shell, `--eval`, running `.js` files, shell commands |
| 01 | [01-crud.md](01-crud.md) | insertOne/Many, find (operators, projection, sort/limit), update, delete, upsert |
| 02 | [02-indexes.md](02-indexes.md) | Single, compound, unique, TTL, text, partial indexes; `explain()` |
| 03 | [03-aggregation-views.md](03-aggregation-views.md) | Aggregation pipeline, read-only views, `$out` materialized views |
| 04 | [04-users-roles.md](04-users-roles.md) | Creating users, built-in roles, custom roles, `authSource` |
| 05 | [05-security.md](05-security.md) | Auth model, least privilege, TLS flags, hardening checklist |
| 06 | [06-backup-restore.md](06-backup-restore.md) | `mongodump`/`mongorestore`, `mongoexport`/`mongoimport` via sidecar |
| — | [operations.md](operations.md) | Day-to-day ops & live-data inspection: where data lives, read-only browsing, server/ops commands, `explain()` |

## Engine facts at a glance

| Item | Value |
|------|-------|
| Container | `mini-baas-mongo` |
| Image | `ghcr.io/univers42/grobase-mongo:latest` |
| MongoDB version | 7.0.37 |
| Client inside container | `mongosh` |
| Backup tools | NOT in main container — use `mongo:7` sidecar |
| Network (for sidecar) | `mini-baas_mini-baas` |
| Auth mode | Keyfile replica-set auth (auth always on) |
| Root creds env vars | `MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD` |
| Auth source | `admin` database |
