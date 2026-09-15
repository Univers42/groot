# The applications

> **Status:** Verified · 2026-09-15
> **Evidence:** app table and URLs from the repository README; service roles confirmed against
> `deploy/fly/boot.sh` and the prismatica README
> **Sources:** root `README.md` · `deploy/fly/boot.sh` · `apps/opposite-osiris/README.md`

Eight things in this project have a URL. **Four are products; four are plumbing.** Confusing the
two is the fastest way to sound like you do not know your own system — and the distinction, said
correctly, is more impressive than the inflated version.

---

## The four products

| Product | Mounted at | Repository | What it is |
|---|---|---|---|
| **opposite-osiris** | `apps/opposite-osiris` | `prismatica` | Marketing site and front door. Astro. You start here. |
| **osionos** | `apps/osionos/app` | `osionos` | The block editor. React + Vite. **The flagship.** |
| **mail** | `apps/mail` | `osionos-mail` | Gmail integration over Google OAuth |
| **calendar** | `apps/calendar` | `osionos-calendar` | Google Calendar integration |

The user journey chains them: you arrive at the marketing site, authenticate there, and the site
hands you to the editor with a session already created.
→ [03-opposite-osiris](03-opposite-osiris.md)

---

## The four that are not applications

These appear in the README's app table with ports and URLs, and none of them is something a
person uses.

**osionos-bridge** (`:4000`) — the persistence bridge between site and editor. It converts a
site session into an editor session; its telling route is `/api/auth/bridge/consume`. Not a
repository: built from osionos.

**auth-gateway** (`:8787`) — part of grobase, written in Go. Authentication and sessions.

**Kong** (`127.0.0.1:8000`) — the BaaS door. Everything going to data, realtime, storage or auth
passes through it. → [security/04-network](../security/04-network.md)

**LiveKit** (`ws://127.0.0.1:7880`) — WebRTC media server, for osionos video rooms.

**Why it matters:** "we have eight applications" is false and lands badly. "Four products and
four platform services" is true, and the second sentence is the more impressive one.

---

## The proving ground

Inside **grobase** (a separate repository) there is a `vendor/` directory holding third-party
applications re-platformed onto the BaaS: a photo social network in PHP, a film community in
Java/Spring, a surf directory in Laravel, a multiplayer Tetris, a restaurant ordering app, a
video search tool. They are tracked files, excluded from the default build and CI.

Two adoption shapes, and grobase supports both:

- **Re-platformed** — the app's own backend disappears; its frontend talks only to Kong.
- **External mount** — the app keeps its backend intact and grobase mounts its live database.
  The app never notices.

That second shape is what the osionos database block exposes to users, and it is the more
interesting of the two. → [02-osionos](02-osionos.md)

---

## Two products that ride on grobase but are not part of this delivery

**vault42** — a zero-knowledge secret store in Rust, built *on* grobase, which it uses for auth,
ABAC, tenant isolation and audit. Its own repository; consumed here as a published image.

**42ctl** — the umbrella CLI for the stack. Its own repository.

Both are grobase's customers rather than its parts. vault42 in particular is the strongest
argument the project has: a security product that chose this backend precisely because it needed
strong isolation guarantees. → [operations/05-secrets](../operations/05-secrets.md)

---

## Everything else

Tooling submodules — `vendor/scripts` (shared shell tools, carried over from ft_irc),
`vendor/born2root` (the VM), `vendor/QA`, `vendor/monkey-bot`, and `.claude` (agent
configuration). None is an application in any sense. → [04-repos](04-repos.md)

---

See also: [02-osionos](02-osionos.md) · [04-repos](04-repos.md) ·
[platform/01-overview](../platform/01-overview.md)
