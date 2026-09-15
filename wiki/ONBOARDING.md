# Onboarding — read these seven, in order

> **Status:** Verified · 2026-09-15
> **Evidence:** every page linked here exists and has been reviewed
> **Sources:** this wiki

You are looking at a monorepo with eight submodules, four products, three languages and a
backend that is a product in its own right. It is genuinely large. This path gets you to a
working mental model in about ninety minutes of reading, without opening the code.

Do not start with the architecture. Start with what the thing is for.

---

### 1 · [product/01-apps](product/01-apps.md) — what exists

Four products a user can open, and four services that have a URL but are not products. Read
this first so the rest has somewhere to attach. *~8 min.*

### 2 · [platform/01-overview](platform/01-overview.md) — the bet

Why a generic backend instead of an API per project, what makes it actually generic rather
than aspirationally generic, and what that genericity costs. This is the page that explains
why the project looks the way it does. *~12 min.*

### 3 · [platform/06-contracts](platform/06-contracts.md) — the factory

An entire application declared in one JSON file: its database, its isolation strategy, its
roles, its permissions, its keys, its frontend config. No server code. If one page makes the
project click, it is usually this one. *~10 min.*

### 4 · [platform/02-planes](platform/02-planes.md) — the shape

Four planes, three languages, and the seam between deciding and executing. *~12 min.*

### 5 · [platform/07-isolation](platform/07-isolation.md) — the load-bearing idea

Security scoping travels with the request, not with the connection. This is the single
decision everything else rests on, including the ability to put ten thousand tenants on one
pool. It also has a declared hole — read that part carefully. *~10 min.*

### 6 · [operations/01-bring-up](operations/01-bring-up.md) — run it

Editions, packages, planes, and the two traps that cost an afternoon. Do this with a terminal
open. *~15 min, plus the build.*

### 7 · [quality/02-key-gates](quality/02-key-gates.md) — how we know

Eight verification gates and what each one proves. This is where the claims in pages 2–5 stop
being claims. *~10 min.*

---

## After the seven

Depending on what you are here to do:

- **Writing backend code** → `apps/grobase/CLAUDE.md` is the authoritative document. Then
  [platform/03-data-plane](platform/03-data-plane.md) and
  [platform/04-control-plane](platform/04-control-plane.md).
- **Operating or debugging** → [operations/04-troubleshooting](operations/04-troubleshooting.md)
  and [operations/02-flags](operations/02-flags.md). Most "it doesn't work" turns out to be one
  of those two pages.
- **Preparing the evaluation** → [DEFENSE.md](DEFENSE.md).
- **Security** → [security/03-known-weaknesses](security/03-known-weaknesses.md) before
  anything else. Knowing what is weak is more useful than knowing what is strong.

---

## Two things to internalise early

**Silence is not success.** A green log, an empty result, or a passing check means nothing
until you know the tool looked at the right thing. The repo states this as a rule for its own
test suite: *a gate that passes vacuously is not a gate.* Apply it to yourself too.

**Nothing installs on the host.** There is no host node, npm or go. Everything runs through the
root `Makefile` or `docker compose`. If a suggestion starts with `npm install`, it is wrong.

---

See also: [catalogue](README.md) · [status ledger](STATUS.md) · [repository README](../README.md)
