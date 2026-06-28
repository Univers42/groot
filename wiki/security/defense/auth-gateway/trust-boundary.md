# Trust-Boundary Enforcement — auth-gateway (the auth BFF)

> The auth-gateway holds the BaaS service-role key exclusively server-side and exposes it only through narrowly scoped admin operations, ensuring the browser can never obtain or exercise privileged credentials.

## What it is (the concept)

A **trust boundary** is a demarcation line between two security zones across which data or control flow must be explicitly validated before being trusted. In a Backend-for-Frontend (**BFF**) architecture, the boundary sits between the untrusted browser/client zone and the trusted server zone. Crossing that boundary without enforcement is a **privilege-escalation vector**: a caller in the lower-trust zone acquires capabilities that only higher-trust principals should possess. **Privilege separation** is the technique of instantiating distinct clients or credentials at each trust level and refusing to promote a low-trust request to a high-trust operation without explicit gate logic.

## What it defends against

See [Privilege Escalation via Trust-Boundary Crossing](../../attack/trust-boundary.md).

In this application, the BaaS service-role JWT bypasses all Row-Level Security policies and can invoke unrestricted admin operations (create user, generate magic-link, update any account). If that key leaked to the browser — or if the gateway used a single over-privileged client for both public and admin paths — an attacker could call the BaaS API directly from the browser with full service-role authority. The BFF pattern is only as strong as the trust boundary it enforces between its own public surface and its privileged back-channel.

## How auth-gateway implements it

The implementation lives in [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) and its container definition in [`apps/opposite-osiris/docker/services/api-gateway/Dockerfile`](../../../../apps/opposite-osiris/docker/services/api-gateway/Dockerfile).

**Dual-client construction at startup (lines 94-97).**
Two distinct BaaS SDK clients are created when the process starts:

```js
const publicBaas = createClient({ url: config.baasUrl, anonKey: config.anonKey, persistSession: false });
const serviceBaas = config.serviceKey
    ? createClient({ ..., serviceRoleKey: config.serviceKey, accessToken: config.serviceKey, persistSession: false })
    : null;
```

`publicBaas` carries only the anon key and is used for all user-facing operations (sign-in, sign-up, password recovery, token refresh). `serviceBaas` is constructed only when `SERVICE_ROLE_KEY` is present in the environment; otherwise it is explicitly `null`. The key is read from env at line 53: `serviceKey: process.env.SERVICE_ROLE_KEY ?? process.env.KONG_SERVICE_API_KEY ?? process.env.BAAS_SERVICE_ROLE_KEY ?? ''`.

**Hard guard on every privileged operation (lines 266-291).**
Each function that crosses the trust boundary into service-role territory opens with an unconditional null-check:

```js
async function createAdminUser(body) {
    if (!serviceBaas) throw new Error('Missing service role key.');
    return sdkResult(await serviceBaas.auth.admin.createUser(body));
}
```

The same pattern is repeated for `generateAdminLink` (line 277) and `updateAdminUser` (line 286), and extends to the audit-RPC path (line 332) and profile-existence probes (line 294). No privileged BaaS call can be reached unless `serviceBaas` is non-null.

**Secrets never baked into the image (Dockerfile lines 6-8, 51).**
The Dockerfile header states explicitly:

```
# It holds SERVER-ONLY secrets (SERVICE_ROLE_KEY, OSIONOS_BRIDGE_SHARED_SECRET,
# TURNSTILE_SECRET_KEY, SMTP) which are injected at RUNTIME via env — NEVER baked into this image.
```

The image contains no secret values; they arrive exclusively through Docker runtime environment injection.

**Non-root container user (Dockerfile line 48).**
The container runs as `USER node` (UID 1000), the unprivileged user shipped in `node:22-alpine`, reducing the blast radius of a container escape.

**Compose wiring (docker-compose.yml lines 330-340).**
The root compose file annotates the service: "Server-only secrets (SERVICE_ROLE_KEY, OSIONOS_BRIDGE_SHARED_SECRET, TURNSTILE_SECRET_KEY, SMTP) are injected at RUNTIME via env_file below." The `env_file` points to `./.env.local` (vault-sourced or locally generated); no secret defaults appear in the `environment:` block, preventing accidental override of the vault-fetched value.

## How we know it is applied

The gate is structural, not aspirational: `serviceBaas` is declared `const` at module scope (line 95) and never reassigned. Any code path that reaches a privileged call without a non-null `serviceBaas` throws synchronously before the BaaS network call is attempted. The anon client (`publicBaas`) has no `serviceRoleKey` in its construction arguments and therefore cannot exercise service-role authority even if passed to a misrouted admin call.

At the compose layer, `TURNSTILE_SECRET_KEY` is intentionally absent from the `environment:` block (docker-compose.yml lines 348-352) — a deliberate design note confirms this: "`environment:` overrides `env_file:`, so an empty default would clobber the Vault-fetched value." The same discipline applies to `SERVICE_ROLE_KEY`: it is not assigned a default in `environment:`, so the only way it reaches the process is through the vault-sourced `.env.local`.

## Reference

The [Threat Modeling Cheat Sheet — OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html) frames trust-boundary identification as a mandatory step in every threat model: enumerating where data crosses from a lower-trust to a higher-trust zone surfaces exactly the privilege-escalation risks this control addresses. Mapping the auth-gateway's two SDK clients to OWASP's trust-zone model makes the boundary explicit and auditable rather than implicit in deployment convention.

OWASP category: **A01:2021 Broken Access Control**.

## Residual risk / assumptions

- **Single process, shared memory.** Both `publicBaas` and `serviceBaas` live in the same Node.js process. A code-injection or prototype-pollution vulnerability within the gateway process could access `serviceBaas` directly without going through the null-check guards.
- **Env-file integrity.** The trust boundary holds only as long as `.env.local` is not world-readable and is not committed to the repository. The vault42 pull mechanism is the enforced distribution path; local no-vault mode self-generates secrets but does not constrain filesystem permissions.
- **No mutual TLS between gateway and BaaS.** The gateway authenticates to Kong using the service-role JWT as a bearer token, not a client certificate. A network-adjacent attacker who can intercept the `mini-baas` internal Docker network would obtain the key in transit.
- **Admin HTTP routes are not separately authenticated.** The gateway exposes admin endpoints (e.g., invite-user flows) over its own HTTP surface. The caller is the opposite-osiris SSR layer, not the browser directly, but there is no per-route HMAC or mutual secret between the SSR server and the gateway (only the shared Docker network provides isolation).
- **Image pull trust.** The compose file pulls `dlesieur/prismatica-auth-gateway:latest` from Docker Hub without a pinned digest. A compromised image push would bypass the source-code trust boundary entirely.
