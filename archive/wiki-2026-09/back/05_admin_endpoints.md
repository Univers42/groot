# 05 — Admin Endpoints: Raw SQL + Per-tenant Migrate

Two privileged endpoints on the Rust data-plane router for ops + DDL work
that doesn't fit the structured `operation` shape.

Both require `X-Service-Token: <INTERNAL_SERVICE_TOKEN>` and a signed
identity envelope. The query-router never proxies these from end-user
traffic — they're for control-plane callers only.

## `/v1/admin/raw`

Execute an arbitrary statement against a tenant's mount. Returns rows for
SELECTs, affected row count for DML.

```http
POST /v1/admin/raw
X-Service-Token: …
X-Baas-Tenant-Id: t-acme

{
  "mount_id": "m-pg-primary",
  "statement": "SELECT count(*) FROM orders WHERE created_at > $1",
  "params": ["2026-01-01"]
}
```

Engine support:

| Engine | Supported |
|---|---|
| PostgreSQL | yes (parameterized) |
| MySQL | yes (positional `?`) |
| MongoDB | no — use the structured `operation` API |
| Redis | yes (command strings) |
| HTTP | no |

The statement runs under the tenant's RLS context — you cannot use `/admin/raw`
to escape a tenant boundary. Use the admin DB directly (port 5432) for
cross-tenant ops.

## `/v1/admin/migrate`

Apply a migration to a tenant's mount and record it in
`<schema>._baas_migrations`.

```http
POST /v1/admin/migrate
X-Service-Token: …
X-Baas-Tenant-Id: t-acme

{
  "mount_id": "m-pg-primary",
  "name": "2026_06_02_add_total_index",
  "up": "CREATE INDEX CONCURRENTLY orders_total_idx ON orders(total)",
  "checksum": "<sha256 of up>"  // optional; computed if omitted
}
```

Behaviour:

- If `(name, checksum)` already exists in `_baas_migrations`, returns
  `{ status: "already_applied" }`.
- If `name` exists with a different checksum, returns 409 — never silently
  re-applies.
- Otherwise runs `up` inside a tx, inserts the marker row, commits.

`_baas_migrations` table shape:

```sql
CREATE TABLE _baas_migrations (
  name       TEXT PRIMARY KEY,
  checksum   TEXT NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Only PG and MySQL support `/admin/migrate`. Mongo "migrations" are
schemaless and out of scope.

## Auditing

Both endpoints emit an `audit_log` row tagged with `actor='service'`,
`action='admin.raw'` / `'admin.migrate'`, the rendered SQL (truncated to
8KB), and the mount id. Hook these up to your SIEM via the outbox-relay
stream `outbox.audit_log`.
