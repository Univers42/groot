# ADR-003 — Language layer: one manifest, projections everywhere, zero core edits

Status: PROPOSED (Phase 1) · Decides: RECON §6 obstacle 3 · Falsifiers at end.

## Problem

The same fact ("what is Python; how do you run C") lives in six-plus unsynchronized
registries across two repos (RECON §3): the 35-record frontend registry, two frontend LSP
maps, the bridge LSP table, the runner's 13-language table plus its comment-synced
duplicate allowlist, and three formatter tables — with two more non-IDE highlight
registries adjacent. Adding language N+1 touches up to five files; drift is the steady
state (unreachable `tsx`/`jsx` LSP keys already prove it).

## Options considered

**A — Status quo + lint rule to keep tables in sync.** Treats the symptom; N registries
remain N places to be wrong. Rejected.

**B — tree-sitter-first rebuild** (grammar WASM at runtime, per the brief's sketch).
CodeMirror 6 is already the editor and its Lezer grammars already cover the 35 languages;
replacing working syntax infrastructure for architectural symmetry is churn without user
value. Rejected for this engagement — kept as a *provider*, see falsifiers.

**C — One manifest as the single source; every existing table becomes a generated or
derived projection.** Chosen.

## Decision

1. **A language is a data file.** `app/src/features/ide/languages/<id>.ts` exports one
   typed `LanguageManifest` object (TypeScript-as-data: schema-checked at compile time,
   zero logic). Auto-registration via `import.meta.glob` — **adding a language adds one
   file and touches zero core sources**; that is the Phase 6 acceptance demo.
2. **Schema** (full definition in `interfaces/ide-language-manifest.ts`): identity
   (`id`, display name), detection (`extensions`, `filenames`, `shebangs`), editor
   (`cm` loader key, `accent`), intelligence (`lsp: { server, docLanguageId }`),
   execution (`runner: { file, cmd }` for Plane A; `pty: { runCmd }` for Plane B;
   both templates over `{file}`), formatting (`fmt: { browser? , sandbox? }`),
   debugging (`dap?` — schema reserved, no adapter this engagement, stated honestly),
   projects (`detect?` globs, `steps?` for multi-step compile→link→run with
   dependencies — schema present, consumed from Phase 4).
3. **Tiers are computed, never declared.** Tier 3 = any file (edit/search/shell). Tier 2 =
   `cm` present. Tier 1 = lsp/runner/pty/fmt present **and** the toolchain doctor confirms
   the binaries. Unknown language = Tier 3, never a hard failure.
4. **Backends consume projections, not the registry.** A build-time script emits
   `ide-languages.json` (runner table, bridge LSP table, allowlists) consumed by
   `runner/server.mjs` and the bridge; a **drift test** fails CI when the generated file
   is stale. The comment-synced duplicate dies. The block-editor picker and highlight.js
   maps are *out of scope* (non-IDE surfaces) — recorded, not smuggled in.
5. **Toolchains stay an image concern; honesty is runtime.** The manifest declares
   `requires: ["gcc", …]`; a `GET /api/ide/doctor` exec probes the sandbox and the UI
   degrades tiers per-language with a visible reason ("Java: jdtls not installed") instead
   of silent absence.
6. **Syntax host = CodeMirror 6 / Lezer** (embeddable core already fitted — the brief's
   §9 asks for justification, this is it: it works, it's lazy-loaded, and the manifest's
   `cm` key keeps it swappable). Structure/folding come from Lezer; tree-sitter is not
   adopted now.
7. **LSP and DAP stay spec-compliant clients** keyed by manifest data. The LSP transport
   fix (Tty mux desync) lands in the hotfix batch; the client itself already speaks
   byte-accurate `Content-Length` framing (RECON §1, unit-tested).

## Consequences

- `IDE_LANGUAGES`, `LSP_SERVER`, `LSP_DOC_LANG`, `LSP_SERVERS`, runner `LANGS`, the
  bridge allowlist, `BROWSER_FORMAT`, `RUNNER_FORMAT_LANGS` all become derived views;
  the diff is wide but mechanical (Phase 4), and behavior-preserving by construction
  (projection equality asserted against the current literals before deletion).
- The proving matrix (brief §4.3) becomes tractable: each new language is a manifest file
  + toolchain image entry; the awkward ones (NASM, COBOL, Prolog) exercise the schema's
  multi-step and shebang corners, which is the point.

## What would falsify this decision

- If a Tier-1 target language has no usable Lezer/CM mode and structural navigation is
  required, tree-sitter WASM enters as a second syntax provider behind the same `cm`-key
  seam (the manifest gains a `treeSitter` field; consumers don't move).
- If TypeScript-as-data proves too permissive (people sneak logic into manifest files), a
  JSON-with-schema loader replaces it; the schema is already the contract.
- If the generated-projection drift test flakes or the two-repo split makes generation
  awkward, the projection moves to runtime (bridge serves the table to the runner) — a
  distribution change, not a schema change.
