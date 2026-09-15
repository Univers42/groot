# osionos — the block editor

> **Status:** Partial · 2026-09-15
> **Evidence:** the six-engine capability is proven by gate `m174`; the `#source=adapter` seam
> is visible in the bridge handoff URL
> **To check:** whether osionos consumes the published `@notion-db/object-database` package or
> carries its own implementation — decides whether the relationship with `notion-database-sys`
> is a dependency or a lineage. And whether that repo is inside the delivered perimeter with its
> own Fastify backend, which would be an exception to "zero per-project server code".
> **Sources:** `apps/osionos/README.md` · `notion-database-sys/README.md` · gate `m174`

A Notion-style workspace: pages built from blocks, where notes, tables and business models are
organised and viewed. React + Vite, no server of its own.

Its distinctive block is **a block that is a database**.

---

## The database block

Drag it onto a page and it gives you views — table, board, calendar — over a data source. The
ambitious part is what a data source can be: **any database or product you want to integrate**,
including one that belongs to someone else and keeps running its own backend.

That is not a feature osionos implements. It is grobase's external-mount mechanism given a face.

Put the two together and the architecture snaps into focus. What
[platform/01-overview](../platform/01-overview.md) describes as "external databases mount live"
— an infrastructure decision, invisible to anyone — becomes, here, a block you drag onto a page.

There is a small, pleasing proof that this is not theory. The URL the bridge uses to hand over
the editor carries:

```
#source=adapter&view=v-prod-table
```

The source is **adapter** — the adapter registry, meaning a mounted database — and the view is a
table. The seam between product and platform is written in a URL.

Better still: grobase's own documentation notes that one of the `vite-gourmand` mounts is
consumed by osionos dashboards. A restaurant app with its Laravel backend untouched, its
database mounted, its data appearing inside the editor. The thesis working end to end.

---

## Proven across six engines

Gate `m174` exercises osionos against **Postgres, MySQL and Mongo** in one script and **SQLite,
MSSQL and DynamoDB** in the other — **through a single application key**.

Six engines, one client, one credential. If you demonstrate one thing in this project,
demonstrate this. → [quality/02-key-gates](../quality/02-key-gates.md)

---

## Real-time collaboration

Live document editing runs on the realtime plane, over the protected namespace
`collab:<spaceId>`. Gate `m175` proves a wildcard token cannot subscribe to a space it was not
added to — the classic realtime hole, closed deliberately.
→ [platform/05-realtime](../platform/05-realtime.md)

Video rooms use LiveKit.

**Before demonstrating:** realtime is **not** in the default edition. Raise
`EDITION=realtime|prod|full` or `PACKAGE=pro`, or there will be nothing to show and the failure
will look like a broken app. → [operations/01-bring-up](../operations/01-bring-up.md)

---

## Where the database block came from

`notion-database-sys` is a complete, standalone Notion clone: ten-plus view types, a block
editor, a formula engine in Rust/WASM, realtime collaboration — **and its own backend**, a
Fastify API with its own JWT auth, Mongoose models, ABAC and its own Postgres/Mongo/Redis stack.

It exports an embeddable component, `@notion-db/object-database`, with a `RemoteAdapter` and
page or inline modes, plus an `examples/parent-app` showing an external application consuming it.

**The hypothesis, marked as such:** notion-database-sys came first as a self-contained product;
osionos is the version re-platformed onto grobase, keeping the database component and dropping
the Fastify backend. The vocabulary matches (`adapter`, `view`), the pattern matches everything
in `vendor/`, and osionos being "React + Vite" with no server of its own matches.

**The loose end** is in the status block above, and it matters: if that repository is inside the
delivered perimeter with its backend alive, the "zero per-project server code" claim has an
exception in the flagship product.

---

See also: [01-apps](01-apps.md) · [platform/08-engines](../platform/08-engines.md) ·
[03-opposite-osiris](03-opposite-osiris.md)
