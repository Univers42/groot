# 0058. The profile README renders a parsed HTML subset and never injected HTML, and metric code, database pins and the signed-out view stay blocked

- Status: accepted.
  - U3 (HTML subset in the markdown engine): PROCEED-WITH-CONDITIONS U3-1 to U3-11. Remote images: choice A.
  - U4 (README written as markdown): PROCEED-WITH-CONDITIONS U4-1 to U4-7, shape A through the existing `codeView` key. The fence fix ships and goes live first.
  - U5 (follows, organizations): PROCEED-WITH-CONDITIONS U5-1 to U5-7. Bridge fixes before any UI; the organizations migration needs a human go.
  - U6 (highlights): PROCEED-WITH-CONDITIONS H-1 to H-6 for page and shared-post pins. Database pins BLOCK. Achievements BLOCK until U7.
  - U7 (metrics): the contract may be written (M-1 to M-11). Code BLOCK until the contract and a new ruling.
  - U8 (signed-out view): BLOCK. Not requested.
- Date: 2026-11-17
- Deciders: devil (ruling), osionos main session / builders (live with it)

## Context

The owner asked for a profile page that reads and edits like a GitHub profile, with a README written in markdown
that can reproduce a real GitHub profile README, and values computed across the owner's databases. The design is
`docs/superpowers/specs/2026-11-17-profile-page-design.md` (rev 1) in the osionos repo, branch `feat/profile-page`.
U1 (sidebar) and U2 (edit on the page) add no endpoint and no exposure and were built without a ruling. U3 to U8
touch stored HTML, other users' data and a new evaluator, so they were ruled first.

Code was read at osionos develop `63c376994`. Paths are in the osionos repo unless prefixed `groot:`. The section
numbers below are the ruling's own.

## 1. Verdicts (axes: blast / reversibility / cost on failure / confidence, 1–5)

