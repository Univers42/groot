# ft_transcendence — "Track Binocle"

A Docker-first monorepo: a Notion-like collaborative block editor (**osionos**), a marketing
and auth site (**opposite-osiris**), and Gmail/Calendar apps — all running on a self-hostable
Backend-as-a-Service (**grobase**). One command brings the whole thing up.

Three languages, three planes: **TypeScript** (the apps), **Go** (the control plane —
provisioning, auth, tenancy), **Rust** (the data plane — query execution, realtime). Everything
runs in containers. **Never install dependencies on the host** — there is no host `node`/`npm`/`go`.

---

## Quick start

You need **Docker** (with its data-root on a big disk — see [below](#docker-on-a-big-disk)) and **git**.

```bash
git clone --recursive <repo-url> ft_transcendence
cd ft_transcendence
make all
```

`make all` is self-provisioning. It syncs submodules to the latest source, pulls secrets from the
vault if they're missing, starts the **grobase** backend, restores the demo data when the databases
are empty, builds and starts the frontends, healthchecks them, and prints a clickable list of URLs.
The first run may prompt for `sudo` once to trust the local TLS certificate.

When it finishes, open the website and sign in:

| URL | Login |
|-----|-------|
| `https://localhost:4322` | `dev.pro.photo` / `Osionos123!` |

> First time on a machine? You also need the vault key — see [Fresh machine](#fresh-machine--migration).

---

## The apps

`make all` brings up the frontends; the **grobase** backend serves them. Host ports:

| App | Tech | URL | Purpose |
|-----|------|-----|---------|
| **opposite-osiris** | Astro | `https://localhost:4322` | Marketing site + auth landing — start here |
| **osionos** | React + Vite | `https://localhost:3001` | Block editor / collaborative document system |
| **osionos-bridge** | TypeScript | `https://localhost:4000` | Workspace persistence between site and editor |
| **auth-gateway** | Go | `https://localhost:8787/api/auth` | Authentication & session management |
| **mail** | React / TS | `https://localhost:3002` | Gmail OAuth integration |
| **calendar** | React / TS | `https://localhost:3003` | Google Calendar OAuth integration |
| **grobase** (Kong) | Rust/Go/TS | `http://127.0.0.1:8000` | The BaaS gateway — auth, data, realtime, storage |
| **LiveKit** | WebRTC SFU | `ws://127.0.0.1:7880` | Media server for osionos video rooms |

A single TLS proxy publishes the 8 HTTPS frontend ports. The `showcase` step lists only the
services that are actually running. Desktop/Electron builds must use `127.0.0.1`, not `localhost`
(Kong is IPv4-only).

---

## Everyday commands

Every command runs through the root **Makefile** — it's the authority.

| Command | What it does |
|---------|-------------|
| `make all` | The everyday lifecycle: certs → backend → frontends → health → URLs |
| `make healthcheck` | Probe the backend, website, editor, bridge, and auth gateway |
| `make showcase` | Print the clickable URL list for the running stack |
| `make pulls` | Fetch and update all submodules |
| `make -C apps/grobase up` | Start the grobase backend on its own |
| `make -C apps/grobase editions` | List backend editions (see [Configuration](#configuration)) |
| `docker compose ps` | Service status |
| `docker compose logs -f <service>` | Follow a service's logs |
| `docker compose up -d --build <service>` | Rebuild one frontend |
| `docker compose down` | Stop the frontends (keeps data) |

`make grobase-up` is unrelated — it serves the standalone **grobase marketing site** at
`http://127.0.0.1:4324`, not the backend.

---

## Configuration

**Editions** pick which slice of the grobase backend comes up. Run them from `apps/grobase`:

```bash
make -C apps/grobase editions          # lean query realtime analytics prod full migrate tetris
make -C apps/grobase up EDITION=query  # start a known-good shape
```

`make all` uses the **`migrate`** edition by default — every snapshot engine (Postgres, MySQL,
Mongo, MSSQL, MinIO) plus the full app/control/data plane and realtime, minus the heavy monitoring
extras. Override with `make all GROBASE_EDITION=full` for the everything-on shape.

**Secrets** live in **vault42** (a zero-knowledge store) and travel through the **42ctl** CLI only.
HashiCorp Vault is retired — don't use it.

```bash
make vault42-pull-all              # dry-run: show what would be restored
make vault42-pull-all APPLY=1      # restore the whole .env tree (passphrase prompt, hidden)
```

`make all` pulls secrets automatically when the vault key is present and the env files are missing,
so you rarely call this directly. `.env*` files land at the repo root and under each app
(`apps/grobase/.env`, `apps/osionos/app/.env`, …).

For depth: backend internals and flags → [`apps/grobase/CLAUDE.md`](apps/grobase/CLAUDE.md);
architecture and security → [`wiki/`](wiki/).

---

## Fresh machine / migration

The vault key is the one secret in neither git nor the vault itself — copy it over first, then
`make all` reconstitutes the whole machine (code, secrets, and all-engine data).

```bash
scp -r OLD_HOST:~/.config/42ctl ~/.config/      # the vault42 key + tenant contract
git clone --recursive <repo-url> ft_transcendence && cd ft_transcendence
make all                                         # prompts once for the passphrase
```

Passphrase: `Grobase-Vault-2026!`. The data restore only touches **empty** databases — it never
wipes populated ones. Full ordered runbook (engines, restore order, caveats):
[`DATA-MIGRATION.md`](DATA-MIGRATION.md).

<a name="docker-on-a-big-disk"></a>
> **Docker on a big disk.** The system disk is usually too small for the images. Point Docker's
> data-root at a large volume before the first build.

---

## Architecture in brief

grobase is the **Backend-as-a-Service**: one backend, any frontend, no per-project server code.
The Go control plane resolves an API key to an identity; the Rust data plane then executes the
query and owner-scopes it per request. Major changes follow a **shadow → parity → cutover**
discipline — new code runs beside the old, validation precedes any switch, deletion is always last.

grobase is a **nested, independent repository** at `apps/grobase/` with its own git history and its
own authoritative [`apps/grobase/CLAUDE.md`](apps/grobase/CLAUDE.md). The root stack joins it over an
external Docker network. Read [`wiki/ARCHITECTURE.md`](wiki/ARCHITECTURE.md) for the full design and
[`wiki/SECURITY.md`](wiki/SECURITY.md) for the threat model.

---

## Project layout

| Path | What's there |
|------|-------------|
| `apps/` | The apps: `grobase/` (nested BaaS repo), `osionos/app/` (editor), `opposite-osiris/` (site), `mail/`, `calendar/`, Electron/desktop shells |
| `infrastructure/` | `makes/` (Makefile fragments), TLS, compose helpers |
| `models/` | Root-app SQL migrations (idempotent, RLS-enforced) |
| `wiki/` | Architecture, security, setup, contributing |
| `tools/`, `scripts/` | Seeds and dev helpers |

Submodules carry the apps — **commit inside the submodule first**, then the root records the SHA.

---

## Docs & deeper reading

- [`apps/grobase/CLAUDE.md`](apps/grobase/CLAUDE.md) — the BaaS: editions, planes, flags, gates
- [`DATA-MIGRATION.md`](DATA-MIGRATION.md) — fresh-machine / migration runbook
- [`wiki/ARCHITECTURE.md`](wiki/ARCHITECTURE.md) · [`wiki/SECURITY.md`](wiki/SECURITY.md) · [`wiki/SETUP.md`](wiki/SETUP.md) · [`wiki/CONTRIBUTING.md`](wiki/CONTRIBUTING.md)
- [`CLAUDE.md`](CLAUDE.md) — full project overview for contributors and agents

**Contributing to osionos:** branch from `develop`, commit message `"updated"`, no co-author
trailer, no auto-push. Docker-first throughout — no host `node`/`npm`.
