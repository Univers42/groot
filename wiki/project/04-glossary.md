# Glossary

> **Status:** Verified · 2026-09-15
> **Evidence:** every term here appears in the pages that link to it
> **Sources:** this wiki
> **Deeper:** [archive/wiki-2026-09/components/backend/glossary.md](../../archive/wiki-2026-09/components/backend/glossary.md) ·
> [components/frontend/glossary.md](../../archive/wiki-2026-09/components/frontend/glossary.md)

Terms that mean something specific here, or that have two names.

---

## Names

**Track Binocle** — the project. **groot** — the repository holding it. Same thing.

**opposite-osiris / prismatica** — the marketing site. Folder and remote disagree after a
rename. → [product/04-repos](../product/04-repos.md)

**grobase** — the BaaS. A separate repository since it was extracted from `apps/baas/`.

**osionos** — the block editor, and also a family prefix (`osionos-mail`, `osionos-bridge`).

**vault42 / 42ctl** — zero-knowledge secret store and its CLI. grobase customers, not parts.

---

## Architecture

**Plane** — a set of responsibilities answering one kind of question, not a layer. Four of them:
application (TS), control (Go), data (Rust), realtime (Rust).
→ [platform/02-planes](../platform/02-planes.md)

**The seam** — the control plane resolves an API key to an identity; the data plane executes and
scopes to the owner. Deciding and executing, kept apart.

**Contract** — `infra/config/contracts/<app>.json`, a declarative description of an entire
application. → [platform/06-contracts](../platform/06-contracts.md)

**Mount** — a database registered with grobase. May be one it created or one that belongs to
somebody else and keeps running its own backend.

**Adapter** — the code translating a generic operation into one engine's dialect. Eight of them.

**Edition** — a named set of compose planes (`query`, `full`…), an engineering shape.
**Package** — a customer tier (`nano`…`max`), a commercial shape. Both select planes.

---

## Security

**Per-request owner scoping** — identity travels with each query rather than living in the
connection. The load-bearing decision. → [platform/07-isolation](../platform/07-isolation.md)

**`owner_id`** — the column added to every generated table whether or not you ask for one. What
makes one isolation rule writable for every table, including future ones.

**Isolation strategy** — `shared_rls`, `db_per_tenant`, `tenant_owned`, `schema_per_tenant`.
Declared per mount, as a field of the contract.

**RLS** — row-level security: a rule attached to the table itself, so the database filters even
if the application forgets.

**ABAC / RBAC** — permissions from attributes and roles, stored as rows rather than written as
conditionals. → [security/01-model](../security/01-model.md)

**Field mask** — the finer layer: a role may read a row but not every column.

**SSRF** — making a server fetch a URL an attacker chooses. Invited by the `http` engine,
blocked by `guard_and_resolve`. → [security/04-network](../security/04-network.md)

---

## Verification

**Gate** — a numbered, self-contained script exercising one behaviour against a running system.
About 160 of them; the unit of "done". → [quality/01-gates](../quality/01-gates.md)

**Vacuous pass** — a gate that succeeds without exercising anything. The repo's rule: that is
not a gate. The same idea as *silence is not success*.

**Capability honesty** — the test asserting each engine serves exactly what it advertises, so
the capability catalogue cannot drift into a lie.

**Shadow mode** — the Rust data plane executes and discards its result, so both implementations
can be compared under real traffic at zero risk.

---

## Operations

**Pull-fallback** — 54 compose services fetch a published image instead of building local code.
The reason your changes are not in the running container.
→ [operations/04-troubleshooting](../operations/04-troubleshooting.md)

**Master/sub flags** — features needing a flag on both planes. Raise one and nothing happens,
silently. → [operations/02-flags](../operations/02-flags.md)

**Honor sets** — cached snapshots (`quota_over`, `spend_over`, `suspended`) the data plane reads
instead of asking the control plane per request. Source of `402`.

**Protected namespace** — `collab:<spaceId>`, `xapp:<channel_id>`. Realtime subscriptions are
authorised against membership, not against a pattern.

---

See also: [README.md](../README.md) · [ONBOARDING.md](../ONBOARDING.md)
