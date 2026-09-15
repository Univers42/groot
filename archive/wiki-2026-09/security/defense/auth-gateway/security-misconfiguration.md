# Security Misconfiguration — auth-gateway (the auth BFF)

> auth-gateway enforces a fail-closed startup contract: if any anti-abuse control is disabled under a public-HTTPS origin, the process refuses to boot with `exit(1)` and scrubs internal error detail from every response body it does emit.

## What it is (the concept)

**Security misconfiguration** occurs when a system ships with settings that are safe in a development environment but dangerous in production — or when configuration is absent where it is required. The risk is not a code defect but a **deployment-time omission**: a flag that silences CAPTCHA, an environment variable that bypasses email verification, or a missing secret key. OWASP A05 covers the full class, from exposed stack traces and default credentials to server-side misconfiguration that widens the attack surface without any single-line bug being written.

## What it defends against

See [Security Misconfiguration Exploitation](../../attack/security-misconfiguration.md).

The primary threat in this app is a **convenient local-dev bypass silently surviving into a production deployment**. `TURNSTILE_BYPASS_LOCAL=true` makes Cloudflare Turnstile always pass (eliminating bot friction); `AUTH_REQUIRE_EMAIL_VERIFICATION=false` lets any address create a confirmed account without receiving a real email. Both are correct for offline development and catastrophic for a live site. A secondary threat is **information disclosure**: returning raw Postgres errors, file paths, or Node.js stack frames from a failed auth request gives an attacker a detailed map of the back-end.

## How auth-gateway implements it

**Fail-closed startup guard** — [`apps/opposite-osiris/scripts/auth/guards.mjs`](../../../../apps/opposite-osiris/scripts/auth/guards.mjs)

`isProductionOrigin` (lines 26-47) classifies any `PUBLIC_SITE_URL` whose protocol is `https:` and whose hostname is not `localhost`, `127.*`, `::1`, `*.local`, `*.localhost`, `*.internal`, or an RFC-1918 range as a production origin. When that condition is true, `collectStartupViolations` (lines 51-77) checks five invariants and returns a human-readable violation for each one breached:

```js
if (config.turnstileBypassLocal) violations.push('TURNSTILE_BYPASS_LOCAL is true on a public https origin …');
if (!config.requireEmailVerification) violations.push('AUTH_REQUIRE_EMAIL_VERIFICATION is false …');
if (!config.turnstileSecret) violations.push('TURNSTILE_SECRET_KEY is missing …');
if (Number(config.trustedProxyHops ?? 0) <= 0) violations.push('AUTH_TRUSTED_PROXY_HOPS must be >= 1 …');
if (!config.serviceKey) violations.push('SERVICE_ROLE_KEY is missing …');
```

`enforceStartupGuards` (lines 79-87) logs `[auth-gateway] FATAL: refusing to start with an insecure production configuration:` followed by each violation, then calls `exit(1)`. The function is invoked at module scope in [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) at line 1139, unconditionally, before `createServer` is called — so no request can ever be served from a misconfigured production process.

**Generic error responses / no internal-detail leak** — [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)

The `json()` helper (line 119) sets `cache-control: no-store` on every JSON response, preventing auth errors from being stored in intermediary caches. The top-level `catch` (lines 1159-1161) maps any thrown error with `status >= 500` to the fixed string `'Authentication gateway error.'`, discarding the original message entirely:

```js
json(response, status, { message: status >= 500 ? 'Authentication gateway error.' : String(error?.message ?? 'Request error.') });
```

`humanAuthMessage` (lines 344-347) extracts user-facing text from upstream BaaS responses and hard-caps it at 240 characters, preventing long upstream payloads (which can contain SQLSTATE codes or internal details) from being forwarded verbatim.

## How we know it is applied

[`apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs`](../../../../apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs) spawns the real `auth-gateway.mjs` process as a subprocess under a fabricated insecure environment and asserts:

```js
assert.equal(result.code, 1, `expected exit code 1 …`);
assert.ok(/refusing to start/i.test(handle.err()), `stderr should mention "refusing to start" …`);
```

A companion check confirms that a `PUBLIC_SITE_URL=https://localhost:4322` config does **not** trigger the guard and the process reaches the listening state. These tests run inside the built Node image where `@mini-baas/js` is resolvable; they skip (never falsely pass) on a bare checkout without the SDK.

The `noInternalLeak` helper in [`apps/opposite-osiris/scripts/security/_shared.mjs`](../../../../apps/opposite-osiris/scripts/security/_shared.mjs) (lines 182-197) is used across the security suite to assert that no response body contains `'stack trace'`, `'/app/'`, `'/usr/'`, `'postgres'`, `'sqlstate'`, `'syntax error at or near'`, or any Node.js stack-frame pattern (`at <identifier>:<line>:<col>`).

## Reference

[A05 Security Misconfiguration — OWASP Top 10:2021](https://owasp.org/Top10/2021/A05_2021-Security_Misconfiguration/) catalogues misconfiguration as one of the most pervasive vulnerability classes, noting that moving from development to production is a prime vector for unsafe defaults to slip through. The controls here address the specific sub-category OWASP describes as "unnecessary features enabled or installed" and "missing appropriate security hardening across any part of the application stack."

## Residual risk / assumptions

- The guard only fires when `PUBLIC_SITE_URL` is set correctly. If the operator leaves it pointing to a `localhost` URL in a production deployment (intentional or accidental), the guard silently passes and none of the five invariants are enforced.
- Proxy-hop misconfiguration (`AUTH_TRUSTED_PROXY_HOPS`) is caught only when the value is `<= 0`; an incorrect positive integer (e.g., `2` when only one proxy hop exists) is not detected, meaning per-IP rate-limiting could read a spoofed `X-Forwarded-For` address.
- The `humanAuthMessage` 240-character cap truncates but does not sanitize; if an upstream BaaS response embeds user-controlled data inside an error message field, that data could still reach the client (it will not contain internal stack paths, but could contain reflected content).
- The information-leak scrubbing (`noInternalLeak`) is a test-time assertion, not a runtime middleware filter — a future code path that calls a different response helper could bypass it without a failing guard.
- Secrets referenced by name (`TURNSTILE_SECRET_KEY`, `SERVICE_ROLE_KEY`) are validated only for presence (non-empty string), not for format or validity; a placeholder value such as `"placeholder"` passes the guard.
