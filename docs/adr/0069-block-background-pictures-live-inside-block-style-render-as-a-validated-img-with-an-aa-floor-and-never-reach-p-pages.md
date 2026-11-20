# 0069. Block background pictures live inside block.style, render as a validated img with an AA floor, and never reach /p/ pages

- Status: accepted. PROCEED-WITH-CONDITIONS BG1–BG21. The canvas cell writer is BLOCKED until BG17. `/p/` is BLOCKED (BG13).
- Date: 2026-11-20
- Deciders: devil (ruling); osionos builder (lives with it)

## Context

The user asked for a background picture behind callouts and sections, with an adjustable overlay so the text
stays readable. The design was approved 2026-11-20. The ruling's evidence (contrast table, URL probe, picker
census) is in `/mnt/storage/dlesieur/scratch/devil-bg/` (`RULING.md`, `contrast.mjs`, `probe-url.mjs`):

- A 50 % theme overlay fails WCAG AA: 4.37 light, 2.64 dark. AA needs 60 % light and 70 % dark.
- `isSafeImageSource` (`bridgeMediaUrl.ts:17-20`) accepts `/\evil.example/p.png` and `/\t/…`, and both resolve
  off-site. The profile banner and avatar use it today.
- The cover picker yields `http:`, `data:`, `blob:`, gradients and videos. A failed upload stores `data:`
  inline with no cap, so every later save hits the 128 KB 413.
- Canvas cell migrations drop unknown keys. `LayoutBlockReadOnly.tsx:66` paints cell colours as a raw `background`.

## Decision

1. The picture is a nested record in `block.style`.
2. One shared URL-parsing validator checks it at render time.
3. It renders as a real `<img>`.
4. An opacity floor guarantees AA for the text.
5. It never reaches `/p/`. The README carries it only for the owner's own uploads.

## Alternatives considered

