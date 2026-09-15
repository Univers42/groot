# The realtime plane

> **Status:** Partial · 2026-09-15
> **Evidence:** crate layout from the backend document; gates `m175`, `m179`, `m180`; the
> workspace is tracked in git (`git ls-files infra/docker/services/realtime/`)
> **To check:** which bus is assembled by default — `inprocess` or `irc`. Decides whether the
> deployment is single- or multi-node. Also: how long a subscription survives a revoked access.
> **Sources:** `apps/grobase/CLAUDE.md` §Three-language plane

Everything else in grobase rests on one unit: **the request**. Identity is resolved per
request, owner scoping is applied per request, the Rust cutover switch decides per request.

Realtime breaks that unit, which is why it has its own rules.

A subscription is not a request; it is a long conversation. Check authorisation only at connect
time and a permission revoked ten minutes later never lands — the client keeps receiving. Check
it on every delivered message and the cost is unbearable, because the point of realtime is
pushing thousands of cheap events.

**The tension:** the rest of the system is secured by checking every time, and here you cannot
check every time.

---

## Ten crates, two plug points

`realtime-core`, `-engine`, `-auth`, `-gateway`, `-server`, `-client`, plus two database-change
producers (`-db-postgres`, `-db-mongodb`) and two buses (`-bus-inprocess`, `-bus-irc`).
`realtime-server` assembles them.

Two things stand out. A **crate dedicated to authorisation**, separate from the gateway — in
most WebSocket servers that is a fragment of the connection code. And a **client crate**:
publishing a reference client forces the protocol to be defined rather than implied.

The **event bus** is `inprocess` (memory, fastest, single node) or `irc` (a real pub/sub
protocol with channels and membership, so it works across nodes). The **change producer** is
`postgres` or `mongodb`: it listens to what changes in the database and turns it into events.

What to retain: realtime is not a messaging system, it is a **translator** — data changes into
events, over a bus that can be anything. Both plug points being interchangeable is why one plane
serves a single binary and a multi-node deployment.

---

## Protected namespaces — the answer to the tension

If you cannot check per message, make **the right to be subscribed precise**. Two namespaces
are live: `collab:<spaceId>` for document collaboration and `xapp:<channel_id>` for cross-app
messaging.

Gate `m175` proves the property that matters: **a wildcard token cannot subscribe to a
`collab:<spaceId>` it was not added to.**

That is the classic failure of every realtime system: subscription tokens grant patterns like
`collab:*` because one token for everything is convenient, and obtaining one then reaches not a
document but *all* of them. A gate proving the wildcard is *not* sufficient means someone saw
the pattern and closed it. Membership is checked against a list, not a shape.

So: authorisation is checked per subscription, and subscriptions are narrow enough that
authorising once is acceptable. **The price stands** — there is a window between revoking access
and the connection closing, and its length is not yet documented.

---

## Cross-app channels: a consented exception

Gate `m179` opens a bidirectional channel between two app-tenants over `xapp:<channel_id>`,
which appears to contradict `m176`. Three properties make it legitimate, all stated: it is
**consented**, it is **control-plane only** — served over the admin pool and never over an RLS
session variable — and it is **flag-gated** (`APP_CHANNELS_ENABLED`, on in production) with its
own migration.

Same discipline as the HTTP engine: when a hole must be opened in a guarantee, it is opened
explicitly, named, consented and switchable. → [security/03-known-weaknesses](../security/03-known-weaknesses.md)

---

## The browser exception

Gate `m180`: the browser reaches the backend **same-origin only**, through Vercel rewrites —
with exactly one exception, realtime, which connects directly over `wss://`. WebSockets through
a rewrite proxy are poorly supported.

The consequence matters: realtime is the only place a browser touches the backend origin
directly, so origin discipline and token scoping carry the whole weight there. It is a good
answer to "what is your most exposed surface?".

---

**Before demonstrating:** realtime is not in the default `query` edition. Raise
`EDITION=realtime|prod|full` or `PACKAGE=pro`. → [operations/01-bring-up](../operations/01-bring-up.md)

See also: [02-planes](02-planes.md) · [product/02-osionos](../product/02-osionos.md)
