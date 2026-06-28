# Transport Security (TLS) — opposite-osiris (marketing + auth website)

> Every byte exchanged between the browser and opposite-osiris travels over an encrypted channel; the browser is instructed never to fall back to plaintext, session cookies are restricted to HTTPS, and outbound SMTP connections refuse to proceed without a verified server certificate.

## What it is (the concept)

**Transport Layer Security (TLS)** is the cryptographic protocol that provides **confidentiality**, **integrity**, and **server authentication** for data in transit between a client and a server. **HTTP Strict Transport Security (HSTS)** is a browser policy mechanism, delivered as a response header, that forces all future connections to a given origin over HTTPS for a declared period — closing the window an SSL-strip attacker needs. The **`Secure` cookie attribute** ensures the browser never transmits a session token over an unencrypted connection. Together these controls create a layered, defense-in-depth posture for the transport plane.

## What it defends against

See [Man-in-the-Middle & Protocol Downgrade](../../attack/transport-security-tls.md).

In the context of opposite-osiris, the highest-value targets for a network attacker are the `prismatica_refresh` session cookie set by the auth-gateway and the SMTP credentials used to deliver login and registration emails. Without HSTS a first-connection SSL-strip is feasible even when the server always redirects to HTTPS; without `rejectUnauthorized: true` on the SMTP socket, a spoofed mail server can harvest credentials silently.

## How opposite-osiris implements it

Three independent layers enforce the policy:

**1. nginx container (`Strict-Transport-Security` response header)**

[`apps/opposite-osiris/docker/services/web/default.conf.template`](../../../../apps/opposite-osiris/docker/services/web/default.conf.template), line 26:

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
```

The `always` directive ensures the HSTS header is present even on error responses, not just 200 OK. `includeSubDomains` extends the policy to every subdomain served under the same origin.

**2. Static CDN/edge host (`_headers` file — preload-eligible)**

[`apps/opposite-osiris/public/_headers`](../../../../apps/opposite-osiris/public/_headers), line 14:

```
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

Two years max-age with the `preload` directive makes this host eligible for inclusion in browser HSTS preload lists, giving first-visit protection before the browser has ever received a Set-Cookie header. The static host also reinforces the other transport headers (`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`) from the same file.

**3. Auth-gateway (`Secure` cookie flag + SMTP `rejectUnauthorized`)**

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs):

- Lines 158–163 — every issued or cleared refresh cookie carries `Secure`:

  ```js
  function refreshCookie(token, maxAge = 60 * 60 * 24 * 30) {
      return `prismatica_refresh=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Secure; Path=/api/auth; Max-Age=${maxAge}`;
  }
  ```

- Lines 622–629 — the SMTP TLS socket refuses to connect if the server certificate does not verify:

  ```js
  const options = existingSocket
      ? { socket: existingSocket, host: config.smtpHost, servername: config.smtpHost, rejectUnauthorized: true }
      : { host: config.smtpHost, port: config.smtpPort, servername: config.smtpHost, rejectUnauthorized: true };
  const socket = tls.connect(options, () => resolveSocket(socket));
  ```

  This applies to both implicit-SSL connections and STARTTLS upgrades, so there is no path through the send flow that skips certificate verification.

## How we know it is applied

The security check suite at [`apps/opposite-osiris/scripts/security/05-headers.mjs`](../../../../apps/opposite-osiris/scripts/security/05-headers.mjs) contains a dedicated gate (`hsts header policy`, lines 39–50) that asserts the `Strict-Transport-Security` header is present with a valid `max-age` whenever `NODE_ENV=production` or `SECURITY_ENV=production`:

```js
{
    name: 'hsts header policy',
    run: async () => {
        const hsts = response.headers.get('strict-transport-security');
        if (!hsts && !productionMode) {
            return skipped('Strict-Transport-Security is absent in dev mode; fail this check in production.');
        }
        assert.ok(hsts, 'Strict-Transport-Security is missing in production mode');
        assert.match(hsts, /max-age=\d+/i);
        return passed('Strict-Transport-Security is present.');
    },
},
```

The check is a runtime HTTP probe: it fetches the actual deployed endpoint and inspects the response headers. A missing header causes a hard assertion failure in production mode, making the gate non-bypassable without an explicit environment override.

The `Secure` cookie flag is structural — it is embedded in the string literal that produces every `Set-Cookie` header in the auth-gateway, so any login or token-refresh response carries it automatically.

## Reference

The [Transport Layer Security Cheat Sheet (OWASP)](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html) is the canonical checklist for this control family, covering cipher suite selection, certificate pinning trade-offs, and HSTS preloading requirements. The opposite-osiris implementation addresses the header-level controls (HSTS max-age, `includeSubDomains`, `preload`) and the cookie transport controls that OWASP treats as mandatory for session security.

## Residual risk / assumptions

- **TLS termination is upstream.** The nginx container in the root compose project listens on HTTP port 8080; TLS is terminated by the `infrastructure/tls` reverse proxy (a separate nginx layer). The HSTS header is added by the inner container, but the encrypted channel itself depends on the outer proxy being correctly configured and having a valid certificate. If the outer proxy is misconfigured or omitted (e.g., when running the inner container directly without the TLS proxy), the HSTS header is emitted over plaintext — which browsers will ignore.
- **HSTS offers no first-visit protection without preloading.** The nginx `max-age=31536000` header without `preload` means a browser connecting for the first time over HTTP is not yet protected. The `_headers` file adds `preload`, but the host must actually be submitted to and accepted by browser preload lists for first-visit protection to hold on the static CDN path.
- **SMTP destination trust.** `rejectUnauthorized: true` validates the SMTP server's certificate against the system CA bundle inside the container. If the bundle is outdated or the mail provider uses a private CA not in that bundle, sends will fail rather than fall back silently — which is the safe failure mode, but it requires keeping the base image CA bundle current.
- **No certificate pinning.** The SMTP and upstream proxy connections rely on the public CA trust hierarchy. A CA compromise or mis-issuance event is outside the scope of these controls.
