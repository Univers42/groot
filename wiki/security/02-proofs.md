# What is proven, and by what

> **Status:** Verified · 2026-09-15
> **Evidence:** this page *is* the evidence index; each row names its gate
> **Sources:** `apps/grobase/CLAUDE.md` §Verify gates · `crates/data-plane-pool/README.md` ·
> `src/control-plane/internal/identity/identity_test.go`

A security claim without a test is an opinion. This page lists what we can actually stand
behind, what proves it, and — the part people skip — **what each proof does not cover**.

---

## Isolation

| Claim | Proof | Does not cover |
|---|---|---|
| Sharing a pool between tenants leaks nothing | `m46` | Engines with no scoping surface (`http`) |
| One app cannot read another's data | `m176` — a foreign key to another app's mount resolves **zero rows, a 404** | Deliberately consented cross-app channels (`m179`) |
| A new app gets its own fresh database and scoped key | `m177` | Requires `APPS_SELFSERVE_ENABLED` (on in production) |
| A wildcard realtime token cannot reach a space it was not added to | `m175` | The window between revoking access and the socket closing |
| Per-user `read_scoped` isolation holds in production over public HTTPS | Two non-merging PostgreSQL databases (website, vault42) on the live deployment | — |

That last row is the strongest thing here: not a local test but the running system, over the
internet, with two real products.

---

## Engine behaviour

**`m27` / `make conformance`** drives every adapter through its public pool surface against a
**real** engine — not a mock — and asserts it serves exactly what its descriptor advertises.

**`capability_honesty`** closes the gap between promise and implementation in code:

```rust
descriptor_advertises_exactly_what_dispatch_implements()
```

`dispatch_reality(engine)` returns the very `SUPPORTED_OPS` constant the adapter's dispatch gate
uses — not a hand copy — and the test asserts it matches what the engine advertises, for every
operation of every engine. **The capability catalogue cannot lie.**
→ [platform/03-data-plane](../platform/03-data-plane.md)

**`m174`** exercises six engines through a single application key. It is the best single
demonstration in the project. → [quality/02-key-gates](../quality/02-key-gates.md)

---

## The identity path

`src/control-plane/internal/identity/` carries the most rigorous test suite in the repository,
and it is worth knowing it exists because the code it guards is a known weak point.

Named unit tests, each one an attack:

```go
TestTenantSelfMatch_HMACRejectsForgedHeaderNoSignature   // "THE FORGE VECTOR"
TestTenantSelfMatch_HMACRejectsSpoofedTenant             // a signature for T does not authorise T2
TestTenantSelfMatch_HMACRejectsExpiredTimestamp          // replay outside the ±120s window
TestTenantSelfMatch_HMACRejectsWrongToken                // signed with the wrong key
TestTenantSelfMatch_EmptyIdNeverMatches                  // no self-grant without a tenant id
```

And two fuzz tests, fed arbitrary input rather than chosen cases:

- `FuzzVerifyIdentitySignature` — for **any** header, the verifier must not panic, and the only
  way it may return true is a byte-equal freshly computed signature.
- `FuzzTenantSelfMatch_FlagOff` — with the flag off, behaviour is identical to the previous
  implementation for **any** (header, id) pair.

That second one is the instructive one: it is how you demonstrate that a flag defaulting to off
changes nothing. Not with three hand-picked cases — with arbitrary input.

---

## Network

**`m140`** covers network controls and the WAF, and is **not flag-gated** — it runs in the
default configuration. → [04-network](04-network.md)

The SSRF guard on the `http` engine is covered by unit tests in `data-plane-pool` rather than a
numbered gate; verify before quoting it as gate-backed.

---

## How to read a green result

The repo's own rule, and it applies to this page too: **a gate that passes vacuously is not a
gate.** A green run tells you a script exited zero. It tells you nothing until you know the
script exercised the behaviour. When something matters, read the script — the Makefile targets
are thin wrappers. → [quality/01-gates](../quality/01-gates.md)

---

See also: [01-model](01-model.md) · [03-known-weaknesses](03-known-weaknesses.md)
