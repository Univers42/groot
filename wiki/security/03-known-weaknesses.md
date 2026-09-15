# Known weaknesses

> **Status:** Verified · 2026-09-15
> **Evidence:** every item here is documented in the code or docs that implement it, not
> inferred; read `src/control-plane/internal/identity/identity.go` header comment first
> **Sources:** `identity/identity.go` · `crates/data-plane-pool/README.md` §http.rs ·
> `apps/grobase/CLAUDE.md` §flag-gating

Read this before the pages describing what works. In an evaluation, **saying it first changes
the conversation**. Everything here is *declared* — written where it lives, not found by us.

---

## 1 · Header-based authorisation in the control plane

The most serious item, and it documents itself. From the header of `identity/identity.go`:

```go
// THE FINDING: several control-plane handlers authorize a tenant-scoped request
// on a RAW, unsigned `X-Baas-Tenant-Id` header that equals the path {id} — with
// no independent crypto check. Today that is contained ONLY by Kong routing +
// ip-restriction: one misrouted/widened Kong route turns a forged header into
// cross-tenant access (the data plane re-derives the tenant from the verified
// api-key; these control-plane reads do not, so the header IS the authority).
```

**Mitigation, shipped:** an opt-in, fail-closed HMAC over the asserted identity
(`TENANT_HEADER_IDENTITY_HMAC`), reusing one signature mechanism rather than a parallel one.
With the flag **off**, behaviour is byte-identical to before — proven by
`FuzzTenantSelfMatch_FlagOff` over arbitrary input — so enabling it is safe and reversible.

**Deeper fix, named and not done:** derive the tenant from a verified credential, as the
self-serve path already does, so the header is never authoritative. It needs each caller to
forward a credential these internal routes do not receive today.

**Status:** the flag is not set in production. Containment is currently network-level.

---

## 2 · The `http` engine does not scope

An HTTP mount has no schema, database or keyspace, so it applies **no per-request scoping under
any isolation strategy**. It forwards an `X-Owner-Id` header derived from the identity and
leaves authorisation to the upstream service. The crate README calls it an explicit no-op, and
the strategy enum resolves `http` to "none" deliberately.

So: on this one engine, the seam the whole system rests on does not exist.
→ [platform/07-isolation](../platform/07-isolation.md)

**How to state it:** *scoping is applied per request on the seven engines that have somewhere to
apply it; HTTP mounts have no surface to scope, so we propagate identity and authorisation stays
with the remote service.*

---

## 3 · Cross-app channels are a deliberate hole

`APP_CHANNELS_ENABLED` (**on in production**) opens a bidirectional channel between two
app-tenants — exactly what `m176` otherwise forbids. Legitimate because it is consented by both
sides, control-plane only (admin pool, never an RLS session variable), and switchable, with its
own migration and gate `m179`. Worth knowing it is on: "apps cannot see each other" has a
documented exception in the running system.

---

## 4 · Stale snapshots

Identity, permissions and quotas are decided in the control plane and read from cached snapshots
in the data plane. A snapshot is stale by definition. Between revoking a key and the cache
refreshing, requests pass. **The `verify_cache` TTL is not documented** — it is the length of
that window. → [platform/04-control-plane](../platform/04-control-plane.md)

The same shape in realtime: authorisation is checked per subscription, not per message, so
there is a window between removing someone from a space and their socket closing. Also not
documented. → [platform/05-realtime](../platform/05-realtime.md)

---

## 5 · Escape hatches that must stay unset

`DATA_PLANE_HTTP_ALLOW_INTERNAL=1` disables the SSRF guard for development mocks. In production
it would re-open the cloud-metadata vector the guard exists to close.
→ [04-network](04-network.md)

---

## 6 · The silent failure mode

Not a bug — a property. A fault in owner scoping does not raise an error; it returns a correct-
looking response containing someone else's rows. No exception, no alert. That is why the gates
are the only sensor that exists, and why a vacuous pass is worse than a failure.

---

See also: [02-proofs](02-proofs.md) · [DEFENSE.md](../DEFENSE.md)
