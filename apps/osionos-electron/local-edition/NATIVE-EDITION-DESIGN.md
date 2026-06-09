# osionos Native edition — design spike (no Docker, no cloud)

> **Status: design (not built).** This is the Phase-2 spike output: the concrete path to a desktop
> app a non-technical user double-clicks, with **no Docker and no cloud** — her data is a file on
> her own disk. See [[project-osionos-distribution]].

## Goal & why it's tractable

The current "local edition" still needs **Docker** (9 lean containers). The end-state consumer app
must drop Docker entirely. Two facts make this bounded:

- The local stack is **Postgres-only** (no Mongo — Mongo lives only in the cloud/dev mini-baas).
- The osionos frontend talks to exactly **one** backend process: the **bridge**
  (`apps/osionos/app/scripts/bridge-api.mjs`, port 4000). In local edition the app's `API_URL` is
  `http://localhost:4000` and `BAAS_URL` is empty, so everything funnels through the bridge.

The bridge (1578 lines) is **already self-contained** for sessions (HMAC app-tokens, `configFromEnv`
→ `issue/verify` at lines ~313–367), graph, translation, MCP and handoff. It reaches outside for
only **two** things:

| Dependency | Where in `bridge-api.mjs` | Docker service today |
|---|---|---|
| **Data** (read/list pages, upsert workspace, graph) | `postgrestQuery` (l.418) → `${baasUrl}/rest/v1/*` (l.400, l.576/587/615/627) + RPC `osionos_bridge_upsert_workspace` (l.689) | Kong → **PostgREST** → **Postgres** |
| **Credentials** (login/register) | `handleAuthProxy` (l.1473) → 3 `gatewayCall`s: `/api/auth/register`, `/login`, `/osionos-session` (l.1484–1497) | **auth-gateway** (Go, :8787) → gotrue |

Replace those two and Docker is gone.

## Two options

**Option A — embed the services, leave the bridge UNCHANGED (recommended).**
Electron `main.js` becomes a small **process supervisor** that spawns three native binaries on
loopback and points the (unmodified) bridge at them:

```
Electron main  ──spawns──▶  postgres (embedded binary, PGDATA in userData)
                           ▶  postgREST (static binary)  ──▶ postgres
                           ▶  auth-gateway (Go static binary) ──▶ postgres
                           ▶  bridge-api.mjs  ──▶ postgREST + auth-gateway   ──▶ serves :4000
                           ▶  loads the bundled frontend (app://)
```
- **Bundle 3 binaries** via electron-builder `extraResources`, per platform:
  - **Postgres** — `embedded-postgres` / `pg-embed` downloads the platform binary at build time.
  - **PostgREST** — single static binary (linux + windows releases exist on GitHub).
  - **auth-gateway** — it's **Go** (`go/control-plane/`), so `GOOS=linux/windows go build` yields a
    single static binary; cross-compiles trivially.
