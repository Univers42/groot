# ADR-004 — Pages as files: `.omd` in an osionos-owned workspace folder

Status: PROPOSED · Date: 2026-10-13 · Decides: which store is authoritative for a block page
once the IDE and the page editor share one workbench · Builds on [ADR-001](ADR-001-vfs.md)
(mount table, `FsProvider`), [ADR-002](ADR-002-terminal.md) · Source design:
`apps/osionos/app/docs/superpowers/specs/2026-10-13-workbench-page-files-design.md`
(in the app submodule, branch `feat/ide`). Falsifiers at end.

Nothing in this ADR is shipped. The interfaces listed under "Interfaces" exist as stubs;
no `.omd` file is produced by the app yet, so this page has no runnable example. The
codec tests the spec names (`page-file-codec`, `page-paths`) are not on disk.

## Problem

Today Postgres JSONB (`osionos_pages.content`) is the only truth for a block page. Real
files exist only in a per-`(user, workspace)` Docker volume, mirrored by SyncLink
(ADR-001). The result is two interfaces stacked in each other (the page chrome and an
"IDE mode" shell) and two file trees. The owner's requirement: pages are files in a folder
osionos owns, next to code, in osionos's own dialect; web + docker sandbox first, the real
OS (Electron/Tauri) later behind the same provider interfaces. The database stays, as
index, sync replica and collaboration transport. Tenant isolation (the 16 conditions in
`infrastructure/docker/osionos/ide-sandbox/README.md`) is unchanged.

## Decision

1. **A block page is a file.** `<Title>.omd`, in the workspace folder (`/workspace` of the
   sandbox volume). Children of a page live in a sibling directory `<Title>/`. A
   `surface:"folder"` page is `<Title>/_folder.omd` (front-matter only). A
   `surface:"code"` page is the raw file at its path, no front-matter. Name collisions get
   ` (2)` by page `_id`. Embed, console and chat tabs have no file; archived pages have no
   file (trash stays database-backed).
2. **`.omd` is the osionos dialect; `.md` is standard Markdown. The extension decides the
   editor, never a guess.** `.omd` opens in the block engine. `.md` and every other file
   open in Monaco, with two explicit actions: "Preview as page" (read-only,
   `PageBlocksRenderer`) and "Convert to .omd". One workbench, two document kinds.
3. **`.omd` layout.** Body = the existing dialect (`serializeBlocksToMarkdown` <->
   `parseMarkdownToBlocks`, round-trip tested today in
   `tests/canvas/markdown-roundtrip.test.ts`). Front-matter = a `---` block with one
   `key: <JSON literal>` per line, valid YAML flow syntax, so any YAML reader parses it and
   osionos needs only `JSON.parse` per line (no new dependency). Keys: `id`, `title`,
   `icon`, `cover`, `cover_position`, `surface`, `visibility`, `database_id`, `template*`,
   `recurrence`, `properties`, `updated`, `blocks` (the type is `PageFileMeta` in
   `types.ts`).
4. **`blocks` is an overlay**, keyed by structural index path (`"3"`, `"3.1"`), carrying
   the block `id` and the non-Markdown attributes from an allowlist. An entry applies only
   when the block type at that path matches (`t`). A canvas self-check (spec, not yet
   written) fails when a `Block` key is neither emitted by `blockToMarkdown` nor
   allowlisted, so no field becomes lossy silently.
