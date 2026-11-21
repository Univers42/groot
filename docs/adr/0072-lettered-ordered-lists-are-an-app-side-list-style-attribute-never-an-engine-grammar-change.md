# 0072. Lettered ordered lists are an app-side `listStyle` attribute, never an engine grammar change

- Status: accepted. PROCEED-WITH-CONDITIONS AL1–AL14. Rejected: rendering the letters with CSS
  `list-style-type`, and copying the engine's numeric shortcut rule to letters.
- Date: 2026-11-21
- Deciders: devil (ruling); osionos block-editor builder (lives with it)

## Context

This is Univers42/osionos#328: typing `a.` then Space should start a list lettered a., b., c.
The facts below are from osionos develop 3da3391c6, with markdown-engine pinned at 9ff30b1.

- The Space shortcut calls the engine's `detectBlockType`. Its `isOrdered` rule accepts digits followed by
  `.` or `)` and throws the number away.
- **Measured:** the numeric rule also fires inside a decimal. `3.14 ` becomes a list whose text is `14 `.
  Copying the rule for letters would turn `e.g. ` into a list `g. ` and `i.e. ` into a list `e. `.
- List markers are computed text (`listMarkers.ts`), not CSS. Three counters existed side by side: the
  editor, the virtualized view and the PDF export.
- Pressing Enter builds a new block from `{id, type, content}` only, so every other attribute is dropped.
- Collab diffs whole-block JSON, so an unknown key is carried. Old clients show `1.` and lose no data.
  An old client writing `.omd` drops the key, because `.omd` only keeps allowlisted keys.

## Decision

1. The check lives in osionos (`handleParagraphSpaceShortcut`), before the engine call. It fires only when
   the paragraph's whole text is exactly `a.` and the key is Space. The engine is not changed and the pin
   is not bumped (AL1, AL2).
2. The block stores `listStyle: "lower-alpha"`, and only on `numbered_list`. A missing key means decimal;
   `"decimal"` is never written. Turning the block into another type removes the key (AL4).
3. Markers go through `getNumberedMarker` with a start slot. Children of a lettered item continue the
   rotation: a., then i., then A. (AL5).
4. One shared run counter serves the editor, the virtualized view, the PDF export and the read-only
   renderers. A change of style between neighbouring items restarts the count (AL6).
5. One shared continuation function serves both Enter paths and copies `listStyle` only (AL7):
   - Tab removes the style, so the child follows the rotation.
   - Shift+Tab takes the style of the new previous sibling.
6. `.omd` keeps `listStyle` as a scoped overlay key that accepts only `lower-alpha` (AL8).
7. Exports (AL9):
   - Markdown export and the clipboard keep writing `1.`.
   - HTML writes `<ol type="a">` and starts a new `<ol>` when the style changes.
   - PDF uses the shared marker.
8. Paste and markdown import are unchanged. `a. x` stays a paragraph, as CommonMark has it (AL10).

## Consequences

- **Lost on export.** A lettered list copied out as markdown comes back numbered. The text never turns
  into `a.` paragraphs.
- **Undo.** Undo matches numeric lists: one Ctrl+Z leaves the list item. Neither kind of list has an undo
  path back to the paragraph (AL3).
- **Version skew.** Until both live and beta run the new build, older clients show `1.`, and an `.omd`
  saved by an older client drops the style (AL12).
- **Read-only numbering.** Nested and root numbered runs now restart after a non-numbered sibling, the
  same way the editor always did.
- **Lint suppression.** The shared counter lets the React Compiler reach `useVirtualizer` in
  `BlockEditorSurface.tsx`. Its `react-hooks/incompatible-library` suppression is tracked in
  Univers42/osionos#337.
- **Out of scope (AL14):** roman `i.`, capital `A.`, a start letter other than a, and `a)`. Changing the
  engine grammar needs its own ruling, because it is a public surface and needs the pin-bump drill. The
  `3.14 ` false positive is filed separately as Univers42/markdown-engine#11.
