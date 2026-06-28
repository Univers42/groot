# Cross-Site Scripting (XSS) Defenses — opposite-osiris (marketing + auth website)

> opposite-osiris eliminates XSS at every HTML sink: inline SVGs are sanitized through a locked-down allowlist before reaching `set:html`, and all runtime DOM writes flow through a Trusted Types policy that the browser CSP enforces at the platform level.

---

## What it is (the concept)

**Cross-Site Scripting (XSS)** is an injection attack in which an adversary causes a browser to execute attacker-controlled JavaScript in the context of a trusted origin. The attack surface is any **HTML sink** — a DOM property or API that parses a string as markup (`innerHTML`, `insertAdjacentHTML`, Astro's `set:html`, raw SVG imports). **Stored XSS** persists in the server's data; **DOM-based XSS** occurs entirely in the client's JavaScript. **Trusted Types** is a browser-side API (enforced by a CSP directive) that prevents arbitrary string-to-HTML coercions by requiring every HTML creation to pass through an explicit policy object.

---

## What it defends against

See [Cross-Site Scripting (XSS)](../../attack/xss.md).

SVG is an active document format: a `<script>` tag, an `onload=` attribute, or a `javascript:` href inside an SVG turns a seemingly inert illustration into a JavaScript execution vector. Because opposite-osiris inlines several character illustrations via `set:html`, any unchecked SVG in that pipeline is a stored/DOM XSS path. Separately, runtime DOM writes that build auth portal markup or display BaaS user data (username, email) from external sources are classic DOM XSS targets if the data reaches an HTML sink without escaping.

---

## How opposite-osiris implements it

### 1. Inline-SVG sanitization before `set:html`

Every SVG illustration that reaches Astro's `set:html` sink is first passed through `sanitizeSvgMarkup` defined in [`apps/opposite-osiris/src/lib/svg-security.mjs`](../../../../apps/opposite-osiris/src/lib/svg-security.mjs).

The function applies two layers of defense before returning the markup:

**Layer A — regex pre-rejection** (lines 87–105): three compiled patterns throw immediately if the raw markup contains event handlers (`on{event}=`), dangerous URL schemes in link attributes (`javascript:`, `data:`, `vbscript:`), or blocked element names (`script`, `foreignObject`, `iframe`, `object`, `embed`, `audio`, `video`, `canvas`, `image`, `link`, `meta`, `style`):

```js
const SVG_EVENT_ATTRIBUTE_PATTERN = /\son[a-z]+\s*=/iu;
const SVG_URL_ATTRIBUTE_PATTERN   = /\s(?:href|xlink:href|src)\s*=\s*(['"]?)\s*(?:javascript:|data:|vbscript:)/iu;
const SVG_BLOCKED_MARKUP_PATTERN  = /<\s*\/?\s*(?:script|foreignObject|iframe|…)\b/iu;
```

**Layer B — `sanitize-html` allowlist** (lines 107–128): the markup is re-parsed with an explicit `allowedTags` list (`svg`, `g`, `path`, `circle`, `ellipse`, `rect`, `linearGradient`, `clipPath`, `use`, etc.), an explicit `allowedAttributes` list (drawing primitives only), `allowedSchemes: []`, and `allowProtocolRelative: false`. Any tag or attribute outside these lists is silently discarded. The function then asserts the root element is still `<svg>` before returning.

The sole consumer in the application is [`apps/opposite-osiris/src/components/svg/CharacterIllustration.astro`](../../../../apps/opposite-osiris/src/components/svg/CharacterIllustration.astro), which wraps every `?raw` import before reaching the only `set:html` in that module (line 21):

```astro
const characterSvgs = {
  reader:  sanitizeSvgMarkup(readerSvg),
  student: sanitizeSvgMarkup(studentSvg),
  chatter: sanitizeSvgMarkup(chatterSvg),
};
// …
<div class="character-svg character-svg--exact" set:html={characterSvgs[kind]} />
```

---

### 2. Trusted Types policy for runtime DOM writes

[`apps/opposite-osiris/src/scripts/main.ts`](../../../../apps/opposite-osiris/src/scripts/main.ts) creates a single, named Trusted Types policy (lines 174–194):

```ts
function trustedHTML(markup: string): unknown {
  if (trustedHtmlPolicy === undefined) {
    const trustedTypes = (globalThis as typeof globalThis & { trustedTypes?: TrustedTypesFactory }).trustedTypes;
    try {
      trustedHtmlPolicy = trustedTypes?.createPolicy('prismatica-static-markup', { createHTML: (value) => value }) ?? null;
    } catch { trustedHtmlPolicy = null; }
  }
  return trustedHtmlPolicy ? trustedHtmlPolicy.createHTML(markup) : markup;
}

function setTrustedInnerHTML(element: HTMLElement, markup: string): void {
  (element as unknown as { innerHTML: unknown }).innerHTML = trustedHTML(markup);
}

function insertTrustedHTML(element: HTMLElement, position: InsertPosition, markup: string): void {
  element.insertAdjacentHTML(position, trustedHTML(markup) as string);
}
```

The policy is named `'prismatica-static-markup'`; no `'default'` policy is created. All `innerHTML` and `insertAdjacentHTML` calls in the codebase route exclusively through `setTrustedInnerHTML` or `insertTrustedHTML`. These wrappers carry only static internal markup (mascot SVG, portal dialog structure) — none of it originates from user input.

User-supplied BaaS data (username and email from the demo users API) is explicitly rendered via `textContent`, never HTML (lines 2368–2374):

```ts
name.textContent  = user.username;
email.textContent = user.email;
```

The CSP in [`apps/opposite-osiris/astro.config.mjs`](../../../../apps/opposite-osiris/astro.config.mjs) (lines 99–100) binds this at the browser level:

```js
"trusted-types prismatica-static-markup",
"require-trusted-types-for 'script'",
```

With `require-trusted-types-for 'script'` active, any attempt to assign a bare string to `innerHTML` or call `insertAdjacentHTML` with a string throws a `TypeError` in supporting browsers, making ad-hoc sink bypass a hard runtime error rather than a silent misconfiguration.

---

## How we know it is applied

[`apps/opposite-osiris/scripts/security/ctf/01-xss-sinks.mjs`](../../../../apps/opposite-osiris/scripts/security/ctf/01-xss-sinks.mjs) is a static analysis gate that fails the security suite (exit code 1) if any of the following invariants are violated:

1. Any `.astro` / `.ts` / `.mjs` source file that contains `set:html=` does not also contain `sanitizeSvgMarkup(` in the same module.
2. Any source file that contains a `?raw` import does not also contain `sanitizeSvgMarkup(`.
3. Any source file that contains `.innerHTML =` or `insertAdjacentHTML(` is not `src/scripts/main.ts` carrying all three wrapper definitions.
4. `src/scripts/main.ts` contains `createPolicy('prismatica-static-markup'` and does **not** contain `createPolicy('default'`.
5. `src/scripts/main.ts` renders seeded data with `name.textContent = user.username;` and `email.textContent = user.email;`.

The gate text for the sink check (lines 52–68):

```js
{
  name: 'DOM HTML sinks are restricted to trusted wrappers',
  run: () => {
    const allowed = new Map([
      ['src/scripts/main.ts', ['function setTrustedInnerHTML', 'function insertTrustedHTML', 'trustedHTML(markup)']],
    ]);
    // … fails if any other file matches HTML_SINK_PATTERN
    assert.deepEqual(offenders, [], `Unexpected HTML sink usage: ${offenders.join(', ')}`);
  },
},
```

---

## Reference

The [OWASP Cross Site Scripting Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html) defines the canonical output-encoding and sink-avoidance rules that underpin this implementation. The controls above address its HTML context encoding rule (sanitize before `set:html`) and its safe DOM API guidance (`textContent` over `innerHTML` for untrusted data); the Trusted Types integration further operationalises its recommendation to treat HTML sinks as privileged operations.

---

## Residual risk / assumptions

- **Allowlist completeness.** `sanitizeSvgMarkup` only sanitizes SVGs that flow through the `CharacterIllustration` component. Any future `set:html` use in a different component must be caught by the CTF gate — the gate failing to run in CI would create a gap.
- **Trusted Types browser support.** The policy enforcement is only active in Chromium-family browsers that implement the Trusted Types API. Firefox and Safari (as of the writing date) implement the CSP header without enforcing the policy, so the protection degrades to the static gate + correct coding convention on those browsers.
- **Static internal markup.** The Trusted Types wrappers do not sanitize; they only create a `TrustedHTML` token. If static markup passed to `setTrustedInnerHTML` ever includes interpolated external data, the policy would pass it through unchanged. The protection assumes the arguments to those wrappers are always application-controlled strings, which the CTF gate verifies structurally but not semantically.
- **CSP delivery.** The `require-trusted-types-for 'script'` directive is set at the Astro build layer and a dev-server header injection. Its delivery in production depends on the reverse proxy (the TLS WAF) forwarding the header correctly — a misconfigured proxy that strips CSP would remove the runtime enforcement layer while leaving the static coding conventions in place.