5. **The page `id` in the front-matter identifies the file**, not its path. Renames and
   moves in the shell are detected by `id`. A file created in the shell without an `id`
   gets one written back on first inbound sync. (This replaces "the page tree is the sync
   manifest" for block pages: [IDE-BACKLOG.md](../../IDE-BACKLOG.md) §3.2.) Raw code files
   keep the path-derived mapping (`idePaths.ts`).
6. **The database is index + sync replica + collab transport.** Every page edit still goes
   through the existing outbox (`PATCH /api/pages/:id`); a page-file writer additionally
   writes the file. Shell edits flow back through the fs-agent -> `/api/ide/fsync` -> page
   store. Echo suppression is by content hash (`sha16`), and a real divergence is a
   surfaced conflict ([ADR-001](ADR-001-vfs.md) decision 7).
7. **`workspace://` is a switching mount.** The sandbox provider while the sandbox is
   online; a page-file provider over the database replica otherwise. Details and limits:
   [ADR-001 addendum 3](ADR-001-vfs.md#addendum-3--the-workspace-switching-mount-2026-10-13-proposed).
8. **Standalone Monaco stays the editor engine** (0.56, `monacoRuntime.ts`). Upgrade
   trigger, recorded: when TextMate grammars or a web extension host become a requirement.
9. **Migration is not a cliff.** The database keeps every page. Files are produced on first
   attach by `reconcileOnAttach`, which replaces the blind `mirrorTree` in
   `materialize.ts` (it overwrites shell edits on every attach). Old shells are deleted only
   after the new workbench is green behind the `osio.workbench` flag (default OFF).

## Options considered

**A — `@codingame/monaco-vscode-api` "views" mode.** Mounts VS Code's own sidebar and panel
widgets inside our layout: the nesting this change removes, plus about 40 packages locked
to one version. Rejected; revisit at the upgrade trigger in decision 8.

**B — Theia, OpenSumi, code-server.** osionos becomes the guest of someone else's
workbench instead of the host. Rejected.

**C — FUSE / WinFsp / FSKit mounts** (a real "own partition" the OS sees). Kernel or
privileged drivers on three operating systems for what an osionos-owned folder gives
(Obsidian model). Rejected: "own partition" means an owned folder.

**D — TipTap (or another off-the-shelf block editor) for pages.** Rejected. The block
engine is the product and already round-trips the dialect. Evidence gap: the source design
spec does not mention TipTap, and the app has no TipTap dependency (`rg -i tiptap` over
`src/` and `package.json` -> no matches); the rejection came with the task brief, not with a
measurement. Re-open it only with one.

**E — Keep the database as the only truth, files as a projection** (today). Rejected for
the same reasons as ADR-001 option A, and it keeps two shells.

## Consequences

- One workbench replaces two shells. `ide-shell/`, `ideModeStore`, the `osio.ide` flag and
  the page-tree sidebar are deleted at cut-over (P3), not before.
- Online, `workspace://` is the sandbox volume; degraded, it is the replica. Shell-only
  files are invisible while degraded.
- Per-user sandboxes mean the folder is per collaborator; the database remains the
  convergence point this cycle. There is no CRDT over files.
- The bridge and `osio-fs-agent.mjs` need no change: `/api/ide/fs` is path-generic and the
  agent does not ignore `.omd`.
- Existing caps stay: 500 files / 512 KiB per file in `materialize.ts`.
- `.gitattributes` in the workspace template maps `*.omd` to Markdown so GitHub renders
  pages.

**Known-lossy after P1** (by design, named so nobody discovers them): database records and
schema (the `.omd` is a pointer with `database_id` plus the `osidb-page` fence; data stays
in Postgres), `placeholderText`, comments, `sortOrder` (the explorer orders by name), and
any `Block` field outside the overlay allowlist. Overlay entries are positional: a hand
edit that inserts a block can misalign them; the `t` type guard drops mismatched entries
but cannot recover them. Shell renames of raw code files are delete + create (new page id)
because the fs-agent emits no rename event (IDE-BACKLOG gap G-FSW); `.omd` is safe because
of `id`.

## Interfaces (frozen contracts, as on disk 2026-10-13)

All under `apps/osionos/app/src/`. They are **lane I stubs**: signatures are fixed, several
bodies throw `not implemented` until lanes A-C land. `docs/ide/interfaces/ide-interfaces.ts`
(the ADR-001/002/003 types) does not yet declare these; the spec's lane I plans to add them.

| File | Exported names | State |
|---|---|---|
| `features/ide/model/sandboxHealthStore.ts` | type `SandboxHealthState` (`unknown`, `online`, `stopped`, `disabled`, `unavailable`); interface `SandboxHealth` (`state`, `reason`, `workspaceId`, `checkedAt`, `probe`, `ensure`, `markClosed`, `retry`); `useSandboxHealthStore`; `isSandboxOnline`; `useSandboxHealthProbe` | stub: `probe` only records the workspace id, the hook returns the stored state |
| `features/ide/model/wsCloseCodes.ts` | `isDeliberateClose(code)`, `healthFromCloseCode(code)` (4001, 4003 -> `disabled`; 4004 -> `unavailable`) | implemented |
| `features/page-file/model/types.ts` | `PAGE_FILE_SUFFIX` (`.omd`), `FOLDER_META_NAME` (`_folder.omd`), types `PageFileKind`, `BlockOverlayEntry`, `BlockOverlay`, `PageFileMeta`, `ParsedPageFile` | types and constants |
| `features/page-file/model/pagePaths.ts` | `kindOfPage`, `titleFromFileName`, `fileNameForPage`, `pathForEntry` | `kindOfPage`, `titleFromFileName` implemented; the other two throw |
| `features/page-file/model/pageIndex.ts` | interfaces `PageIndexEntry`, `PageIndex`; `buildPageIndex` | `buildPageIndex` throws |
| `features/page-file/model/pageFileCodec.ts` | `isPageFileName`, `isFolderMetaName`, `pageToFile`, `fileToPage` | name checks implemented; `pageToFile`, `fileToPage` throw |
| `features/ide/vfs/workspaceMounts.ts` | `WORKSPACE_SCHEME`, `workspaceUri`, `getWorkspaceMounts`, `subscribeWorkspaceMounts` | `getWorkspaceMounts` binds the page provider only; `subscribeWorkspaceMounts` is a no-op |
| `shared/config/featureFlags.ts` | `isWorkbenchEnabled()` for flag `osio.workbench` (default off; `?osio.workbench=1`, the `osio.workbench` localStorage key, or `VITE_OSIO_WORKBENCH=1`) | implemented |
| `features/ide/model/monacoRuntime.ts` | re-exports `editor`, `languages`, `KeyCode`, `KeyMod`, `MarkerSeverity`, `Range`, `Uri`; types `IDisposable`, `IMarkdownString`, `IPosition`, `IRange` | implemented; the only entry of the Monaco core |

`pathForEntry`'s signature is in `pagePaths.ts:39`; it is not restated here.

## What would falsify this decision

- If `list()` on the page-file provider cannot serve a large workspace within explorer
  latency (ADR-001 falsifier, unmeasured until P1), the memoised `pageIndex` is not enough
  and an index cache is needed.
- If overlay misalignment after hand edits shows up in practice (positional keys), switch
  the overlay key from index path to something content-anchored.
- If collaborators must edit the same page live while one of them is editing the `.omd` in
  a shell, the database-as-convergence-point is insufficient: a CRDT-bearing provider is
  needed (same trigger as ADR-001's first falsifier).
- If a TextMate grammar or web extension host becomes required, decision 8 reopens (option A).
