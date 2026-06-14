# Changelog — `@mini-baas/js`

All notable changes to the Grobase product SDK (and the bundled `baas` CLI) are recorded here.
This package follows [semantic versioning](https://semver.org). Releases publish to npm only on an
explicit `baas-cli-v<semver>` tag (see `.github/workflows/baas-cli-publish.yml`).

## 0.2.0 — initial public release

First release intended for the public npm registry. The SDK is the **public product API**: gateway
routes and service endpoints stay private inside the SDK, so application code only ever calls domain
methods. The surface is **Supabase-shaped** on purpose (`createClient`, `.from(...)`, `.auth`,
`.storage`, `.rpc()`), so migration from Supabase is mostly a dependency swap (see
`wiki/migrate-from-supabase.md`).

### Added
- **Client** — `createClient({ url, anonKey, defaultDatabaseId, timeoutMs, retry })` with built-in
  timeout + retry, talking to the gateway over the public surface.
- **Data** — `.from(table).select/insert/update/delete/upsert(...)` over the engine-agnostic data
  plane (one API across all supported engines), with multi-database selection via
  `defaultDatabaseId` / per-call database id.
- **Auth** — `.auth.signIn/signUp/session(...)`.
- **Storage** — `.storage.from(bucket)` upload / download / list / createBucket / signed URLs.
- **RPC & analytics** — `.rpc(...)` and `.analytics.track(...)`.
- **Typed domain methods** — generated from the live OpenAPI spec (`npm run codegen:all`) so the
  surface stays congruent with the gateway contract.
- **`baas` CLI** (`npx baas …` / bundled bin) — `login`, `functions`, `secrets`, `triggers` for
  deploying serverless functions and managing function secrets/DB-event triggers (gate m61).

### Notes
- Published with npm provenance and `--access public` under the `@mini-baas` scope.
- In this monorepo the SDK is consumed via Docker-managed dependency volumes — do not install it on
  the host for local development (Docker-first).
