# Secrets Management — osionos (the block editor)

> The Vite build pipeline enforces a hard boundary between public configuration and privileged secrets: only explicitly allow-listed `VITE_`-prefixed variables are statically inlined into the browser bundle; server-side credentials (the bridge HMAC secret, the BaaS service-role key, session signing material) are accessible exclusively through `process.env` inside the server-side API package and never enter the Vite client graph.

## What it is (the concept)

**Secrets management** is the discipline of ensuring that credentials, signing keys, and privileged tokens are available only to the runtime context that legitimately needs them — and are provably absent from any context (the browser bundle, version-controlled files, log streams) where they could be read by an adversary. The central control here is **build-time variable gating**: the build tool controls which variables are inlined, and anything not on that allowlist is structurally excluded from the produced artefact. A complementary control is **runtime credential sourcing**: tokens the browser does need (user JWTs) are loaded from in-memory store state at request time, never baked into the compiled code.

## What it defends against

See [Credential Theft via Secrets Exposure](../../attack/secrets-management.md).

In the osionos context the primary threat is an attacker downloading the production JS bundle (or its source map) and extracting the `OSIONOS_BRIDGE_SHARED_SECRET` used for HMAC verification on the `/bridge/session` route, the BaaS service-role key, or the session signing secret. Possession of any one of these would allow forging authenticated bridge requests, impersonating arbitrary users, or escalating privilege against the grobase BaaS without valid credentials.

## How osionos implements it

**1. Explicit build-time allowlist — `vite.config.ts`**

`apps/osionos/app/vite.config.ts` (lines 55–66) defines a `define` block that is the exhaustive list of variables statically inlined into the bundle:

```ts
define: {
  __OBJECT_DATABASE_DISABLE_WASM__: JSON.stringify(env.VITE_OBJECT_DATABASE_DISABLE_WASM === 'true'),
  'import.meta.env.VITE_API_URL':               JSON.stringify(env.VITE_API_URL ?? ''),
  'import.meta.env.VITE_AUTH_MODE':             JSON.stringify(env.VITE_AUTH_MODE ?? ''),
  'import.meta.env.VITE_REQUIRE_BRIDGE_SESSION':JSON.stringify(env.VITE_REQUIRE_BRIDGE_SESSION ?? ''),
  'import.meta.env.VITE_ALLOW_OFFLINE_MODE':    JSON.stringify(env.VITE_ALLOW_OFFLINE_MODE ?? ''),
  'import.meta.env.VITE_BAAS_URL':              JSON.stringify(env.VITE_BAAS_URL ?? ''),
},
```

None of the keys has a name matching a credential (`*_SECRET`, `*_KEY` in privileged sense, `SERVICE_ROLE`, `SESSION_SECRET`). Vite's default `envPrefix` restricts `import.meta.env` exposure to `VITE_`-prefixed variables, so non-prefixed credentials (`OSIONOS_BRIDGE_SHARED_SECRET`, `OSIONOS_APP_SESSION_SECRET`) are structurally invisible to the client graph.

Production source maps are disabled at the same location (`line 105: sourcemap: false`), preventing bundle-level secret recovery through map file extraction.

**2. Server-side secret access — `notion-database-sys/packages/api/src/routes/auth.routes.ts`**

The only reference to `OSIONOS_BRIDGE_SHARED_SECRET` in the entire `src/` tree is at line 90 of the server-side Fastify API package, accessed exclusively via Node's `process.env`:

```ts
const secret = process.env.OSIONOS_BRIDGE_SHARED_SECRET ?? process.env.JWT_SECRET ?? '';
// ...
if (!secret || !verifyBridgeSignature(secret, timestamp, signature, request.body)) {
  return reply.code(401).send({ error: 'Unauthorized bridge request' });
```

This file path (`src/shared/notion-database-sys/packages/api/`) lives outside the Vite client import graph; it is not aliased, not imported by any front-end entry point, and Vite never processes it for the browser bundle.

**3. Runtime JWT sourcing — `src/shared/api/client.ts`**

The API client (`apps/osionos/app/src/shared/api/client.ts`) reads only one static env var at module init:

```ts
export const API_BASE = ((import.meta.env as Record<string, string>)['VITE_API_URL'] ?? '').trim();
```

The user JWT required for authenticated requests is not baked in. It is pulled at call time from the in-memory Zustand store published to `globalThis.__playgroundUserStore` (lines 34–55), so no token value is ever present in compiled bundle code:

```ts
const store = (globalThis as unknown as Record<string, unknown>).__playgroundUserStore as
  | { getState: () => { activeJwt: () => string | null } }
  | undefined;
return store?.getState().activeJwt() || null;
```

## How we know it is applied

The constraint is structural, not advisory. A grep across the app `src/` tree for `SESSION_SECRET`, `SHARED_SECRET`, or `service.role` returns exactly one result — `auth.routes.ts` line 90 above, which is a `process.env` read inside the Node API package that Vite never bundles. No `import.meta.env.*_SECRET` or `import.meta.env.*_KEY` reference appears in the Vite client graph. The define block is the exhaustive allowlist: any variable not named there is absent from the compiled output by construction.

The quality gate `npm run test:quality` (`docker-run.sh test:quality` → graph-engine tsc → root tsc → `eslint src/ packages/ --max-warnings=0`) type-checks and lints the full client source on every merge candidate. Because the server-side `packages/api/` tree is **excluded** from the root `tsconfig.json` and from ESLint's `eslint.config.js`, any accidental import of a server module into the client graph would produce a module-not-found type error that fails the tsc pass before a build could proceed.

## Reference

The [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html) prescribes strict separation of credentials by runtime context, explicit lifecycle controls, and the elimination of secrets from version-controlled artefacts and build outputs. This implementation directly instantiates its "secrets should not be accessible to client-side code" and "avoid embedding secrets in build artefacts" recommendations through Vite's define-block gating and disabled source maps.

## Residual risk / assumptions

- **VITE_-prefixed keys that are public-intent only:** Vite exposes all `VITE_`-prefixed variables to `import.meta.env` by default. If a future developer adds a credential under a `VITE_`-prefixed name (e.g., `VITE_API_KEY`), it will enter the bundle with no lint-level warning. There is no automated check that distinguishes public config from credential-shaped `VITE_` vars.
- **Container secret injection:** The control assumes that `OSIONOS_BRIDGE_SHARED_SECRET` is injected into the bridge server's container environment at runtime (via the root `.env.local` / Docker Compose) and never written into any file that enters the image layer. This is a deployment trust assumption, not enforced by app code.
- **Source maps stripped at the Vite level:** `sourcemap: false` prevents `.map` file generation, but the Dockerfile.prod reference in the config comment implies the production image build provides a secondary strip as belt-and-suspenders. The app-level control alone is sufficient only if the Vite config is the build path used in production.
- **No secret scanning CI gate:** There is no `trufflehog` or `gitleaks` pre-commit hook in the osionos submodule itself. Secret-scanning at the monorepo level (`make baas-security-scan` / TruffleHog) is the backstop, but it runs against the backend (`apps/grobase`) scope, not the frontend submodule.
