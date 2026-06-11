# Data-plane cutover status (Phase 7 / D6)

The TypeScript→Rust data-plane cutover follows **shadow → parity → cutover**, and
deletion is gated (CLAUDE.md). This tracks where the live demo stands.

## State: bypass is PRODUCTION-READY; app flip is the remaining (out-of-band) step

| Layer | Status |
|---|---|
| Rust `/data/v1` (query, schema, DDL, graph, masks, automations, realtime via outbox) | ✅ feature-complete, parity-gated |
| `DATA_PLANE_BYPASS_ENABLED` | ✅ **default ON** — the Kong `/data/v1` route is live |
| Kong `/data/v1` route (key-auth + ip-restriction, two-key app auth) | ✅ live |
| Shadow parity (direct Rust port) | ✅ `m31-bypass-shadow` |
| **Cutover parity (through Kong, app's real mount)** | ✅ **`m36-cutover-parity`** — list/get/aggregate row-identical to `/query/v1` |
| query-router / permission-engine | ✅ **kept as the fallback — NOT deleted** |
| **App flips its base path `/query/v1` → `/data/v1`** | ⏳ pending (osionos-side change) |

## The remaining step (app-side, deliberately not done here)

The osionos app calls `/query/v1/<dbId>/tables/<table>` with a `{op, …}` body in
`apps/osionos/app/src/features/second-brain/baas/*`. The cutover flips that to the
`/data/v1/query` route with a `{db_id, operation:{op, resource, …}}` body. That is
an **osionos submodule change** (its own branch/review per CLAUDE.md), not a BaaS
change — so it is intentionally left to a dedicated app PR. The BaaS side is ready
and proven: `make verify-m36` is the green light.

## Deletion gate (still CLOSED — do not delete TS)

Deleting query-router/permission-engine requires ALL of: m18 live traffic on Rust
with the app actually flipped, sustained shadow parity, and CI green with forward
routing. Until the **app flip** above ships and soaks, the TS path stays as the
fallback. `make verify-m36` proves readiness; it does **not** authorize deletion.

## Roll back

`DATA_PLANE_BYPASS_ENABLED=0` removes the `/data/v1` routes (the app is unaffected —
it still uses `/query/v1`).
