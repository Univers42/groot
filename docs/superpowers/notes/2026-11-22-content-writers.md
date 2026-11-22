# Page-content writers (AM16)

Decision: `OSIONOS_PAGE_STRICT_VERSION=1` on live. Three class (d) writers exist, two of
them outside the web app (an MCP script and a SQL function).

Classes: (a) always sends `baseVersion` · (b) atomic append RPC · (c) create-only ·
(d) LWW content write, reachable without `baseVersion` on some branch.

Trees searched: `apps/osionos/app` at 68ed56642 (`src/`, `scripts/`, `services/`,
`models/` in groot), groot `apps/osionos-electron` (present in the worktree, 22 files),
groot `infrastructure/docker/osionos/ide-sandbox/osio-fs-agent.mjs`.

## Writers

| file:line | writer | class |
| --- | --- | --- |
| src/store/sync/pageOutbox.ts:111 (body), :132 (publishPage PATCH) | editor flush; `baseVersion` only when `carriesContent && baseVersion !== null` | (d) |
| src/store/sync/pageOutbox.ts:67, :172 | unload keepalive PATCH, same body builder | (d) |
| src/services/button-program/runProgram.ts:129 | button program, calls `publishPage` (the row above) | (d) via pageOutbox |
| src/features/page-file/model/pageFileFacadeOps.ts:145, pageFileAddPage.ts:43 | IDE / page-file edits, `patchPage` into the store, flushed by pageOutbox | (d) via pageOutbox |
| scripts/osionos-mcp-server.mjs:722-725 | `osionos_update_page`: version is the caller's or a prior GET; omitted when `contentVersion` is not a safe integer | (d) |
| scripts/bridge-discussions.mjs:237 -> models/osionos-discussions-migration.sql:418 | `rpc/osionos_decide_suggestion`: accepting a suggestion rewrites a block path in `content`; guarded by `expectedUpdatedAt`, not by version | (d) |
| src/features/share/shareApi.ts:121 | sharing PATCH, `baseVersion: before.version` always | (a) |
| scripts/osionos-mcp-server.mjs:723 | version branch of `osionos_update_page` (see the (d) row for the other branch) | (a) partial |
| scripts/bridge-api.mjs:4719 (rpc/osionos_page_append, handler :4705) | `POST /api/pages/:id/blocks`, one SQL statement (models/osionos-page-version-migration.sql:201) | (b) |
| services/osionos-ai/src/approvals/execute.ts:118 | `add_blocks` approval, calls the route above | (b) |
| scripts/osionos-mcp-server.mjs:745 | `osionos_append_to_page`, same route | (b) |
| scripts/bridge-api.mjs:4407 (handlePageCreate) | `POST /api/pages` | (c) |
| src/store/pageStore.actions.ts:117, :283, :383 | client page create / seed | (c) |
| services/osionos-ai/src/approvals/execute.ts:80 | `create_page` approval | (c) |
| services/osionos-ai/src/builders/execute.ts:108 | builder page create | (c) |
| scripts/osionos-mcp-server.mjs:684 | `osionos_create_page` | (c) |
| scripts/bridge-api.mjs:3795 | page-from-template/import insert (`return=representation`) | (c) |
| scripts/bridge-api.mjs:3312, :3322 | marketplace app + sub-pages, `content: []` | (c) |
| scripts/bridge-api.mjs:3696 | record-note insert, `on_conflict=id` + ignore-duplicates | (c) |

## Hits that are not content writes

