# Isolation — scoping travels with the request

> **Status:** Verified · 2026-09-15
> **Evidence:** gates `m46` (shared pools), `m176` (cross-app), `m175` (realtime namespaces);
> two non-merging production databases prove per-user `read_scoped` isolation over public HTTPS
> **Sources:** `crates/data-plane-core/README.md` · `infra/config/contracts/website.json` ·
> `apps/grobase/CLAUDE.md` §Three-language plane

This is the decision everything else rests on. One sentence: **every query carries the identity
of whoever asked, and scoping is applied at that moment — not held in the connection.**

---

## Why per-request, and not the alternatives

Suppose a thousand tenants must share a database server, none able to see another's rows.
Three ways.

**One connection per tenant.** Obvious, and perfect at ten tenants. At ten thousand it fails —
connections are a scarce resource with a hard ceiling. Not slow: impossible.

**Scope by connection state.** Set the tenant context each time a pooled connection is handed
out. Fewer connections — but now a connection *remembers* whose it is. Return one to the pool
uncleaned and the next user inherits someone else's identity: a silent cross-tenant leak.

**Scope per request.** The connection remembers nothing. Identity travels with the query.
Connections become interchangeable because they are anonymous, and therefore shareable without
limit.

grobase does the third, and the documentation names the consequence: it is what lets
`SHARE_POOLS` collapse **ten thousand tenants onto a single pool**. That number is not
marketing — it falls out of this choice.

---

## As a function

```rust
Isolation::scope(&DatabaseMount, &RequestIdentity) -> ScopeDirective

// SharedRls | DbPerTenant | TenantOwned  -> None
// SchemaPerTenant  -> SetSearchPath   (postgres)
//                  -> UseNamespace    (mysql, mongo, redis, dynamodb)
//                  -> None            (http, unknown)
```

It takes the mount and **the identity of this request** and returns how to scope. The
`"isolation": "shared_rls"` field from the contract enters here.
→ [06-contracts](06-contracts.md)

Four strategies exist. The contract path produces database-per-application in practice;
`SharedRls` is the dense mode, the only one compatible with collapsing tenants onto one pool.

---

## Where it does not reach

The last branch is not an oversight. **An HTTP mount has no schema, no database, no keyspace**
— there is nothing to attach a scope to. So it applies **no per-request scoping under any
strategy**. Instead it forwards an `X-Owner-Id` header derived from the identity and leaves
authorisation to the upstream service. The crate README describes it as an explicit no-op.

Read that against the sentence at the top of this page: on the HTTP engine, the seam does not
exist.

What makes this good engineering rather than a hole is that it is **declared** — in the place it
lives, with "no-op" used on purpose.

**How to say it.** Not "grobase isolates tenants". Say: *scoping is applied per request on the
seven engines that have somewhere to apply it; HTTP mounts have no surface to scope, so we
propagate identity and authorisation stays with the remote service — and it is documented as
such.* Longer, and far stronger, because it shows you know your own limits.

---

## The failure mode

Worth stating plainly, because it shapes everything else in the repo.

A fault here does not produce an error. It produces a **correct-looking response containing
someone else's rows**. No exception, no stack trace, no alert. Silent by nature.

That is why `m46` and `m176` are not nice-to-haves but the only sensors that exist, and why
the repo insists that a gate passing vacuously is not a gate.
→ [quality/01-gates](../quality/01-gates.md)

---

## In realtime

Subscriptions cannot be scoped per message, so they are scoped per subscription instead, with
namespaces narrow enough that authorising once is acceptable. Gate `m175` proves a wildcard
token cannot reach a space it was not added to. → [05-realtime](05-realtime.md)

---

See also: [03-data-plane](03-data-plane.md) · [security/02-proofs](../security/02-proofs.md) ·
[security/03-known-weaknesses](../security/03-known-weaknesses.md)
