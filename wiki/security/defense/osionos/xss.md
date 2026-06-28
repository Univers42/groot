# Cross-Site Scripting Prevention — osionos (the block editor)

> Every user-authored string that reaches the DOM passes through a mandatory encoding and sanitization pipeline; no raw user content can be injected as executable HTML.

## What it is (the concept)

**Cross-Site Scripting (XSS)** is an injection attack in which an attacker causes a victim's browser to execute attacker-controlled JavaScript by embedding it in content that is subsequently rendered as HTML. The two main variants relevant to a collaborative block editor are **stored XSS** (payload persisted in the database and rendered on page load) and **DOM-based XSS** (payload injected via a URL or user input processed client-side). Effective defense requires **output encoding** — transforming characters that have special HTML meaning into their entity equivalents — applied at every point where untrusted data reaches the DOM.

## What it defends against

See [Cross-Site Scripting (XSS)](../../attack/xss.md).

osionos is a multi-tenant collaborative editor; any workspace member can author block content (callout text, media captions, link URLs, image sources) that is persisted to the grobase BaaS and subsequently rendered for every visitor to that page. Without output encoding, a user could store `<img src=x onerror=alert(document.cookie)>` or `[x](javascript:alert(1))` in block content and cause arbitrary JavaScript execution in every viewer's session.

## How osionos implements it

Three complementary controls form the XSS defence at the markengine rendering layer. The markengine library (`src/shared/lib/markengine/`) is the single render path for all inline content; it is not optional.

### 1. HTML output encoding of all inline text

`src/shared/lib/markengine/renderCore.ts` defines `escapeHtml()` (lines 92–103), which maps `&`, `<`, `>`, `"`, and `'` to their HTML entities via `HTML_ESCAPE_MAP` and a single global `replaceAll`:

```ts
const HTML_ESCAPE_MAP: Record<string, string> = {
  "&": "&amp;",  "<": "&lt;",  ">": "&gt;",
  '"': "&quot;", "'": "&#39;",
};
export function escapeHtml(value: string): string {
  return value.replaceAll(HTML_ESCAPE_PATTERN, (char) => HTML_ESCAPE_MAP[char]);
}
```

`src/shared/lib/markengine/markdown/renderers/inlineHtml.ts` re-exports this as `esc()` (lines 137–139) and calls it unconditionally in `renderInlineNodeToHtml`:

- `case "text": return esc(node.value);` (line 96–97) — every literal text node is encoded before emission.
- All attribute values (`color`, `alt`, `title`, `pageId`, `label`) are wrapped in `esc()` before string interpolation (lines 65, 75, 78, 83–84, 88, 90–91, etc.).

Block components wire this through `parseInlineMarkdown`, which returns a `__html` string. `src/entities/block/ui/CalloutBlockReadOnly.tsx` (lines 34–36, 61) builds `{ __html: parseInlineMarkdown(block.content, …) }` and feeds it to `dangerouslySetInnerHTML` — the raw `block.content` string never touches the DOM directly. `src/entities/block/ui/MediaBlockReadOnly.tsx` (lines 36–43, 54–56) applies the same pipeline for media captions.

### 2. URL scheme allowlisting (blocking `javascript:` and `data:`)

`src/shared/lib/markengine/renderCore.ts` defines `sanitizeUrl()` (lines 109–123) and `stripUrlControlAndSpaceChars()` (lines 125–133). `sanitizeUrl` strips control/whitespace characters (codepoints ≤ `0x20` and `0x7F`) to defeat obfuscated schemes such as `java\tscript:`, parses the scheme, and returns the original URL only when the scheme is one of `http`, `https`, `mailto`, or `tel`; any other scheme — including `javascript:`, `data:`, `vbscript:` — causes the function to return `""`.

Both render paths apply this on every URL before it can reach the DOM:

