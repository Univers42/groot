# Bridge Redirect-Target Allowlist — auth-gateway (the auth BFF)

> After the osionos-bridge responds, the gateway enforces that any `redirectUrl` in the bridge response must begin with the configured osionos origin (`PUBLIC_OSIONOS_APP_URL`); any other value is rejected with a 502 and a structured audit event before the URL ever reaches the client.

## What it is (the concept)

**Server-Side Request Forgery (SSRF)** and its sibling **open redirect** both exploit a server's willingness to act on attacker-controlled URLs. In an open-redirect variant the server does not make the outbound request itself, but it forwards a crafted `Location` value to a trusting browser, which then navigates away — enabling phishing, OAuth-token theft, or cookie-stealing redirects. The defensive primitive is an **allowlist**: rather than trying to detect malicious URLs, the gateway only accepts URLs whose prefix matches a pre-approved origin. Any URL outside that prefix is rejected unconditionally, no matter its form.

## What it defends against

See [Server-Side Request Forgery (SSRF)](../../attack/ssrf.md).

In this application the auth-gateway acts as a Backend-For-Frontend (BFF): after a successful login it calls the osionos-bridge to establish a workspace session and then reads a `redirectUrl` from the bridge's JSON response. If an attacker could influence that response — through a compromised bridge container, a misconfigured upstream, or a response-smuggling attack — they could inject an arbitrary redirect target. Without the allowlist check the gateway would silently forward that target to the browser, redirecting authenticated users to an attacker-controlled page.

## How auth-gateway implements it

**Configuration — [`apps/opposite-osiris/scripts/auth-gateway.mjs` line 69](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)**

```js
osionosAppUrl: (process.env.PUBLIC_OSIONOS_APP_URL ?? '').replace(/\/$/, ''),
```

`PUBLIC_OSIONOS_APP_URL` is read at startup and normalized (trailing slash stripped) into `config.osionosAppUrl`. This is the sole permitted redirect origin.

**Enforcement — [`apps/opposite-osiris/scripts/auth-gateway.mjs` lines 1113-1117](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)**

```js
if (result.ok && config.osionosAppUrl && typeof body?.redirectUrl === 'string'
    && !body.redirectUrl.startsWith(config.osionosAppUrl)) {
  await audit('osionos_bridge_redirect_rejected', request, { email, status: result.status });
  json(response, 502, { message: 'osionos bridge returned an unexpected redirect target.' });
  return;
}
```

The guard fires on every successful bridge response that carries a `redirectUrl`. The check is a strict prefix comparison — the redirect is allowed only if it begins with the expected origin. When the check fails, the gateway emits a structured audit event (`osionos_bridge_redirect_rejected`) and terminates the handler with a 502 before any value reaches the client.

## How we know it is applied

**Compose wiring — [`docker-compose.yml` line 373](../../../../docker-compose.yml)**

```yaml
# osionos origin used to validate the bridge redirect target (LOW-3).
PUBLIC_OSIONOS_APP_URL: ${PUBLIC_OSIONOS_APP_URL:-https://localhost:3001}
```

The environment variable is injected into the `auth-gateway` service at container start. The inline comment explicitly names its security purpose (`LOW-3` references the internal risk register). Because `config.osionosAppUrl` is derived directly from this variable (line 69), the allowlist is always active in every deployed environment — the default `https://localhost:3001` covers local development, and production overrides the variable via the vault-managed `.env.local`.

The audit event `osionos_bridge_redirect_rejected` provides an observable signal: any unexpected redirect attempt surfaces in the structured audit log, enabling alerting without requiring a separate probe.

## Reference

The [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html) recommends allowlisting as the primary mitigation layer, specifically advocating for restricting destinations to a known set of safe values rather than attempting to detect and block malicious ones. This implementation applies that guidance at the BFF boundary, where the gateway has full control over which URLs may leave the server context.

## Residual risk / assumptions

- **Allowlist scope is origin-only.** The check is a prefix match on `config.osionosAppUrl` (e.g., `https://localhost:3001`). A bridge response returning `https://localhost:3001.evil.com/...` would pass if the attacker controls a domain whose prefix happens to match — though in practice the origin string includes the scheme and hostname without a trailing slash, making this unlikely unless the osionos origin itself is a bare IP or short string with no trailing path separator.
- **Bridge confidentiality is assumed.** The redirect-target check is only a second line of defense: it protects against a compromised or spoofed bridge response. It does not protect against a fully compromised bridge that chooses not to include a `redirectUrl` field (the path at line 1113 only fires when `typeof body?.redirectUrl === 'string'`).
- **Env-var correctness is assumed.** If `PUBLIC_OSIONOS_APP_URL` is left unset or set to an empty string, `config.osionosAppUrl` evaluates to `''`, and the guard's `config.osionosAppUrl` truthiness check short-circuits — making the allowlist dormant. Production deployments must ensure this variable is always populated.
- **Outbound bridge URL is hardcoded to `OSIONOS_BRIDGE_URL`** and is not validated as an allowlisted destination at the point of the `fetch` call. If the bridge URL itself were attacker-influenced, the gateway could be directed to make a request to an internal network target — a classic SSRF vector not covered by this redirect-target guard.
