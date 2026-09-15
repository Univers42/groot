# Engines — reference

> **Status:** Partial · 2026-09-15
> **Evidence:** transcribed from the adapter crate READMEs and the feature tables
> **To check:** the live truth is `GET /engines` on a running stack; the committed catalogue is
> `engines.ts` in the SDK. Reconcile this table against one of them before quoting it.
> **Sources:** `crates/data-plane-pool/README.md` · `crates/data-plane-server/README.md`

**Seven engines by default, eight with DynamoDB, plus two dialects.** The counting confuses
people, so: `engines-full` is the seven-engine set; `dynamodb` is deliberately excluded from the
default build so it never fetches or compiles the AWS SDK; `cockroachdb` and `mariadb` have
their own capability constructors but no separate adapter.

```
default = ["postgres", "mongodb", "mysql", "redis", "sqlite", "mssql", "http"]
```

A lean build compiles only what it mounts: `--no-default-features --features sqlite` is the
nano edition, a ~5 MB image.

---

## The eight

| Engine | Driver / note | `batch` | `transactions` | Per-request scoping |
|---|---|:--:|:--:|---|
| `postgres` | + `cockroachdb` dialect | ✓ | ✓ | `SetSearchPath` / RLS |
| `mysql` | + `mariadb` dialect | ✓ | ✓ | `UseNamespace` |
| `mongodb` | `schema_ddl: true`, `ddl: false` | ✓ | ✗ | `UseNamespace` |
| `mssql` | two-level logins/users model | — | — | — |
| `sqlite` | file-backed; the `nano` shape | — | — | — |
| `redis` | key-value; no tables | ✓ | ✗ | `UseNamespace` |
| `http` | passthrough, `reqwest` | ✗ | ✗ | **none — explicit no-op** |
| `dynamodb` | opt-in feature; `ClientRequestToken` | — | ✓ | `UseNamespace` |

Blank cells are not "false" — they are not transcribed here. Check `/engines`.

DynamoDB is **the only adapter that can honestly set `native_idempotency: true`**, and that
adverb is the point: capabilities are not declared out of optimism.
→ [03-data-plane](03-data-plane.md)

---

## The `http` engine

The strangest of the eight, and the most revealing. Its "DSN" is not a DSN:

```json
{ "baseUrl": "https://api.example.com", "headers": {}, "routes": {} }
```

A remote HTTP API is declared as if it were a database, and from then on queried through the
same envelope as Postgres. A generalisation of "engine" to its limit: a data source no longer
has to be a database. This is what the osionos database block exposes to users.
→ [product/02-osionos](../product/02-osionos.md)

Two consequences, both important.

**No scoping.** An HTTP mount has no schema, database or keyspace, so it applies no per-request
scoping under any strategy. It forwards `X-Owner-Id` and leaves authorisation upstream.
→ [07-isolation](07-isolation.md)

**SSRF.** "Mount any URL" means "let a user make my server fetch any URL". The guard
(`guard_and_resolve`) blocks loopback, RFC-1918, link-local including `169.254.169.254` — the
cloud metadata endpoint — CGNAT, IPv6 ULA and link-local, IPv4-mapped forms, and names like
`localhost`, `*.internal` and `metadata`. It then pins the client to the validated public IPs so
a later DNS rebind cannot redirect inward. `DATA_PLANE_HTTP_ALLOW_INTERNAL=1` skips it for dev
mocks and must never be set in production. → [security/04-network](../security/04-network.md)

---

## Proven together

Gate `m174` exercises **six engines through a single application key** — Postgres, MySQL and
Mongo in one script, SQLite, MSSQL and DynamoDB in the other. It is the best demonstration in
the project. → [quality/02-key-gates](../quality/02-key-gates.md)

Gate `m27` runs the conformance battery: every adapter driven against a **real** engine,
asserting it serves exactly what its descriptor advertises.

---

## What this is not

The same API over seven engines is **not portability between engines**. There is no button that
moves a database from PostgreSQL to Mongo. Saying otherwise in an evaluation invites a demo
that does not exist.

---

See also: [03-data-plane](03-data-plane.md) · [07-isolation](07-isolation.md)
