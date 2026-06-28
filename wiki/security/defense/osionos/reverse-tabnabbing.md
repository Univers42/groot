# Reverse Tabnabbing Protection — osionos (the block editor)

> Every external link rendered by osionos carries `rel="noopener noreferrer"`, unconditionally severing the `window.opener` channel and suppressing the `Referer` header before the destination page loads.

## What it is (the concept)

**Reverse tabnabbing** exploits the `window.opener` reference that a browser passes to a page opened via `target="_blank"`: the destination page can call `window.opener.location.replace(…)` to silently redirect the originating tab to an attacker-controlled URL while the user is reading the new tab. The defence is **`rel="noopener"`**, which instructs the browser not to expose `window.opener` to the child page. **`rel="noreferrer"`** implies `noopener` and additionally suppresses the HTTP `Referer` header, preventing the destination server from knowing which osionos page the user came from. Together they form the standard two-attribute mitigation.

## What it defends against

See [reverse-tabnabbing](../../attack/reverse-tabnabbing.md). In osionos, users embed arbitrary external URLs in Markdown blocks — wiki pages, notes, and database cells all pass through the same markengine render pipeline. Without this control, any collaborator (or an attacker who compromised a shared page) could plant a link whose destination tab redirects the osionos editor tab to a phishing sign-in page, silently stealing the user's workspace session.

## How osionos implements it

The control is implemented in three layers of the markengine render pipeline, each enforcing `rel="noopener noreferrer"` independently.

### 1. URL sanitisation (`sanitizeUrl`) blocks dangerous schemes first

`apps/osionos/app/src/shared/lib/markengine/renderCore.ts` (lines 109-122):

```ts
export function sanitizeUrl(value: string): string {
  // …
  const scheme = schemeMatch[1].toLowerCase();
  if (scheme === "http" || scheme === "https" || scheme === "mailto" || scheme === "tel") {
    return trimmed;
  }
  return "";   // javascript:, data:, vbscript:, … → empty string → rendered as href="#"
}
```

A `javascript:` or `data:` href never reaches the external-link gate; it is replaced with `""` and the anchor falls back to `href="#"`.

### 2. External-URL detection gates the `rel` attributes

`apps/osionos/app/src/shared/lib/markengine/renderCore.ts` (lines 105-107):

```ts
export function isExternalUrl(href: string): boolean {
  return /^https?:\/\//i.test(href.trim());
}
```

Only `http://` and `https://` URLs are considered external. Relative paths and internal `[[page-id]]` links are excluded from the rel treatment.

### 3. HTML string render path — `renderLink` in `inlineHtml.ts`

`apps/osionos/app/src/shared/lib/markengine/markdown/renderers/inlineHtml.ts` (line 67):

```ts
options.externalLinks && isExternalUrl(href) ? 'target="_blank" rel="noopener noreferrer"' : "",
```

`externalLinks` defaults to `true` in `DEFAULT_INLINE_HTML_OPTIONS` (line 37) and in the top-level `renderHtml` defaults (`markdown/renderers/html.ts` line 48). The option must be **explicitly set to `false`** to suppress the attributes; no call site in the app does this.

### 4. React element render path — `renderInlineNode` in `reactHelpers.tsx`

`apps/osionos/app/src/shared/lib/markengine/markdown/renderers/reactHelpers.tsx` (lines 226-228):

```ts
...(o.externalLinks && isExt
  ? { target: "_blank", rel: "noopener noreferrer" }
  : {}),
```

`externalLinks` defaults to `true` in both the `reactHelpers.tsx` defaults (line 87 of `markdown/renderers/react.tsx`) and in `shortcutsReact.tsx` (line 25: `externalLinks: options.externalLinks ?? true`). The React and HTML paths are separate code paths; both carry the same guard, so a refactor of one path cannot silently remove protection from the other.

### 5. Direct JSX usage in page headers

`apps/osionos/app/src/pages/notion-page/ui/headerSlots.tsx` (line 70): a hard-coded `rel="noreferrer"` on a direct JSX anchor confirms the pattern is applied outside the markengine pipeline too.

## How we know it is applied

The protection is **on by default** and cannot be disabled by content: `externalLinks: true` is the resolved default in all three entry-point defaults (`DEFAULT_INLINE_HTML_OPTIONS` in `inlineHtml.ts`, `defaults` in `html.ts`, `defaults` in `react.tsx`). The option is a renderer-level flag, not a per-link attribute; a caller that omits it receives the secure behaviour automatically.

`sanitizeUrl` runs before `isExternalUrl` in every render path, meaning a crafted `javascript:` URL never triggers the external-link branch — it is discarded to `""` and emitted as `href="#"`. This means the two controls are layered: scheme filtering removes injection risk, then `rel` attributes remove opener leakage for all remaining external URLs.

No dedicated automated test currently asserts the presence of `rel="noopener noreferrer"` in rendered output. The control's correctness rests on the default-on option and the fact that both render paths share the same `isExternalUrl` and `sanitizeUrl` primitives from `renderCore.ts`.

## Reference

OWASP — [Reverse Tabnabbing](https://owasp.org/www-community/attacks/Reverse_Tabnabbing) (OWASP Foundation). Maps to **OWASP Top 10 A05:2021 — Security Misconfiguration** (insecure `target="_blank"` without `rel="noopener"` is classified as a browser security misconfiguration at the application level).

## Residual risk / assumptions

- **No automated test gate.** A future refactor that introduces a third render path (e.g. a server-side renderer or an export pipeline) would not automatically inherit the protection unless it is wired to the same `renderLink`/`renderInlineNode` primitives.
- **`externalLinks: false` is a valid opt-out.** Any caller that explicitly passes `{ externalLinks: false }` suppresses both `target="_blank"` and the `rel` attributes for all links. The index-level JSDoc example (`markengine/index.ts` line 91) illustrates this opt-out; callers must be audited if new render surfaces are added.
- **Modern browsers apply implicit `rel="noopener"`** on `target="_blank"` since ~2018 (Chromium 88, Firefox 79, Safari 12.1), so the `noopener` part of the defence is redundant in evergreen browsers. The explicit `noreferrer` adds Referer suppression, which browsers do not apply implicitly.
- **Internal links and relative paths are excluded** from the `rel` treatment by `isExternalUrl`. A misconfigured internal link that resolves to an attacker-controlled host (e.g. via an open redirect in the bridge) would not receive the protection.
- **The `notion-database-sys` vendored sub-repo** ships its own parallel markdown renderer (`src/shared/notion-database-sys/src/lib/markdown/renderers/html.ts`), which also defaults `externalLinks: true` (line 28) and applies the same `rel` string (line 179). That renderer is excluded from the app's ESLint pass and is treated as vendored code; changes to it are not covered by the root `test:quality` gate.
