# Security Audit-Event Logging — auth-gateway (the auth BFF)

> Every security-relevant action that passes through the auth-gateway — sign-in, lockout, session refresh, bridge handoff, and more — is durably recorded as a typed audit event in the BaaS, keyed by a unique request ID, before any response is returned to the caller.

## What it is (the concept)

**Audit logging** is the systematic, tamper-evident recording of security-relevant events in a system so that breaches, anomalies, and policy violations can be detected and reconstructed after the fact. Each **audit event** carries a typed label (e.g. `login_failed`, `login_lockout_triggered`), the actor's email, contextual details, and a **per-event unique identifier** that correlates log lines across subsystems. Unlike general application logging, audit logs are written to a controlled, service-role-authorized persistence layer rather than stdout, making them available for monitoring queries independently of container log streams.

## What it defends against

See [Security Logging and Monitoring Failures (A09:2021)](../../attack/audit-logging-monitoring.md).

Without audit logging, a credential-stuffing campaign, a session-hijacking attempt, or an unexplained lockout wave leaves no forensic trace. In the auth-gateway's threat model this is especially acute: the gateway is the single chokepoint for all authentication, registration, token refresh, and session-bridge operations — a blind spot here means an attacker can probe the system repeatedly with no detector ever firing, and post-incident investigation has no event timeline to work from.

## How auth-gateway implements it

All audit writes flow through a single internal function defined in [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) at line 331:

```js
async function audit(eventType, _request, details = {}) {
    if (!serviceBaas || !config.serviceKey) return;
    await serviceBaas.rpc('auth_record_audit_event', {
        event_type: eventType,
        email: details.email ?? null,
        details: { ...details, request_id: randomUUID() }
    }, { apiKey: config.serviceKey, bearerToken: config.serviceKey })
    .catch((error) => {
        console.warn(`[auth-gateway] audit event "${eventType}" was not recorded: ${...}`);
    });
}
```

Key design choices:

- **Service-role authorization only.** The RPC is called with `config.serviceKey` (resolved from `SERVICE_ROLE_KEY` / `KONG_SERVICE_API_KEY` / `BAAS_SERVICE_ROLE_KEY` at line 53). Ordinary anon-key callers cannot write or suppress audit rows.
- **Per-event `request_id`.** Each invocation stamps a fresh `randomUUID()` into the `details` payload, enabling cross-service correlation without requiring a request-scoped context object.
- **Non-blocking failure handling.** If the RPC fails (network partition, BaaS down), the gateway emits a `console.warn` and continues rather than returning a 500 to the user. This avoids using audit-write failures as a denial-of-service vector against the login flow.
- **Exhaustive call sites.** `audit()` is awaited at every security branch, covering: `login_success`, `login_failed` (line 891); `login_locked` when an account is under active lockout (line 886); `login_lockout_triggered` the moment the failure counter crosses the threshold (line 897); `refresh_success` / `refresh_failed` (line 1046); `logout` (line 1056); `register_requested` / `register_failed` / `register_dev_confirmed` (lines 787–799); `password_recovery_requested` / `password_recovery_link_failed` (lines 415, 927); `osionos_bridge_success` / `osionos_bridge_failed` / `osionos_bridge_redirect_rejected` (lines 1108–1118); and all email-notification outcomes including `login_alert_sent`, `login_alert_suppressed`, `login_alert_skipped`, and `login_alert_failed` (lines 457–914).

## How we know it is applied

The [`docker-compose.yml`](../../../../docker-compose.yml) at lines 330–331 and 337–339 injects the service-role secret at runtime via `env_file: ./.env.local`:

```yaml
# Server-only secrets (SERVICE_ROLE_KEY, OSIONOS_BRIDGE_SHARED_SECRET,
# TURNSTILE_SECRET_KEY, SMTP) are injected at RUNTIME via env_file below.
auth-gateway:
  image: ${AUTH_GATEWAY_IMAGE:-dlesieur/prismatica-auth-gateway:latest}
  env_file:
    - path: ./.env.local
      required: false
```

The guard at the top of `audit()` (`if (!serviceBaas || !config.serviceKey) return;`) means the function silently no-ops only when `SERVICE_ROLE_KEY` is absent. In the running stack — where `.env.local` carries the vault-provisioned or self-generated service key — `serviceBaas` is initialized at line 95–96 and every `await audit(...)` executes the RPC. The no-op path is a safe degradation for bare development environments without a BaaS, not the production code path.

## Reference

The [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) defines what events must be captured, at what verbosity, and how to protect log integrity. The auth-gateway's typed event taxonomy (`login_locked`, `login_lockout_triggered`, `osionos_bridge_redirect_rejected`, …) directly maps to the cheat sheet's categories of authentication events, authorization decisions, and security control failures — implemented at the application layer rather than delegated to infrastructure.

## Residual risk / assumptions

- **No log integrity guarantee at rest.** Audit rows land in the BaaS PostgreSQL database under the same service-role key used for other operations. Row-level security on the `auth_audit_log` table (or equivalent) is a BaaS-side concern, not enforced by this gateway; a compromised service-role key could delete rows.
- **`required: false` on the env_file.** If `.env.local` is absent (e.g. a misconfigured deployment), `SERVICE_ROLE_KEY` will be empty, `serviceBaas` will be `null`, and every `audit()` call will silently no-op. No alerting fires on this condition.
- **No real-time alerting.** The implementation records events but does not ship them to a SIEM or trigger alerts. Detection of patterns (e.g. bulk `login_failed` events for different accounts) requires an out-of-band query against the BaaS database.
- **Email as the only actor identifier.** Events are keyed by email rather than a stable user UUID; pre-registration probing events (e.g. Turnstile failures before an email is known) carry a null email, reducing their forensic value.
- **Covers the Node.js BFF layer only.** Auth actions taken directly against the BaaS Kong gateway (bypassing the auth-gateway) are not captured by this mechanism.
