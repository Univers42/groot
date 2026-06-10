# Binocle Intelligence Agency — Master Checkup List

The full verification matrix for the agency organization simulation: what to
check, exactly how, which gate automates it, and the live status from the
Wave 3 verification pass (2026-06-10).

**Run the ladder:**

```bash
make agency-verify             # m23 foundation gate (tenant, data, graph, identities, ABAC)
make agency-verify-platform    # m23 platform gate (bundle, sessions, chat+WS, DM privacy, video, feed, masks)
make agency-sim                # Playwright end-to-end organization simulation (multi-context browsers)
```

Sim artifacts (screenshots + `results.json`):
`apps/osionos/app/test-results/agency-simulation/`.

Legend: ✅ verified live · ⚠️ partial / honest caveat · ❌ broken.
`automated-by`: `m23-foundation` = `scripts/verify/m23-agency-foundation.sh`,
`m23-platform` = `scripts/verify/m23-agency-platform.sh` (both in
`apps/baas/mini-baas-infra`), `agency-sim` =
`apps/osionos/app/scripts/agency-simulation.mjs`.

---

## A. Foundation (tenant, accounts, workspace)

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 1 | Live tenant `agency` exists with API key + postgresql mount | `cat apps/baas/mini-baas-infra/.agency-tenant.env` (AGENCY_DB_ID=d3ecb3e1-9947-41a6-a0d3-ff2063b4adee) | m23-foundation | ✅ |
| 2 | 11 tables on the mount, served through Kong key-auth → query-router → Rust data plane | `curl $KONG/query/v1/$DB/schema -H "apikey: $ANON" -H "X-Baas-Api-Key: $KEY"` | m23-foundation | ✅ |
| 3 | Row counts match the design (cases 40, transactions 150, edges 80, ~950 total) | gateway `op=aggregate` count per table | m23-foundation (spot: cases/transactions/edges) | ✅ |
| 4 | 21 gotrue accounts `@agency.local` (owner + 20 employees) | `SELECT count(*) FROM auth.users WHERE email LIKE '%@agency.local'` in track-binocle-postgres-1 | m23-foundation | ✅ |
| 5 | 21 bridge identities + the 21 roster accounts are org-workspace members | members JOIN auth.users filtered to `@agency.local` (extra members — invites, the dev account — are allowed) | m23-foundation | ✅ |
| 6 | Org workspace `Binocle Intelligence Agency` (b1a0c1e5-…0001) owned by Helena Voss | `SELECT * FROM osionos_workspaces WHERE id='b1a0c1e5-…'` | m23-foundation (membership), sim step 2 (UI) | ✅ |
| 7 | gotrue invite → Mailpit email lands (`You have been invited`) | probe invite via gotrue admin + `GET :8025/api/v1/search?query=…` | m23-foundation + agency-sim step 3 | ✅ |
| 8 | Roster file with uuids/roles/departments/clearance | `cat tools/seeds/.agency-people.env` (AGENCY_PERSON_0…20) | m23-foundation (consumes) | ✅ |

## B. Data & Graph

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 9 | Graph overview serves a connected investigation graph (≥100 nodes, explicit `associate` edges) | `POST $KONG/query/v1/graph/overview` with cases+subjects resources + edgesDbId | m23-foundation | ✅ |
| 10 | Gateway reads work with the agency tenant key (list/aggregate) | `POST $KONG/query/v1/$DB/tables/cases {"op":"list"}` | m23-foundation, m23-platform (implicit) | ✅ |
| 11 | Gateway writes work + restore (update a transactions cell, put it back) | sim step 7 does `op=update` → assert → restore | agency-sim | ✅ |
| 12 | Realtime `row_changed` fires on gateway writes (topic `table:<db>:<table>`) | WS subscribe (HS256 token) → gateway update → event ≤8s | agency-sim step 7 (+ m22 gate for the generic path) | ✅ |
| 13 | Live mounts catalog reaches the browser (VITE_BAAS_LIVE_MOUNTS / registry) | rebuilt image carries the agency mount: `docker exec track-binocle-osionos-app-1 grep -rl d3ecb3e1 /usr/share/nginx/html/assets/` | manual (build step `make osionos-app-live`) | ✅ |
| 14 | Wiki pages embed live tables (`database_inline` → `baas:<db>:<table>`) and render rows | open “Erik Johansson — Working Notes” → transactions embed | agency-sim step 5 (screenshot 05) | ✅ |
| 15 | Live edit propagates to another user's open embed **live** | sim step 7: analyst DOM watched for the new value | agency-sim | ⚠️ event verified; the embed view didn't render the edited row/column, so the DOM assert fell back to the WS event (recorded per run in `results.json`) |

