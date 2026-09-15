# The four planes, and the seam

> **Status:** Verified · 2026-09-15
> **Evidence:** plane layout and package counts read from the authoritative backend document;
> the seam is exercised by every query in production
> **Sources:** `apps/grobase/CLAUDE.md` §Three-language plane layout, §Editions
> **Deeper:** [archive/wiki-2026-09/back/](../../archive/wiki-2026-09/back/)

A **plane** is not a layer. A layer implies order — each sits on the one below and a request
passes through all of them. A plane is a set of responsibilities answering the same *kind* of
question. A request may touch two planes and never touch the others.

Think of an airport: the tower decides who takes off, the runways execute departures. Neither
sits on top of the other, which is why they can be sized and replaced separately.

---

## The four

**Application plane** — TypeScript, NestJS. `src/apps/` and `src/libs/`: query-router,
storage-router, and services for schema, session, permissions, analytics, AI, email, GDPR and
newsletter. The oldest plane, being hollowed out; today mostly a front door.

**Control plane** — Go. `src/control-plane/`: **44 internal packages, 6 binaries**. Provisions,
manages tenancy, resolves identity. Go suits it — concurrent I/O, long-running processes, and a
clear preference for code that reads plainly over code that runs at the limit. A provisioner
does not need to be fast; it needs to be correct and boring. → [04-control-plane](04-control-plane.md)

**Data plane** — Rust. `src/data-plane-router/`: four crates, eight engine adapters. Every
query passes through here. Rust justifies itself on the hot path: predictable latency with no
garbage-collector pauses, and memory safety where a fault is not a crash but a cross-tenant
leak. → [03-data-plane](03-data-plane.md)

**Realtime plane** — Rust, a separate workspace of ten crates with a pluggable event bus and a
pluggable database-change producer. → [05-realtime](05-realtime.md)

> A note on counting. The April dossier also describes "four planes", but conceptual ones —
> identity, control, data, operations. They do not map onto these. The dossier's scheme says
> *why* the system is split; this one says *where things live*.

---

## The seam that carries the load

The control plane resolves an API key to an identity via `POST /v1/keys/verify`. The data plane
executes the query and scopes it to the owner **on every request**.

Control decides and executes nothing. Data executes and decides nothing.

Why per-request scoping rather than per-connection is the central argument of the whole system,
and it has its own page: [07-isolation](07-isolation.md).

The cost is amortised: the data plane carries its own ABAC evaluator in Rust and caches key
verification, so it decides locally. The real price is not latency — it is the same permission
logic living in two languages and having to agree.

---

## Shapes: editions, packages, planes

There are **fifteen** compose planes and they do not all come up. Two orthogonal vocabularies
combine them.

An **edition** is a named set of planes — `lean query realtime analytics prod full`. The
default is `query`: data, go, rust, adapter, background. Editions are engineering shapes.

A **package** is a customer tier — `nano basic essential pro max`, growing by accumulation.
Packages are commercial shapes.

Precedence when several are set: profiles over package, package over edition.

Two vocabularies for one stack costs real confusion, accepted because an engineer wants the
minimum shape and a customer buys a service level.

**Practical consequence:** realtime is not in the default edition. Demonstrating live
collaboration on `EDITION=query` shows nothing. → [operations/01-bring-up](../operations/01-bring-up.md)

---

## The TypeScript → Rust cutover

Two independent switches, both per request, not per build.

```
RUST_DATA_PLANE_FORWARD=1                 # TS side: does traffic go to Rust?
RUST_DATA_PLANE_FORWARD_ENGINES=...       # one engine at a time
DATA_PLANE_ROUTER_PRODUCT_MODE=shadow     # Rust side: serve, or only compute? (default shadow)
```

In `shadow`, Rust executes and discards the result. That allows comparing both implementations
under real production traffic at zero risk — no staging environment reproduces real traffic
with its odd queries and dirty data. Rolling back needs no deployment.

---

See also: [01-overview](01-overview.md) · [07-isolation](07-isolation.md) ·
[operations/02-flags](../operations/02-flags.md)
