# The gates that matter

> **Status:** Verified · 2026-09-15
> **Evidence:** each gate's purpose read from the backend document's gate index
> **Sources:** `apps/grobase/CLAUDE.md` §Verify gates · `scripts/verify/`

Eight out of roughly 160. These are the ones that carry a claim someone will question.

---

## `m174` — six engines, one application key

osionos queries **Postgres, MySQL and Mongo** in one script and **SQLite, MSSQL and DynamoDB**
in the other — all through a single application key.

**The best demonstration in the project** — the product thesis end to end: one block giving views
over anything, no per-engine client. → [platform/08-engines](../platform/08-engines.md)

---

## `m46` — shared pools do not leak

Tenants sharing a pool cannot reach each other's rows. Validates the decision the whole system
rests on: scoping travels with the request, so connections can be anonymous and therefore
shareable. Without it, the ten-thousand-tenant claim is an assertion.
→ [platform/07-isolation](../platform/07-isolation.md)

---

## `m176` — applications cannot see each other

A foreign key pointing at another application's mount resolves **zero rows — a 404, never a
cross read**.

The 404 rather than a 403 is the right answer: not "you lack permission" but "it does not
exist".

---

## `m177` — the factory runs itself

`POST /v1/tenants/me/apps` creates a new app-tenant with its own fresh `CREATE DATABASE` and a
scoped key, behind `APPS_SELFSERVE_ENABLED` (**on in production**). Paired with `m165`, the
strongest candidate for a custom module: one request produces an entire backend.
→ [platform/06-contracts](../platform/06-contracts.md)

---

Its companion **`m165`** proves the other half: two declarative files produce an isolated
database, seeded, with minted keys and the frontend's `PUBLIC_*` configuration emitted.

---

## `m175` — wildcards do not open realtime spaces

A wildcard token **cannot** subscribe to a `collab:<spaceId>` it was not added to.

This closes the classic realtime hole: tokens tend to grant patterns like `collab:*`, and
obtaining one then reaches every document. A gate proving the wildcard is *insufficient* means
someone recognised the pattern. → [platform/05-realtime](../platform/05-realtime.md)

---

## `m27` — engines serve exactly what they advertise

`make conformance`. Every adapter driven through its public pool surface against a **real**
engine, asserting it serves precisely its declared capability set.

Its in-code counterpart, `descriptor_advertises_exactly_what_dispatch_implements`, compares the
descriptor against the very constant dispatch uses. **The catalogue cannot lie.**
→ [platform/03-data-plane](../platform/03-data-plane.md)

---

## `m140` — network controls and WAF

Not flag-gated: it runs in the default configuration.
→ [security/04-network](../security/04-network.md)

---

## Also worth knowing

**`m179`** — consented cross-app channels: the documented exception to `m176`, on in production.
→ [security/03-known-weaknesses](../security/03-known-weaknesses.md)
**`m180`** — browser reaches the backend same-origin only, realtime's `wss://` excepted.

---

## Using these in the evaluation

Pair each claim with its gate rather than asserting it alone:

| If asked | Say | Show |
|---|---|---|
| "Is it really multi-engine?" | One API, seven engines by default | `m174` |
| "How is tenant data isolated?" | Per request, on engines that can scope | `m46`, `m176` |
| "Anyone can create an app?" | Declared, not programmed | `m165`, `m177` |
| "Is the realtime secure?" | Per subscription, wildcards insufficient | `m175` |
| "How do you know?" | A gate per claim, and no vacuous passes | [01-gates](01-gates.md) |

**Invoke gates by full name, not number** — some numbers are reused.

---

See also: [01-gates](01-gates.md) · [DEFENSE.md](../DEFENSE.md)
