# Trust Boundary — opposite-osiris (marketing + auth website)

> `deriveClientIp` enforces a fixed, topology-matched proxy-hop count so that only addresses appended by **our** reverse proxies are trusted, making the client IP used for all rate-limit and lockout keys impossible to forge from the network edge.

## What it is (the concept)

A **trust boundary** is the line between code that runs under our control and input that an adversary controls. At the network layer, the canonical problem is the `X-Forwarded-For` (XFF) header: HTTP reverse proxies append the IP of the direct peer they received the connection from, but nothing prevents a client from pre-populating XFF with arbitrary values before the request reaches the first proxy. A correct implementation must know exactly how many trusted proxy hops sit between the public internet and the application, read only the **right-most `N` entries** (appended by those trusted hops), and treat everything to their left as untrusted client data. The integer `N` is the **trusted-proxy-hop count** — a topology secret that must match the actual deployment.

## What it defends against

See [Privilege Escalation via Trust-Boundary Crossing](../../attack/trust-boundary.md).

In this application context, every rate-limit bucket, login-attempt counter, and account-lockout record is keyed on the derived client IP. If an attacker can shift the derived IP by prepending a fresh value to XFF on each request, they obtain a clean bucket for every attempt and defeat all per-IP throttling — reducing brute-force protection to zero. The threat is a complete bypass of `A04:2021 Insecure Design` controls that the rest of the gateway assumes are in force.

## How opposite-osiris implements it

**[`apps/opposite-osiris/scripts/auth/net-ip.mjs`](../../../../apps/opposite-osiris/scripts/auth/net-ip.mjs)** — the authoritative derivation function.

`deriveClientIp` splits the XFF header into a chain and selects the entry at `chain.length - trustedProxyHops`:

```js
const index = chain.length - trustedProxyHops;
// Chain shorter than hop count: fall back to the left-most we have.
// Over-throttles a shared upstream at worst — fail safe, never fail open.
if (index < 0) return chain[0];
return chain[index] ?? remote ?? 'unknown';
```

Prepending additional values to XFF only grows the left side; `index` is anchored to the right-most trusted tail and therefore does not move. With `trustedProxyHops <= 0` the function ignores XFF entirely and returns the raw socket peer — XFF is never trusted when the hop count is unknown. `cf-connecting-ip` is honoured only when `trustCfConnectingIp` is explicitly set to `true` (off by default).

**[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)** — live wiring inside the gateway process.

`clientIp()` is the single call site used throughout the gateway (login, newsletter, rate-limit key derivation, lockout record) — no other code derives an IP independently:

```js
// line 110-111
function clientIp(request) {
    return deriveClientIp(request, { trustedProxyHops: config.trustedProxyHops, trustCfConnectingIp: config.trustCfConnectingIp });
}
```

`config.trustedProxyHops` is populated at startup from `process.env.AUTH_TRUSTED_PROXY_HOPS`.

**[`apps/opposite-osiris/scripts/auth/guards.mjs`](../../../../apps/opposite-osiris/scripts/auth/guards.mjs)** — startup enforcement.

`collectStartupViolations` treats `AUTH_TRUSTED_PROXY_HOPS <= 0` as a hard violation that aborts the gateway in production mode:

```js
if (Number(config.trustedProxyHops ?? 0) <= 0) {
    violations.push(
        'AUTH_TRUSTED_PROXY_HOPS must be >= 1 in production so the client IP is read from a trusted proxy hop; per-IP throttling is meaningless otherwise.',
    );
}
```

**[`docker-compose.yml`](../../../../docker-compose.yml)** — topology declaration.

```yaml
# Real browser traffic reaches the gateway through 2 appending reverse
# proxies: local-https-proxy(4322) -> opposite-osiris-web(8080) -> gateway.
AUTH_TRUSTED_PROXY_HOPS: ${AUTH_TRUSTED_PROXY_HOPS:-2}
```

The comment names the two appending proxies so the integer is traceable to the actual deployment graph, not an arbitrary constant.

## How we know it is applied

Two independent test suites run without a live stack and assert the spoof-resistance property directly.

**Unit gate — [`apps/opposite-osiris/scripts/security/unit/net-ip.mjs`](../../../../apps/opposite-osiris/scripts/security/unit/net-ip.mjs):**

```js
// "prepended spoof entries do not shift the trusted tail"
const base    = deriveClientIp(fakeRequest('9.9.9.9, 203.0.113.7, 172.18.0.5'),              { trustedProxyHops: 2 });
const spoofed = deriveClientIp(fakeRequest('1.2.3.4, 5.6.7.8, 9.9.9.9, 203.0.113.7, 172.18.0.5'), { trustedProxyHops: 2 });
assert.equal(spoofed, base);          // 203.0.113.7 in both cases
assert.equal(spoofed, '203.0.113.7');
```

**Integration gate — [`apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs`](../../../../apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs)** (check "rotating X-Forwarded-For does not bypass throttling"):

The gate sends repeated login requests each carrying a unique `X-Forwarded-For` value against a running gateway instance and asserts that at least one `429` response is returned, confirming the throttle fires on a fixed internal IP rather than on the attacker-supplied XFF prefix.

The startup guard in `guards.mjs` additionally prevents the gateway from reaching the request-handling path at all when the hop count is zero in a production origin, making misconfiguration a hard startup failure rather than a silent degradation.

## Reference

The OWASP [Threat Modeling Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html) recommends enumerating trust boundaries during design and confirming that data crossing each boundary is validated against the capabilities of the **sending** party, not the data itself. This control operationalises that principle at the HTTP layer: the hop count encodes the known topology, and anything outside that topology is treated as untrusted client input regardless of what it claims.

## Residual risk / assumptions

- **Topology drift:** if a new reverse proxy is inserted between the internet and the gateway without incrementing `AUTH_TRUSTED_PROXY_HOPS`, the gateway will read one proxy's internal IP as the client IP, causing all traffic through that proxy to share a single rate-limit bucket (over-throttling) rather than leaking rate-limit bypasses. The startup guard does not detect this; it only catches the zero-hop misconfiguration.
- **No Cloudflare:** `trustCfConnectingIp` defaults to `false`. If Cloudflare is introduced without setting this flag, `cf-connecting-ip` is ignored and derivation falls back to XFF counting — which remains correct only if the Cloudflare edge hop is included in `AUTH_TRUSTED_PROXY_HOPS`.
- **Socket-level spoofing:** the rightmost trusted tail is the IP the innermost proxy observed on its TCP socket. The control assumes that proxy is not itself reachable from the public internet; if an attacker can TCP-connect directly to the gateway (or to the innermost proxy), they can supply an arbitrary socket-peer address and the hop-count logic provides no protection.
- **IPv4-only Kong constraint:** `normalizeIp` unwraps IPv4-mapped IPv6 (`::ffff:x.x.x.x`) and strips port suffixes, but the broader stack (Kong) is IPv4-only. IPv6 clients in a future dual-stack deployment would need to be verified against the normalisation path.
