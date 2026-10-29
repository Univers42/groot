# Multi-database, multi-engine — the holistic plan (groot + osionos half)

*What the osionos database UI, the bridge, the test workspace and the groot e2e suite need
so every engine grobase serves can be seen, created, related and tested from the
frontend. The engine capability matrix and the backend work live in grobase
`wiki/architecture/multidb-holistic.md` (gates m243–m256, devil verdict 2026-10-29) — this page does not repeat them.*

Mapped 2026-10-29 from osionos `develop` 7893bdac2 and groot `develop` fdf1f9de.

## Where the UI stands

| Need | Today | Evidence |
|---|---|---|
| Open database says which DBMS / server / file it is on | No — loading/error panes say "ADAPTER"; Source row shows the name only | `object_database.tsx:560`, `MainSettingsScreen.tsx:98` |
| Legacy JSON/CSV/Mongo/Postgres switcher | Playground only: `/api/dbms/*` is served by the Vite dev middleware; live mounts show the badge instead | `dbmsMiddleware.ts`, `MountSourceBadge.tsx` (`DataSourceIndicator`) |
| Choose where a new database is created | No — always a JSONB blob in `osionos_object_databases` | `useDatabaseStore.ts:53-63` |
| Register a connection / link a mount to a workspace | No route; only seed scripts with direct `psql` | `bridge-api.mjs:3322`, `bridge-api.mjs:3743-3749` |
| Cross-engine relations | Guessed from column names, one-way, 500-row preload | `liveReferenceInfer.ts:56-121`, `liveSchemaMapper.ts:100`, `liveQueryTranslator.ts:37` |
| Relation / index / trigger / function DDL in UI | Unsupported | `liveDdlMapper.ts:74-75` |
| Automations on live mounts | Fixed by O2: the client calls the bridge's gated `/api/databases/:dbId/automations` | `liveAutomationsClient.ts`, `bridge-api.mjs` (`handleDatabaseAutomations`) |
| Scripts in automations | No — v2 ButtonProgram AST runs only in-browser for page databases | `contract-types/src/index.ts:475-480` |
| Live DB e2e in CI | db1/db2/od1 specs exist, no workflow runs them; `databasesPanel.spec` skips offline | `fresh-machine.yml:102,342`, `databasesPanel.spec.mjs:59,75` |

## The work — in order, each behind a gate and a CI job

UI rules for every item (ui-ux-pro-max, improve, never redesign): status as text + icon,
never colour alone; skeleton past 300 ms; `role=alert` errors with a recovery action;
confirm before anything irreversible (migration, dropping a contract); progressive
disclosure with visible labels; tables in an `overflow-x-auto` wrapper; empty states
carry a message and an action.

Devil verdict 2026-10-29 for this half: O1, O2, O4, W1, W2 PROCEED-WITH-CONDITIONS;
O3, O5, O6 BLOCKED until their grobase prerequisites land. Conditions are folded below.

### Phase 1 — say what a database is bound to (needs grobase G4)

**O1 · Connection badge + Source settings** — osionos
- [x] Database top bar shows an engine badge and the binding: host or file,
      database/schema, TLS state (icon + text), credential mode. Data from the bridge,
      which proxies grobase's credential-free mount descriptor (G4, grobase e6815228) —
      Univers42/notion-database-sys#24, Univers42/osionos#226. Engine *version* waits for
      G4b (the data plane is the one that knows it).
- [x] Replace "ADAPTER" in loading/error panes with the engine and mount name — O1a, Univers42/osionos#226 + Univers42/notion-database-sys#23 (draft until the screenshot). Engine comes from the host mount catalog, not `LiveSchemaResponse.engine`: the catalog has it before the first schema fetch.
- [ ] Source settings row: full binding, read-only for members, editable for owners.
- [x] ~~Delete `DbSourceDropdown`~~ — not dead: `dbmsMiddleware.ts` serves `/api/dbms/*` to the Vite playground and `HttpAdapter.ts` calls it. Live mounts render the badge; the playground keeps the switcher (`DataSourceIndicator`).
- [ ] Unit: badge renders for each of the 10 engines; e2e DOM spec asserts the badge.
- Conditions: the full badge lands after grobase m246 is green; the bridge proxies the
  descriptor through the mount ACL and never sends a host for platform mounts;
  `DbSourceDropdown` and `/api/dbms/*` go only after rg proves no other caller.
- O1a (before G4): the engine name the schema response already returns
  (`LiveSchemaResponse.engine`) plus the mount name from the host catalog — no host, no
  TLS claim — replaces "ADAPTER". The binding and TLS rows wait for G4.