## C. Permissions (ABAC)

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 16 | 11 `agency:*` roles + 48 policies seeded in the permission engine | `GET $KONG/permissions/v1/permissions/bundles/roles` / `…/policies` (service apikey + X-Service-Token + X-Tenant-Id) | m23-platform (bundle counts ≥21 roles-assignments / ≥40 policies) | ✅ |
| 17 | Bundle endpoint `GET /permissions/bundles/latest` serves user_roles + policies incl. masks | m23-platform §a | m23-platform | ✅ |
| 18 | Director allowed on transactions | `POST /permissions/decide` user=owner | m23-foundation | ✅ |
| 19 | Analyst allowed but `amount` masked `'***'` | decide user=e11 → `mask.redact.amount === "***"` | m23-foundation, m23-platform §h, agency-sim step 6 | ✅ |
| 20 | Field agent denied on communications + `subjects.ssn` hidden + denied transaction writes | decide user=e07 | m23-foundation | ✅ |
| 21 | Guest denied on evidence | decide with the guest probe uuid | m23-foundation | ✅ |
| 22 | Bridge perms proxy (`/api/perms/*` → Kong permission-engine) works incl. CORS for the browser | `curl -k https://localhost:4000/api/perms/decide …` + browser fetch from :3001 | m23-platform §h + agency-sim step 4 | ✅ (CORS headers added in Wave 3 — bridge-perms.mjs) |
| 23 | Permissions matrix panel renders the role × resource grid + mask badges | app → Settings → Permissions | agency-sim step 4 (screenshot 04) | ✅ |
| 24 | Mask enforcement on the osionos **read path** (UI shows `***`) | analyst opens the live transactions table | agency-sim step 6 (DOM probe) | ⚠️ pending — the browser read path uses the shared tenant API key (no per-user identity), masks are decide-only today |
| 25 | Share popover on a page | sim step 12: owner opens Mission Control → page-header "Share" → dialog renders people picker + access list + General access (screenshot 12) | agency-sim | ✅ mounted — `PageShareButton` in the page header bar lazily opens `features/share` `SharePopover` (page mode, AccessRules); hydrates live from `/api/perms/people` + `/api/perms/rules` |

