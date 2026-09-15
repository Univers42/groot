# Input Validation — grobase (the BaaS backend)

> Every UPDATE and DELETE issued through the data plane is rejected with HTTP 400 unless the caller supplies a filter that constrains at least one column beyond the system-reserved owner/tenant predicates, making accidental or malicious full-table mutation structurally impossible.

## What it is (the concept)

**Input validation** is the practice of rejecting requests whose parameters fall outside an acceptable domain before any processing occurs. In the data-mutation context, the specific sub-control in use here is a **non-empty filter invariant**: a **constraining filter** is one whose logical fold does not reduce to `AlwaysTrue` (the degenerate case that would match every row). The data plane enforces this as a hard **schema-level guard** at SQL-build time, not a caller convention.

## What it defends against

See [Injection Attacks (SQLi, XSS, Command Injection)](../../attack/input-validation.md).

A missing or tautological filter on a mutating endpoint is the simplest mechanism for mass data destruction — either by an application bug that omits the `WHERE` clause, or by a deliberate payload that supplies a structurally valid but vacuously true filter (e.g. `{}`). In grobase's multi-tenant context, a single such request reaching the wrong table could wipe an entire tenant's dataset in one round-trip, with no second chance.

## How grobase implements it

Two layers cooperate to enforce the invariant:

**Layer 1 — semantic fold guard** (`src/data-plane-router/crates/data-plane-pool/src/sql_scope.rs`, lines 73–89):

`guard_constraining_filter` strips the `owner_id` and `tenant_id` keys that the system appends unconditionally (so a caller cannot "satisfy" the check by submitting only those keys), then calls `Filter::parse().fold()`. Any result that folds to `Folded::AlwaysTrue` — including `None`, `{}`, `{ "$and": [] }`, `{ "$not": { "$or": [] } }`, or a filter that becomes empty after stripping reserved keys — is rejected immediately:

```rust
if folded == Folded::AlwaysTrue {
    return Err(DataPlaneError::InvalidRequest {
        message: "update/delete requires a constraining filter \
                  (refusing full-table mutation)".to_string(),
    });
}
```

**Layer 2 — SQL builder guard** (`src/data-plane-router/crates/data-plane-pool/src/postgres/crud_build.rs`, lines 82–115):

`build_update_sql` and `build_delete_sql` each independently check whether `build_where` produced a non-empty WHERE fragment. An empty fragment triggers a second `InvalidRequest` error before the SQL string is ever formed:

```rust
// build_update_sql (L83-88)
if where_sql.is_empty() {
    return Err(DataPlaneError::InvalidRequest {
        message: "update requires a non-empty `filter` \
                  (refusing full-table update)".to_string(),
    });
}

// build_delete_sql (L110-115)
if where_sql.is_empty() {
    return Err(DataPlaneError::InvalidRequest {
        message: "delete requires a non-empty `filter` \
                  (refusing full-table delete)".to_string(),
    });
}
```

The owner predicate (`owner_id = $N`) is appended **after** both guards pass, ensuring that scoping is additive and cannot substitute for a caller-supplied constraint.

## How we know it is applied

The guards are exercised by two unit test suites that run on every CI push:

**`guard_refuses_none_and_tautologies`** (`sql_scope.rs`, lines 463–481) drives six distinct unconstrained inputs — `None`, `{}`, `{ "$and": [] }`, `{ "$not": { "$or": [] } }`, an owner-only filter, and an owner-plus-tenant filter — and asserts each produces `DataPlaneError::InvalidRequest`.

**`update_refuses_empty_filter`** and **`delete_scopes_owner_and_refuses_empty_filter`** (`crud_build.rs`, lines 311–365) assert that `build_update_sql` and `build_delete_sql` both return `InvalidRequest` for a `None` filter or an empty-object filter.

The CI gate that runs these is `.github/workflows/ci.yml`, line 650:

```
docker run --rm ... -v "$PWD/src/data-plane-router:/src" -w /src \
  rust:1-bookworm cargo test --workspace
```

This invocation runs the full data-plane cargo workspace, including `data-plane-pool`, on every pull request and push to `main`.

## Reference

The OWASP Input Validation Cheat Sheet ([https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html)) establishes the principle that validation must occur server-side, independent of client assumptions, and must cover semantic correctness — not just syntactic well-formedness. The grobase guard satisfies both requirements: it runs entirely in the data plane, and it validates the *logical meaning* of the filter (folding to `AlwaysTrue` is a semantic failure even when the JSON is syntactically valid).

## Residual risk / assumptions

- **Non-Postgres engines.** The fold guard in `sql_scope.rs` is engine-agnostic, but the SQL builder guards in `crud_build.rs` are in the `postgres/` submodule. Other engine adapters (`mysql`, `mongo`, `mssql`, `sqlite`, `redis`, `http`, `dynamodb`) must implement equivalent guards independently; their coverage is not asserted here.
- **Partial filter correctness.** The guard blocks the tautologically-unconstrained case; it does not validate that the supplied filter is *semantically correct for the caller's intent*. A filter `{ "id": 9999 }` that matches no rows passes the guard and produces an UPDATE/DELETE that affects zero rows — silent but not destructive.
- **TS legacy path.** The guard applies to the Rust data plane. Requests routed through the TypeScript query-router (when `RUST_DATA_PLANE_FORWARD` is off or the engine is not in `RUST_DATA_PLANE_FORWARD_ENGINES`) are subject to whatever validation that layer enforces, which is outside the scope of this document.
- **Authenticated callers only.** The guard assumes the caller has already been authenticated by the control plane API-key verification step. An unauthenticated request never reaches the SQL builder; the guard is therefore a defense-in-depth measure on top of auth, not a substitute for it.
