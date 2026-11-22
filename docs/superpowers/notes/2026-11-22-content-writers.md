# Page-content writers (AM16)

Decision: `OSIONOS_PAGE_STRICT_VERSION=1` on live. Found three class (d) writers: the editor
flush (`pageOutbox`), the MCP `osionos_update_page` fallback and the groot demo loader. The
last two are fixed in the commits named below, so one writer (the editor flush, in the web
app) is left, plus the trees listed UNKNOWN, which count as (d). Strict mode is what makes
the editor flush safe against an auto-applied AI edit.

Classes: (a) always sends `baseVersion` · (b) atomic RPC, block-addressed or append ·
(c) create-only · (d) LWW content write, reachable without `baseVersion` on some branch.

Trees searched: `apps/osionos/app` at 68ed56642 (`src/`, `scripts/`, `services/`),
groot `models/`, groot `scripts/` (found the demo loader), groot `apps/osionos-electron`
(present in the worktree, 22 files), groot
`infrastructure/docker/osionos/ide-sandbox/osio-fs-agent.mjs`.

## Writers

| file:line | writer | class |
| --- | --- | --- |
| src/store/sync/pageOutbox.ts:111 (body), :132 (publishPage PATCH) | editor flush; `baseVersion` only when `carriesContent && baseVersion !== null` | (d) |
| src/store/sync/pageOutbox.ts:67, :172 | unload keepalive PATCH, same body builder | (d) |
| src/services/button-program/runProgram.ts:129 | button program, calls `publishPage` (the rows above) | (d) via pageOutbox |
| src/features/page-file/model/pageFileFacadeOps.ts:145, pageFileAddPage.ts:43 | IDE / page-file edits, `patchPage` into the store, flushed by pageOutbox | (d) via pageOutbox |
| vendor/*, apps/grobase, apps/calendar, apps/mail, apps/opposite-osiris | not checked out in the worktree, not searched in it (the review grepped the develop checkout and found none) | UNKNOWN, counts as (d) |
| scripts/osionos-mcp-server.mjs:722-725 (app commit 7231e308e) | `osionos_update_page`: a content replacement without the caller's `baseVersion` is refused; before 7231e308e it read the current version and pinned to it, which strict cannot see | (a) after the fix, (d) before |
| scripts/demo/load-pages.mjs:128 (groot commit 15fdb24b) | `resolveLinks` content PATCH; now sends the create answer's `contentVersion`, or reads it | (a) after the fix, (d) before |
| scripts/bridge-discussions.mjs:237 -> models/osionos-discussions-migration.sql:418 | `rpc/osionos_decide_suggestion`: locks the page row (`FOR NO KEY UPDATE`, :366), finds the block by id, re-anchors on the current text (:411) and splices that one block in a single UPDATE; the version trigger bumps `version` | (b) (atomic, block-addressed) |
| scripts/bridge-api.mjs:4719 (rpc/osionos_page_append, handler :4705) | `POST /api/pages/:id/blocks`, one SQL statement (models/osionos-page-version-migration.sql:201) | (b) |
| services/osionos-ai/src/approvals/execute.ts:118 | `add_blocks` approval, calls the route above | (b) |
| scripts/osionos-mcp-server.mjs:745 | `osionos_append_to_page`, same route | (b) |
| scripts/bridge-api.mjs:4407 (handlePageCreate) | `POST /api/pages` | (c) |
| scripts/bridge-agent.mjs:225 | agent `toolCreatePage`, direct `osionos_pages` POST | (c) |
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
| src/features/share/shareApi.ts:121 | sharing patch plus `baseVersion`, no `content` key |
| scripts/bridge-api.mjs:3256, :3277 | app publish: properties, visibility |
| scripts/bridge-api.mjs:3350 | app edit: title, icon, properties |
| scripts/bridge-api.mjs:3705 | record-note refresh: `RECORD_DERIVED_FIELDS` = title, properties (bridge-records.mjs:126) |
| scripts/bridge-api.mjs:4492 | archive cascade: archived_at |
| scripts/bridge-api.mjs:4636 | the page PATCH handler itself (the guard, `handlePageUpdate`, :4549) |
| scripts/bridge-api.mjs:5148 | translate: returns blocks, writes nothing |
| scripts/bridge-api.mjs:5164, :5169 | `handlePageDelete`: hard DELETE |
| scripts/demo/load-pages.mjs:152 | demo loader `reshape`: properties only |
| src/store/pageStore.actions.ts:458, :1008 | archive / restore |
| src/shared/config/pageConfigStore.ts:224 | page config |
| services/osionos-ai/src/approvals/execute.ts:92, :96, :101; builders/undo.ts:69 | rename, config, archive |
| src/features/collab/model/blockSync.ts | realtime broadcast only; "never persisted" (header), persistence goes through pageOutbox |
| infrastructure/docker/osionos/ide-sandbox/osio-fs-agent.mjs | no `osionos_pages`, `/api/pages` or `baseVersion` match; sandbox files only |
| apps/osionos-electron | only native-migrate.sh:29 (pg_dump of the table) and native/firstrun.mjs:97 (existence check); no content write |
| scripts/seed-*.mjs, services/osionos-ai/eval/*, spikes/* | one-shot SQL INSERT of seed data, not runtime writers |

Count, by table row: (a) 2 (after the two fixes) · (b) 4 · (c) 9 · (d) 1 distinct (pageOutbox PATCH and
keepalive share one body builder; runProgram and page-file reach it through the store), plus
the UNKNOWN trees.

## What strict mode does to each writer

The flag is read at scripts/bridge-api.mjs:260 (`config.strictPageVersion`) and applied at
:4599: a PATCH with no `baseVersion` and a `content` key is compared with the stored content.
Equal -> it proceeds and is pinned to the version just read (:4608). Different -> 409 with the
server copy (`versionConflict`). A PATCH that carries a `baseVersion` skips this branch and is
only checked by `version=eq.<n>`.

| writer | under strict | breaks? |
| --- | --- | --- |
| pageOutbox publishPage (:132) | A null base happens when the page was never loaded with `contentVersion` (baseFor, pageBase.ts:42). It 409s only when its content differs from the stored one. With no base the merge returns `unresolved` (mergePageContent.ts:62-63), so the local edit is diverted to a private copy page (pageConflict.ts:104-108), not merged into the page. | No loss; a user-visible fork instead of an overwrite. Rare while `pageStore.actions.ts:214` sets the base from `contentVersion`. |
| pageOutbox keepalive (:67/:172) | Same 409, dropped on unload. The edit stays in the pending record; the next load replays it, 409s again and is diverted to a copy (pageOutbox.ts:149-166). | No loss; the unload write does not land on the page. |
| runProgram, page-file | Through publishPage, same as the first row. | Same. |
| demo loader (before 15fdb24b) | Each link-resolving PATCH changed the content, so strict answered 409 and `load-pages.mjs` threw, failing `seed-baas.sh:92`. | Yes; fixed in 15fdb24b, test `scripts/demo/tests/load-pages.test.mjs` fails (409) on the old loader. |
| osionos_update_page (before 7231e308e) | The tool pinned its PATCH to a version it read at write time, so the bridge saw a `baseVersion` and strict never fired. An agent that read at v5, after an auto-applied append (v6), erased the AI blocks silently. | Strict did not cover it; fixed in 7231e308e (version must come from the caller). |
| osionos_decide_suggestion RPC | Not a PATCH, so strict does not see it, and does not need to: one UPDATE under a row lock, one block, version bumped by trigger. It cannot erase concurrent blocks; a concurrent versioned editor gets a 409. | No. |

Consequence for AM16: with strict on and the two fixes live, an auto-applied AI edit that
sends `baseVersion` (class (a)) or appends (class (b)) cannot be silently overwritten by an
unversioned editor flush, and a version-pinned writer cannot overwrite one it did not read.
Residuals, named so nobody relies on more than this:
- Any external client holding a personal access token can PATCH pages (bridge-pat-middleware.mjs:80)
  and repeat the read-then-pin pattern; strict cannot see it. Not searched, so UNKNOWN.
- Old local copies of `osionos-mcp-server.mjs` (run from a checkout before 7231e308e) still read the
  current version and pin to it; strict cannot see them. UNKNOWN how many exist.
- Old cached web bundles from before `baseVersion` was sent (2026-10-21): their reaction to a
  409 is UNKNOWN.
- Direct database writers (psql, a service holding a database role) bypass the bridge.

Auto modes wait until osionos 7231e308e is promoted: until then the live MCP server still
auto-fills the version, which is the (d) behaviour above.

## Turning it on and off

The key is in `docker-compose.yml:108`, the `osionos-bridge` `environment:` block, default
`1`. `environment:` overrides the bridge's `env_file: ./.env.local`, so
`OSIONOS_PAGE_STRICT_VERSION=0` in `.env.local` does nothing. Rollback is the groot `.env` or the
shell, then a bridge recreate. The flag takes effect at the next bridge recreate, which may be an
unrelated one; recreate it deliberately.

Before that recreate, probe that the live database has the `version` column and its trigger
(models/osionos-page-version-migration.sql). Without the column, `fetchPageVersionRow`
(bridge-api.mjs:4544) fails every unversioned content PATCH. UNKNOWN: not probed here.

Caveat: this is a text-pattern inventory (`git grep -n`). A writer that builds its URL or
table name dynamically, or that reaches `osionos_pages` through a path not containing
the strings searched, can be missed (under-reporting). Direct database writers are invisible
to it. Trees not searched are listed as UNKNOWN above.

Evidence: in apps/osionos/app at 68ed56642:
`git grep -n -F baseVersion`, `git grep -n -F /content`, `git grep -n -F "method: 'PATCH'"`,
`git grep -n -F 'method: "PATCH"'`, `git grep -n -F osionos_page_append`,
`git grep -n -E "content:" -- scripts services src/features/collab src/store/sync`,
`git grep -n -E "osionos_pages" -- scripts services`; in groot (c18ced87):
`git grep -n -E "osionos_pages|/api/pages|baseVersion" -- apps/osionos-electron`,
`git grep -n -E "api/pages|osionos_pages|baseVersion|PATCH" -- infrastructure/docker/osionos/ide-sandbox/osio-fs-agent.mjs`,
`git grep -n -i -E "update +(public\.)?osionos_pages" -- models`,
`git grep -n -E "PATCH|api/pages" -- scripts/demo`.