- **Drop Kong** — the bridge can point `OSIONOS_BAAS_URL` straight at PostgREST (Kong was only
  routing + API-key gating; a single local user doesn't need it).
- **First-run config** (generated once into userData): a local **JWT secret** (PostgREST + the
  service-role JWT the bridge sends as `SERVICE_ROLE_KEY`), the Postgres superuser password, run
  `models/*.sql` migrations, create the single user + workspace.
- **Pro:** zero changes to the constrained `apps/osionos/app` submodule or the 1578-line bridge;
  keeps the gateway's hardening (lockout/policy) + Postgres **RLS**. **Con:** ships ~3 binaries
  (~tens of MB) and Electron main owns process lifecycle/health/teardown.

**Option B — rewrite the bridge's two backends.**
Replace `postgrestQuery`+RPC with a direct `pg` (node-postgres) client, and `handleAuthProxy` with a
local credential verify (argon2 hash in the DB) + the bridge's existing session mint. Embeds **only
Postgres**. **Pro:** one binary. **Con:** heavy edits to `bridge-api.mjs` (constrained submodule,
≤200-line rule, `"updated"` commits), loses the gateway hardening, higher regression risk.

**Recommendation: Option A.** Lower risk, no constrained-submodule churn, preserves auth hardening +
RLS. Revisit B later if the 3-binary bundle size becomes a problem (then collapse auth into the
bridge and keep just Postgres).

## Work breakdown (Option A)

All in **`apps/osionos-electron/`** (NOT the constrained submodule):

1. **`native/supervisor.js`** (new, Electron main child) — start/health/stop the 3 binaries in order
   with readiness gates (pg_isready → postgrest health → gateway health → bridge `/api/auth/bridge/health`),
   structured logs, crash-restart, clean teardown on app quit.
2. **`native/firstrun.js`** (new) — on first launch: init `PGDATA` under `app.getPath('userData')`,
   generate secrets, apply `models/{osionos-bridge,osionos-folder-surface,rls-hardening,auth-security}-migration.sql`
   + `user.sql` (osionos-only subset — skip mail/calendar), create the single user + private workspace.
3. **`build.sh`** — a new `--native` edition: bundle the 3 binaries as `extraResources`, set the app
   to "native" mode (frontend `API_URL=http://127.0.0.1:4000`, `BAAS_URL=""`, already supported).
4. **`package.json`** — `extraResources` for the binaries; keep `deb`/`AppImage`/`nsis` targets.
5. **`main.js`** — in native mode, `require('./native/supervisor')` before loading `app://`; route
   shutdown through it. (`main.js` already has the `API_URL`/`BAAS_URL` seam.)

Migrations to bundle (osionos-only): `models/osionos-bridge-migration.sql`,
`osionos-folder-surface-migration.sql`, `rls-hardening-migration.sql`, `auth-security-migration.sql`,
`user.sql`. **Skip** `mail-migration.sql`, `calendar-migration.sql`, and the cloud-only `gdpr`
pieces unless needed.

## De-risk PoC — RESULTS (validated 2026-06-09, throwaway containers, `make all` untouched)

**Verdict: GREEN.** The two riskiest assumptions are proven; what remains is mechanical.

✅ **Stock Postgres is enough — no custom image.** The entire osionos schema applies cleanly on
**`postgres:16-alpine`** (the heavy `track-binocle-postgres` FDW image — mongo/mysql/oracle fdw,
pg_net — is all mini-baas machinery osionos never touches). Bootstrap needed beyond stock:
- `CREATE EXTENSION pgcrypto;`
- roles `anon` / `authenticated` (NOLOGIN) + `service_role` (NOLOGIN BYPASSRLS) + `GRANT USAGE ON
  SCHEMA public` to them. (The mini-baas `db-bootstrap.psql` extras — `supabase_admin`, realtime db,
  `adapter_registry_role`, tenant/schema registries — are **not** needed.)
- The migrations self-create the `auth` schema + `auth.uid()`; they only need the 3 roles to pre-exist.

✅ **Migration order matters** (the one gotcha found): apply in this order —
`osionos-bridge-migration` → `osionos-folder-surface-migration` → **`user.sql`** →
`auth-security-migration` → `rls-hardening-migration`. `user.sql` must precede `auth-security`
(`auth_audit_events` FKs `public.users(id)`). `rls-hardening` is self-guarding (skips absent gdpr fns).
Result: **12 tables** land clean — `osionos_pages`, `osionos_workspaces`, `osionos_workspace_members`,
`osionos_bridge_identities`, `osionos_bridge_audit_events`, `osionos_page_configurations`,
`osionos_page_action_events`, + `users`, `sessions`, `user_tokens`, `user_activities`,
`auth_audit_events`.

✅ **The bridge is zero-dependency, portable.** `scripts/bridge-api.mjs` + `bridge-graph.mjs` import
only Node built-ins (no `npm install`). Run as a bare `node scripts/bridge-api.mjs` in a plain
`node:22-alpine` → `GET /api/auth/bridge/health` returns `200 {"ok":true,"service":"osionos-bridge"}`.
So bundling the bridge = ship Node + 2 files; the Electron supervisor just spawns it.

⏳ **Remaining (mechanical, not yet wired):** PostgREST + the Go auth-gateway pointed at the embedded
PG with a locally-generated JWT secret, then a full page round-trip through the bridge
(`/api/pages`). This is standard PostgREST JWT setup — low risk, do it during implementation.

**Conclusion:** Option A is viable. Embedded DB = stock Postgres binary + the ~10-line trimmed
bootstrap above + the 5 migrations in order. No custom image, no Mongo, no Kong.

## Build progress (2026-06-09)

**Data path fully proven** (PoC, throwaway containers): real **PostgREST v12.2.3** against the
osionos schema, connecting as `authenticator`, with a `service_role` JWT (HS256, `PGRST_JWT_SECRET`)
→ `GET /osionos_workspaces` = **200**; no/invalid JWT = **401**. So bridge → (shim) → PostgREST →
Postgres is locked.

**Modules written** (in `apps/osionos-electron/native/`, all `node --check` clean):
- `bootstrap.sql` — the validated trimmed bootstrap (pgcrypto + anon/authenticated/service_role +
  the `authenticator` LOGIN role + grants).
- `firstrun.mjs` — applies bootstrap + the 5 migrations in order via the bundled `psql`, idempotent,
  generates + persists local secrets (JWT secret, signed `service_role`/`anon` tokens, app-session +
  bridge-shared secrets) to `userData/secrets.json` (mode 600), sets the `authenticator` password.
- `restProxy.mjs` — the loopback `/rest/v1`→PostgREST rewrite shim (so the bridge stays unchanged).
- `supervisor.mjs` — boots postgres → firstRun → PostgREST → restProxy → auth-gateway → bridge with
  health gates; `stop()` tears down in reverse. PostgREST + bridge env is the proven wiring.

**Open decision — native auth (the auth-gateway is OUT-OF-REPO).** The Go `auth-gateway` is
**pull-only** (`dlesieur/prismatica-auth-gateway`, source in the separate **prismatica** repo), so it
can't be cross-compiled from this monorepo. Two ways forward:
- **A1 — bundle the gateway binary:** build it from the prismatica repo (Go static, linux+win) and
  ship it. Keeps the bridge untouched + the gateway's lockout/policy hardening. Cost: cross-repo build.
- **A2 — minimal local auth (recommended for a single-user app):** drop the gateway; add a small local
  credential path to the bridge (`handleAuthProxy` → INSERT/verify against `public.users` with a
  hashed password via the service-role PostgREST path, then the bridge's existing app-session mint).
  Removes the hardest-to-bundle binary; native then ships only **postgres + postgrest + bridge**. Cost:
  edits the constrained `apps/osionos/app` submodule (≤200-line / `"updated"` rules) + reimplements a
  slice of the gateway's register/login.

**Remaining work:** pick A1/A2; `build.sh --native` to acquire+bundle the binaries (embedded-postgres
+ PostgREST release + [gateway or local-auth]); `package.json` `extraResources`; `main.js` native mode
(spawn `supervisor.startSuite` before `app://`, route shutdown through `stop()`); first full bring-up.

## Targets & constraints

- **Linux** (`.deb`/`.AppImage`) + **Windows** (`.exe`/NSIS) — same electron-builder targets as the
  stopgap, just with the 3 extra bundled binaries.
- Supervisor/firstrun/build live in `apps/osionos-electron/` → free of the osionos/app submodule
  rule. **No bridge edits** in Option A (that's the point).
- Data dir: `app.getPath('userData')/pgdata` — verify offline (pull the network → still works) and
  that data persists across restarts/upgrades.
