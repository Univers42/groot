# Captcha / Bot Protection — opposite-osiris (marketing + auth website)

> Every state-changing auth call (login, register, password recovery) requires a valid Cloudflare Turnstile token that is verified server-side before any credential or identity operation runs.

## What it is (the concept)

**CAPTCHA / bot-protection** is a challenge–response mechanism interposed between a human-facing form and the back-end action it triggers. A **challenge widget** (here: Cloudflare Turnstile) runs browser-side heuristics and produces a cryptographically-signed **response token**. The token is submitted with the form and **verified server-side** against the issuing authority — in this case the Cloudflare `siteverify` API — before any credential operation proceeds. Because the token is single-use and bound to the issuing edge node, replaying or forging it fails at the verification step.

## What it defends against

See [captcha-bot-protection](../../attack/captcha-bot-protection.md).

Automated bots cannot obtain valid Turnstile tokens at scale without solving real browser-environment challenges. In the opposite-osiris context this directly blocks three bot-driven threat classes: **credential stuffing** (bulk replaying of leaked username/password pairs against `/login`), **mass account creation** (automated bulk registration to abuse free-tier resources or evade bans), and **password-reset spam** (bulk `/recover` calls harvesting valid emails or flooding inboxes). All three call paths are gated behind the same `protectedAction` wrapper, so none can be reached without first clearing the challenge.

## How opposite-osiris implements it

### 1. Server-side verification — `protectedAction` gate

`apps/opposite-osiris/scripts/auth-gateway.mjs` lines 225–231 define `verifyTurnstile`, which POSTs the submitted token to Cloudflare's canonical siteverify endpoint:

```js
// auth-gateway.mjs  lines 225–231
async function verifyTurnstile(token, ip) {
    if (config.turnstileBypassLocal && (!token || token === 'localhost-turnstile-token')) return true;
    if (!config.turnstileSecret || !token) return false;
    const form = new URLSearchParams({ secret: config.turnstileSecret, response: token, remoteip: ip });
    const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body: form });
    const payload = await response.json().catch(() => ({}));
    return payload?.success === true;
}
```

`verifyTurnstile` is called unconditionally inside `protectedAction` (lines 689–703), which wraps every login, register, and recover handler. A `success !== true` result immediately returns `HTTP 403` with body `"Anti-abuse verification failed."` — the downstream credential logic never runs:

```js
// auth-gateway.mjs  lines 696–702
const validTurnstile = await verifyTurnstile(String(payload.turnstileToken ?? ''), ip);
if (!validTurnstile) {
    await audit(`${action}_turnstile_failed`, request, { email: payload.email });
    json(response, 403, { message: 'Anti-abuse verification failed.' });
    return;
}
```

The `TURNSTILE_SECRET_KEY` env var is the server-side secret sent to Cloudflare; its value is never echoed in logs or responses.

### 2. Client-side widget — `mountTurnstile`

`apps/opposite-osiris/src/scripts/main.ts` lines 237–265 render the Turnstile widget into every auth portal. The widget injects a signed token into a hidden `<input data-turnstile-token>`. When no site key is configured (local dev), the hidden field receives the literal string `localhost-turnstile-token`, which the gateway accepts only when `turnstileBypassLocal` is also true — a flag the startup guard blocks in production (see below):

```ts
// main.ts  lines 244–247
if (!authConfig.turnstileSiteKey) {
    token.value = 'localhost-turnstile-token';
    container.hidden = true;
    return;
}
```

The corresponding HTML in the portal template (`main.ts` lines 1121–1122) wires the widget container and the hidden field into every auth form:

```html
<div class="turnstile-box" data-turnstile-widget aria-label="Anti-abuse verification"></div>
<input type="hidden" name="turnstile_token" data-turnstile-token />
```

### 3. Test-key neutralisation — `auth-config.ts`

`apps/opposite-osiris/src/lib/auth-config.ts` lines 13–24 strip all three known Cloudflare test site keys to the empty string before the key reaches the widget renderer, preventing a misconfigured deployment from silently running Turnstile in a mode that always passes:

