# CORS Misconfiguration — platform / infrastructure (cross-cutting)

> The osionos-bridge enforces a single, explicitly configured allowed origin on every response and every preflight, so no arbitrary third-party site can drive authenticated cross-origin bridge calls.

## What it is (the concept)

**Cross-Origin Resource Sharing (CORS)** is the browser mechanism that decides whether a script on
one origin may read a response from a different origin. The server controls this through
`Access-Control-Allow-Origin` response headers. A **CORS misconfiguration** occurs when that header
is set to `*` (wildcard), reflected blindly from the `Origin` request header, or is otherwise broader
than the set of trusted origins — allowing any site to issue credentialed cross-origin requests on
behalf of a logged-in user. The correct countermeasure is an **explicit allowlist**: the server
returns only the origins it deliberately trusts and rejects all others at the CORS layer.

## What it defends against

See [CORS Misconfiguration](../../attack/cors-misconfiguration.md). In this application the
osionos-bridge holds the BaaS service-role key and proxies PostgREST/Kong for workspace persistence,
chat, feed, permissions, and LiveKit token minting. A wildcard or reflected-origin policy on this
service would let any page on the internet issue authenticated persistence calls using a visitor's
session cookie, enabling data exfiltration or workspace manipulation without the user's knowledge.

## How the platform implements it

**Configuration layer — compose**

In [`docker-compose.yml`](../../../../docker-compose.yml) (line 42) the bridge service receives:

```yaml
OSIONOS_ALLOWED_ORIGIN: ${OSIONOS_ALLOWED_ORIGIN:-https://localhost:3001}
```

The default is a concrete `https://` origin — not `*`. The desktop/Electron overlay in
[`docker-compose.local.yml`](../../../../docker-compose.local.yml) (lines 22–23) substitutes the
Electron renderer origin:

```yaml
OSIONOS_APP_URL: app://osionos
OSIONOS_ALLOWED_ORIGIN: app://osionos
```

Both values are specific scheme+host strings; neither compose file ever sets a wildcard.

**Enforcement layer — bridge-api.mjs**

[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs)
is the bridge's Node HTTP server. On startup it reads the env var into a config object (line 139):

```js
allowedOrigin: env.OSIONOS_ALLOWED_ORIGIN ?? appUrl,
```

Every JSON response path (line 1328) and every SSE stream response (line 1442) emits the header
from that config value — never from the raw `Origin` request header:

```js
'access-control-allow-origin': config.allowedOrigin,
'access-control-allow-credentials': 'true',
vary: 'Origin',
```

Preflight `OPTIONS` responses follow the same pattern (lines 1505–1513), also constraining
`access-control-allow-methods` and `access-control-allow-headers` to an explicit set.

**Dynamic widening is localhost-scoped only**

`requestOriginConfig()` (lines 1335–1344) allows the allowed origin to be narrowed to the actual
request `Origin` value — but only for origins that match one of four recognized patterns:
`http(s)://localhost:<port>`, `http(s)://127.0.0.1:<port>`, `tauri://localhost`,
`https://tauri.localhost`, or `app://osionos`. External, internet-routable origins are never
reflected; the static `config.allowedOrigin` value is returned unchanged.

## How we know it is applied

The `OSIONOS_ALLOWED_ORIGIN` environment variable is injected by the root compose into the
`osionos-bridge` service at container start. Any request to the bridge from an unlisted origin
receives the fixed allowed-origin header (defaulting to `https://localhost:3001`); the browser's
CORS enforcement then blocks the cross-origin read. The `vary: Origin` header is present on every
response, signalling to CDNs and caches that the CORS decision is per-request rather than fixed —
preventing a cached wildcard or wrong-origin response from leaking to a different client.

The health-check wired into the same service definition (line 86 of `docker-compose.yml`) confirms
the bridge is alive on every `make all` run; the bridge cannot respond to health probes without the
full request-handling path — including the CORS header emission — being active.

## Reference

The OWASP [HTML5 Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html)
dedicates a section to cross-origin trust and documents the specific risks of wildcard and
reflected-origin policies. This implementation follows its guidance by using an explicit allowlist
configured out of band (environment variable), keeping `vary: Origin` to prevent cache poisoning,
and pairing the `Access-Control-Allow-Origin` header with `Access-Control-Allow-Credentials: true`
only when the origin is in the trusted set — never both simultaneously for `*`.

## Residual risk / assumptions

- **Trust assumption on the allowlist value**: the default `https://localhost:3001` is safe in a
  local development context. If `OSIONOS_ALLOWED_ORIGIN` is misconfigured in a deployment (e.g.
  set to `*` via `.env.local` override), the compose-level default no longer applies and the
  protection evaporates. No CI gate currently validates that the runtime value is not a wildcard.
- **Localhost widening**: the `requestOriginConfig()` logic accepts any `localhost` or `127.0.0.1`
  port. In a shared-development environment where multiple users share a host, this is broader than
  a single-origin allowlist; it does not protect against other localhost services issuing cross-origin
  calls to the bridge.
- **Submodule boundary**: CORS header emission lives in `apps/osionos/app/scripts/bridge-api.mjs`
  (the osionos submodule). Root-repo configuration only supplies the env var; it cannot enforce the
  header logic itself. A change to `bridge-api.mjs` that bypasses `config.allowedOrigin` would not
  be caught by the root-repo test suite.
- **No CORS tests in the root CI**: there is no automated test in `.github/workflows/` that sends a
  cross-origin preflight to the running bridge and asserts it is rejected; the control relies on
  correct configuration and code review of the submodule.