- **HTML string renderer** (`src/shared/lib/markengine/markdown/renderers/inlineHtml.ts`, lines 62–64, 82–84): `href = sanitizeUrl(node.href)` then `esc(href || "#")`; `src = sanitizeUrl(node.src)` and the `<img>` is omitted entirely when `src` is empty.
- **React renderer** (`src/shared/lib/markengine/markdown/renderers/reactHelpers.tsx`, lines 219, 255): `sanitizeUrl(node.href)` and `sanitizeUrl(node.src)` are applied before any `createElement` call; an empty `src` short-circuits to `null` (line 256), suppressing the element.

### 3. Raw HTML blocks inert by default (`allowHtml: false`)

The React markdown renderer (`src/shared/lib/markengine/markdown/renderers/react.tsx`) ships with `allowHtml: false` in its default options object (line 88). The `html_block` case (lines 317–329) gates `dangerouslySetInnerHTML` behind an explicit `allowHtml` check:

```ts
case "html_block":
  if (!o.allowHtml) {
    return React.createElement("pre", { key, "data-block-state": blockState },
      React.createElement("code", null, node.value));
  }
  return React.createElement("div", { key, dangerouslySetInnerHTML: { __html: node.value } });
```

When `allowHtml` is `false` (the default), raw HTML in markdown is rendered as inert escaped text inside `<pre><code>`, never as live HTML. The string renderer (`src/shared/lib/markengine/markdown/renderers/html.ts`) mirrors this: `sanitizeHtml: false` in defaults (line 50), and the `html_block` case (line 157) emits `<!-- sanitized html block -->` when `sanitizeHtml` is `true`, suppressing the payload entirely.

## How we know it is applied

The URL sanitization control is covered by an automated test in `src/shared/lib/markengine/tests/markengine.test.js` (lines 85–90), run via `node --test` (the `test:unit` script in the markengine package):

```js
test("sanitizes unsafe href schemes in rendered html", () => {
  const result = compileMarkdownToHtml("[bad](javascript:alert(1))");
  assert.match(result.html, /href="#"/);
  assert.doesNotMatch(result.html, /javascript:/i);
});
```

This gate fails the build if `sanitizeUrl` ever passes a `javascript:` URL through to the rendered HTML. The encoding pipeline is structurally enforced: `parseInlineMarkdown` is the only rendering entry point consumed by the read-only block components (`CalloutBlockReadOnly`, `MediaBlockReadOnly`), and the `text` node branch unconditionally calls `esc()` — there is no code path through which a literal `<` or `>` in user content can reach `dangerouslySetInnerHTML` without encoding.

## Reference

The OWASP [Cross Site Scripting Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html) establishes the canonical set of output-encoding rules, including the specific five characters (`&`, `<`, `>`, `"`, `'`) that must be entity-encoded before insertion into HTML element content or attribute values. osionos's `escapeHtml` and the scheme allowlist in `sanitizeUrl` directly implement the cheat sheet's HTML Entity Encoding and URL encoding rules respectively — including its explicit guidance to block `javascript:` and `data:` URI schemes.

## Residual risk / assumptions

- **`allowHtml: true` callers:** any code that explicitly sets `allowHtml: true` when calling `renderReact` — or `sanitizeHtml: false` (the default, meaning passthrough) with the string renderer when passing raw HTML — bypasses control 3. A review of current consumers shows no such call in production block-rendering paths, but the unsafe branch exists and could be enabled by a future contributor.
- **Non-markengine surfaces:** block types that do not route through `parseInlineMarkdown` (e.g. heading text, paragraph blocks rendered via the live editor's `contentEditable` path) rely on React's own JSX escaping rather than `escapeHtml`. React escapes text children by default, which covers standard cases, but this is a different mechanism and not covered by the markengine test suite.
- **`dangerouslySetInnerHTML` and trusted pipeline breaks:** the security of the `__html` injection in callout/media components depends entirely on `parseInlineMarkdown` never returning unescaped attacker input. Any future change to the inline renderer that emits raw values (e.g. a new node type that bypasses `esc()`) would silently introduce XSS without a type error.
- **Server-side content validation:** the markengine controls are client-side rendering defences only. They do not prevent malicious content from being stored in the grobase BaaS. A compromised API response or a direct PostgREST write (bypassing the bridge) could deliver content that, if ever rendered with `allowHtml: true`, would execute.