```ts
const CLOUDFLARE_TURNSTILE_TEST_SITE_KEYS = new Set([
    '1x00000000000000000000AA',
    '2x00000000000000000000AB',
    '3x00000000000000000000FF',
]);
// …
turnstileSiteKey: CLOUDFLARE_TURNSTILE_TEST_SITE_KEYS.has(rawTurnstileSiteKey) ? '' : rawTurnstileSiteKey,
```

## How we know it is applied

### Startup fail-closed guard

`apps/opposite-osiris/scripts/auth/guards.mjs` — `collectStartupViolations` (lines 51–77) — is called at gateway boot. When `config.siteUrl` resolves to a public HTTPS origin, any of the following aborts the process with exit code 1:

```js
// guards.mjs  lines 55–66
if (config.turnstileBypassLocal) {
    violations.push(
        'TURNSTILE_BYPASS_LOCAL is true on a public https origin — Turnstile would be fully bypassed. Set it to false in production.',
    );
}
// …
if (!config.turnstileSecret) {
    violations.push('TURNSTILE_SECRET_KEY is missing — Turnstile cannot be verified in production.');
}
```

`enforceStartupGuards` (lines 79–87) calls `process.exit(1)` on any violation, so the gateway cannot start in production without a valid secret key and with the bypass disabled.

### Unit test suite

`apps/opposite-osiris/scripts/security/unit/guards.mjs` runs three pure checks with no network dependency:

- `isProductionOrigin` correctly classifies `https://localhost:4322` (not production) vs `https://prismatica.app` (production).
- A localhost config with bypass flags produces **zero** startup violations (local dev is not blocked).
- A public-HTTPS config with every anti-abuse control off produces **five or more** violations and would never boot.

```js
// security/unit/guards.mjs  lines 60–65
name: 'public https with anti-abuse disabled is refused',
run: async () => {
    const violations = collectStartupViolations(insecureProdConfig);
    assert.ok(violations.length >= 5, `expected >=5 violations, got ${violations.length}: ${violations.join(' | ')}`);
    return passed(`Insecure prod config produced ${violations.length} startup violations.`);
},
```

### Integration test

`apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs` spawns the real auth-gateway subprocess to confirm it refuses to start under an insecure public-HTTPS configuration and still boots under localhost — a live exercise of the same guard.

## Reference

[OWASP Top 10:2021 — A07 Identification and Authentication Failures](https://owasp.org/Top10/2021/A07_2021-Identification_and_Authentication_Failures/index.html)

OWASP explicitly lists "permits automated attacks such as credential stuffing" as the primary symptom of this category and recommends challenge mechanisms to prevent "automated credential stuffing, brute force, and stolen credential reuse attacks."

## Residual risk / assumptions

- **Cloudflare availability:** `verifyTurnstile` calls `challenges.cloudflare.com` synchronously on every protected request. A Cloudflare outage or network partition from the gateway host will cause `fetch` to throw; the `.catch(() => ({}))` path returns `{}`, so `payload?.success` is `undefined`, the function returns `false`, and the request is rejected. This is fail-closed but means legitimate users are also locked out during an outage.
- **Widget-only enforcement:** Turnstile validation happens at the HTTP handler layer, not at the BaaS (grobase/Kong) layer. A request that reaches the BaaS APIs directly — bypassing the auth-gateway — is not subject to this check. The gateway should be the sole public ingress for auth mutations.
- **Bypass scope:** `TURNSTILE_BYPASS_LOCAL=true` disables Turnstile entirely for all requests bearing the `localhost-turnstile-token` sentinel. The startup guard prevents this flag from reaching a public-HTTPS origin, but any misconfiguration of `siteUrl` that makes a production host appear as localhost would silently neutralise the control.
- **Token binding:** `remoteip` is forwarded to Cloudflare to improve signal quality. Accurate IP attribution depends on `AUTH_TRUSTED_PROXY_HOPS` being correctly set; the startup guard enforces `>= 1` in production, but an incorrect hop count would let the gateway forward a proxy IP instead of the real client IP, weakening per-IP signal to Cloudflare.
- **No coverage of non-auth endpoints:** rate-limiting and Turnstile apply only to login, register, and recover. Public read endpoints (e.g., marketing content) are not gated and are outside the scope of this control.
