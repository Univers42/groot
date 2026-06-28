# Parameterized queries by construction — grobase (the BaaS backend)

> Every value that reaches a relational engine is recorded through a single typed
> accumulator (`SqlParamSink::bind`), so the number of placeholders in any
> generated query is structurally guaranteed to equal the number of bound
> parameters, and every column name is validated against a strict identifier
> allowlist before it is quoted into SQL — making value injection and identifier
> injection impossible by construction, not by convention.

## What it is (the concept)

**Parameterized queries** (also called **prepared statements**) are the primary
defense against SQL injection: instead of formatting user-supplied values directly
into a SQL string, each value is transmitted to the database engine as a separate,
typed **bound parameter** referenced by a placeholder (`$n`, `?`, `@Pn`). The
engine parses the query template before seeing the values, so no value can ever be
interpreted as SQL syntax. The complementary control is an **identifier allowlist**:
because column and table names cannot be bound as parameters, any field name that
arrives from a client must be validated against a strict charset rule (`[A-Za-z0-9_]`,
must start with a letter or `_`, max 63 characters) and **double-quoted** before
interpolation, which prevents SQL metacharacters from breaking out.

## What it defends against

See [SQL Injection](../../attack/sql-injection.md).

In grobase, the attack surface is the filter, data, and schema objects that clients
send to the data-plane router.  Without parameterization, a value like
`1; DROP TABLE users--` in a filter field, or a column name like `evil;--` in a
client payload, would be formatted directly into the SQL string and executed by
the engine.  The multi-tenant design amplifies the risk: because up to 10,000
tenants share a connection pool, a successful injection in one tenant's request
could read or mutate another tenant's rows, bypassing the `owner_id` predicate and
RLS policies that enforce isolation.

## How grobase implements it

Two interlocking Rust modules form the complete defense.

**1. `SqlParamSink` — the bind-only accumulator (all non-Postgres relational engines)**

[`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/sql_scope.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/sql_scope.rs)
defines the `SqlParamSink` trait (L30–41):

```rust
pub(crate) trait SqlParamSink {
    /// Record `value` as a bound parameter and return its placeholder text
    /// (`?` for positional engines, `@P{n}` for SQL Server).
    fn bind(&mut self, value: &Value) -> String;
    /// Quote an identifier for this dialect (rejects an invalid identifier).
    fn quote_ident(&self, name: &str) -> DataPlaneResult<String>;
}
```

`bind` is the **only** mechanism for recording a value.  `lower_filter` (L94–160)
recurses over every filter variant (`Cmp`, `In`, `Like`, `Between`, `IsNull`,
`And`, `Or`, `Not`) and routes every value through `sink.bind` and every field
name through `sink.quote_ident`.  `strip_reserved_top_level` (L59–71) removes
`owner_id` and `tenant_id` from any client-supplied filter object before lowering,
so a client cannot inject a trusted column into the WHERE clause.

**2. `quote_ident` — the identifier allowlist (all relational adapters)**

[`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/ident.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/ident.rs)
validates every field name against `[A-Za-z0-9_]` (must start with a letter or
`_`; max 63 characters; at most one `.` separator for schema-qualified names) and
double-quotes the result.  Any input that fails — including `users; drop table`,
`a.b.c`, `1abc`, `us"er`, `u-v` — returns `DataPlaneError::InvalidIdentifier`
before any SQL string is assembled.  The postgres adapter imports this function
and calls it on every column name in every mutating operation; the unit test
`rejects_injection_attempts` (L78–82 of `ident.rs`) asserts rejection of the
canonical injection strings.

**3. Postgres CRUD builders — `owner_id` server injection and per-column quoting**