| file:line | what it writes |
| --- | --- |
| scripts/bridge-api.mjs:3256, :3277 | app publish: properties, visibility |
| scripts/bridge-api.mjs:3350 | app edit: title, icon, properties |
| scripts/bridge-api.mjs:3705 | record-note refresh: `RECORD_DERIVED_FIELDS` = title, properties (bridge-records.mjs:126) |
| scripts/bridge-api.mjs:4492 | archive cascade: archived_at |
| scripts/bridge-api.mjs:4636 | the page PATCH handler itself (the guard, `handlePageUpdate`, :4549) |
| scripts/bridge-api.mjs:5148 | translate: returns blocks, writes nothing |
| src/store/pageStore.actions.ts:458, :1008 | archive / restore |
| src/shared/config/pageConfigStore.ts:224 | page config |
| services/osionos-ai/src/approvals/execute.ts:92, :96, :101; builders/undo.ts:69 | rename, config, archive |
| src/features/collab/model/blockSync.ts | realtime broadcast only; "never persisted" (header), persistence goes through pageOutbox |
| infrastructure/docker/osionos/ide-sandbox/osio-fs-agent.mjs | no `osionos_pages`, `/api/pages` or `baseVersion` match; sandbox files only |
| apps/osionos-electron | only native-migrate.sh:29 (pg_dump of the table) and native/firstrun.mjs:97 (existence check); no content write |
| scripts/seed-*.mjs, services/osionos-ai/eval/*, spikes/* | one-shot SQL INSERT of seed data, not runtime writers |

Count: (a) 1 (+1 partial) · (b) 3 · (c) 9 · (d) 3 distinct (pageOutbox PATCH and keepalive
share one body builder; runProgram and page-file reach it through the store).

## What strict mode does to each (d) writer

The flag is read at scripts/bridge-api.mjs:260 (`config.strictPageVersion`) and applied at
:4599: a PATCH with no `baseVersion` and a `content` key is compared with the stored content.
Equal -> it proceeds and is pinned to the version just read (:4608). Different -> 409 with the
server copy (`versionConflict`).

| (d) writer | under strict | breaks? |
| --- | --- | --- |
| pageOutbox publishPage (:132) | A null base happens when the page was never loaded with `contentVersion` (baseFor, pageBase.ts:42). It 409s only when its content differs from the stored one; the outbox already handles 409 (`conflictFrom`, pageOutbox.ts:140) through the merge path. | No loss; a page with no base and an edit now takes the conflict path instead of overwriting. |
| pageOutbox keepalive (:67/:172) | Same 409, but the answer is dropped on unload. The edit stays in the pending record and replays next load (comment at pageOutbox.ts:149-166). | No loss; the unload write may not land. |
| runProgram, page-file | Through publishPage, same as the first row. | Same. |
| osionos_update_page (mcp:722) | Sends a version whenever the bridge answers an integer `contentVersion` (it does since the page-version migration), so strict never fires. Against a bridge without it, an unversioned PATCH with changed content would 409. | No, on this bridge. |
| osionos_decide_suggestion RPC | Not a PATCH: the strict check does not see it. The RPC is one UPDATE that bumps `version` by trigger; a client holding an older base gets a 409 on its next versioned PATCH, which is correct. It still overwrites its block path regardless of the version a concurrent editor held. | Strict does NOT cover it. Residual lost-update window: a suggestion accepted between an editor's read and flush. |

Consequence for AM16: with strict on, an auto-applied AI edit that sends `baseVersion` (class
(a)) or appends (class (b)) cannot be silently overwritten by an unversioned editor flush,
and cannot silently overwrite one. The accepted-suggestion RPC is the one writer strict leaves
open; it is a human-initiated action, not an AI-mode path.

Env change: `docker-compose.yml`, `osionos-bridge` service `environment`, key
`OSIONOS_PAGE_STRICT_VERSION`, default `1` (docker-compose.yml:108). Live is not touched by this commit; the live
bridge reads it at start (`bridge-api.mjs:260`), so it applies at the next bridge recreate.

Caveat: this is a text-pattern inventory (`git grep -n`). A writer that builds its URL or
table name dynamically, or that reaches `osionos_pages` through a path not containing
the strings searched, can be missed (under-reporting). Direct database writers (psql, a
migration, a service with a database role) are invisible to it. The strict-version branch
does not depend on the inventory being complete for PATCH writers. UNKNOWN: the live
database's other triggers or functions beyond `models/`; anything under `vendor/` and
`apps/grobase` (not searched).

Evidence: in apps/osionos/app at 68ed56642:
`git grep -n -F baseVersion`, `git grep -n -F /content`, `git grep -n -F "method: 'PATCH'"`,
`git grep -n -F 'method: "PATCH"'`, `git grep -n -F osionos_page_append`,
`git grep -n -E "content:" -- scripts services src/features/collab src/store/sync`,
`git grep -n -E "osionos_pages" -- scripts services`; in groot (c18ced87):
`git grep -n -E "osionos_pages|/api/pages|baseVersion" -- apps/osionos-electron`,
`git grep -n -E "api/pages|osionos_pages|baseVersion|PATCH" -- infrastructure/docker/osionos/ide-sandbox/osio-fs-agent.mjs`,
`git grep -n -i -E "update +(public\.)?osionos_pages" -- models`.
