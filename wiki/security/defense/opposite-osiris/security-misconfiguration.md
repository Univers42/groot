# Security Misconfiguration — opposite-osiris (marketing + auth website)

> The auth gateway refuses to bind when any anti-abuse control that is safe to disable in development is left disabled against a public HTTPS origin, preventing convenient dev defaults from silently becoming production vulnerabilities.

## What it is (the concept)

**Security misconfiguration** occurs when a system ships with insecure default settings, incomplete hardening, or configuration options that are intentionally relaxed for developer convenience but never tightened before deployment. The danger is asymmetric: a single overlooked flag — a bypassed CAPTCHA, a disabled email-verification step, a missing trusted-proxy count — can nullify controls that took weeks to build. **Fail-closed startup guards** are a mitigation pattern where the process itself detects an unsafe configuration and terminates before accepting any network connection, making misconfiguration an explicit, loud boot failure rather than a silent runtime regression.

## What it defends against

See [Security Misconfiguration Exploitation](../../attack/security-misconfiguration.md).

In the context of opposite-osiris, the concrete threat is a developer copying a local `.env` file — or leaving a Docker environment variable at its development default — into a production deployment. Without a guard, `TURNSTILE_BYPASS_LOCAL=true` would accept any login without CAPTCHA validation; `AUTH_REQUIRE_EMAIL_VERIFICATION=false` would mint confirmed accounts with no email proof; a missing `SERVICE_ROLE_KEY` would make privileged auth operations fail silently; and `AUTH_TRUSTED_PROXY_HOPS=0` would make the per-IP rate limiter read the attacker-controlled `X-Forwarded-For` header instead of the proxy-injected real IP, defeating throttling entirely.

## How opposite-osiris implements it

The control lives in three files that form a detection → enforcement → test chain.

**[`apps/opposite-osiris/scripts/auth/guards.mjs`](../../../../apps/opposite-osiris/scripts/auth/guards.mjs)** implements the detection logic in three exported functions:

- `isProductionOrigin(siteUrl)` — returns `true` only when the scheme is `https:` **and** the host is not `localhost`, `127.*`, `::1`, `*.local`, `*.localhost`, `*.internal`, or any RFC 1918 range (`10.*`, `192.168.*`, `172.16-31.*`). All other origins are treated as local/dev and bypass the checks.
- `collectStartupViolations(config)` — collects human-readable violation strings for each unsafe flag when `isProductionOrigin` is true: `TURNSTILE_BYPASS_LOCAL`, absent `TURNSTILE_SECRET_KEY`, `AUTH_REQUIRE_EMAIL_VERIFICATION=false`, `AUTH_TRUSTED_PROXY_HOPS < 1`, and absent `SERVICE_ROLE_KEY`.
- `enforceStartupGuards(config, { logger, exit })` — logs every violation under the prefix `[auth-gateway] FATAL: refusing to start with an insecure production configuration:` then calls `exit(1)`.

```js
// guards.mjs lines 79-86
export function enforceStartupGuards(config, { logger = console, exit = (code) => process.exit(code) } = {}) {
    const violations = collectStartupViolations(config);
    if (violations.length === 0) return true;
    logger.error('[auth-gateway] FATAL: refusing to start with an insecure production configuration:');
    for (const violation of violations) logger.error(`  - ${violation}`);
    logger.error('[auth-gateway] Fix the configuration above or run against a local/non-https origin for development.');
    exit(1);
    return false;
}
```

**[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)** wires the guard at module load, before any network listener is created:

```js
// auth-gateway.mjs line 1139
enforceStartupGuards(config, { logger: console });

createServer(async (request, response) => { ... }).listen(...);
```

Because `enforceStartupGuards` precedes `createServer(...).listen`, the process terminates before binding to any port when the configuration is unsafe. There is no window where the server briefly accepts connections under a misconfigured state.

## How we know it is applied

**[`apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs`](../../../../apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs)** is a subprocess-level behavioral test that spawns the real `auth-gateway.mjs` entrypoint (not a mock) with controlled environment variables and asserts the observed exit behavior:

```js
// 11-gateway-failclosed.mjs lines 126-140 — insecure-prod path
const handle = spawnGateway({
    PUBLIC_SITE_URL: 'https://evil.example.com',
    TURNSTILE_BYPASS_LOCAL: 'true',
    AUTH_REQUIRE_EMAIL_VERIFICATION: 'false',
    TURNSTILE_SECRET_KEY: '',
    AUTH_TRUSTED_PROXY_HOPS: '0',
    SERVICE_ROLE_KEY: '',
    AUTH_GATEWAY_PORT: String(randomPort()),
});
const result = await waitForExit(handle, 6000);
assert.equal(result.code, 1, ...);
assert.ok(/refusing to start/i.test(handle.err()), ...);
```

A second check (lines 143-167) spawns the same gateway with `PUBLIC_SITE_URL: 'https://localhost:4322'` and asserts that it does **not** exit with code 1 due to a guard violation, confirming that the guard is inert for local origins. Both paths exercise the deployed entrypoint binary, not an isolated unit of the guard module.

## Reference

The guard pattern directly addresses **A05:2021 Security Misconfiguration** as defined by the OWASP Top 10: [https://owasp.org/Top10/2021/A05_2021-Security_Misconfiguration/](https://owasp.org/Top10/2021/A05_2021-Security_Misconfiguration/). That category explicitly calls out missing hardening, unnecessarily enabled features, and default credentials or settings left unchanged as the primary root causes. The fail-closed approach — rejecting misconfigured starts rather than logging a warning and continuing — corresponds to OWASP's recommended hardening posture of making the secure configuration the only configuration that reaches production.

## Residual risk / assumptions

- **Scope is limited to the five checked variables.** A new environment variable introduced to the gateway that has a dangerous dev default will not be caught unless a corresponding violation is added to `collectStartupViolations`. The guard is not self-extending.
- **The guard fires only on public HTTPS origins.** A deployment behind a TLS-terminating reverse proxy that presents a non-HTTPS `PUBLIC_SITE_URL` to the gateway process (e.g., `http://internal-lb/`) would be treated as local and skip all checks, even if it is publicly reachable.
- **`exit` is injectable for testing but defaults to `process.exit`.** If a future refactor removes the injection or wraps the guard in a try/catch, the process could survive a guard violation. The behavioral subprocess test in `11-gateway-failclosed.mjs` would catch this regression only when its prerequisites (`@mini-baas/js` resolvable) are met.
- **Secrets are referenced by environment variable name only.** The guard checks that `SERVICE_ROLE_KEY` and `TURNSTILE_SECRET_KEY` are non-empty strings; it does not validate that they are well-formed or authorized keys. A placeholder value would satisfy the check.
