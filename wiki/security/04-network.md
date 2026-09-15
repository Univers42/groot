# Network and transport

> **Status:** Partial · 2026-09-15
> **Evidence:** the SSRF guard is described in the adapter crate README; CORS origins and
> `IDENTITY_HEADER_MODE=strict` read from `deploy/fly/boot.sh`; gate `m140` covers network
> controls and the WAF and is not flag-gated
> **To check:** whether Kong's `127.0.0.1:8000` is reachable as an external surface in any
> deployment — if it is, the "HTTPS from outside" claim needs qualifying
> **Sources:** `crates/data-plane-pool/README.md` §http.rs · `deploy/fly/boot.sh`
> **Deeper:** [archive/wiki-2026-09/security/attack/](../../archive/wiki-2026-09/security/attack/)

---

## One public door

Kong fronts everything reaching the backend from outside: data, realtime, storage, auth. In the
fly deployment it is the only published port; every other service stays on the inner Docker
network. That is a small, auditable perimeter — and it is also, today, the main containment for
the header-authorisation weakness. → [03-known-weaknesses](03-known-weaknesses.md)

CORS origins are pinned to the public host at boot, not left permissive:

```
KONG_CORS_ORIGIN_FRONTEND / _APP / _PLAYGROUND / _STUDIO = https://$PUBLIC_HOST
IDENTITY_HEADER_MODE=strict
```

---

## Transport

Every connection from a browser or script uses HTTPS. Locally that means a TLS proxy with a
trusted local CA — a green padlock, not a warning page. Plaintext is used only on the inner
Docker network. Browser traffic is **same-origin only** through Vercel rewrites, with one
exception: realtime's direct `wss://`, because WebSockets through a rewrite proxy are poorly
supported. That makes realtime the only surface where a browser touches the backend origin.
→ [platform/05-realtime](../platform/05-realtime.md)

---

## The SSRF guard

The `http` engine lets a user declare a remote API as a data source — *let a user make my server
fetch any URL*, textbook SSRF, invited by design. The defence is the most carefully engineered
thing in the repository.

`guard_and_resolve(base_url)` resolves the host and validates it against `is_blocked_ip`:

- loopback, RFC-1918 private ranges, link-local, CGNAT
- IPv6 ULA and link-local, IPv4-mapped forms
- names: `localhost`, `*.internal`, `metadata`

Two details show the author knew the specific attacks.

**`169.254.169.254` is named explicitly.** That is the cloud metadata endpoint; getting a server
to query it yields account credentials. It is the first target of any SSRF in a cloud
environment, and it is blocked by its full address.

**The client is pinned to the already-validated public IPs**, so a later DNS rebind cannot
redirect inward. Defending against that requires having thought about the window between the
check and the connection — which is exactly where most implementations leave the hole.

`DATA_PLANE_HTTP_ALLOW_INTERNAL=1` skips the guard for trusted dev mocks and must never be set
in production.

The same guard protects outbound automation webhooks, which are additionally HTTPS-only with
pinned IPs and a redirect-free client.

---

## WAF

A hardened WAF/ModSecurity configuration sits in front, covered by gate `m140` with the network
controls, and is **not flag-gated**. For an evaluation, note the asymmetry honestly: a WAF is
installed; the SSRF guard above was designed.

---

## Rate limiting

Kong rate-limits at the edge; the data plane carries a second layer compiled in
(`ratelimit-redis`, runtime-selected) with per-tier limits — `tier_rate` and `tier_max_rows`,
the latter clamping a query's row limit to the contracted cap. Kong protects the perimeter from
volume; the data plane enforces what a tenant is entitled to.

---

## Secrets in transit and at rest

API keys are hashed with a pepper generated on first boot and persisted on the deployment
volume. SMTP credentials arrive from platform secrets, never from the repository. Mount
credentials are encrypted in the adapter registry and decrypted only to hand to the executor.
→ [operations/05-secrets](../operations/05-secrets.md)

---

See also: [01-model](01-model.md) · [platform/08-engines](../platform/08-engines.md)