| Unit | Verdict | Scores, worst | Reason |
|---|---|---|---|
| U3 HTML subset | PROCEED-WITH-CONDITIONS | 4/3/**5**/3, cost | Stored XSS lands in every viewer's session, and the refresh token sits in localStorage, so a stolen token is a one-way door. The parse-to-AST plus createElement shape is the right one. |
| U4 markdown README | PwC, shape A via the existing `codeView` key | 3/**3**/**3**/2 | A README pasted today is split on the raw-mode round trip (measured: 42 blocks, §6). Fix the fence first. |
| U5 follows, orgs | PwC: bridge fixes before any UI | 3/3/**3**/2 | Counts ignore blocks (`bridge-social-follows.mjs:81`). Lists ignore directory opt-out (`:111-115`). Org visibility needs a schema change. |
| U6 highlights | PwC for page and shared-post pins. Database pins BLOCK. Achievements BLOCK until U7. | 3/3/**4**/3 | A pinned private title leaks one way. The shares grid fails open when its filter is absent (`bridge-profile.mjs:290-292`, `:307`). |
| U7 metrics | PwC on writing the contract. BLOCK on code. | 5/4/5/**5**, confidence | No server-side evaluator exists. "Computed as the owner" is a confused deputy. |
| U8 anonymous | BLOCK (not requested) | 5/4/4/**5** | It is a new unauthenticated surface with no design (§2 U8). |

## 2. Conditions (acceptance criteria for the builder)

### U3

- U3-1. **One parser, typed nodes, no injection.**
  - The subset parses into typed `html_element` nodes that render only through `React.createElement`.
  - Delete the `allowHtml` innerHTML branch at `packages/markdown-engine/markdown/renderers/react.tsx:320-332`. No caller sets it to true: only `false` at `src/features/chat/model/assistantMarkdown.ts:61` and `src/features/ide/ui/MarkdownDocumentView.tsx:40`.
  - `renderers/html.ts:156-157` stops emitting raw `node.value`. It feeds the clipboard through `crossTextOps.ts:95`, so it renders the same subset, escaped.
  - Probe: `grep -c dangerouslySetInnerHTML packages/markdown-engine/markdown/renderers/*` = 0.
  - Never route the profile through the duplicate engine `src/shared/notion-database-sys/src/lib/markdown/`. Its `react.tsx:164-165` injects HTML unconditionally.
- U3-2. **Attribute map, per tag.**

  | Tag | Allowed attributes |
  |---|---|
  | `a` | href, title |
  | `img` | src, alt, title, width, height, align |
  | `td`, `th` | align, valign, width, height, colspan, rowspan |
  | `div`, `p`, `h1`–`h6`, `table` | align |

  - `align` must be one of left, center, right, justify. `valign` must be one of top, middle, bottom, baseline.
  - `width` and `height` must match `^[1-9]\d{0,3}%?$`, with px ≤ 2048 and % ≤ 100. `colspan` is 1–64 and `rowspan` 1–256. `alt` and `title` are ≤ 512 chars.
  - An attribute that fails is dropped, never clamped.
  - Attributes are emitted as HTML attributes, never through a `style` prop. `id`, `name` and `class` from the input are never emitted (DOM clobbering).
  - The README container clips overflow at max-width 100%.
  - Test: every README descendant stays inside the card at 375 and 1440 px.
  - The fixture uses width 100%/25%/45%/55% and height 125/165. All pass.
- U3-3. **URLs.**
  - Decode entities once, before validating: the named set, numeric, and numeric without `;`.
  - `href` goes through `sanitizeUrl` and the existing link renderer (`renderers/reactHelpers.tsx:220-240`). The HTML `title` must not be able to set the mention marker (`isLinkMention(node.title)`).
  - `src` gets a new `sanitizeImageSrc`, because `sanitizeUrl` returns scheme-less input unchanged (`renderCore.ts:109-135`), so `//evil` and `/\evil` pass it.
  - `sanitizeImageSrc` accepts an absolute `https:` URL, or an exact app media prefix with a single leading `/`.
  - It rejects `http:`, `data:` (unlike `inlineHtml.ts:145-151`), `blob:`, `//`, `/\`, `\\`, and `..`/`%2e`/`%2f`/`%5c` once decoded.
  - Test: a table of 40 or more vectors.
- U3-4. **No expansion inside attributes.** No `{{expr}}`, variable or binding is expanded inside an attribute or URL. Reason: variables resolve in the VIEWER's scope (`src/features/variables/ui/VariableChip.tsx:27-28`), which is an exfiltration channel. Test: a viewer variable `secret` never appears in any `src` or `href`.
- U3-5. **XSS corpus**, in the engine suite.
  - Assert on the rendered DOM, AND on `renderToStaticMarkup` output re-parsed by an HTML5 parser.
  - Invariant: no `<script>`, no `on*`, no `javascript:`/`vbscript:`/`data:` in href or src, no tag outside the allowlist.
  - Extend `tests/fuzz-reliability` with a generator over these classes.

  | Class | Vectors |
  |---|---|
  | a. Scheme obfuscation | mixed case; tab, newline, CR inside the scheme; `&#106;` `&#x6A;` `&#0000106` `&#106` (no `;`); `&colon;` `&Tab;` `&NewLine;`; double-encoded; `%3A`; fullwidth; U+00A0/2028/FEFF; vbscript, data, blob, file |
  | b. Handlers | `img onerror` variants; `<img/src/onerror=…>`; `details open ontoggle`; uppercase names; duplicate attributes |
  | c. Forbidden tags | script, split script, svg, math, iframe srcdoc, object, embed, form/formaction, input autofocus, base, meta refresh, link, style, template, noscript, xmp, plaintext, textarea, title, `--!>` comment ends, CDATA, `<?xml`, DOCTYPE, a NUL in a tag name, unclosed `</script` |
  | d. mXSS classics | noscript/title, svg/style, math/mglyph, form/math nesting |
  | e. Clobbering | `name` and `id` |
  | f. Markdown in HTML | `[x](javascript:…)` and `![](javascript:…)` inside `<td>`; `[![](js)](js)`; the autolink `<javascript:…>`; a reference definition; a fenced `<img onerror>` inside `<td>` |
  | g. Structure | 1000 stray closers; unclosed tags; misnesting; `a` inside `a`; `div` in `table`; a 100k-deep bomb (beyond 16 renders as text); 200 KB of `<div>`; a 200 KB attribute; 200 KB with no `>`; 10k `<img>` (element cap 5,000) |
  | h. Size | over 200 KB is refused whole, never partly parsed |
  | Fixture gaps | add `<details>`, `<summary>` and `<kbd>`. The fixture has 0 of each, so the brief is wrong on this point. |

- U3-6. **Linear time.**
  - Render time for 200 KB ≤ 5 × the 50 KB time, inside an absolute budget set from the existing `bench/`.
  - The benchmark artifact is committed with its command.
  - No nested-quantifier regex in the tokenizer.
- U3-7. **Every remote `<img>`** gets `loading="lazy"`, `decoding="async"` and `referrerPolicy="no-referrer"`, with no `crossOrigin` and no `srcset`. This is the same pattern as `src/shared/ui/embed/LinkCard.tsx:39`. DOM test on all 24 fixture images.
- U3-8. **CSP `img-src`.**
  - Add `img-src 'self' https: data: blob:` to EVERY CSP header in one commit: `docker/services/node/nginx.conf:22,33,41,48` (repeated because of how nginx inherits `add_header`, `:20`) and `public/_headers`.
  - Ship it as `Content-Security-Policy-Report-Only` first, through a green e2e/GR2 zero-console-errors run, then enforce.
  - Header test: all locations carry the same policy.
- U3-9. **Disclosure and choice.**
  - The viewer sees one line: "Images in this README load from N other sites, which see your IP address", with [Load] / [Don't load] remembered per viewer.
  - The default is the owner's recorded decision: load by default, or ask first.
  - The owner's edit mode lists the image hosts.
  - E2E: with [Don't load], 0 non-self image requests.
- U3-10. **Submodule pin.** The engine commit is on the engine's remote before the osionos gitlink moves. Proof: `git ls-remote`. The existing engine suites (parity-*, markengine, variables, link-mention, fuzz) stay green.
- U3-11. **Caveat.** The tokenizer carries a `Caveat:`: it is not a full HTML5 tokenizer and has no foster parenting. It can render differently from GitHub, but never more permissively.

### U4

- U4-1. **Fence fix first**, at the shared function, in its own commit and deploy.
  - `src/services/page-actions/pageMarkdownSerialize.ts:98` writes a fixed 3-backtick fence.
  - Extract the existing `fenceFor` from `src/features/diagram/model/diagramMarkdown.ts:42-45` (longest backtick run + 1, minimum 3) into a shared module and call it from both places. Library-first: one copy.
  - `appFence` (`pageMarkdownEscape.ts:123-125`) is safe as it stands: a `JSON.stringify` line never starts with a backtick.
  - Canvas test: the fixture round trip gives 1 code block with identical content.
  - Property test: random content containing backtick runs comes back identical.
- U4-2. **Render flag.**
  - Render only when `language === "markdown"` AND `codeView === "preview"` explicitly. An absent flag means source, the opposite of mermaid's default (`BlockEditor.tsx:113,178`), so no existing markdown code block changes on upgrade.
  - Reuse the `codeView` key. It survives the page file (`src/features/page-file/model/blockOverlay.ts:92`), whereas a new key is dropped (`:164-168`).
  - Tests: an old markdown block without the flag stays code; with `codeView: "preview"` it renders through the U3 subset; the page-file round trip keeps `codeView`.
- U4-3. **One call site.** The read-only view (`CodeBlockReadOnly.tsx:33-34`), the editor preview and the README all render through ONE subset-renderer call site. Probe: a grep gate.
- U4-4. **Older client.** It shows escaped source: `CodeSyntaxHighlight.tsx:50-65` (hljs or `escapeHtml`). A unit test pins this.
- U4-5. **Deploy order.** The fence fix is live for at least one deploy, including the service-worker rollover, before the preview or paste offer ships. Record the residual: an old tab still writes 3-tick fences until it reloads.
- U4-6. **Paste offer.** Pasting a README offers [Keep as markdown] / [Convert to blocks], and refuses input over 200 KB. E2E: pasting the fixture with "keep" gives 1 block.
- U4-7. **Size warning.** The owner is warned when the serialized README page crosses the 200 KB projection cap (`bridge-account-profile.mjs:309-325`). JSON escaping inflates the size; the fixture is 9,096 chars.

### U5

- U5-1. **One `hiddenFrom(subject, viewer)` predicate.**
  - Rule: `subject ≠ viewer AND (directory_opt_out OR a block in either direction)`.
  - Fails closed: an error gives 503, as at `bridge-account-profile.mjs:240-249`.
  - Used by `lookupUser`, `getProfile`, counts, lists, orgs and highlights. Today it is duplicated: `bridge-account-profile.mjs:275-297` and `bridge-profile.mjs:111`.
  - Test: a table of {self, stranger, blocked-by, blocking, opted-out} × every route.
- U5-2. **Counts.** For a hidden subject, the counts body is byte-identical to an unknown UUID's. Today `counts()` calls `rpc/osionos_follow_counts` (`bridge-social-follows.mjs:81`) with no check, and the RPC counts every edge (`groot:models/osionos-social-follow-presence-migration.sql:109-118`).
- U5-3. **Lists.**
  - A hidden owner gives `items: []`.
  - A listed person who opted out is omitted for every viewer except themselves. Today only blocks are filtered (`:111-115`), and the view does not filter opt-out (`groot:models/osionos-account-profiles-migration.sql:702-724`).
  - `Caveat:` the count can exceed the listed rows.
- U5-4. **Legacy route.**
  - `role` and `workspaceId` (`bridge-profile.mjs:129-130`) go only to the subject.
  - Readers: `ContactInfoPanel.tsx:52` (falls back to `channel.description`), `sidebarModel.ts:109` (U1's file) and the admin-template `role` in `binding.tsx:27`. No `profile.workspaceId` reader was found.
  - Before the change, query live templates that bind `role` (SKIP for me).
  - `customFields: fields` (`:145`) goes to every non-hidden viewer. Rule each field public or owner-only before U5 ships (UNKNOWN).
  - Test: another viewer gets neither key; self gets both.
- U5-5. **Organizations.**
  - A groot `models/` migration adds an opt-in per membership, default false: idempotent, passing `scripts/verify/models-grants.sh`, with no grant to anon or authenticated. No such column exists today.
  - The card returns `{name, avatar}` only.
  - Record the consent rule. Recommended: the member's opt-in AND a workspace-admin "may be listed" flag.
  - A human go is required (schema, another repo).
- U5-6. **Reduced card.** It shows no follow button and no counts (e2e). It still carries `user_id` (`bridge-account-profile.mjs:76`). That is acceptable only because the follow route itself checks blocks (`bridge-social-follows.mjs:58`).
- U5-7. **Timing.** The UI starts after U1 merges (shared sidebar files).

### U6

- H-1. **Read check.** Reuse `canReadPageRowAsMember` (`bridge-page-read.mjs:77-98`) plus `pageAccessFilter`, and fail CLOSED when the filter is absent. Copy the agent pattern (`bridge-agent.mjs:182`), not the shares grid (`bridge-profile.mjs:290-292`).
- H-2. **Omit unreadable targets.** A missing, archived, trashed, unreadable or live-DB target is omitted: no "Untitled" (that one is at `bridge-profile.mjs:298-300`), no gap, no hidden count.
- H-3. **Storage.** Store target ids only and read titles at request time. Enforce ≤ 6 pins with a DB constraint, not app code.
- H-4. **Order of checks.**
  - U5-1 runs first.
  - The owner must be able to read the target when pinning it.
  - Each viewer is checked at read time; a revoked share disappears on the next request.
- H-5. **Database pins: BLOCK.** No non-member read predicate for databases was found. Lift: cite one and test it.
- H-6. **Matrix test.** Viewer ∈ {owner, member, shared-with, stranger, blocked} × target ∈ {private, shared, public, archived, deleted}. Only rows the viewer may open come back.
- Achievements: BLOCK until U7 is ruled. They may reference public metrics only.

### U7: what the architect contract must answer before any code

- M-1. **Verified or not.** Does a viewer need a server-verified value? If not, the owner's client computes and publishes a snapshot, as `scripts/bridge-publish-snapshot.mjs:30-33` does today. That removes the confused deputy.
- M-2. **The one evaluator.** Name it and its location. None exists on the server; `computedSlice.ts` is client-only.
- M-3. **"As the owner".** It means the owner's CURRENT access when the metric is evaluated. Revoked access makes the metric unavailable within the TTL.
- M-4. **Eligible sources.** Owner-owned only, or workspace data with admin consent? What about live-DB mounts?
- M-5. **Cost bounds**, each a benchmarked number: metrics per profile, sources per metric, rows scanned, wall time, per-engine timeout, cache key, TTL, invalidation, and a rate limit per profile.
- M-6. **Filter oracle and differencing.** Filters plus precision must not let a viewer reconstruct rows. Precedent: `bridge-account-insights.mjs:14-30` suppresses results under 5.
- M-7. **Precision.** Exact, rounded or bucket, chosen by the owner with a preview of what a viewer sees.
- M-8. **README scope.** `{{expr}}` in a README resolves only against the owner's public metrics, never the viewer's scope (U3-4).
- M-9. **Cross-engine values.** Types and determinism: decimal128, DECIMAL, bigint above 2^53, timezones, nulls.
- M-10. **Server allowlist.** `metric:<id>` is checked against a server allowlist, like `README_BINDABLE_FIELDS` (`bridge-readme-bindings.mjs:27-30`), with a drift test.
- M-11. **Composition bounds.** Cycle detection and a depth cap for metrics built on other metrics.

### U8 (one paragraph)

A signed-out read needs:

- its own projection, made only of fields the owner marked public;
- an IP rate limit;
- no directory or listing, and a username lookup that resists enumeration (identical 404s and timing);
- no remote README images unless the U3 proxy exists, and no metrics;
- an explicit indexing choice (noindex by default);
- a cache/CDN policy that can never serve a signed-in projection;
- the same CSP;
- a fix for the endless spinner (`useProfile.ts:84-85`);
- its own devil ruling.

## 3. The two choices

- **U3 images: A.** Image blocks already load arbitrary `https:`/`http:`/`data:`/`blob:` sources directly, with no referrer policy (`MediaBlockPreview.tsx:160-167`, `collectionMedia.ts:37`), so A adds no new leak class.
  - A host allowlist cannot stop tracking: 3 of the fixture's 10 image hosts are `*.vercel.app`, where anyone can deploy.
  - B (a proxy for every remote image) is the real fix, as its own unit.
- **U4 shape: A, via the existing `codeView`.** An older client renders an unknown block type as one `<p>` (`ReadOnlyBlock.tsx:563-571`). Its raw-mode serializer writes that block out as bare markdown (`pageMarkdownSerialize.ts:66-67`), which re-parses into dozens of blocks. A new flag key is dropped by the overlay (`blockOverlay.ts:164-168`); `codeView` survives (`:92`).

## 4. UNKNOWN / SKIP

| Item | State |
|---|---|
| Live templates that bind `role` | SKIP (no DB access) |
| A non-member read predicate for databases | UNKNOWN; database pins stay blocked |
| Whether `customFields` are meant to be public | UNKNOWN |
| Workspace avatar source | UNKNOWN (no avatar column seen on `osionos_workspaces`) |
| Effect of `img-src` on `http:` image blocks under mixed-content auto-upgrade | UNKNOWN; Report-Only resolves it |
| Which of nginx or Vercel `_headers` serves production | Unchecked, so both change |
| README `button` blocks with `buttonProgram` pass the projection unchanged and run in the viewer's session | Unruled; route to `security` before U4 ships |
| Reachability of the duplicate engine's innerHTML and its unsanitized `href` | Grep only (SKIP); not on the profile path |
| React 19 `javascript:` URL blocking | Not relied upon |
| Whether the counts and lists leaks are live in production | SKIP; fix them regardless of the profile feature |
| GDPR exposure of third-party images (LG München I 3 O 17493/20) | Not a legal opinion |
| Round trip | BE: the line-98 template was reproduced by hand, not imported (§6) |

## 5. Build order and parallelism

- **Now**, in parallel with the U1/U2 builder (disjoint write targets):

  | Lane | Work | Write target |
  |---|---|---|
  | P1 | U4-1 fence fix | `src/services/page-actions/`, `src/features/diagram/model/`, the shared module |
  | P2 | U3 engine and corpus | `packages/markdown-engine` (submodule), U3-1..7, 10, 11 |
  | P3 | U5 bridge fixes U5-1..4, 6 | `scripts/bridge-social-*.mjs`, `bridge-profile.mjs`, `bridge-account-profile.mjs`, `tests/bridge` |
  | P4 | U7 contract | architect; docs only |

- **After P2**: U3-8 CSP (`nginx.conf`, `public/_headers`), Report-Only, then enforce. Then U3-9 UI after U1 merges.
- **After U1/U2 merge and P1 is live**: the U4 UI (BlockEditor, CodeBlockReadOnly, paste). Then the U5 UI. The U5-5 migration goes to groot `models/` and needs a go.
- **After P3**: U6 bridge (it shares the `bridge-profile.mjs` dispatcher with P3).
- **Later**: U7 code after the contract plus a re-ruling; achievements after U7; U8 only on request.

## 6. Evidence: the round trip (measured 2026-11-17)

- The probe uses the scratch files `devil/hooks.mjs` and `devil/register.mjs` (a resolve hook for extensionless TS imports, run on Node 26 type stripping) and `devil/roundtrip.mjs`.
- `roundtrip.mjs` wraps the fixture the way `pageMarkdownSerialize.ts:98` does and parses it with `packages/markdown-engine/markdown/shortcuts.ts` `parseMarkdownToBlocks`.
- Run: `cd /mnt/storage/dlesieur/scratch/profile/devil && timeout 60 node --import ./register.mjs roundtrip.mjs`

| Fence | Blocks | First block keeps | Identical |
|---|---|---|---|
| 3 backticks | 42 (code, paragraph, bulleted_list, heading_2, table_block, heading_3) | 2,989 of 9,096 chars | false |
| 4 backticks | 1 (code, language markdown) | 9,096 chars | true |

Cause: the fixture carries its own fences at lines 33 (```` ```c ````) and 50 (```` ``` ````), inside `<td>`.

## Alternatives rejected

- **A sanitizer (DOMPurify) on an HTML string.** It loses to the mXSS and parser-differential class; the parser that
  renders must be the one that decides.
- **An image host allowlist.** `.out-of-scope/readme-image-host-allowlist.md`.
- **An image proxy for every remote image now.** Deferred as its own unit (SSRF surface, bandwidth). It is the
  upgrade path for U3-9.
- **A new `markdown` block type, or a new flag key.** `.out-of-scope/readme-markdown-block-type.md`.
- **A second sanitizer in the bridge projection.** `.out-of-scope/server-side-readme-html-sanitizer.md`.
- **Per-route visibility checks.** They produced the counts gap (U5-2).
- **Showing every workspace membership.** No consent column exists (U5-5).

## Consequences

- Any new tag or attribute in the subset needs a corpus entry first (U3-5).
- An old tab writes 3-backtick fences until it reloads (U4-5). There is no page-version undo.
- `customFields` on the legacy profile route must be ruled field by field before U5 ships.
- Database pins wait for a named non-member read predicate. Achievements and `{{expr}}` in a README wait for U7.
- README `button` blocks run in the viewer's session and were not ruled here: a `security` review before U4 ships.
- The round-trip measurement rebuilt the line-98 template by hand; the U4-1 canvas test replaces it with the real
  serializer.

## 2026-11-17: U7 contract re-ruling

The architect contract for U7 was ruled. The verdicts and conditions (MC, MA, MB, MD, ME) are ADR 0059.

## 2026-11-18: U3 push decisions

The callout kind, the nesting cap and the two host tests EP5 and EP21 were ruled before any push of the engine. The
verdicts and conditions (CK, NC, TD, PO) are ADR 0062. The callout sink is live on osionos main (0062 L-1).
