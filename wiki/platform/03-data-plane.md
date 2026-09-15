# The data plane

> **Status:** Partial · 2026-09-15
> **Evidence:** crate layout and the honesty tests read from the crate READMEs, which the
> backend document names as authoritative for this plane; gate `m27` runs conformance
> **To check:** the exact operation envelope — `GET /engines` on a running stack
> **Sources:** `crates/data-plane-{core,pool,server,engine-conformance}/README.md`
> **Deeper:** [08-engines](08-engines.md)

Four crates, and the division is clean.

- **`data-plane-core`** — the truth: types, operation semantics, the per-engine capability
  catalogue, the isolation directive, the planner. Talks to no database.
- **`data-plane-pool`** — the eight adapters, the mount resolver, and the credential layer.
- **`data-plane-server`** — the axum binary: authenticate, authorise, resolve, execute, answer.
  Also rate limits, quotas, metering, audit, and the single-binary product editions.
- **`engine-conformance`** — a test-only battery that drives any adapter against a **real**
  engine and asserts it serves exactly what it advertises.

That fourth crate sitting as a peer is a statement: cross-engine conformance is part of the
product, not an external check.

---

## A request, end to end

Authenticate → `RequestIdentity` → authorise (ABAC field masks) → resolve the mount → run the
operation through planner and adapter → return JSON.

```rust
tier_max_rows(...)                       // clamp the limit to the contracted tier
state.registry.get_or_create(mount)      // pooled connection for this mount
pool.execute(operation, identity)        // identity travels WITH the operation
map_data_plane_error(...)                // 400 402 403 404 409 422 501 502
```

`pool.execute(operation, identity)` is the signature that summarises the project. An operation
is not run *in a context*; it is run **with an identity**. The `402` — Payment Required — comes
from quota and spend caps, decided in the control plane and read from a locally cached snapshot.

---

## Engine-agnostic by construction

Stated in the backend document as a completion criterion, not an aspiration: **a fix that works
for Postgres but breaks the other seven is not done.**

Here parity is the bar rather than an aspiration, which is why the conformance crate exists.

The cost is severe: every new capability costs eight times, and costs *the minimum of the
eight*. A structural brake on speed, accepted so that "any engine" is true.

---

## Capability honesty

Engines are not equally capable. Postgres has native row-level security; Mongo does not. Redis
has no tables. A single API over eight unequal engines can only reduce to the lowest common
denominator — useless — or **declare what each one can do**. grobase declares.

The mechanism has a name in the repo: `capability_honesty`.

```rust
descriptor_advertises_exactly_what_dispatch_implements()
// dispatch_reality(engine) returns the very SUPPORTED_OPS const the adapter's
// dispatch gate uses — not a hand copy. descriptor(engine) returns what it
// advertises. The test asserts they agree, for every op of every engine.
```

**The catalogue cannot lie.** Advertising something you do not implement fails the test. Pinned
flags back this against real `begin()` implementations: `batch` is true for pg, mysql, mongo and
redis and false for http; `transactions` is true for pg and mysql, false for mongo, redis and
http.

The per-engine honesty call-outs are the best part: Mongo advertises `schema_ddl: true` but
`ddl: false`, and DynamoDB alone can set `native_idempotency: true` honestly. See
[08-engines](08-engines.md).

One layer up, the SDK's `src/generated/` is gitignored **except** `engines.ts`, the capability
catalogue, which is committed and pinned by a type test. The generator only diffs it against a
live `/engines` endpoint. Capabilities are a public promise, not a derived artifact: changing
them should be a decision, not a side effect.

---

## Rejecting rather than pretending

When an engine cannot satisfy an operation the planner does not improvise.

```rust
Verdict::FederateOrReject -> Plan::Reject(NotImplemented)   // federation off by default
```

The stated justification: *the workload never silently succeeds.* Returning an empty or partial
result would be a better immediate experience and a much worse system — a rejection is visible,
an incomplete result that looks complete is not.

---

See also: [08-engines](08-engines.md) · [07-isolation](07-isolation.md) ·
[quality/02-key-gates](../quality/02-key-gates.md)