- **A new top-level Block key.** Live's overlay allowlist drops it, so an old client erases it.
- **CSS `background-image` from the stored URL.** This opens injection and a public beacon.
- **Reuse `isSafeImageSource`.** It has the `/\` bypass.
- **Keep the approved 50 % default.** AA fails at 4.37 light and 2.64 dark.
- **Smuggle the cell picture into `backgroundColor`.** That paints a raw `background` and is a beacon.

## Consequences

BG1–BG21 below bind. Re-rule if:
- pictures are wanted on `/p/`;
- the user explicitly asks for sub-floor opacity;
- canvas cells move before BG17 holds.

## Conditions (BG1–BG21, acceptance criteria)

### Format

- **BG1.** The picture is a single nested record inside `block.style` (for example `style.backdrop`). It never becomes a top-level Block key, a `STYLE_SCALES` or `PROP_SCALE` entry, or a `:::` opener attribute.
  - Tests:
    - `bridge sanitizeStyle` drops it;
    - `publish-style-drift` stays green unchanged;
    - `layoutAttributeText` output is byte-identical with and without it;
    - a `.omd` write and read keeps it byte-equal.
- **BG2.** The values are enums or clamped numbers only:
  - `layer`: `'theme'` or a `STYLE_SCALES.surface` token, never hex or free CSS;
  - `opacity`: one of {0, 10, …, 90};
  - `blur`: a small enum;
  - `x`/`y`: integers 0–100 through `clampCoverPosition`;
  - `src`: at most 2048 chars.
  - Read-side sanitiser: own keys only (`Object.hasOwn`). An invalid record renders nothing and never throws.
  - Tests: the PS1 hostile-key test and the 10k seeded fuzz, extended to the nested record.
- **BG3.** One validator, `sanitizeBackdropSource`, shared by client and bridge (one module, or a drift test as in PS35/PS39). It parses with `new URL(value, appOrigin)` and accepts only:
  - (a) an absolute `https:` URL with no userinfo, or
  - (b) a URL whose resolved origin and path start with the bridge's `/api/media/uploads/`.
  - It refuses `http:`, `data:`, `blob:`, `javascript:`, protocol-relative URLs, gradients and video sources (`isVideoCoverSource`).
  - The test vector must include `/\evil.example/p.png` and `/\t/evil.example/p.png` (both accepted today by `isSafeImageSource`).
  - `isSafeImageSource` is **not** reused as-is.
- **BG4.** Validation happens at render time, not only in the picker. A synced value from a hostile collaborator or an old client passes BG3 before any `<img>` exists. On failure there is no `<img>` and no layer, and text keeps today's style.

### Picker and upload

- **BG5.** The background picker is the cover picker in a restricted mode:
  - image gallery tiles only, with no gradient tiles and no Video tab;
  - the URL tab and the Library tab both filtered through BG3;
  - Upload.
- **BG6.** Upload never falls back to `data:`. If `uploadPageMedia` fails, the picker shows an error and writes nothing to the block or to the asset library (F6, F7).
- **BG7.** Uploads are bounded before the POST. Either refuse files over a stated cap, or downscale on the client (canvas to webp/jpeg, at most 2560 px on the long side). Test with a 20 MB fixture.
  - Per-user quota is U3. A `Caveat:` line names it.

### Rendering

- **BG8.** The DOM is a real `<img>` with:
  - `alt=""` and `aria-hidden="true"`;
  - `loading="lazy"`, `decoding="async"`, `draggable={false}`;
  - `referrerPolicy="no-referrer"`;
  - `crossOrigin` from `mediaCrossOrigin`;
  - `object-fit: cover`;
  - `object-position` computed from BG2's clamped numbers.
  - Layer and blur come from `data-*` enum attributes and CSS. No `background`, `background-image` or custom property is built from a stored string (PS2).
  - Test: no element in the rendered fixture has an inline style containing `url(`.
- **BG9.** The picture sits behind a flag (`osio.layout.modes` or its own), off on live.
  - With the flag off, the DOM is today's. PS4-style parity: 0 changed pixels on a fixture.
  - The PS3 per-block error boundary wraps the picture.

### Contrast (WCAG AA)

- **BG10.** A pure function `worstCaseContrast(layerRGB, alpha, textRGB)` is tested against the F13 table. Pinned values: light 50 % = 4.37 and 60 % = 6.10; dark 60 % = 3.55 and 70 % = 4.90.
- **BG11.** When the block holds text, the rendered alpha is `max(stored, floor)`.
  - `floor` is the lowest step whose worst case is at least 4.5:1, for the **viewing** theme, the resolved layer colour and the block's resolved text colour (flat `textColor` included).
  - The default stored opacity is the author's floor (60 % light, 70 % dark), not 50 %.
  - The menu shows when the floor is applied.
  - A layer colour that cannot reach 4.5:1 at 90 % is not offered for text blocks.
  - axe passes on the fixture in both themes.
  - This deviates from the approved "default 50 %, 0–90 %". Rendering below the floor needs the user's explicit decision, recorded in the ADR. The builder may not decide it.
  - `Caveat:` mixed inline text colours inside the block are not covered.

### Position

- **BG12.** Reposition is an explicit mode (a button), never a `pointerdown` on the block content.
  - It works on two axes, reusing `nextCoverPosition` for each.
  - It commits once on Save, through the editor commit: one undo step and one outbox write.
  - Arrow keys step the position. The control is `role="slider"` with `aria-valuenow`.

### Surfaces

- **BG13.** **Published `/p/`: not published.** A test proves that `publishSnapshot` of a block with `style.backdrop` emits no `backdrop`. Publishing pictures is a separate exposure ruling (PS47 class: anonymous IP leak, plus capability URLs).
- **BG14.** **README projection.** The bridge drops `style.backdrop` unless its `src` resolves, through BG3's parser, to the README owner's own `/api/media/uploads/<ownerId>/` path. This also applies to blocks inside `layoutCells[].blocks`.
  - Tests: a tracker URL is dropped, the owner's own upload is kept, and another user's upload is dropped.
- **BG15.** **Shared pages.** They render any BG3-valid https picture, the same exposure class as image blocks today. A `Caveat:` at the render site says that third-party hosts see viewer IPs.

### Old clients and round trip

- **BG16.** A test runs on **origin/main's** code (or its frozen copy) on content holding `style.backdrop`: a text edit, turn-into, duplicate, move, and a `.omd` save. `backdrop` survives byte-equal on every path. This closes U4; a path that drops it blocks develop.
- **BG17 (lift for canvas cells; the writer is BLOCKED until then):**
  - (a) `migrate`/`unmigrate` carry unknown cell keys through, proved by a foreign-key test;
  - (b) that reader is served on live one promotion before any cell-picture writer (the TD verdict precedent);
  - (c) the cell picture uses the BG1/BG2 record, BG3, BG14's walk and the publish cell allowlist (which drops it);
  - (d) never encode the picture in `backgroundColor` or `tint`.
  - Residual: a tab opened before (b) still erases until it reloads.

### Performance

- **BG18.** A prod-build fixture with 0 against 24 pictured blocks, 12 of them blurred.
  - Boot delta and scroll frame time are measured, with the command and artifact named.
  - Below-the-fold pictures are not fetched at load: the request count at load equals the in-viewport count.
  - The budget is stated before the measurement.
- **BG19.** Size budgets:
  - Content growth: at most 2.3 KB per pictured block (the BG2 cap plus the record).
  - Snapshot growth: 0 bytes (BG13).

### Review

- **BG20.** A `security` agent pass on BG3, BG14 and BG8 before anything reaches live.
- **BG21.** These residuals predate this design and are handed to `security`, not fixed in this unit:
  - the F4 bypass in the profile banner and avatar;
  - F8 `LayoutBlockReadOnly.tsx:66` raw `background`, which already reaches README visitors through `layoutCells`;
  - F11, no `img-src`. U3 Report-Only was the earlier proposal.
