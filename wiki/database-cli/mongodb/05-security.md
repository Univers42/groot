# Security

MongoDB's security model has three layers: **authentication** (who are you?), **authorization**
(what can you do?), and **transport security** (is the wire encrypted?). In this stack, auth is
already on and the network is Docker-internal — this file explains the model and gives you the
checklist for going beyond the defaults.

---

## Authentication and authorization model

### Authentication — keyfile mode

This container runs in keyfile mode (replica-set authentication). Each member of the replica set
shares a secret keyfile so nodes can verify each other without TLS. You can confirm it:

```bash
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin --quiet \
           --eval "db.adminCommand({getCmdLineOpts:1}).parsed.security"'
# { keyFile: '/etc/mongo/rs-keyfile' }
```

Every external client connection still uses password authentication (`SCRAM-SHA-256` by default in
MongoDB 7).

### Authorization — RBAC

MongoDB uses Role-Based Access Control. A user is assigned one or more roles; each role grants a
set of privilege actions on specific resources (database + collection pairs, or cluster-wide
resources). There is no row-level security — filtering sensitive fields must be done at the
application layer or via field-level redaction (see below).

Verify who you are authenticated as:

```bash
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin --quiet \
           --eval "db.runCommand({connectionStatus:1}).authInfo.authenticatedUsers"'
# [ { user: 'mongo', db: 'admin' } ]
```

---

## `authSource` pitfalls

The single most common connection failure comes from a wrong `authSource`. Rules to remember:

| User type | User lives in | Connect with |
|-----------|--------------|--------------|
| Root / superuser | `admin` | `--authenticationDatabase admin` |
| App user created via `use("learn_cli"); db.createUser(...)` | `learn_cli` | `--authenticationDatabase learn_cli` |
| App user created via `use("admin"); db.createUser(...)` | `admin` | `--authenticationDatabase admin` |

In a URI string, `authSource` is the query parameter:

```
mongodb://shop_app:secret@mini-baas-mongo:27017/learn_cli?authSource=learn_cli
```

Omitting `authSource` defaults to the **target database** (the path component). That is correct
when the user lives in the target db, but wrong when connecting as root to a different db.

---

## Least-privilege checklist

Follow this checklist for every new application credential:

1. **Create a dedicated user** in the target database (not `admin` unless a cross-db role is
   genuinely required).
2. **Grant only what the app needs.** A read-only reporting service gets `read`, not `readWrite`.
   A service that only needs two collections gets a custom role scoped to those collections.
3. **Never use the root account** from application code. Root can do anything — including dropping
   all databases.
4. **Rotate passwords** via `db.updateUser` on a schedule. Store them in a secrets manager (vault42
   in this project), not in environment files committed to git.
5. **Audit what a user can do** before deploying:

```bash
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin --quiet \
           --eval "use(\"learn_cli\"); db.getUser(\"shop_app\")"'
```

---

## TLS connection flags

This container does not expose TLS externally (it is Docker-internal), but you will encounter TLS
options when connecting to production clusters or Atlas.

```bash
# Basic TLS connection to an external host
mongosh \
  --tls \
  --tlsCAFile /path/to/ca.pem \
  --tlsCertificateKeyFile /path/to/client.pem \
  "mongodb://user:pass@host:27017/db?authSource=admin"

# Accept self-signed CA (dev only)
mongosh \
  --tls \
  --tlsAllowInvalidCertificates \
  "mongodb://user:pass@host:27017/"
```

In a URI string:

```
mongodb://user:pass@host:27017/db?tls=true&tlsCAFile=/path/ca.pem&authSource=admin
```

`--tlsAllowInvalidCertificates` disables certificate verification — never use it in production.

---

## Field-level redaction concept

MongoDB has no built-in column-level encryption that blocks the server from reading a field.
However, you can implement **field-level redaction** in the aggregation pipeline using `$redact`:

```js
// Concept only — $redact is a pipeline stage
db.customers.aggregate([
  {
    $redact: {
      $cond: {
        if:   { $eq: ["$clearance", "public"] },
        then: "$$DESCEND",   // keep this document / subdocument
        else: "$$PRUNE"      // remove it
      }
    }
  }
])
```

For true client-side field encryption (where the server never sees plaintext), look at
**MongoDB Client-Side Field Level Encryption (CSFLE)** — a driver-side feature not available
through `mongosh` alone.

---

## Network exposure

The `mini-baas-mongo` container is only reachable on the `mini-baas_mini-baas` Docker network.
No port is mapped to `0.0.0.0` on the host by default. This means:

- External clients cannot connect without `docker exec` or a port mapping.
- The attack surface is the Docker network (other containers on the same network).

Check current port bindings:

```bash
docker port mini-baas-mongo
# (no output = no host port mapping = good)
```

---

## Audit

MongoDB Enterprise has a built-in audit log. The Community Edition (used here) does not. For
Community, the closest equivalent is:

- Enable the **slow-query log** (`profile` level 1 or 2) to capture query patterns.
- Route MongoDB logs to a centralised log aggregator.
- Use `mongosh` connection events and the `$currentOp` admin command for real-time inspection.

```bash
# See currently running operations
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin --quiet \
           --eval "db.adminCommand({ currentOp: 1 }).inprog.length + \" ops in flight\""'
```

---

## Hardening checklist

```
[ ] Auth is ON           — confirmed via getCmdLineOpts (keyFile present)
[ ] No host port mapping — docker port mini-baas-mongo returns nothing
[ ] Root not used by app — app connects as shop_app, not mongo/root
[ ] authSource is correct — shop_app authenticates against learn_cli, not admin
[ ] Passwords in vault42 — not in .env files, not in git
[ ] Roles are scoped     — readWrite per db, not readWriteAnyDatabase
[ ] Custom roles for tight scoping — reporting users get read only on specific collections
[ ] Rotate on a schedule — db.updateUser(...) or vault42 rotation workflow
[ ] Slow query profile   — db.setProfilingLevel(1, {slowms: 100}) during debugging
[ ] Logs forwarded       — docker logs mini-baas-mongo → centralised store
```

---

## Gotchas / Docker notes

- **Auth is always on in this stack.** There is no unauthenticated mode available. Every connection
  attempt without valid credentials receives `MongoServerError: Authentication failed`.
- **SCRAM-SHA-1 vs SCRAM-SHA-256** — MongoDB 7 defaults to SCRAM-SHA-256 for new users. Older
  drivers may only support SHA-1. If you see `SCRAM` errors, check the driver version.
- **Keyfile vs TLS mutual auth** — keyfile auth secures node-to-node replica set communication but
  does NOT encrypt the data on the wire. For in-transit encryption you need TLS on top.
- **`--tlsAllowInvalidCertificates` bypasses all certificate validation.** It is a dev convenience,
  not a production option. CI pipelines have been breached via MITM when this flag was left on.

---

[README](README.md) | [00-connect.md](00-connect.md) | [01-crud.md](01-crud.md) |
[02-indexes.md](02-indexes.md) | [03-aggregation-views.md](03-aggregation-views.md) |
[04-users-roles.md](04-users-roles.md) | [06-backup-restore.md](06-backup-restore.md)
