# Repositories and names

> **Status:** Partial · 2026-09-15
> **Evidence:** repository URLs and submodule paths from `REPOS.md`; grobase's extraction from
> `apps/baas/` stated in its own document
> **To check:** what exactly is delivered for the evaluation. grobase, vault42 and 42ctl are
> separate repositories, and the subject only evaluates what is inside the submitted repository.
> **Sources:** `REPOS.md` · `apps/grobase/CLAUDE.md` §Layout & branch state

Several pieces here have **two names**, not through carelessness but because things were renamed
and the old name survived somewhere. Four cases worth fixing in your head once.

---

## The four name collisions

**Track Binocle is groot.** Track Binocle is the project's name; `groot` is the repository. Same
thing, two registers. When documentation says "the Track Binocle monorepo root", it means
`Univers42/groot`.

**opposite-osiris is prismatica.** Folder `apps/opposite-osiris/`, README titled
`opposite-osiris`, repository `Univers42/prismatica`. The likeliest trap for anyone inspecting
submodules: a folder and a remote that do not match, and nothing actually missing.

**osionos is a product *and* a family prefix.** `osionos` is the editor. `osionos-bridge` is not
a repository — it is a service built *from* osionos. `osionos-mail` and `osionos-calendar` are
their own repositories, mounted at `apps/mail/` and `apps/calendar/`. The prefix means "same
family", not "part of osionos".

**grobase no longer lives in groot.** It was extracted from the `apps/baas/` subtree and is now
`github.com/Univers42/grobase` — an independent repository with its own remote, its own CI and
its own authoritative `CLAUDE.md`. What sits at `apps/grobase/` is a nested repository, not a
folder of the monorepo.

---

## The map

| Path in groot | Repository | What |
|---|---|---|
| `apps/opposite-osiris` | `prismatica` | Marketing site and auth |
| `apps/osionos/app` | `osionos` | Block editor |
| `apps/mail` | `osionos-mail` | Gmail integration |
| `apps/calendar` | `osionos-calendar` | Calendar integration |
| `apps/grobase` | `grobase` | The BaaS — nested independent repo |
| `vendor/scripts` | shared shell tooling | carried over from ft_irc |
| `vendor/born2root` | the VM | common environment |
| `vendor/QA`, `vendor/monkey-bot`, `.claude` | tooling | purpose still unconfirmed |

**Outside groot entirely:** `vault42` (zero-knowledge secret store, built on grobase) and
`42ctl` (the umbrella CLI). Both are grobase customers, not parts of it.
→ [operations/05-secrets](../operations/05-secrets.md)

**Mentioned but not a submodule:** `notion-database-sys`, the standalone Notion clone the
database block appears to descend from. → [02-osionos](02-osionos.md)

---

## Licensing

grobase is **open-core**, with the core under **AGPL-3.0**. Cloud and enterprise features are
flag-gated off in the same codebase.
→ [operations/02-flags](../operations/02-flags.md)

---

## The delivery boundary — resolve this before the evaluation

The subject evaluates only what is inside the submitted repository. grobase, vault42 and 42ctl
are separate repositories, and grobase is where roughly 70% of the work lives.

Either the submodule is correctly registered and clonable in the delivered tree, or a large part
of the work falls outside what can be evaluated. This is not fixed by writing code, and it is
the kind of thing discovered on the day if nobody looks first.

Check that a fresh `git clone --recursive` produces a tree with `apps/grobase/` populated, and
that `make all` succeeds from it. → [DEFENSE.md](../DEFENSE.md)

---

## Known documentation drift

`MAP.md` and `REPOS.md` both say grobase manages six database engines and list MinIO among them.
Neither is right: there are seven by default plus optional DynamoDB, and MinIO is object storage,
not an engine adapter. → [platform/08-engines](../platform/08-engines.md)

`vite-gourmand` is listed with "purpose to confirm" — it is one of the re-platformed vendor
apps, and the one whose external mount feeds osionos dashboards.

---

See also: [01-apps](01-apps.md) · [platform/01-overview](../platform/01-overview.md)
