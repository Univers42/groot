# BaaS Service-Role Key Confinement — osionos-bridge (website-to-editor trust boundary)

> The bridge keeps the RLS-bypassing BaaS service-role key exclusively in the server process; no path exists for the key to reach a browser, a serialized session, or a Vite-exposed environment variable.

## What it is (the concept)

**Secrets management** in a server-side proxy means ensuring that high-privilege credentials are read from the process environment, used only in server-to-backend calls, and structurally excluded from every channel that could deliver them to an untrusted client. The critical distinction is the **VITE_ prefix boundary**: Vite statically inlines any variable whose name starts with `VITE_` into the browser bundle; variables that lack this prefix remain server-only. The **service-role key** is the PostgreSQL RLS bypass credential — a tenant-level master credential that grants unrestricted read/write access to all rows regardless of row-level security policies.

## What it defends against

See [Credential Theft via Secrets Exposure](../../attack/secrets-management.md). In this application a stolen service-role key would allow any holder to impersonate any workspace owner, read or destroy all tenants' data through the PostgREST/Kong gateway, and permanently invalidate the RLS isolation boundary that separates workspace data from other tenants. XSS in the editor, a compromised browser extension, or a leaked build artifact would each be sufficient exfiltration vectors if the key ever appeared in a client bundle or session token.

## How osionos-bridge implements it

**Key reading — no VITE_ prefix:**
[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs), line 156, inside `configFromEnv()`:

```js
serviceKey: env.SERVICE_ROLE_KEY ?? env.KONG_SERVICE_API_KEY ?? env.BAAS_SERVICE_ROLE_KEY ?? '',
```

All three candidate variable names are deliberately unprefixed. Vite never sees them; they are present only in the Node `process.env` of the bridge server process.

**Key usage — server-side BaaS calls only:**
[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs), lines 453–458, the `baasRest()` function that is the single chokepoint for all PostgREST/Kong REST calls:

```js
async function baasRest(config, fetchImpl, path, { method = 'GET', body, prefer } = {}) {
    requireBaasConfig(config);
    const headers = {
        Accept: 'application/json',
        apikey: config.serviceKey,
        Authorization: `Bearer ${config.serviceKey}`,
    };
```

`baasRest` is called server-side only; the bridge returns opaque application-scoped `osionos_v1.` HMAC tokens to the browser, never the raw key.

**Session serialization exclusion:**
[`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs), line 244 — the session object is JSON-serialized and a negative regex is asserted:

```js
assert.doesNotMatch(serialized, /SERVICE_ROLE|JWT_SECRET|OSIONOS_BRIDGE_SHARED_SECRET|database_password/i);
```

**Vite environment file exclusion:**
[`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs), lines 469–478 — the test reads `.env.example`, `opposite-osiris/.env.example`, and `docker-compose.yml` and asserts:

```js
assert.doesNotMatch(content, /VITE_[A-Z0-9_]*(SERVICE_ROLE|JWT_SECRET|OSIONOS_BRIDGE_SHARED_SECRET|APP_SESSION_SECRET)/);
```

This closes the supply-chain vector: even if a developer copies a secret into an env example file under a `VITE_` name, the test fails.

## How we know it is applied

Both negative tests run as part of `npm run test:bridge`, which is the standard bridge quality gate executed inside Docker. The test names are unambiguous:

- `'creates an owner-scoped app session without database secrets'` — line 237
- `'keeps server-only secrets out of Vite-exposed environment variables'` — line 469

`baasRest` is exercised by the page, workspace, and member route tests in the same suite, confirming the chokepoint is live under test. The suite is run in the `playground` Docker Compose service (same container as the bridge), not on the host, so the test environment matches the production environment.

## Reference

The [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html) defines the principle that secrets must never appear in build artifacts, client-side bundles, or serialized tokens — only in the server runtime that actually needs them. The `VITE_` prefix boundary implemented here is a direct application of that principle: it uses the build tool's own prefixing contract as an architectural enforcement layer rather than relying solely on developer discipline.

## Residual risk / assumptions

- **Bridge process compromise:** if the Node bridge process itself is compromised (e.g., through a malicious npm dependency loaded at runtime), the service key is readable from `process.env`. The 10 080-minute supply-chain hold (`minimum-release-age` in `.npmrc`) and the `pnpm.onlyBuiltDependencies` five-entry allowlist reduce but do not eliminate this surface.
- **Container environment leakage:** the key is passed to the bridge container as a plain environment variable. Any mechanism that dumps container environment (e.g., a debug endpoint, `docker inspect` on a compromised host, or a container escape) would expose it. Secrets injection via Docker secrets or a vault sidecar would harden this; the current design relies on host-level access control.
- **Test coverage scope:** the Vite environment file test checks `.env.example` and `docker-compose.yml` but not developer-created `.env.local` or `.env.production` files — those are gitignored and excluded from the check by `existsSync` skip logic, so a developer typo in a local env file is not caught.
- **Single key rotation path:** there is no automated rotation; if `SERVICE_ROLE_KEY` is leaked it must be rotated manually in both the vault42 store and the running containers.
