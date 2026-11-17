# 0059. Profile metrics are computed in the owner's browser and published as a rounded snapshot, and live-mount metrics stay blocked

- Status: accepted.
  - U7c (README variables never resolve in the viewer's scope): PROCEED-WITH-CONDITIONS MC-1 to MC-7. Ships first.
  - U7a (owner-only metrics): PROCEED-WITH-CONDITIONS MA-1 to MA-9.
  - U7b (publish and README binding): PROCEED-WITH-CONDITIONS MB-1 to MB-15, and only after the owner answers Q2.
  - U7d (composites): PROCEED-WITH-CONDITIONS MD-1 to MD-4, after U7b.
  - U7e (live-mount metrics): BLOCK until ME-1 to ME-5.
- Date: 2026-11-17
- Deciders: devil (ruling), architect (contract), osionos main session / builder (live with it)

## Context

ADR 0058 blocked profile metrics (U7) until a contract existed. The architect wrote one (M-1 to M-11) and the devil
ruled on it. Code was read at osionos `feat/profile-page` 7f78c4c36 (base: develop 628f5de19) and in groot `models/`.

The contract's decision (option A) holds:
- A metric is evaluated only in the owner's browser, under the owner's session. The browser already holds the rows and
  the only filter and formula evaluator.
- A viewer gets a stored snapshot per public metric: id, label, format, a rounded or bucketed decimal string, and
  `asOf`. Never rows, filters, sources or counts.
- Definitions live in the settings section `metrics`, published values in `metrics_public` (rows of
  `osionos_user_settings`). There is no migration and no server evaluator.
- The bridge checks on publish and on every read.

The runner-up (option D, the bridge evaluates object databases) wins only if a value must stay fresh while the owner
is away, or must be verified. That is owner question Q2.

The probes behind "measured" below are in the session scratch directory, not in this repository. A probe that is
needed again is re-written from its description here.

## 1. Verdicts (axes: blast / reversibility / cost on failure / confidence, 1–5)

| Unit | Verdict | Scores | Changes the design |
|---|---|---|---|
| U7c README variables | PwC, before U7b and the U4 preview | 4/2/3/2 | One injected variable mode reaches all four read-only call sites, React and string (`ReadOnlyBlock.tsx:106`, `TableBlockReadOnly.tsx:44`, `CalloutBlockReadOnly.tsx:36`, `MediaBlockReadOnly.tsx:42`). The content-keyed inline cache (`ReadOnlyBlock.tsx:89`) also keys on the mode. |
| U7a owner-only | PwC | 2/2/3/3 | One top-level settings key per metric, never a nested map: the merge is a shallow `||` (`models/osionos-account-profiles-migration.sql:345`). PATCH only, no PUT. A byte budget replaces "20 × 8 filters" (measured 38,389 B; 7–8 fit). `metrics:owner` is page-scoped, never in the global registry. |
| U7b publish | PwC, needs owner Q2 | 4/4/4/3 | Sections are enough. The browser holds no account-role token (`bridge-pg.mjs:56`, :174), so a route that is the only writer can enforce the interval. The bridge owns `asOf`. Writes use version compare-and-swap. Withdrawal leaves a tombstone. Sources are object DBs only. Dominance and overlap refusals. The preview flags exact values. |
| U7d composites | PwC, after U7b | 3/4/3/3 | Composites are computed from the inputs' published strings, not exact values. |
| U7e live mounts | BLOCK | 5/4/5/5 | `unique (workspace_id, db_id)`, not `db_id`: a link does not prove whose rows are in the database. Router types unmeasured. |

Corrections to the contract:
- k counts rows, not people. The precedent counts people (`bridge-account-insights.mjs:25`).
- A count rounded to 2 significant figures is exact below 100.
- A dedicated table would not make `n` server-checked. Under option A, `n` is always a client claim.

## 2. Conditions (acceptance criteria; each names its test)

### U7c: README variables. No owner question needed. Ships before U7b and before the U4 preview.
- MC-1. The README subtree injects one variable mode that reaches all four read-only call sites, React and string paths. Test: another viewer's README has `{{user.name}}` and `{{env.X}}`, and the viewer's env.json defines X. Both render literal in a paragraph, a table, a callout and a media caption.
- MC-2. The `inlineMarkdownCache` key includes the variable mode, or README rendering bypasses the cache. Test: the same content renders resolved on my own page, then literal in a README, then resolved again.
- MC-3. Before U7b, every `{{…}}` in a README stays literal. After U7b, `{{metric.<public id>}}` resolves from the projection only, and a private or unknown id stays literal.
- MC-4. A resolved value is a React text node, or escaped text on the string path. P4 shows the string path escapes today. Test: a value of `<img onerror>` with `**b**` gives no element and no bold.
- MC-5. The owner viewing their own README sees the same view as a viewer: no private value.
- MC-6. Grep gate: no `renderVariableChip` or `resolveVariableInActivePage` under `src/widgets/profile-page/` or in the U4 subset renderer. The U4-3 call site takes the mode as a required argument.
- MC-7. Regression: `{{user.name}}` on my own page in the editor and read-only views still resolves (TableParts.tsx:136 is untouched).

### U7a: owner-only. Object DBs only.
- MA-1. Layout: one top-level key per metric (`"m:<id>"`) plus `v`. Never a nested `metrics` map. A delete is `{"m:<id>": null}`. Test: two PATCHes from two tabs add different metrics and both survive.
- MA-2. The `metrics` SECTIONS entry allows `['GET','PATCH']` only. Test: PUT returns 405. The client never writes after a failed or non-200 GET. Test: GET returns 500 and no PATCH is sent.
- MA-3. The budget is in bytes.
  - `prepare` refuses a patch whose merged JSON text would exceed 15,360 B, with 413 and a stable code.
  - A CHECK violation (SQLSTATE 23514) also maps to 413.
  - Filter `value`: at most 256 B of JSON, either a primitive or an array of at most 20 primitives.
  - Label: at most 60 code points and at most 120 UTF-8 bytes.
  - "20 definitions" is only a ceiling under the byte budget.
  - Test: with the P2 shape, the 9th 8-filter definition gets 413.
- MA-4. `metrics:owner` is never in the global registry (`App.tsx:345`). A page-level provider adds it only when `page.ownerId === me`. Test: the global registry holds my values, and a page with `ownerId ≠ me` shows the placeholder.
- MA-5. No resolved value is persisted. Publish snapshot, export, clipboard and page JSON carry the expression or the binding, never the value. Test: a publish snapshot of my page with a bound private metric does not contain the value string.
- MA-6. Metrics are not in formula or `visibleWhen` scope; `shown` reaches the bridge (bridge-publish-snapshot.mjs:28-34). Test: a formula referencing `metric.x` evaluates as missing.
- MA-7. Null round-trip against a real PostgreSQL (the repo's docker PG or testcontainers). For every filter operator, the definition reads back equal to what was written.
- MA-8. A device without the timezone, or an `Intl` RangeError, gives `unavailable`, never a throw. The contract's sentinel and period tests stay.
- MA-9. `rows_incomplete` when the database state was not loaded from the server in this session or its load failed.

### U7b: publish and README binding. Needs Q2.
- MB-1. Only the publish route writes `metrics_public`, and it never enters SECTIONS (grep gate). One top-level key per id.
- MB-2. Writes use a version compare-and-swap: `version=eq.N` (migration :346 bumps `version`; pattern at :356-357). On 412: re-read and re-check once. Test: two concurrent publishes of different values inside the interval; exactly one is accepted.
- MB-3. The bridge sets `asOf` (its own clock at accept) and `changedAt` (its own clock on a change). Client values are ignored. When the interval refuses a change, the old value **and the old `asOf`** stay. Test.
- MB-4. Withdrawal leaves a tombstone `{changedAt, withdrawn: true}`, and the interval honours it. Auto-withdraw happens only on `no_access` or `source_missing`, never on `timeout` or a transient `unavailable`. Test: withdraw then republish inside the interval gives `interval`.
- MB-5. Sources are object DBs only. The bridge refuses `kind: 'mount'` until U7e. Test.
- MB-6. Dominance: refuse a public `sum` or `average` when the largest |row value| exceeds 50% of the sum of |row values|. Test: 5 rows, one of them 60%, gives `dominant`.
- MB-7. Overlap and exact-flag:
  - Refuse a public metric whose row set differs by 1 to 4 rows from another public metric's over the same source.
  - The preview labels a value "exact" when the rounded value equals the exact one, as for any count under 100 at 2 significant figures.
  - Tests for both.
- MB-8. The Caveat and the preview say "5 rows", not "5 people". Rows ≠ people is named.
- MB-9. A publish carries each source's `updated_at` as loaded. The bridge refuses with `stale_source` when it is older than the row's current `updated_at`. The ownership read adds that column. Test.
- MB-10. Published section: either a label cap of 120 B, or a section cap of 12 KiB. 10 × 60 emoji measured 8,698 B (P3). Test with the maximal shape.
- MB-11. Format and labels:
  - The bridge accepts only a currency in `Intl.supportedValuesOf('currency')`.
  - The client formats inside try/catch and falls back to a plain number.
  - Labels reject C0/C1 controls, U+202A–U+202E and U+2066–U+2069.
  - Tests.
- MB-12. A non-owner sees a generic placeholder, never `fieldBind` (BoundFieldReadOnly.tsx:39-45). The id is already in the page JSON, so this is hygiene, not a boundary.
- MB-13. Audit:
  - No audit row per read; read-side drops are logged at most once per (subject, version, reason) per process.
  - No labels or values in audit lines.
  - Test: 100 reads of a malformed value give at most 1 write.
- MB-14. The contract's own tests stay:
  - projected keys equal `PublicMetric` keys;
  - a reduced card has no metrics;
  - 8-day TTL and the 429.
- MB-15. A public metric's date filters run in the definition's timezone, or they are refused. Test: the same fixture under `TZ=UTC` and `TZ=Pacific/Kiritimati` gives the same value.

### U7d: composites. After U7b.
- MD-1. A composite is computed from its inputs' **published** strings, then its own precision applies. Test: A is exactly 9123 and published as 9100; `A − 9000` publishes 100, not 120.
- MD-2. A composite over a bucketed input is refused.
- MD-3. A composite's interval is at least the largest interval among its inputs.
- MD-4. The contract's rules stay: cycle, depth over 3, more than 4 inputs, a private input, division by zero gives null.

### U7e: live mounts. BLOCK. Lift requires all of these:
- ME-1. Measure the router's return type for SUM and AVG on Mongo decimal128, SQL DECIMAL and BIGINT above 2^53, and whether an empty groupBy is accepted (the contract's own gate).
- ME-2. Prove who owns a mount's data:
  - who writes `osionos_workspace_databases` (not the osionos bridge);
  - whether one `db_id` can link to two owners' workspaces (`unique (workspace_id, db_id)`);
  - whether members wrote the rows.
- ME-3. Q1 answered before any public mount metric. Private mount metrics are then PwC under ME-1 and MA-*.
- ME-4. MB-6 and MB-7 need row-level max and overlap. Without router support, public mount sums are refused.
- ME-5. Never through `Number(...)` at `liveAggregateParse.ts:38`.

## 3. Owner questions

- Q1. May a public metric read workspace data the owner does not own? Recommended: no for now.
- Q2. Is a value up to 7 days old acceptable while the owner is away? Recommended: yes.
- Q3. Settings sections or a dedicated table? Ruled: sections.
- Q4. Default precision? Recommended: 2 significant figures, with a preview.
- Q5. Metrics on shared pages beyond the README? Recommended: not in U7.

| Q | Blocks | Why |
|---|---|---|
| Q1 workspace data | U7e public use | U7b is restricted to object DBs (MB-5) |
| Q2 7-day staleness | U7b | A "no" means option D (a server evaluator), which replaces U7b |
| Q3 sections vs table | none | Ruled: sections. A table adds no `n` enforcement (see the corrections in §1). |
| Q4 default precision | none | It blocks only if the owner loosens the 2-sig default plus exact-flag |
| Q5 shared pages | none | The default fails closed (`unavailable`) |

## 4. Measured versus read

Measured on 2026-11-17 (probes in the session scratch directory):
- **P1** `timeout 60 node --import ./register.mjs varurl.mjs`
  - Five cases: `[x](https://e.example/?q={{env.KEY}})`, `![i](…/{{env.KEY}}.png)`, `<https://…/{{env.KEY}}>`, `[x]({{env.URL}})`, `plain {{env.KEY}} text`.
  - The four URL forms give `inUrl:false`, and `{{env.KEY}}` stays literal in href/src.
  - The plain-text case gives `inText:true` (an escaped span).
- **P2** `timeout 30 node sectionsize.mjs` (bytes for 20 definitions / how many fit in 16 KiB):

  | Label | Filter value 0 B | 8 B | 40 B |
  |---|---|---|---|
  | ascii | 38,389 / 8 | 39,669 / 8 | 44,789 / 7 |
  | emoji | 41,989 / 7 | 43,269 / 7 | 48,389 / 6 |

  One definition with no filters is 769 B.
- **P3** `timeout 30 node publishedsize.mjs`: 10 maximal values are 6,898 B (ascii) and 8,698 B (emoji).
- **P4** `timeout 60 node --import ./register.mjs varescape.mjs`: `rawTagPresent:false`, `boldReparsed:false`, `bidiKept:true`.

SKIP (not measured):
- `jsonb_strip_nulls` depth;
- `pg_column_size` versus text bytes inside the CHECK (no PostgreSQL image here);
- the React path of P1 and P4 (it shares the AST; read only);
- the 50k-row bench, the +5 ms read cost, router types.

Read only, citations above:
- bridge-preferences.mjs:25-45, :124-131, :149-152;
- the account-profiles migration :233-241, :326-357 and :662-666;
- bridge-pg.mjs:13-24 and :52-66;
- bridge-account-insights.mjs:24-46;
- bridge-api.mjs:4001-4005, :4758-4768;
- the workspace-databases migration :17-28;
- ReadOnlyBlock.tsx:88-110;
- BoundFieldReadOnly.tsx:39-45;
- bindingSources.ts:155-162;
- evaluateFilter.ts:25-137.

## 5. Residuals (accepted with U7a–U7d)

- One new row per interval is revealed to within the rounding (caveat a). The preview names it.
- `n` stays a client claim under any storage. A hostile owner is out of scope.
- Rows ≠ people. MB-6 narrows the gap for sums only.
- An old client shows a public metric's id as its placeholder.
- `minIntervalHours` 168 equals the 7-day TTL, so a held value can expire exactly as the interval ends and show "—" briefly. Cap the interval at 167 h, or accept the gap.
- Gateway config was not read. If a route hands an account-role token to a browser, MB-1 falls, and with it the "sections are enough" ruling.

## Alternatives rejected

- **A `metrics_public` table now.** It would change the ruling only if a second writer, or a server evaluator (option D), had to be constrained.
- **A server evaluator (option D).** It would be a second evaluator and a confused deputy. It returns only if the
  owner answers "no" to Q2.

## Consequences

- U7c lands before U7b and before the U4 preview: today every README viewer resolves `{{…}}` in the viewer's own scope.
- A published value that was seen cannot be unpublished. The preview says so before the first publish.
- `metrics:owner` is never in the app-wide binding registry.
- An osionos ADR records the decision next to the code when U7 code lands.