## D. Chat & DMs

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 26 | Channels persisted (9 seeded: #general all-21, #case-ops, #intel-analysts, #field, War Room video private, 4 DMs) + 202 messages + 18 reactions | `GET /api/chat/channels?workspaceId=<org>` as owner | m23-platform (list implied), `make agency-content` idempotent | ✅ |
| 27 | Message roundtrip: post as owner → analyst reads it back | m23-platform §c (namespaced `sim-probe-*` channel, cleaned up) | m23-platform | ✅ |
| 28 | Realtime chat: `message_created` arrives on `chat:<ws>:<channel>` over Kong `/realtime/v1/ws` | WS probe container (node:22-alpine, mini-baas network, in-band HS256 AUTH) | m23-platform §c | ✅ |
| 29 | Cross-context chat in the real UI (send in one browser, appears live in the other) | sim step 9: owner ↔ analyst in #general, both opened from the sidebar Channels section, both directions | agency-sim | ✅ (reply arrived live over the WS) |
| 30 | DM privacy: third party cannot read a DM (API 403) nor see it in the sidebar | sim step 8 + m23-platform §d | m23-platform + agency-sim | ✅ |
| 31 | Sidebar entry for bridge **text** channels (#general …) | sidebar “Channels” section lists the bridge channels; sim step 9 opens #general from it in two contexts (screenshots 09a/09) | agency-sim | ✅ `widgets/channel-list` (DmList pattern, cross-workspace): #general, #case-ops, #intel-analysts, #field + War Room with a camera glyph; click opens the channel tab exactly like DmList |
| 32 | Display names in chat | cosmetic check | — | ⚠️ each website login overwrites the bridge identity display_name with the gateway username (e.g. `Nadia Petrova` → `e08.petrova`, owner → `owner`) — cosmetic, but visible in DM titles |

## E. Profiles & People

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 33 | People search (`/api/people?query=`) scoped to the org workspace | m23-platform §g (finds the analyst) | m23-platform | ✅ |
| 34 | Profile fetch (`/api/profile/:uuid`) with org role + presence | m23-platform §g | m23-platform | ✅ |
| 35 | Avatar upload (dataUrl ≤200KB) + heartbeat presence | `POST /api/profile/avatar`, `POST /api/profile/heartbeat` | manual (`curl` with a session token; covered by WS-B tests) | ✅ (API verified in WS-B; not re-driven by the sim) |
| 36 | Org workspace reachable in the editor for every member (pages list + tree) | login any roster member → switch workspace → tree shows Mission Control etc. | agency-sim steps 2+5 | ✅ (Wave 3 bridge fix: sessions now carry org workspaces; `/api/pages` consults `osionos_workspace_members`) |

## F. Video (LiveKit)

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 37 | `/api/rtc/token` mints HS256 join tokens after channel-membership check (403 for non-members) | m23-platform §e + bridge-rtc integration tests (`docker cp … && docker exec … node /tmp/rtc/bridge-rtc.test.mjs`) | m23-platform | ✅ |
| 38 | LiveKit twirp admin path accepts an admin JWT (`ListRooms` 200) | m23-platform §e | m23-platform | ✅ |
| 39 | Two real participants join the War Room and show up in `ListRooms` | sim step 10: owner joins through the in-app “Join call” button, deputy via livekit-client; ≥2 participants asserted, owner leaves via the UI | agency-sim | ✅ |
| 40 | In-app “Join call” UI | sim step 10: sidebar → War Room → header “Join call” → VideoRoomView connects (“1 in call” → 2), owner clicks Leave and the panel unmounts (screenshots 10a/10) | agency-sim | ✅ `CallPanel` in `ChannelMessagesView` mounts `VideoRoomView` above the chat for voice/video channels (room `channel-<id>`, browser token via `/api/rtc/token`) |

## G. Feed

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 41 | Like roundtrip cross-user (count increases, like removed after to keep counts stable) | m23-platform §f + sim step 11 | m23-platform + agency-sim | ✅ |
| 42 | Comment roundtrip cross-user | m23-platform §f (probe comment cleaned up via psql) + sim step 11 | m23-platform + agency-sim | ✅ |
| 43 | Feed UI (FeedView) | notion-database-sys feed view preset | — | ⚠️ interactions asserted via API; FeedView is a database view preset, not wired as a standalone feed surface |

## H. Wiki & Content

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 44 | 26 wiki pages in the org workspace (handbook, 6 case wikis, galleries, analyst notebooks) | `SELECT count(*) FROM osionos_pages WHERE workspace_id='b1a0c1e5-…'` (26 + any sim/user additions) | `make agency-content` (idempotent) | ✅ |
| 45 | Wiki tree reachable in the UI (root sections + nested notebooks) | sim steps 2/5 (screenshots 02, 05) | agency-sim | ✅ |
| 46 | 44 likes + 14 comments backfilled | `SELECT count(*) FROM osionos_feed_likes / osionos_feed_comments` | `make agency-content` | ✅ (plus sim comments, which read as real activity) |

## I. Simulation & toolchain

| # | Check | How | Automated by | Status |
|---|-------|-----|--------------|--------|
| 47 | Real auth flow end-to-end (website portal → gateway → bridge handoff → editor) | sim step 1 | agency-sim | ✅ |
| 48 | Owner invite flow in the UI (Settings → People → Add members) + email leg | sim step 3 (screenshot 03) | agency-sim | ✅ UI pending-invite row + gotrue/Mailpit email; ⚠️ the UI invite store is client-side (no bridge `/api/workspaces/:id/invites` route yet) so the two legs are stitched by the sim |
| 49 | The whole tree still typechecks | `bash apps/osionos/app/scripts/docker-run.sh typecheck` | manual | ✅ (exit 0, 2026-06-10) |
| 50 | Bridge unit + rtc integration tests | `bash scripts/docker-run.sh test-bridge` + the bridge-rtc /tmp/rtc procedure | manual | ✅ 16/16 + 8/8 |

---

## Known gaps (honest list — all ⚠️ above)

1. **UI mask enforcement pending** (#24): the osionos live-table read path
   authenticates with the shared tenant API key; per-user masks only exist on
   `/permissions/decide`. Enforcing `***` in the UI needs per-user identity on
   the query path (or the bridge proxying reads through the decide mask).
2. **Workspace-invite bridge route** (#48): persist invites server-side and
   send the gotrue invite from the bridge so the UI flow is one leg.
3. **Display-name drift** (#32): logins overwrite seeded display names with
   gateway usernames.
4. **Live-edit row visibility** (#15): the embed's default view doesn't show
   the `counterparty` column for the edited row; the realtime event is proven,
   the visual confirmation depends on the view configuration.

Closed in the final polish pass (2026-06-10): sidebar text channels (#31 —
`widgets/channel-list`), the video “Join call” entry (#40 — `CallPanel` in
`ChannelMessagesView`), and the Share popover mount (#25 — `PageShareButton`
in the page header bar). All three are driven by the sim (steps 9/10/12).

## Wave 3 application changes (full disclosure)

- `apps/osionos/app/scripts/bridge-api.mjs` —
  (a) `requireWorkspaceAccess` falls back to `osionos_workspace_members` when
  the workspace is not in the app token (org pages were a hard 403);
  (b) `/api/workspaces` lists member workspaces (UI hydration);
  (c) sessions minted by `createBridgeHandoff`/`createUserSession`/`signAppSessionToken`
  carry org workspaces (sidebar switcher);
  (d) `requirePageOwnership` grants shared-workspace members holding the
  `update` permission (client `canEditPage` parity — fixed the outbox 403 storm).
- `apps/osionos/app/scripts/bridge-perms.mjs` — CORS headers on `/api/perms/*`
  responses (the in-app Permissions matrix was “Failed to fetch” cross-origin).
- `apps/osionos/app/.env` — VITE_BAAS_API_KEY → agency tenant key,
  VITE_BAAS_TENANT_ID=agency, VITE_BAAS_LIVE_MOUNTS → the agency mount
  (the live-demo mounts belonged to the other tenant key).
- `m23-agency-foundation.sh` — org-member count now asserts the 21 roster
  accounts instead of an exact total (extra members are legitimate).

## Final polish pass changes (2026-06-10, full disclosure)

- `src/widgets/channel-list/` (new) — sidebar “Channels” section listing
  non-DM bridge channels (DmList pattern: same tab-open mechanism, cross-
  workspace list); mounted in `widgets/sidebar/ui/Sidebar.tsx` above DmList.
- `src/widgets/channel-messages/` — `model/useChannelInfo.ts` (resolve a
  channel's kind from the channel list) + `ui/CallPanel.tsx` (lazy
  VideoRoomView mount) + a “Join call” header button in
  `ChannelMessagesView` for `voice|video` channels.
- `src/entities/page/ui/PageShareButton.tsx` (new) — “Share” button in
  `PageHeaderBar` anchoring the WS-C `SharePopover` (page resource mode).
- `src/widgets/video-room/useRtcToken.ts` — browser token fetch now sends the
  bridge PAGE JWT (`getActivePageJwt`, like every `/api/chat` call);
  `getActiveJwt()` is empty in bridge-session mode → the in-app join 401'd.
- `scripts/bridge-rtc.mjs` + `scripts/bridge-api.mjs` — `/api/rtc/token`
  responses now carry the per-request (per-origin) CORS config like
  chat/profile/feed; the base `OSIONOS_ALLOWED_ORIGIN` blocked browsers on
  `https://127.0.0.1:3001` (the old sim fetched tokens Node-side, hiding it).
- `scripts/agency-simulation.mjs` — step 9 drives the sidebar Channels entry
  (#general in both contexts), step 10 drives the “Join call” button +
  UI leave, new step 12 opens the Share popover on Mission Control.

Last verified: 2026-06-10 — `agency-verify` ✅ · `agency-verify-platform` ✅ ·
`agency-sim` 12 PASS / 2 WARN / 0 FAIL (remaining WARNs: #24 mask
enforcement, #15 live-edit DOM assert) · typecheck ✅ · lint ✅ ·
canvas 243/243 ✅ · bridge tests 16/16 ✅.
