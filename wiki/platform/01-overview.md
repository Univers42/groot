# grobase — overview

> **Status:** Verified · 2026-09-15
> **Evidence:** seven re-platformed vendor apps with numbered verification gates; contracts
> provisioned on every production boot
> **Sources:** `apps/grobase/CLAUDE.md` §What this repo is, §vendor/ · `deploy/fly/boot.sh`
> **Deeper:** [archive/wiki-2026-09/back/](../../archive/wiki-2026-09/back/) ·
> [archive/dossiers/projet-back_en.md](../../archive/dossiers/projet-back_en.md)

grobase is a self-hostable Backend-as-a-Service. Its promise, stated in its own documentation:
**one backend, any frontend, zero per-project server code.**

It is roughly 70% of the work in this project. osionos is its demonstration, not the other way
round.

---

## The problem it solves

Almost every new project rebuilds the same pieces: authentication, user management, relational
CRUD, document CRUD, access control, file upload, transactional email, logs. None of that is
the product. It is the toll paid before the product starts, and it is paid in full every time.

grobase turns that toll into infrastructure. Projects plug into a platform that already has
those pieces instead of growing a new server each.

---

## Why it stays generic

Most "reusable backends" fail the same way. The platform is generic until the first real
requirement arrives, someone adds one specific endpoint, and from then on it is a bespoke
backend with pretensions. Genericity does not collapse — it erodes one afternoon at a time,
always by the same mechanism: **someone expresses in code something that varies per project.**

Six decisions close that door in six places, and they all do the same thing: move what varies
from code into data.

- **Routes carry no domain.** There is no `/api/invoices`; there is a generic operation over
  any table of any database. The table name travels in the request.
- **Schemas are created at runtime.** The shape of the data is a datum, not a compiled
  migration. Every generated table gets an `owner_id` whether you ask for one or not.
- **External databases mount live.** A database someone else owns can be registered and
  queried without moving its data or touching its server.
- **Access control is data.** Row-level policies and stored permission rows, not conditionals
  scattered through controllers.
- **Frontends consume standard primitives only.** Nothing domain-specific crosses the wire.
- **Services are substitutable.** Known by interface, replaceable underneath — which is how the
  data plane was rewritten from TypeScript to Rust without a redesign.

The result, in one line: a backend programmed by **configuration, schema and policy** rather
than by code. See [06-contracts](06-contracts.md) for what that looks like concretely.

---

## The evidence

`vendor/` holds seven third-party applications re-platformed onto grobase: a photo social
network in PHP, a film community in Java/Spring, a surf directory in Laravel, a multiplayer
Tetris, a restaurant ordering app, a video search tool. Each has numbered gates exercising a
live round trip. They are excluded from the default build and CI — they are the proving ground.

Two adoption shapes, and the distinction matters:

- **Re-platformed** — the app's own backend disappears; its frontend talks only to Kong.
- **External mount** — the app keeps its backend intact and grobase mounts its live database.
  The app never notices. This is what the osionos database block exposes to users.

---

## What it costs

Three prices, and they are real.

**Expressiveness is deliberately narrow.** Business logic has nowhere to live. When the
restaurant app was re-platformed, its logic had to be rehoused in PostgreSQL triggers. A rule
that would be three lines in a service must become a policy, a schema constraint, or nothing.

**A generic query surface is a generic attack surface.** Every degree of freedom given to the
client is paid for in the control plane. See [07-isolation](07-isolation.md).

**The blast radius is shared.** One backend per project means an outage affects one product.
A common platform means it affects everything plugged in. Most of the discipline visible in
this repo — shadow mode, editions, flag-gating, 160 gates — is what that costs.

---

See also: [02-planes](02-planes.md) · [07-isolation](07-isolation.md) ·
[product/01-apps](../product/01-apps.md)
