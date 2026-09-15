# Security model

> **Status:** Partial · 2026-09-15
> **Evidence:** the ABAC shape is visible in `website.json`; Kong-as-sole-door is enforced by
> the fly deployment; `IDENTITY_HEADER_MODE=strict` is set in production
> **To check:** whether `PERMISSION_CONDITIONS_ENABLED` / `API_KEY_ABAC_ENABLED` (migration
> `063`, gates `m135`–`m139`) are needed for what we want to demonstrate — both are off
> **Sources:** `infra/config/contracts/website.json` · `deploy/fly/boot.sh` ·
> `crates/data-plane-server/README.md`
> **Deeper:** [archive/wiki-2026-09/components/backend/](../../archive/wiki-2026-09/components/backend/) ·
> [archive/wiki-2026-09/security/](../../archive/wiki-2026-09/security/) (147 pages)

Three questions, kept separate on purpose: **who are you**, **what may you do**, and **what
rows may you touch**. Most backends answer all three in the same middleware. Here they live in
different places, which is what makes the third one enforceable.

---

## Trust boundaries

**Kong is the only public door**; everything else stays on the inner Docker network. **The
browser reaches the backend same-origin only**, with realtime's `wss://` as the one exception.
**Services authenticate to each other** with an HMAC envelope (`v1.<ts>.<hex>`) over a shared
token, ±120s skew — one primitive reused, not reinvented per service. → [04-network](04-network.md)

And a boundary that is *not* uniform, which matters: **the data plane re-derives the tenant from
a verified API key; several control-plane read handlers derive it from a header.** That
asymmetry is a known weakness and has its own page.
→ [03-known-weaknesses](03-known-weaknesses.md)

---

## Identity

`POST /v1/keys/verify` turns an API key into an identity. GoTrue issues the user-facing proofs;
the Go control plane resolves service credentials. Email OTP is enabled in production with real
SMTP, so a full sign-up lands in a real inbox.

The resolved identity is cached in the data plane (`verify_cache`) — its TTL is the window in
which a revoked key still works, and is not yet documented.

---

## Authorisation — policies are rows, not branches

The usual arrangement scatters permission checks through the code. The problem is not that they
are badly written — it is that the rule ends up in forty places, slightly different in each, and
one forgotten check leaks data. Here the rule is data. From a contract:

```json
"roles": [{ "name": "user", "policies": [{
    "resource_type": "*", "resource_name": "*",
    "actions": ["select","insert","update","delete"],
    "effect": "allow", "conditions": { "owner_only": true }
}]}]
```

Backing that: `roles`, `user_roles` and `resource_policies` tables, and a SQL function
`public.has_permission(...)`. The data plane carries **its own ABAC evaluator in Rust** that
mirrors that function plus the NestJS field-mask resolution, so it decides locally instead of
round-tripping to the permission engine.

Two implementations that must agree is the declared cost of that speed.

**Field masks** are the finer layer: a role may read a row but not every column. Masks are
applied after execution (`apply_masks`), before the response is serialised.

Fine-grained conditions are flag-gated off: `PERMISSION_CONDITIONS_ENABLED` and
`API_KEY_ABAC_ENABLED`, migration `063`, gates `m135`–`m139`.
→ [operations/02-flags](../operations/02-flags.md)

---

## Row reachability

The third question — *which rows* — is not answered by roles at all. It is answered by
per-request owner scoping, and it is the load-bearing decision of the whole system.
→ [platform/07-isolation](../platform/07-isolation.md)

Every generated table gets an `owner_id` whether or not you ask for one — which is what makes a
single isolation rule writable for any table, including ones that do not exist yet.

---

## API keys

Keys carry **scopes** (`read`, `write`) and belong to a tenant. They are hashed with a pepper
generated on first boot and persisted on the deployment volume — a key compromise in the
database alone does not yield usable credentials.

---

See also: [02-proofs](02-proofs.md) · [03-known-weaknesses](03-known-weaknesses.md) ·
[platform/07-isolation](../platform/07-isolation.md)
