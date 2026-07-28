# ADR-001 — Virtual Filesystem: mount-table VFS over both stores

Status: PROPOSED (Phase 1) · Decides: RECON §6 obstacle 1 · Falsifiers at end.

## Problem

osionos has two filesystems and neither is authoritative (RECON §2):

- the **page tree** (BaaS): files are pages (`surface:"code"`), paths *derived* from titles
  through a lossy sanitizer, offline-capable, ACL'd, collaborative, synced;
- the **sandbox volume**: a real POSIX tree the toolchains see — but **write-only** from the
  app (no read/list/stat/delete/rename endpoints exist), observed only via watch events,
  reconciled by hash echo-suppression + silent last-writer-wins.

Every consumer (editor, explorer, terminal cwd, LSP URIs, search, watcher) hard-codes one
of the two planes. Adding any third backend today means touching all of them.

## Options considered

**A — Page tree authoritative; sandbox is a projection.** Formalizes the status quo.
Fails the daily-driver test: `git clone` in the terminal would have to lift thousands of
files (incl. `node_modules`) into pages; the 500-file/512 KiB/binary-drop caps are not
incidental, they are structural. Rejected.

**B — Sandbox authoritative; pages are an index.** Real FS semantics for real work, but the
IDE dies without a sandbox (offline mode lost), and code files leave osionos's
collaborative, ACL'd substrate — the product's identity. Rejected.

**C — A real VFS: URI-addressed mount table; BOTH stores are providers; today's "hybrid" 
becomes an explicit SyncLink policy between two mounts.** The brief's own shape. Chosen.

## Decision

1. **Opaque paths.** `VPath = { uri }` with accessors; no consumer above the provider
   boundary ever string-joins or splits with `/` or `\`. Normalization happens **once**, at
   VPath construction: percent-decoding, segment split, `.`/`..` resolution (refusing to
   escape the mount root), Unicode kept **byte-preserving with an NFC comparison key**
   (macOS NFD and NFC/NFD-colliding names compare equal but round-trip their original
   bytes). Providers whose native paths are not valid UTF-8 expose a lossless escape
   (percent-encoding) at their boundary.
2. **Mount table.** `osionos://<workspaceId>/…` (page-backed provider — the workspace
   default mount, keeping offline/collab/ACL as the identity of the file tree),
   `sandbox://<workspaceId>/…` (remote-POSIX provider via bridge exec ops),
   `mem://…`, `overlay://…` (union provider, itself just another backend). Windows/NTFS,
   SFTP/9P/WebDAV arrive later as leaf providers with **zero consumer changes** — that is
   the acceptance criterion.
3. **Capability descriptor per provider**, queried not assumed: `caseSensitivity`,
   `preservesCase`, `symlinks`, `hardlinks`, `atomicRename`, `watch: native|poll|none` (+
   `pollIntervalMs` so the UI can degrade *honestly*), `maxNameBytes`, `maxPathBytes`,
   `unicodeForm`, `permissionsModel`, `sparse`, `xattrs`, `streamingReads`.
4. **One error taxonomy.** Providers map native errors into
   `NotFound | PermissionDenied | NotADirectory | IsADirectory | NotEmpty | AlreadyExists |
   Loop | NoSpace | ReadOnly | TooLarge | Interrupted | Unsupported | Io` — consumers never
   see errno, HTTP status, or docker text.
5. **Streaming + ranged reads; async + cancellation.** `read(path, {offset,length,signal})`
   returns a byte stream; a 4 GB file never materializes. Every op takes `AbortSignal`.
6. **Watch is first-class**, coalesced, with the reliability capability above. The current
   fs-agent becomes the sandbox provider's watch implementation (gaining rename events and
   debounce per RECON gaps `G-FSW`).
7. **The SyncLink** replaces implicit hybrid behavior: a declared object
   `{ from: osionos://ws/…, to: sandbox://ws/workspace/…, policy }` where policy names the
   mirror rules (text ≤ 512 KiB, ignore-list, direction, and **conflict = surfaced event**,
   never silent LWW). Echo suppression by content hash stays as the loop-breaker, but a
   true concurrent divergence produces a visible conflict item in the UI.
8. **The write-only hole gets filled**: the bridge grows argv-safe exec ops
   (`read/list/stat/delete/rename/mkdir`) built by the same server-derived spec pattern as
   the existing write (`ide-sandbox-spec.mjs`), completing the remote-POSIX provider.

## The artifact that makes it real

A **backend-independent conformance suite**: one corpus written against `FsProvider`,
executed against every provider (mem, overlay, page-backed in-proc via the canvas harness,
remote-POSIX against a real temp dir in the bridge test harness; the dockerized path is
covered by the e2e matrix). Mandatory nasty cases: rename over existing, delete an open
file, symlink cycles, `..` escaping a mount root, concurrent writers, case-only name pairs,
NFC/NFD-colliding names, zero-byte and multi-GB (ranged) files, permission-denied
mid-walk, names with spaces/quotes/newlines/emoji/RTL.

## Consequences

- Phase 2 migrates the RECON §2 call sites onto providers; `useIdeFileOps` becomes the
  page-provider's implementation detail; `ideFsClient`/`materialize`/fs-event index become
  the SyncLink's implementation; LSP URIs and the terminal cwd derive from the sandbox
  mount instead of ad-hoc string concat (`CodeFileView.tsx:93,231` retire).
- The three-way sanitizer agreement (RECON §2) collapses to one function owned by the
  page-provider (title→segment is *its* boundary concern, nobody else's).
- Explorer gains an honest second root ("Sandbox") instead of pretending one tree exists.

## Addendum — approved 2026-07-28, with two confirmed targets

1. **Host integration is a first-class goal, not a maybe.** osionos must eventually run
   as a desktop interface over the real OS filesystem (the way VS Code/Obsidian open a
   folder), on Linux/Windows/macOS, with the SAME UI — i.e. a `file://` host provider
   behind this exact interface, reached from the Electron/Tauri shells. The conformance
   suite is the contract that makes that drop-in: a host provider ships when the corpus
   passes against it, and no consumer changes.
2. **POSIX presentation everywhere.** Whatever the backend (pages, sandbox, NTFS), the
   IDE presents paths POSIX-style (`/workspace/src/main.c`) — differences (case rules,
   separators, reserved names) live in provider capabilities and normalization at the
   boundary, never in the UI.

## What would falsify this decision

- If block-level collaborative editing must operate live on files *inside* a
  sandbox-authoritative subtree (CRDT between shell writes and block edits), SyncLink is
  insufficient → revisit with a CRDT-bearing provider.
- If the page provider cannot serve a 5000-entry directory listing within explorer latency
  budgets, it needs an index cache — measured in the Phase 5 corpus, not assumed.
- If a real backend cannot implement the capability set honestly (e.g. watch on SFTP), the
  degradation path (poll + UI notice) must carry it; if it can't, the interface is wrong.