**O2 · Fix the live automations route** — osionos bridge
- [x] Bridge proxies `GET|PUT /api/databases/:dbId/automations` to grobase with the
      mount ACL (read: `canReadDatabase`; replace: `canRunDdl`); client moves to it.
      Spec proves a rule round-trips — `tests/bridge/bridge-mount-automations.test.mjs`,
      Univers42/osionos#227 + Univers42/notion-database-sys#25 (develop 5037c074).
- [x] One grobase tenant key serves every workspace, so the bridge ACL is the only
      isolation: the same spec proves workspace B gets 403 on GET and PUT with zero
      query-router calls.

### Phase 3 — origin, creation target, migration (needs grobase G6–G8)

**O3 · Register a connection, link it to a workspace** — bridge + UI — BLOCKED
- Lifts: grobase N-22 closed, G2 dial guard live, G1 enforced; register + link is one
  atomic ACL-checked bridge call; list/PATCH/unlink filtered per workspace; canary
  password log gate across 3 planes; test-connection rate-limited, one generic failure.
- [ ] Bridge routes over grobase self-serve `/v1/tenants/me/mounts`: register (DSN is sent
      once, never echoed back, never logged), list, PATCH, unlink.
- [ ] Workspace "Connections" panel: engine picker, TLS fields, test-connection result.

**O4 · Where a new database is created** — UI
- Target picker after grobase m248; "Migrate to…" after m250 with dry run + confirm;
  the default target stays the platform JSON store until a workspace sets one.
- [ ] New database flow: target picker (platform JSON store, or any linked mount +
      database/schema), defaulting to the workspace default target.
- [ ] Non-empty source: "Migrate to…" with a dry-run lossy-column report, then a
      confirmed, resumable job with progress.

### Phase 5 — relations and automations across engines (needs grobase G11–G12)

**O5 · Contract editor + two-way relations** — UI — BLOCKED until G12 slice 1 + m254a
- Open question O5 must answer for G12: is cross-mount cascade needed, or is
  `sync_check` + an orphan report enough?
- [ ] Relation property can target any linked mount's table; saving creates a grobase
      contract (cardinality, on-delete policy, sync vs eventual), shown with its
      validation state and orphan count.
- [ ] Two-way relations; server-side rollups past the 500-row cap.

**O6 · Automations as the cross-engine place** — UI — BLOCKED until grobase G11b
- [ ] Live mounts on the v2 program model; steps `write_mount` and `run_function`
      (an edge-function script with a scoped data client); run history with errors.
- [ ] Button automations can invoke the same programs.

### Test workspace and CI (continuous)

**W1 · A dedicated workspace for dev.pro.photo@gmail.com**
- [x] Created through the supported path (`POST /api/workspaces` as that user,
      `bridge-api.mjs:4879-4904`), named so it never mixes with existing work:
      "Multi-DB Lab", `bc04a437-1da3-4043-9ede-f918ebf11b58` (2026-10-29).
- [x] Parameterised all-engine seeder (`scripts/seed/multidb-workspace.sh`, Univers42/grobase#60): workspace id
      and owner are arguments, not constants (today's seeds hardcode WS_ACME/WS_MAIN).
      One mount per engine — postgresql, cockroachdb, mysql, mariadb, mongodb, redis,
      sqlite, mssql, http, dynamodb — static reference tables and a churn table per
      engine, plus cross-engine edges; later the same seeder declares contracts (O5).
- [ ] Idempotent: a second run changes nothing (three live applies, 24 churn rows per
      engine each time; redis WARNs on re-insert until the 409 fix is deployed); teardown removes only what it made
      (proven by a diff). Never writes WS_ACME / WS_MAIN; credentials read from
      `secrets/` files; non-sensitive data only (mounts sit under the shared bridge
      tenant, visible across workspaces at the grobase level).
- [x] No contracts or cross-engine edges until G12 lifts; DynamoDB only where the image
      has the feature; a live VM run needs a stated go (given 2026-10-29). Live: nine
      mounts list 24 churn rows each and show in the Databases sidebar; http skipped
      (no public `MDW_HTTP_BASE_URL`).

**W2 · Live database e2e in CI**
- [ ] Wire db1/db2/od1 specs into the live-stack job; add the badge spec (O1) and a
      cross-engine relation spec (O5).
- [ ] osionos `databasesPanel.spec` runs against the bridge stub instead of skipping.
- [ ] Specs run against a CI stack, never the live VM; a skipped spec reports SKIP;
      develop/main-only jobs get a documented local equivalent.

## What this does not do

- Two apps' databases never merge; contracts relate mounts inside one workspace's tenant.
- No cross-engine two-phase commit: cross-mount writes are compensated, and the UI says
  "eventual" where it is.
- No redesign of the database UI — every change is additive on the existing chrome.
