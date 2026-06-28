# Backup and Restore

`mongodump`, `mongorestore`, `mongoexport`, and `mongoimport` are **not installed** in the
`mini-baas-mongo` container. They are part of the separate **MongoDB Database Tools** package. Use
a `mongo:7` sidecar container that has them, running on the same Docker network as the backend.

---

## Tool availability — sidecar approach

```bash
# Confirm the main container has no dump tools
docker exec mini-baas-mongo which mongodump 2>/dev/null || echo "not in main container"
# not in main container

# Confirm the sidecar image has them
docker run --rm mongo:7 mongodump --version 2>&1 | head -1
# mongodump version: 100.17.0
```

The `mongo:7` image is available locally on this machine. Every backup/restore command below uses
a `docker run --rm` sidecar on the `mini-baas_mini-baas` network.

Credentials are read at runtime via `docker exec mini-baas-mongo printenv`. They are never
hardcoded.

---

## Reading credentials safely

```bash
MONGO_USER=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME)
MONGO_PASS=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD)
MONGO_URI="mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin"
```

The URI is used in every sidecar command. The credentials exist only in the current shell session.

---

## `mongoexport` / `mongoimport` — JSON format

These tools work with newline-delimited JSON (one document per line). They are the most portable
format and the simplest to pipe between commands.

### Export a collection to a file

```bash
MONGO_USER=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME)
MONGO_PASS=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD)

docker run --rm \
  --network mini-baas_mini-baas \
  mongo:7 \
  mongoexport \
    --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin" \
    --db=learn_cli \
    --collection=customers \
  2>/dev/null > /tmp/customers.json
```

Each line of `/tmp/customers.json` is one document in Extended JSON format:

```json
{"_id":{"$oid":"..."},"name":"Alice","email":"alice@shop.dev","createdAt":{"$date":"..."}}
{"_id":{"$oid":"..."},"name":"Bob","email":"bob@shop.dev","createdAt":{"$date":"..."}}
```

### Import from a file

```bash
docker run --rm -i \
  --network mini-baas_mini-baas \
  mongo:7 \
  mongoimport \
    --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin" \
    --db=learn_cli \
    --collection=customers \
    --drop \
  < /tmp/customers.json
# 2 document(s) imported successfully. 0 document(s) failed to import.
```

`--drop` drops the target collection before importing. Omit it to merge/upsert into an existing
collection.

### Export a query subset

```bash
# Only export shipped orders (filter must be valid JSON)
docker run --rm \
  --network mini-baas_mini-baas \
  mongo:7 \
  mongoexport \
    --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin" \
    --db=learn_cli \
    --collection=orders \
    --query='{"status":"shipped"}' \
  2>/dev/null > /tmp/shipped_orders.json
```

---

## `mongodump` / `mongorestore` — BSON binary format

`mongodump` produces binary BSON files that preserve all BSON types exactly (ObjectIds, Dates,
etc.) — essential for a full fidelity backup. The output is a directory tree with one `.bson` and
one `.metadata.json` file per collection.

### Important: volume mount permissions

The `mongo:7` sidecar runs as a non-root user. Mounting a host directory as `-v /path:/backup`
typically fails with `permission denied` because the mount root is owned by `root`. The two
reliable patterns are:

**Pattern A — dump + restore in the same container (for DR/migration testing):**

```bash
MONGO_USER=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME)
MONGO_PASS=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD)

# Dump learn_cli, then immediately restore it (with --drop) in one sidecar session
docker run --rm \
  --network mini-baas_mini-baas \
  mongo:7 \
  bash -c "
    mongodump \
      --uri='mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin' \
      --db=learn_cli \
      --out=/tmp/dump 2>&1 \
    && echo '--- dump done ---' \
    && mongorestore \
      --uri='mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin' \
      --drop /tmp/dump 2>&1
  "
# → done dumping `learn_cli.customers` (2 documents)
# → done dumping `learn_cli.products` (2 documents)
# → finished restoring `learn_cli.customers` (2 documents, 0 failures)
# → finished restoring `learn_cli.products` (2 documents, 0 failures)
# → 4 document(s) restored successfully. 0 document(s) failed to restore.
```

**Pattern B — archive to file, then copy out with `docker cp` (pattern — unverified here):**

`docker cp` only works on named (non-`--rm`) containers. Run the container in the background,
exec the dump, then copy out and stop the container.

```bash
# 1. Start a sidecar in the background (no --rm)
docker run -d --name mongo-tools \
  --network mini-baas_mini-baas \
  mongo:7 sleep infinity

# 2. Dump to the sidecar's /tmp
docker exec mongo-tools bash -c "
  mongodump \
    --uri='mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin' \
    --db=learn_cli \
    --archive=/tmp/learn_cli.archive 2>&1
"

# 3. Copy the archive to the host
docker cp mongo-tools:/tmp/learn_cli.archive /tmp/learn_cli.archive

# 4. Remove the sidecar
docker rm -f mongo-tools
```