[`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/crud_build.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/crud_build.rs)
applies `quote_ident` to every column before producing an assignment (L72–75 for
UPDATE; analogous in INSERT/upsert).  `owner_id` is stripped from the client
`data` map by `writable_columns` (L37–44) and re-injected as a bound `$n`
parameter by `owner_predicate` (L49–61), so the trusted principal is never
string-formatted.  The test `update_rejects_injection_in_column_name` (L324–332)
asserts that `{"evil;--": 1}` as a column name returns `InvalidIdentifier`, not
a successfully assembled query.

**4. RLS context — `serde_json` guards the JWT claims GUC**

[`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs)
`apply_rls_context` (L99–120) assembles the per-request JWT claims object with
`serde_json::json!({...}).to_string()` and passes all three GUC values as bound
parameters to `set_config($1, $2, $3)`:

```rust
let claims = serde_json::json!({ "sub": &principal, "tenant_id": &tenant }).to_string();
client.execute(
    "SELECT set_config('app.current_user_id', $1, true), \
             set_config('app.current_tenant_id', $2, true), \
             set_config('request.jwt.claims', $3, true)",
    &[&principal, &tenant, &claims],
).await?;
```

The inline comment documents the rationale: "a `"` or `}` in the identity cannot
inject a chosen `sub` — which is the RLS principal that `auth.current_user_id()`
reads".  The one interpolated SQL in `apply_search_path` (L128–141) is the
`SET LOCAL search_path` statement, which cannot use bound parameters; the schema
name is pre-sanitized to `[a-z0-9_]` by `DatabaseMount::tenant_schema`, as the
function's doc comment states.

## How we know it is applied

The bind-only invariant is **structural**: `SqlParamSink::bind` is the only method
that records a value, so a filter that emits `n` placeholders has exactly `n`
bound parameters by definition — it is not a runtime check that can be bypassed.

The property test at `sql_scope.rs` L324–332 proves this for arbitrary filter
trees:

```rust
proptest! {
    #[test]
    fn placeholder_count_always_equals_bound_param_count(f in arb_filter()) {
        let (sql, params) = lowered(&f);
        prop_assert_eq!(sql.matches('?').count(), params);
    }
}
```

This test is exercised by `cargo test --workspace`, which runs in CI at
`.github/workflows/ci.yml` L650 and L657 (the Rust data-plane test step).  The
same workspace also runs `update_rejects_injection_in_column_name` and all
`ident.rs` rejection tests on every push.  The `make conformance` target (the m27
gate) exercises the full data-plane execution path — including filter lowering and
`apply_rls_context` — against a live engine.

## Reference

The [OWASP SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
establishes parameterized queries as the primary defense and identifier allowlists
as the required secondary control wherever dynamic identifiers are unavoidable.
Grobase applies both in a single architectural seam: every value goes through
`SqlParamSink::bind`, every column name goes through `quote_ident`, and the one
unavoidable string interpolation (the schema name in `SET LOCAL search_path`) is
pre-validated to `[a-z0-9_]` before the format call.

## Residual risk / assumptions

- **The `SET LOCAL search_path` interpolation** relies on `DatabaseMount::tenant_schema`
  having sanitized the schema name to `[a-z0-9_]` before it reaches `apply_search_path`.
  If a future code path can supply an un-sanitized schema name to that function, the
  one interpolated SQL in the codebase becomes a risk.
- **Non-relational engines** (MongoDB, DynamoDB, Redis, HTTP) do not use SQL at
  all; their injection surfaces are different (NoSQL operator injection, command
  injection) and are addressed by separate controls not covered here.
- **The TS query-router** (`RUST_DATA_PLANE_FORWARD=0`) still forwards queries to
  the legacy NestJS engine, which has its own parameterization story.  The
  structural guarantees documented here apply only to the Rust data plane.
- **Schema-qualified identifiers** accept exactly one `.` separator.  Any
  three-part name (e.g., `db.schema.table`) is rejected by `quote_ident` as
  `InvalidIdentifier`, which is the safe failure mode.
- **Postgres server-side prepared statement caching** depends on column order being
  stable; `writable_columns` sorts columns alphabetically to make the SQL shape
  deterministic.  If a future change breaks that sort, cache misses degrade
  performance but do not introduce injection risk.
