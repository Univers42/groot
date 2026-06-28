# File Upload Security — opposite-osiris (marketing + auth website)

> Every public media URL rendered by opposite-osiris is constructed through an allowlist-gated helper that rejects path traversal sequences, executable URL schemes, and NUL bytes — both before and after percent-decoding — so no filename under attacker influence can escape the `/assets/` tree or inject a `javascript:` pseudo-URL.

## What it is (the concept)

**File upload security** — and more broadly **safe path construction** — is the discipline of ensuring that filenames or paths supplied to a web application cannot be manipulated to read files outside an intended directory (**path traversal**), execute scripts via crafted URLs (**URL/scheme injection**), or trigger unexpected parsing behaviour (**NUL byte injection**). The key vocabulary here is **allowlist validation**: rather than trying to enumerate every dangerous pattern, the implementation first requires a filename to match a narrow positive pattern (known safe extensions, safe character set) before any further processing. Failing closed — throwing an error on any unrecognised input — is the correct default.

## What it defends against

See [Unrestricted File Upload](../../attack/file-upload-security.md).

In the context of opposite-osiris, the threat is not a traditional binary-upload endpoint but rather **filename-controlled media URL construction**: if a filename value were sourced from user input or an untrusted data store and concatenated directly into a `<img src>` attribute, an attacker could supply `../../../etc/passwd`, `javascript:alert(1).svg`, or a percent-encoded variant (`..%2F`) to achieve server-side path traversal or client-side script injection. Because opposite-osiris is a marketing and auth landing site, its rendered HTML is the outermost trust boundary; a single XSS vector here undermines every downstream authentication flow.

## How opposite-osiris implements it

**`apps/opposite-osiris/src/lib/media-security.mjs`** is the authoritative gate. It defines two compiled regular expressions at module load time:

```js
const SAFE_PUBLIC_ASSET_PATTERN = /^[-A-Za-z0-9._%() ]+\.(?:avif|gif|jpe?g|png|svg|webp)$/u;
const BLOCKED_PATH_PATTERN = /(?:^|[\\/])\.\.(?:[\\/]|$)|[\\/]|\0|^[a-z][a-z0-9+.-]*:/iu;
```

`SAFE_PUBLIC_ASSET_PATTERN` enforces an explicit **extension allowlist** (`avif`, `gif`, `jpeg`/`jpg`, `png`, `svg`, `webp`) and permits only a safe character set in the basename. `BLOCKED_PATH_PATTERN` rejects: `..` traversal sequences (with any surrounding separator), nested slashes, NUL bytes (`\0`), and any **URL scheme** prefix (`javascript:`, `data:`, `https:`, `vbscript:`, etc.).

The exported `safePublicAssetPath` function (lines 27-38) runs both patterns against the **raw** filename and again against `decodeURIComponent(fileName)`, defeating double-encoding bypasses. If either check fails, the function **throws** — it never returns a fallback path. Passing inputs are percent-encoded per segment and assembled as `${baseUrl}/assets/${encodedSegments}`.

**`apps/opposite-osiris/src/components/sections/MediaAssetsSection.astro`** (line 10) is the sole consumer of asset paths in the media section:

```ts
const assetPath = (fileName: string): string => safePublicAssetPath(fileName, import.meta.env.BASE_URL);
```

No raw string concatenation of filenames exists in the component; every path flows through the helper.

The same module also exports `assertSafeSvg` / `isSafeSvg` (lines 64-104), which guard any future user-supplied SVG against forbidden elements (`<script>`, `<foreignObject>`, `<iframe>`, `<embed>`, `<object>`, `<use>`), inline event handlers (`on*=`), dangerous `href` schemes (`javascript:`, `vbscript:`, `data:text`), and enforces a 256 KiB size cap — ready for the moment opposite-osiris accepts avatar or logo uploads.

## How we know it is applied

**`apps/opposite-osiris/scripts/security/ctf/03-media-url.mjs`** is a dedicated security gate that exercises `safePublicAssetPath` directly. It asserts acceptance of five checked-in asset names and rejection of ten crafted payloads including `../secret.svg`, `..%2Fsecret.svg`, `javascript:alert(1).svg`, `data:image/svg+xml,...`, `payload.svg\0.png`, and `nested/file.svg`:

```js
assert.throws(
  () => safePublicAssetPath(name, '/'),
  /Unsafe public asset path/u,
  `${name} should be rejected`
);
```

It also asserts structurally that `MediaAssetsSection.astro` contains `safePublicAssetPath` and does **not** contain raw path concatenation. This gate is registered under the `test:security:ctf` npm script (`package.json`) and is orchestrated by `scripts/security/ctf/run-all.mjs`, which imports it alongside the other hardening checks. The suite runs inside a container via `scripts/container-only.mjs`, meaning it cannot be accidentally executed against a host environment.

## Reference

The [OWASP File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html) is the canonical reference for safe file-handling controls; it covers extension allowlists, MIME sniffing, path normalisation, and sandboxed serving. The implementation in opposite-osiris specifically follows the cheat sheet's guidance on combining allowlist extension validation with path normalisation (including double-decode) and failing closed on any unrecognised input.

## Residual risk / assumptions

- **Static filenames only.** `safePublicAssetPath` is documented to be used for checked-in public assets, not user-controlled uploads. If a future feature passes a value from a database row, query parameter, or API response to this function without an intermediate trust boundary, the allowlist remains the last line of defence — it must not be assumed to sanitise arbitrary user input for storage or serving.
- **No MIME-type verification.** The function validates the filename extension but does not read the file's magic bytes. An SVG file renamed to `payload.png` would pass (though `assertSafeSvg` exists for that case when the content is also inspected).
- **SVG functions are not yet wired to an upload endpoint.** `assertSafeSvg` / `isSafeSvg` are present and tested in the CTF suite but opposite-osiris has no user-facing upload route at this time; the protection is preparatory.
- **`data:` URIs in HTML attributes.** The helper prevents `data:` scheme injection in `src` attributes constructed via `safePublicAssetPath`, but only for paths that flow through it. Any component that builds `src` values via another mechanism is outside this control's scope.
