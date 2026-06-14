# C1 — Supavisor connection pooler (opt-in) + pooled-vs-direct parity

Overlay: [`../../docker-compose.pooler.yml`](../../docker-compose.pooler.yml).
**Opt-in only — never a default.** The base stack stays byte-parity; nothing in
`docker-compose.yml` changes.

## What it wires

```
data-plane-router-rust ──(system/outbox DSN)──► supavisor:6543 (txn mode) ──► postgres:5432
                          per-tenant mounts ────────────────────────────────► (unchanged: DSN from adapter-registry)
```

- Brings the base **Supavisor stub** up with a full transaction-mode config.
- Sets two data-plane env vars — the **C1 wiring seam**:
  - `DATA_PLANE_POOLER_URL` → `postgres://…@supavisor:6543/…` (the pooled system DSN)
  - `DATA_PLANE_STATEMENT_CACHE=off` → tells the data plane to stop client-side
    prepared-statement caching, **required** under a transaction-mode pooler
    (prepared statements are not preserved across pooled checkouts).
- Adds `depends_on: supavisor (service_healthy)` so the data plane waits.

> **Honest status:** the Rust data plane does **not yet read** these two vars
> (verify: `grep -r DATA_PLANE_POOLER_URL docker/services/data-plane-router/src`
> returns nothing today). Applying this overlay brings up a real, health-gated
> Supavisor and stamps the intended config, but does **not** silently reroute
> traffic. The consuming change (config.rs: prefer `DATA_PLANE_POOLER_URL` over
> `DATA_PLANE_OUTBOX_DSN`; gate statement caching on `DATA_PLANE_STATEMENT_CACHE`)
> is a separate one-line-behind-a-flag edit owned by the data-plane slice. This
> file + the overlay are the reviewable, lint-clean seam.

## Run

```bash
cd apps/baas/mini-baas-infra

# Direct baseline (no overlay) — the default stack.
make up PACKAGE=essential

# Pooled (opt-in) — bring postgres, supavisor, and the data plane up together.
docker compose -f docker-compose.yml -f docker-compose.pooler.yml \
    up -d postgres supavisor data-plane-router-rust

# Confirm supavisor is healthy + the seam env landed.
docker inspect mini-baas-supavisor --format '{{.State.Health.Status}}'
docker inspect mini-baas-data-plane-router-rust \
    --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'POOLER_URL|STATEMENT_CACHE'

# Tear down: re-up WITHOUT the overlay → back to direct, byte-parity.
docker compose -f docker-compose.yml up -d data-plane-router-rust
```

## Pooled-vs-direct PARITY expectation

A connection pooler is a **transport optimization, not a semantic one**. The
contract: **for every request, pooled and direct return byte-identical bodies +
status codes.** A pooler changes *how* connections are reused, never *what* a
query returns. Concretely:

| Property | Direct | Pooled (txn mode) | Parity expectation |
|---|---|---|---|
| Response body / status | baseline | — | **byte-identical** (the gate) |
| Isolation (RLS / owner-scope) | per-request `apply_rls_context` | same — re-stamped per checkout | **identical** (pooling holds no tenant state, same reason SHARE_POOLS is neutral — see `wiki/scale-slo.md` §1) |
| Prepared statements | client-cached | **disabled** (`STATEMENT_CACHE=off`) | identical results; first-call latency may rise slightly (no plan reuse) |
| Connection count to PG | 1 per data-plane pool | bounded by `POOLER_DEFAULT_POOL_SIZE` | pooled holds PG conns ≤ direct under fan-out (the *point* of C1) |
| `SET`/session GUCs across statements | same backend | **not guaranteed** across txn-mode checkouts | the data plane already stamps GUCs **per request inside one txn**, so this is safe; any cross-request session state would NOT be (none exists today) |

**The honest caveat that makes txn-mode safe here:** isolation is applied
*inside each request's transaction* (`apply_rls_context` runs at the top of the
request), so a transaction-mode pooler — which can hand a different backend to
the next request — never leaks tenant state. This is the **same invariant** that
lets 24,887 tenants share one pool (`wiki/scale-slo.md`). If a future change
ever moves isolation to a *session*-level `SET` outside the request txn, txn-mode
pooling would break it — that is the one thing the parity gate must guard.

## Parity gate (to author when the seam goes live — C1 gate)

`scripts/verify/m<NN>-pooler-parity.sh` (not yet authored — depends on the
data-plane consuming the vars): run the same request set against the **direct**
stack and the **pooled** stack, diff the response bodies, assert:
- `diff` of normalized bodies is empty (byte-parity), and
- `baas_data_plane_pg_connections` (pooled) ≤ direct under identical fan-out.

Until that gate exists this is **scaffold** (kernel rule #5): the overlay is
real and validated (`docker compose config` merges clean), but pooled traffic
parity is **not yet measured**.
