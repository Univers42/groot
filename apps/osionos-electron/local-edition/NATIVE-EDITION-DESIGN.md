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

## De-risk first (the spike PoC — do this before committing to the build)

Prove the riskiest assumption cheaply, **without** Electron, in a throwaway container:

1. `postgres:16` fresh → apply the osionos `models/*.sql` subset → confirm it's clean (this is the
   one thing that can silently rot).
2. Start **PostgREST** + **auth-gateway** against it with a locally-generated JWT secret.
3. Run `node scripts/bridge-api.mjs` with `OSIONOS_BAAS_URL`/`AUTH_GATEWAY_URL` → those processes;
   `curl http://127.0.0.1:4000/api/auth/bridge/health` and a page round-trip.

If that green-lights, the Electron supervisor is mechanical. If a migration or PostgREST/gateway
wiring fails, fix it here before touching packaging.

## Targets & constraints

- **Linux** (`.deb`/`.AppImage`) + **Windows** (`.exe`/NSIS) — same electron-builder targets as the
  stopgap, just with the 3 extra bundled binaries.
- Supervisor/firstrun/build live in `apps/osionos-electron/` → free of the osionos/app submodule
  rule. **No bridge edits** in Option A (that's the point).
- Data dir: `app.getPath('userData')/pgdata` — verify offline (pull the network → still works) and
  that data persists across restarts/upgrades.