Restore from the copied archive (pattern — unverified here):

```bash
# 1. Start a fresh sidecar
docker run -d --name mongo-tools \
  --network mini-baas_mini-baas \
  mongo:7 sleep infinity

# 2. Copy archive into the sidecar
docker cp /tmp/learn_cli.archive mongo-tools:/tmp/learn_cli.archive

# 3. Restore
docker exec mongo-tools bash -c "
  mongorestore \
    --uri='mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin' \
    --archive=/tmp/learn_cli.archive \
    --drop 2>&1
"

# 4. Remove sidecar
docker rm -f mongo-tools
```

### Dump with `--gzip`

Adds `.gz` compression to each BSON file in the directory:

```bash
# Inside a sidecar bash session (Pattern A style)
mongodump \
  --uri="..." \
  --db=learn_cli \
  --gzip \
  --out=/tmp/dump
# produces: customers.bson.gz, customers.metadata.json.gz, ...
```

Restore with `--gzip`:

```bash
mongorestore \
  --uri="..." \
  --gzip \
  --drop /tmp/dump
```

---

## Scenario — back up and restore `learn_cli`

```bash
# 0. Ensure learn_cli has data (see 01-crud.md for setup)
MONGO_USER=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME)
MONGO_PASS=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD)

# Seed
docker exec mini-baas-mongo sh -lc '
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin --quiet \
  --eval "use(\"learn_cli\");
    db.customers.insertMany([
      {name:\"Alice\",email:\"alice@shop.dev\",createdAt:new Date()},
      {name:\"Bob\",  email:\"bob@shop.dev\",  createdAt:new Date()}
    ]); print(\"seeded:\", db.customers.countDocuments())"
'

# 1. Export customers to JSON (verified)
docker run --rm \
  --network mini-baas_mini-baas \
  mongo:7 \
  mongoexport \
    --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin" \
    --db=learn_cli --collection=customers \
  2>/dev/null > /tmp/customers.json
echo "exported $(wc -l < /tmp/customers.json) documents"

# 2. Drop and reimport
docker run --rm -i \
  --network mini-baas_mini-baas \
  mongo:7 \
  mongoimport \
    --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@mini-baas-mongo:27017/?authSource=admin" \
    --db=learn_cli --collection=customers --drop \
  < /tmp/customers.json

# 3. Verify count
docker exec mini-baas-mongo sh -lc '
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin --quiet \
  --eval "use(\"learn_cli\"); print(db.customers.countDocuments())"
'

# 4. Cleanup
docker exec mini-baas-mongo sh -lc '
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin --quiet \
  --eval "use(\"learn_cli\"); db.dropDatabase(); print(\"clean\")"
'
```

---

## What is verified vs pattern-only

| Command | Status |
|---------|--------|
| `mongoexport` to stdout | Verified — works |
| `mongoimport` from stdin | Verified — works |
| `mongodump --out` + `mongorestore` in same sidecar bash session | Verified — works |
| `mongodump --gzip --out` in sidecar | Verified — `.bson.gz` files created |
| `--archive` written to sidecar's `/tmp` then `docker cp` | Pattern (unverified here) |
| `--archive` via stdout redirect to host file then stdin to restore | Fails — BSON corruption via pipe |
| Volume mount (`-v`) for backup directory | Fails — permission denied in mongo:7 sidecar |

---

## Gotchas / Docker notes

- **`mongodump`/`mongorestore` are not in `mini-baas-mongo`** — only `mongosh` is present.
  Attempting `docker exec mini-baas-mongo mongodump ...` will fail with `not found`.
- **Archive via stdout pipe is unreliable.** Writing `docker run ... mongodump --archive > file`
  to a host file, then restoring via stdin, produces BSON corruption in this environment.
  Use the same-container bash pattern (Pattern A) or the named container + `docker cp` approach
  (Pattern B, unverified).
- **`mongoexport` is not a full backup.** It exports documents as JSON — BSON types like
  `ObjectId` and `Date` are serialised as Extended JSON, so they round-trip correctly. But indexes,
  collection options, and views are not exported. Use `mongodump` for a complete backup.
- **`mongoimport --drop` is destructive.** It drops the collection before importing. Omit `--drop`
  if you want to merge new documents into an existing collection.
- **Replica set backups need a consistent snapshot.** For production, prefer
  `mongodump --oplog` or filesystem-level snapshots (LVM/EBS snapshot) so the backup is
  point-in-time consistent across collections.
- **mongodump version 100.x** (Database Tools) is versioned separately from the MongoDB server.
  100.17.0 is compatible with server 7.0.

---

[README](README.md) | [00-connect.md](00-connect.md) | [01-crud.md](01-crud.md) |
[02-indexes.md](02-indexes.md) | [03-aggregation-views.md](03-aggregation-views.md) |
[04-users-roles.md](04-users-roles.md) | [05-security.md](05-security.md)
