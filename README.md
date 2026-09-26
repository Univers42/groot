*This project has been created as part of the 42 curriculum by dlesieur, serjimen, danfern3, vjan-nie.*

<!--
  README STATUS — work in progress.
  Markers used throughout (grep for them before the evaluation):
    🚧 TODO   — content that still has to be written or decided by the team
    🔍 CHECK  — a claim taken from our docs that has not been verified against a running stack
  Delete this comment and every marker before the final push.
  🚧 TODO: if the team has a fifth member, add their login to the first line (exact format:
  "by login1, login2, ..."), and to the Team section.
-->

# Track Binocle — ft_transcendence

**Track Binocle** is a collaborative workspace built on top of our own self-hostable
Backend-as-a-Service. Users sign up on a public site, land in **osionos** — a Notion-style block
editor with real-time collaboration, chat and video rooms — and can connect their Gmail and
Google Calendar. Every one of those apps is served by **grobase**, a generic backend that the team
wrote in Go, Rust and TypeScript, and which contains no application-specific code.

---

## Table of contents

1. [Description](#description)
2. [Instructions](#instructions)
3. [Team Information](#team-information)
4. [Project Management](#project-management)
5. [Technical Stack](#technical-stack)
6. [Database Schema](#database-schema)
7. [Features List](#features-list)
8. [Modules](#modules)
9. [Individual Contributions](#individual-contributions)
10. [Resources](#resources)
11. [Known limitations](#known-limitations)
12. [Further documentation](#further-documentation)

---

## Description

### Goal

Almost every web project rebuilds the same backend before it can start on the product:
authentication, user management, CRUD, access control, file upload, email, logs. Our goal was to
turn that repeated work into infrastructure — **one backend, any frontend, zero per-project server
code** — and to prove it by building a real product on it.

The project therefore has two halves:

- **grobase** (roughly 70% of the work) — a Backend-as-a-Service. An application is declared in a
  JSON *contract* (its database, isolation strategy, roles, permissions and API keys); a generic
  provisioner creates everything from that file. Routes carry no domain logic: a request names the
  table it targets, and access rules are stored as data, not code.
- **The products** that run on it — a marketing and authentication site, the osionos editor, and
  mail and calendar integrations.

### Overview

| Product | Tech | What it is |
|---|---|---|
| **opposite-osiris** | Astro | Public site: landing page, sign-up / sign-in, legal pages. The entry point. |
| **osionos** | React + Vite | The block editor: pages, databases-as-blocks, real-time collaboration, chat, video rooms. **The flagship.** |
| **mail** | React + Vite | Gmail integration over Google OAuth |
| **calendar** | React + Vite | Google Calendar integration over Google OAuth |

These four products are supported by four platform services (not applications in their own
right): the **auth-gateway** (Go, sessions), the **osionos-bridge** (turns a site session into an
editor session), **Kong** (the single API gateway in front of grobase) and **LiveKit** (the WebRTC
media server for video rooms).

### Key features

- **Contract-driven backend.** A whole application — database, isolation, roles, keys, frontend
  configuration — is one JSON file. `POST /v1/tenants/me/apps` creates a new isolated application
  with its own database and scoped API key.
- **Per-request owner isolation.** The Rust data plane scopes every query to its owner on every
  request; permissions are rows (ABAC/RBAC), not `if` statements.
- **One API over many databases.** PostgreSQL, MySQL, MongoDB, Redis, SQLite, MSSQL, DynamoDB and
  even remote HTTP APIs are queried through the same envelope and the same API key.
- **Collaborative editor.** Block-based pages, a database block with table / board / calendar
  views, real-time co-editing, channels and direct messages, video rooms.
- **Single-command deployment.** `make all` builds and starts the whole stack in Docker, serves
  every frontend over trusted local HTTPS, and health-checks it.

---

## Instructions

### Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **Docker Engine** | 🚧 TODO: minimum tested version | Docker's data-root should be on a large disk — the images are large and a full build takes several minutes (grobase alone ~9 min). |
| **Docker Compose** | v2 (`docker compose`) | Ships with current Docker Engine. |
| **GNU Make** | any recent | Every command goes through the root `Makefile`. |
| **git** | any recent | Needed for submodules. |
| **Free disk space** | 🚧 TODO: measure after a clean build | |
| **Google Chrome** | current stable | The browser the project is evaluated on. |

**Nothing else is installed on the host** — no Node, npm, Go or Cargo. Everything builds and runs
in containers. If an instruction tells you to run `npm install` on your machine, it is wrong.

> 🔍 CHECK: `.gitmodules` uses SSH URLs (`git@github.com:…`). A reviewer without a GitHub SSH key
> will fail at `git clone --recursive`. Either switch the submodule URLs to HTTPS, or document the
> workaround here. Rehearse a clone into an empty directory on a machine that has never seen the
> project.

### Step by step (local mode — no team secrets needed)

This is the path for anyone outside the team, including evaluators.

```bash
# 1. Clone with all submodules
git clone --recursive https://github.com/Univers42/groot.git ft_transcendence
cd ft_transcendence

# 2. Create the root environment file from the committed template
cp .env.example .env.local
#    Fill these three keys with any long random string (e.g. `openssl rand -hex 32`):
#      OSIONOS_APP_SESSION_SECRET
#      OSIONOS_BRIDGE_SHARED_SECRET
#      OSIONOS_BRIDGE_EMAIL_HASH_SALT
#    Every other key has a working Docker default or is optional.

# 3. Build and start everything
make all
```

`make all` runs, in order: submodule sync → secrets → local TLS certificates → trust the local CA
(one `sudo` prompt the first time) → grobase backend → SQL migrations → frontends → health check
→ prints the list of URLs.

With no vault key present, **grobase generates its own secrets** (JWT secret, database passwords,
service keys) into `apps/grobase/.env`. You can also do it explicitly with
`make -C apps/grobase secrets`.

When it finishes, open **https://localhost:4322** and **create a new account**.

> 🔍 CHECK: the demo data restored by `make all` was created under the team's original keys, so it
> does not appear in local mode. Confirm what a fresh account sees and describe it here.

### Service URLs

| Service | URL |
|---|---|
| opposite-osiris (start here) | `https://localhost:4322` |
| osionos editor | `https://localhost:3001` |
| mail | `https://localhost:3002` |
| calendar | `https://localhost:3003` |
| osionos-bridge | `https://localhost:4000` |
| auth-gateway | `https://localhost:8787/api/auth` |
| grobase API gateway (Kong) | `http://127.0.0.1:8000` — internal; IPv4 only |
| LiveKit | `ws://127.0.0.1:7880` |

> 🔍 CHECK: the subject requires HTTPS for every externally reachable connection. Confirm whether
> Kong `:8000` and LiveKit `:7880` are reachable from outside the host, or only through the TLS
> proxy / same-origin paths.

### Environment configuration

- Real credentials live only in git-ignored `.env*` files; the committed template is
  [`.env.example`](.env.example), which documents every key as **required**, **recommended** or
  **optional**.
- Optional integrations turn themselves off cleanly when left blank:
  - `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` — default to a local dev value; video rooms still work.
  - `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in `apps/mail/.env.local` and
    `apps/calendar/.env.local` — without them, the mail and calendar OAuth flows are disabled.
  - `SONAR_TOK`, `FLY_API_TOKEN`, `DOCKER_PAT` — CI and operations only.

### Team setup (with the vault)

Inside the team, secrets are shared through **vault42**, our zero-knowledge secret store, via the
**42ctl** CLI. A machine that holds a vault identity in `~/.config/42ctl/` pulls the whole `.env`
tree automatically during `make all` (or with `make vault42-pull-all APPLY=1`). A new identity is
created with `42ctl keys init` and enrolled with an invitation from the vault's operator.
Details: [`DATA-MIGRATION.md`](DATA-MIGRATION.md).

> 🚧 TODO — security: the previous README, `DATA-MIGRATION.md`, `FRESH-START-LOG.md`,
> `FRESH-START-AGENT-PROMPT.md` and `infrastructure/makes/repo.mk` contain the vault passphrase and
> a demo account password in plain text. Committed credentials are an immediate-failure criterion.
> Remove them from every tracked file, **rotate** both (they remain in git history), then delete
> this note.

### Everyday commands

| Command | What it does |
|---|---|
| `make all` | Full lifecycle: certs → backend → frontends → health check → URLs |
| `make healthcheck` | Probe backend, site, editor, bridge and auth gateway |
| `make showcase` | Print the URL list for what is actually running |
| `make pulls` | Update all submodules |
| `make -C apps/grobase editions` | List the available backend shapes |
| `make all GROBASE_EDITION=full` | Bring up everything, including extra engines and monitoring |
| `docker compose ps` | Service status |
| `docker compose logs -f <service>` | Follow one service's logs |
| `docker compose down` | Stop the frontends (data is kept) |

**Backend editions.** `make all` starts grobase in the **`devlean`** edition: the core engines
(PostgreSQL, MySQL, MongoDB, Redis, MinIO), the full application / control / data planes and
realtime — without the heavy extra engines (MariaDB, CockroachDB, MSSQL) and without the monitoring
stack. `GROBASE_EDITION=migrate` adds every snapshot engine; `GROBASE_EDITION=full` turns everything
on. Some module demonstrations need a larger edition or a feature flag — see [Modules](#modules).

> 🔍 CHECK: run `make -C apps/grobase editions` and confirm `devlean` is listed there — older docs
> name `migrate` as the default and grobase's own list did not include it.

---

## Team Information

> 🚧 TODO — the roles below come from our working notes and conflict with each other (two members
> are listed as Product Owner and two as Project Manager). The subject expects each of PO, PM and
> Tech Lead to be clearly assigned. Agree on the final split and rewrite this table; every member
> must be able to defend what is written next to their name.

| Member | Login | Role(s) | Responsibilities |
|---|---|---|---|
| Dylan Lesieur | `dlesieur` | Product Owner · Developer | Product vision, backlog and priorities; validates completed work. 🚧 TODO: development scope |
| Daniel Fernández | `danfern3` | Tech Lead (listed also as PO) | Architecture, stack decisions, code quality, reviews |
| Sergio Jiménez | `serjimen` | Project Manager · Developer | Frontend, secrets management, deployment |
| Vadim Jan | `vjan-nie` | Project Manager · Developer | Planning, tracking, communication, unblocking |
| 🚧 TODO | 🚧 TODO | Developer | 🚧 TODO — only if the team has a fifth member |

---

## Project Management

> 🚧 TODO — none of this is recorded in the repository. Fill it with what the team actually did;
> evaluators compare it against the git history.

- **Work organisation:** 🚧 TODO — how tasks were split (by plane? by product?), sprint length,
  meeting cadence, how decisions were recorded.
- **Project management tools:** 🚧 TODO — e.g. GitHub Issues / Projects, Trello, Notion.
  The repository does show milestone planning (M1 hardening, M2 federation, M3 coherence,
  M4 observability, M5 security, M11 external-app integration) in
  [`archive/wiki-2026-09/todo/`](archive/wiki-2026-09/todo/).
- **Code workflow:** submodule-based monorepo — changes are committed inside a submodule first,
  then the root records the new commit. Numbered **verification gates**
  (`scripts/verify/run-gate-battery.sh --fast` per pull request, `--enterprise` nightly) are the
  team's definition of "done". 🚧 TODO: branch model and review rules.
- **Communication channels:** 🚧 TODO — e.g. Discord, Slack, in-person at campus.

---

## Technical Stack

### Frontend

| Technology | Used in | Why |
|---|---|---|
| **Astro 6** + **Sass** | opposite-osiris | Mostly static marketing content: Astro ships near-zero JavaScript by default and pre-renders pages, which keeps the public site fast. |
| **React 19** + **Vite 6** + **TypeScript** | osionos, mail, calendar | A block editor is a heavily interactive UI; React's component model fits, and Vite gives fast builds. |
| **Tailwind CSS 4**, **Radix UI**, **lucide-react** | osionos | Utility-first styling framework plus accessible, unstyled primitives for menus and popovers. |
| **Zustand** | osionos | Small, explicit client state store. |
| **Zod** | osionos | Schema validation of user input on the client side. |
| **i18next / react-i18next** | osionos | Interface translation. |
| **livekit-client** | osionos | WebRTC video rooms. |
| **Playwright** | osionos | End-to-end browser tests. |

> 🔍 CHECK: the subject requires a CSS framework or styling solution. osionos uses Tailwind; the
> site uses Sass; mail and calendar list neither in their dependencies. Confirm this is acceptable.

### Backend — grobase

grobase is split into **planes** — groups of responsibilities that can be sized and replaced
independently — each written in the language that suits it.

| Plane | Technology | Role | Why this language |
|---|---|---|---|
| **Control plane** | **Go** | Provisioning, tenancy, identity (`POST /v1/keys/verify` turns an API key into an identity) | Long-running, concurrent I/O; a provisioner needs to be correct and readable, not fast. |
| **Data plane** | **Rust** | Executes every query, applies per-owner scoping and ABAC locally | The hot path: predictable latency with no GC pauses, and memory safety where a bug would be a cross-tenant data leak. |
| **Realtime plane** | **Rust** | Turns data changes into events; WebSocket subscriptions | Same reasons; pluggable event bus. |
| **Application plane** | **TypeScript / NestJS** | Query and storage routers, schema, session, permissions, email, GDPR services | The original backend, progressively replaced by the Go and Rust planes. |
| **Auth** | **GoTrue** + Go **auth-gateway** | Sign-up, sign-in, sessions, email OTP | Battle-tested auth server rather than a hand-rolled one. |
| **Gateway** | **Kong** | The only public entry to the backend; key auth and rate limiting | Keeps every internal service off the public network. |
| **Media** | **LiveKit** | WebRTC SFU for video rooms | |

### Database

- **PostgreSQL** is the primary database: the control-plane registries (tenants, roles, policies,
  API keys) and all application data (see [Database Schema](#database-schema)).
  **Why:** row-level security (RLS), JSONB for block content and flexible properties, strong
  transactional guarantees, and a mature ecosystem. RLS is what makes per-owner isolation
  enforceable inside the database itself, not only in application code.
- **MySQL, MongoDB, Redis, MinIO** (object storage) run in the default edition; **SQLite, MSSQL,
  DynamoDB** and remote **HTTP** APIs are supported through the same data-plane interface. This is a
  deliberate feature of the platform (one API over many engines), not a need of osionos itself.

### Other significant technologies

- **Docker / Docker Compose** — every component runs in a container; one `make all`.
- **A local certificate authority + TLS proxy** — all frontends served over trusted HTTPS locally.
- **vault42 / 42ctl** — our own zero-knowledge secret store and CLI (separate repositories).
- **SonarQube, Semgrep, Trivy, Renovate** — static analysis, dependency and image scanning.
  🔍 CHECK: confirm which of these actually run in CI (`.github/`).

### Justification of the major choices

- **Why build a BaaS instead of a single backend?** Because the same backend pieces are rebuilt
  for every project. We moved everything that varies between projects — routes, schemas, access
  rules, configuration — from code into data, so a new application is a contract, not a server.
- **Why three languages?** Each plane has a different job. Go for boring, correct orchestration;
  Rust where performance and memory safety protect tenant isolation; TypeScript where it already
  existed. The data plane was migrated from TypeScript to Rust behind a per-request switch with a
  *shadow mode* (Rust computes and discards results for comparison), so the migration needed no
  downtime and could be rolled back without a deployment.
- **Why per-request isolation?** Scoping on every request (instead of per connection) means a
  pooled connection can never carry one user's permissions into another user's query.

---

## Database Schema

The schema lives in two places:

1. **Application schema** — idempotent SQL migrations in [`models/`](models/)
   (`*-migration.sql`), applied by `make all`. All tables are in PostgreSQL, with RLS hardening in
   `models/rls-hardening-migration.sql`.
2. **Platform schema** — grobase's control-plane registries (tenants, mounts, roles, policies,
   API keys), created by grobase's own migrations, plus per-application databases created at
   runtime from each contract (e.g. `infra/config/contracts/website.schema.sql` in grobase).

### Core application tables (osionos)

```mermaid
erDiagram
    osionos_workspaces ||--o{ osionos_workspace_members : "has"
    osionos_workspaces ||--o{ osionos_pages : "contains"
    osionos_pages ||--o{ osionos_pages : "parent of"
    osionos_pages ||--o{ osionos_page_comments : "has"
    osionos_pages ||--o{ osionos_page_favorites : "favourited in"
    osionos_workspaces ||--o{ osionos_channels : "has"
    osionos_channels ||--o{ osionos_channel_members : "has"
    osionos_channels ||--o{ osionos_messages : "contains"
    osionos_messages ||--o{ osionos_message_reactions : "has"
    osionos_messages ||--o{ osionos_message_attachments : "has"

    osionos_workspaces {
        uuid id PK
        uuid owner_id
        text name
        text slug UK
        jsonb settings
        timestamptz created_at
    }
    osionos_workspace_members {
        uuid workspace_id PK,FK
        uuid user_id PK
        text role "owner | admin | editor | viewer"
        text_array permissions
    }
    osionos_pages {
        uuid id PK
        uuid workspace_id FK
        uuid parent_page_id FK
        uuid owner_id
        text title
        text visibility "private | shared | public"
        jsonb properties
        jsonb content "the blocks"
        boolean is_template
    }
    osionos_channels {
        uuid id PK
        uuid workspace_id FK
        text kind "text | dm | voice | video"
        text name
        boolean is_private
        jsonb abac
        text dm_key UK
    }
    osionos_messages {
        uuid id PK
        uuid channel_id FK
        uuid author_id
        text content
        jsonb attachments
        timestamptz edited_at
        timestamptz deleted_at
    }
```

Other table groups, by migration file:

| Area | Tables | Migration |
|---|---|---|
| Users & sessions | `users`, `sessions`, `user_activities`, `user_tokens` | `user.sql` |
| Auth security & GDPR | `auth_audit_events`, `gdpr_requests`, `user_consents`, `newsletter_optins` | `auth-security-migration.sql`, `gdpr-migration.sql` |
| Site ↔ editor bridge | `osionos_bridge_identities`, `osionos_bridge_audit_events` | `osionos-bridge-migration.sql` |
| Social & communities | `osionos_communities`, `osionos_community_members`, `osionos_community_channels`, `osionos_connections`, `osionos_user_blocks`, `osionos_user_reports`, `osionos_feed_*` | `osionos-communities-`, `-social-`, `-feed-engagement-migration.sql` |
| Databases-as-blocks | `osionos_object_databases`, `osionos_workspace_databases`, `osionos_app_connections` | `osionos-object-databases-`, `-workspace-databases-`, `-app-connections-migration.sql` |
| Publishing & sharing | `osionos_published_pages`, `osionos_share_rules`, `osionos_page_links` | `osionos-publish-`, `-share-rules-`, `-page-links-migration.sql` |
| Tasks & notifications | `osionos_tasks`, `osionos_notifications`, `osionos_push_subscriptions` | `osionos-tasks-`, `-push-migration.sql` |
| Mail & calendar | `mail_accounts`, `mail_messages`, `calendar_accounts`, `calendar_sources`, `calendar_event_cache` | `mail-migration.sql`, `calendar-migration.sql` |

### Platform (grobase) registries

Access control is stored as data: `roles`, `user_roles` and `resource_policies` tables, evaluated
by the SQL function `public.has_permission(...)` and mirrored by the Rust data plane's own ABAC
evaluator. Every table generated by grobase receives an `owner_id` column automatically, which is
what makes one isolation rule apply to any table.

> 🔍 CHECK: `models/user.sql` defines `users.id` as `SERIAL` (integer), while every osionos table
> references users by `UUID` (GoTrue's `auth.users`). Confirm which `users` table is live and
> remove or explain the other before the defense. Add the grobase registry tables with their key
> columns once read from grobase's migrations.

---

## Features List

> 🚧 TODO — the "Who" column must come from `git shortlog -sn --all` at the root **and in each
> submodule** (`git submodule foreach 'git shortlog -sn --all'`), not from memory. Mark every
> feature below as verified once it has been clicked through in Chrome with the console open.

| Feature | Description | Who |
|---|---|---|
| Sign-up / sign-in | Email and password (hashed and salted) on the public site; email OTP enabled in production with real SMTP | 🚧 TODO |
| Site → editor handoff | After login, a one-time bridge session hands the user to osionos (`/api/auth/bridge/consume`) — no token in a query string | 🚧 TODO |
| Legal pages | Privacy Policy, Terms of Service, Cookie Policy, Data Rights, linked from the site | 🚧 TODO |
| Block editor | Pages built from blocks, nested pages, templates, covers, favourites, search | 🚧 TODO |
| Database block | A block that is a database, with table / board / calendar views over any mounted data source | 🚧 TODO |
| Real-time collaboration | Several users editing the same space live, over the protected `collab:<spaceId>` channel | 🚧 TODO |
| Chat | Workspace channels and direct messages, reactions, mentions, attachments, read receipts | 🚧 TODO |
| Video rooms | LiveKit-based video channels inside workspaces | 🚧 TODO |
| Comments, sharing, publishing | Page comments, share rules, public page publishing | 🚧 TODO |
| Communities & social feed | Communities, connections, feed with likes, comments and shares; blocking and reporting | 🚧 TODO |
| Mail | Read Gmail inside the workspace via Google OAuth | 🚧 TODO |
| Calendar | Google Calendar events via Google OAuth | 🚧 TODO |
| Interface languages | i18next-based translation in osionos — 🔍 CHECK which languages are complete | 🚧 TODO |
| Contract-driven provisioning | One JSON contract → isolated database, roles, keys and frontend `.env` | 🚧 TODO |
| Self-serve applications | `POST /v1/tenants/me/apps` creates a new isolated app with its own database and key | 🚧 TODO |
| Multi-engine data API | One API and one key over PostgreSQL, MySQL, MongoDB, SQLite, MSSQL, DynamoDB, Redis, HTTP | 🚧 TODO |
| Public API | Key-authenticated, rate-limited API behind Kong, documented with OpenAPI | 🚧 TODO |

> 🔍 CHECK: the Privacy Policy and Terms pages exist (`apps/opposite-osiris/src/pages/legal/`) but
> the data-controller name and address in `src/data/legal.ts` are still marked "(placeholder)".
> Placeholder legal content is a rejection criterion — replace them with real content.

---

## Modules

The subject requires **14 points** (Major = 2, Minor = 1). A module that cannot be demonstrated
live scores zero, so the confidence column is honest about where each one stands:

- **A** — works as-is in the default stack
- **B** — backend exists; needs a feature flag and a migration, no new code
- **C** — backend exists; needs a user-facing screen to be demonstrable

> 🚧 TODO — decide the final list. As it stands, **only the A rows plus the two free-choice modules
> (10 pts) are demonstrable today**, which is below the 14 required. Raise the B flags and build the
> C screens that are needed, then delete the rows the team will not defend.

| # | Module | Category | Type | Pts | Conf | How it is implemented | Who |
|---|---|---|---|--:|:--:|---|---|
| 1 | Public API (key, rate limit, docs, ≥5 endpoints) | Web | Major | 2 | A | Kong gateway with key auth and rate limiting; OpenAPI specs in grobase `infra/config/openapi/` | 🚧 TODO |
| 2 | Backend as microservices | DevOps | Major | 2 | A | 15 compose planes (Go control, Rust data, Rust realtime, TS app, storage, auth…) talking over an internal network with HMAC-signed service calls | 🚧 TODO |
| 3 | Real-time features via WebSockets | Web | Major | 2 | A | Rust realtime plane; changes published as events; protected channel namespaces (gate `m175`) | 🚧 TODO |
| 4 | Real-time collaboration | Web | Minor | 1 | A | osionos live co-editing over `collab:<spaceId>` on the realtime plane | 🚧 TODO |
| 5 | Advanced permissions | User management | Major | 2 | C | Roles and policies as rows, ABAC conditions; needs `PERMISSION_CONDITIONS_ENABLED` + `API_KEY_ABAC_ENABLED`, migration `063` | 🚧 TODO |
| 6 | Organisation system | User management | Major | 2 | C | Organisations are **on in production**; only a management screen is missing | 🚧 TODO |
| 7 | Monitoring with Prometheus + Grafana | DevOps | Major | 2 | C | Observability plane; needs `TENANT_OBS_ENABLED` **and** `DATA_PLANE_TENANT_OBS` | 🚧 TODO |
| 8 | Health/status page, backups, disaster recovery | DevOps | Minor | 1 | C | `TENANT_BACKUP_ENABLED`, migration `042` | 🚧 TODO |
| 9 | GDPR compliance | Data | Minor | 1 | B | Data export and hard erase: `TENANT_EXPORT_ENABLED` + `HARD_ERASE_ENABLED`; `gdpr_requests` table | 🚧 TODO |
| 10 | Two-factor authentication | User management | Minor | 1 | B | TOTP (grobase `one` shape) or passkeys (`PASSKEYS_ENABLED`) | 🚧 TODO |
| 11 | Remote authentication (OAuth 2.0) | User management | Minor | 1 | B | `SSO_ENABLED`, migration `053` | 🚧 TODO |
| 12 | File upload and management | Web | Minor | 1 | C | Storage plane on MinIO, `STORAGE_BUCKET_SCOPE_ENABLED` | 🚧 TODO |
| 13 | **Module of choice:** contract-driven application factory | Free choice | Major | 2 | A | See justification below | 🚧 TODO |
| 14 | **Module of choice:** SSRF guard on the HTTP engine | Free choice | Minor | 1 | A | See justification below | 🚧 TODO |

**Point calculation**

| | Points |
|---|--:|
| Catalogue modules listed (rows 1–12) | 18 |
| Modules of choice (rows 13–14) | 3 |
| **Total listed** | **21** |
| Demonstrable today (confidence A: rows 1–4, 13–14) | **10** |
| Required | 14 |

> 🔍 CHECK — candidates not yet in the table, worth up to several points:
> - **Multiple languages** (Accessibility, minor): osionos already uses i18next — count the
>   complete languages (the module needs at least three) and add a language switcher check.
> - **HashiCorp Vault for secrets** (Cybersecurity, major): does grobase's `VaultProvider` talk to
>   HashiCorp Vault (migration `060`)? Our current secrets use vault42 instead.
> - **LLM interface / analytics dashboard**: read grobase `src/apps/ai/` and `src/apps/analytics/`.
> - Gaming-dependent modules are out of reach: the project has no game.
> - 🔍 CHECK every module name and point value against the current subject version before the
>   evaluation.

### Justification — Module of choice (Major): contract-driven application factory

- **Why this module.** It is the central idea of the project: a backend with zero
  application-specific code, where an application is a declarative contract.
- **Technical challenge.** From one JSON file, a generic provisioner must create an isolated
  database, apply its schema, create roles and policies, mint scoped API keys and emit the
  frontend's `PUBLIC_*` configuration — idempotently, on every boot. The self-serve endpoint
  `POST /v1/tenants/me/apps` does it on demand, with a fresh `CREATE DATABASE` per application.
- **Value.** A new application costs a contract instead of a new server. The public site and
  vault42 are both provisioned this way in production.
- **Why it deserves a Major.** It spans the Go control plane, the Rust data plane and the
  database layer, and it comes with isolation proofs: gate `m177` proves self-serve creation, and
  gate `m176` proves one application cannot read another's data (a foreign mount resolves to zero
  rows — a 404, never a cross read).

### Justification — Module of choice (Minor): SSRF guard on the HTTP engine

- **Why this module.** The data plane can mount a remote HTTP API as if it were a database —
  which also means "let a user make our server fetch any URL", the classic SSRF hole.
- **Technical challenge.** The guard blocks loopback, private (RFC 1918), link-local — including
  the cloud metadata endpoint `169.254.169.254` — CGNAT, IPv6 ULA and link-local, IPv4-mapped
  addresses and internal hostnames, then **pins** the connection to the validated public IP so a
  later DNS rebind cannot redirect it inward.
- **Value and weight.** Small, self-contained and demonstrable in seconds (a mount pointing at
  `169.254.169.254` is refused), and it shows security judgement on a feature we chose to build.

---

## Individual Contributions

> 🚧 TODO — each member writes their own subsection, backed by the git history of the root **and**
> of the submodules they worked in. Be specific (features, modules, files) and honest; every
> member will be asked to explain their part and the project as a whole.

### dlesieur — Dylan Lesieur
- **Contributed:** 🚧 TODO
- **Features / modules:** 🚧 TODO
- **Challenges and how they were overcome:** 🚧 TODO

### danfern3 — Daniel Fernández
- **Contributed:** 🚧 TODO
- **Features / modules:** 🚧 TODO
- **Challenges and how they were overcome:** 🚧 TODO

### serjimen — Sergio Jiménez
- **Contributed:** 🚧 TODO
- **Features / modules:** 🚧 TODO
- **Challenges and how they were overcome:** 🚧 TODO

### vjan-nie — Vadim Jan
- **Contributed:** 🚧 TODO
- **Features / modules:** 🚧 TODO
- **Challenges and how they were overcome:** 🚧 TODO

### Team-level challenges

Starting points from the project's history — assign each one to the people who did the work:

- **Migrating the data plane from TypeScript to Rust with no downtime**, using a per-request
  switch and a shadow mode that compared both implementations under real traffic.
- **Keeping eight database adapters at parity**, enforced by a conformance battery that runs every
  adapter against a real engine and checks it serves exactly what it advertises.
- **Auditing our own authorisation path** and shipping a reversible mitigation for a weakness we
  found (see [`wiki/security/03-known-weaknesses.md`](wiki/security/03-known-weaknesses.md)).
- 🚧 TODO: add others.

---

## Resources

### References

- Docker Compose — <https://docs.docker.com/compose/>
- PostgreSQL row-level security — <https://www.postgresql.org/docs/current/ddl-rowsecurity.html>
- Kong Gateway — <https://docs.konghq.com/gateway/latest/>
- Supabase Auth (GoTrue) — <https://github.com/supabase/auth>
- The Go Programming Language documentation — <https://go.dev/doc/>
- The Rust Programming Language — <https://doc.rust-lang.org/book/>
- NestJS — <https://docs.nestjs.com/>
- Astro — <https://docs.astro.build/>
- React — <https://react.dev/> · Vite — <https://vite.dev/> · Tailwind CSS — <https://tailwindcss.com/docs>
- LiveKit — <https://docs.livekit.io/>
- NIST SP 800-162, *Guide to Attribute Based Access Control* — <https://csrc.nist.gov/pubs/sp/800/162/final>
- OWASP SSRF Prevention Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html>
- OWASP Top 10 — <https://owasp.org/www-project-top-ten/>
- GDPR, full text — <https://gdpr-info.eu/>
- 🚧 TODO: add the articles and tutorials the team actually used.

### How AI was used

This project was built with **heavy AI assistance**, and we state it plainly.

> 🚧 TODO — replace the draft below with the team's precise account. For each point, name the tool
> and say how the output was checked. Be specific: vague disclosure reads worse than precise
> disclosure, and every member must be able to explain any AI-assisted code in their area.

- **Tools:** 🚧 TODO (e.g. Claude / Claude Code — the repository carries agent configuration in
  `.claude/` and `apps/grobase/CLAUDE.md`; list any others).
- **Code generation:** 🚧 TODO — which parts (grobase planes, adapters, frontends, migrations…),
  and how much was reviewed, rewritten or discarded.
- **Documentation:** the wiki and this README were drafted and distilled with AI assistance from
  the project's own design documents and code, then checked against the repository.
- **Testing and verification:** 🚧 TODO — e.g. writing verification gates and test scripts.
- **Reviews and audits:** 🚧 TODO — e.g. security review of the authorisation path.
- **How we kept control:** every change is accepted only when its verification gate passes;
  🚧 TODO: add code-review practice and anything else the team did.

---

## Known limitations

- **No game.** All gaming-dependent modules are out of scope.
- **Local mode starts empty.** Demo data restored by `make all` is tied to the team's secrets and
  is not visible to a fresh local account.
- **Expressiveness is narrow by design.** grobase has no place for custom server logic; business
  rules must be expressed as policies, schema constraints or database triggers.
- **Documented security weaknesses.** Known and declared in
  [`wiki/security/03-known-weaknesses.md`](wiki/security/03-known-weaknesses.md).
- **Several features are behind flags that are off by default** — see the confidence column in
  [Modules](#modules).
- 🔍 CHECK: responsive layout (desktop and mobile), clean browser console on all frontends, and
  concurrent use by several users without conflicts — all graded, none verified yet.

## License

🚧 TODO: no `LICENSE` file at the root. Add one, or state here that the project is not licensed
for reuse.

---

## Further documentation

- [`wiki/README.md`](wiki/README.md) — the documentation catalogue
- [`wiki/ONBOARDING.md`](wiki/ONBOARDING.md) — seven pages to understand the project, in order
- [`wiki/DEFENSE.md`](wiki/DEFENSE.md) — evaluation questions mapped to answers
- [`wiki/platform/`](wiki/platform/) — grobase: planes, data plane, contracts, isolation, engines
- [`wiki/security/`](wiki/security/) — security model, proofs, known weaknesses, network
- [`DATA-MIGRATION.md`](DATA-MIGRATION.md) — fresh-machine and migration runbook
- `apps/grobase/CLAUDE.md` — grobase's own authoritative technical document (inside the submodule)
