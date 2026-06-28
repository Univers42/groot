# Audit Logging and Security Monitoring — opposite-osiris (marketing + auth website)

> Every security-relevant outcome in the auth gateway is durably recorded through a privileged RPC with a unique `request_id`, and suspicious sign-ins trigger a real-time email alert to the account owner with IP and geolocation context.

## What it is (the concept)

**Audit logging** is the practice of recording a timestamped, tamper-evident trail of security-relevant events — authentication outcomes, privilege-boundary crossings, and abnormal failures — so that compromises can be detected and reconstructed after the fact. **Security monitoring** pairs that trail with real-time alerting that notifies affected parties when anomalous behaviour is observed. Together they implement **detective controls**: they do not block an attack but ensure its effects are visible and attributable. The **audit sink** here is the grobase backend's `auth_record_audit_event` RPC, reached only via the service-role key — never exposed to browser callers.

## What it defends against

See [Security Logging and Monitoring Failures (A09:2021)](../../attack/audit-logging-monitoring.md).

Without audit trails, an attacker who compromises an account through credential stuffing, brute force, or session replay can operate undetected indefinitely. In the opposite-osiris context this risk is acute: the gateway is the sole auth surface for all frontends, so a silent failure here means no forensic evidence survives. The user-facing email alert also closes the detection gap when the owner is the first to notice anomalous activity.

## How opposite-osiris implements it

All implementation lives in [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs).

### Central `audit()` dispatcher (lines 331–336)

```js
async function audit(eventType, _request, details = {}) {
    if (!serviceBaas || !config.serviceKey) return;
    await serviceBaas.rpc('auth_record_audit_event',
        { event_type: eventType, email: details.email ?? null,
          details: { ...details, request_id: randomUUID() } },
        { apiKey: config.serviceKey, bearerToken: config.serviceKey }
    ).catch((error) => {
        console.warn(`[auth-gateway] audit event "${eventType}" was not recorded: …`);
    });
}
```

The function is a thin, safe wrapper: it no-ops when the service key is absent (safe-degradation in local dev), appends a `randomUUID()` as `request_id` to every payload for correlation, and swallows sink errors without leaking them to callers. The RPC is authenticated with the **service-role key** (`config.serviceKey`), not the anon key, so only the gateway process can write audit rows.

### Exhaustive call-site coverage

`audit()` is invoked on every branch of every security-sensitive handler:

| Event type | Trigger |
|---|---|
| `login_success` / `login_failed` | Credential evaluation outcome (line 891) |
| `login_locked` | Request hits an active lockout (line 886) |
| `login_lockout_triggered` | Failure counter reaches threshold (line 897) |
| `*_turnstile_failed` | Cloudflare Turnstile challenge rejected for any action (line 699) |
| `register_requested` / `register_failed` / `register_dev_confirmed` | Registration pipeline stages (lines 787, 799) |
| `password_recovery_requested` / `password_recovery_link_failed` | Password-reset flow (lines 415, 927) |
| `osionos_bridge_success` / `osionos_bridge_failed` / `osionos_bridge_redirect_rejected` | Bridge proxy outcome (lines 1108, 1114, 1118) |
| `newsletter_*` | Opt-in, confirmation, welcome, unsubscribe, throttle (lines 947–1033) |
| `logout` | Session termination (line 1056) |
| `refresh_success` / `refresh_failed` | Token refresh (line 1046) |
| `login_alert_sent` / `login_alert_skipped` / `login_alert_suppressed` / `login_alert_failed` | Alert pipeline self-audit (lines 457, 461, 471, 902) |

### Real-time login security notification (lines 445–472)

`sendLoginSecurityNotification()` fires on every successful sign-in and on the first failed sign-in within a deduplication window:

```js
async function shouldSendSignInNotice(email, outcome) {
    if (outcome === 'success') return true;              // always alert on success
    const key = `notice:${outcome}:${keyHash(email)}`;
    const existing = await store.get(key);
    if (existing !== null) return false;                 // suppress duplicate failed-login noise
    await store.set(key, '1', SIGN_IN_NOTICE_TTL_SEC);
    return true;
}
```

The email carries the originating IP address and geolocation derived from Cloudflare (`cf-ipcity`, `cf-ipcountry`, `cf-timezone`) or Vercel proxy headers, constructed in `loginAlertContext()` / `loginLocation()` (lines 364–443). The subject line distinguishes success (`"new Prismatica sign-in"`) from failure (`"failed Prismatica sign-in attempt"`), giving account owners an unambiguous signal.

## How we know it is applied

`audit()` is not an opt-in helper — every path through a handler that produces a security outcome calls it. The login handler (lines 875–919) demonstrates the pattern concretely: the `login_success`/`login_failed` call on line 891 is unconditional between the credential check and any response path, making silent omission structurally impossible without also breaking the response. The alert pipeline additionally self-audits every branch (`login_alert_sent`, `login_alert_skipped`, `login_alert_suppressed`, `login_alert_failed`), so even SMTP failures produce a written audit record rather than silent dropout.

The service-key guard `if (!serviceBaas || !config.serviceKey) return;` means the sink is active in every deployed environment where a `SERVICE_ROLE_KEY` is injected — which is required for the gateway to function at all (session refresh and bridge proxy also depend on the service client).

## Reference

The [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) defines the event attributes (who, what, when, from where) and output hygiene rules (no secrets in logs, consistent structured format) that a compliant audit trail must satisfy. This implementation aligns with that model: each event carries `event_type`, `email`, `request_id`, and contextual fields such as `ip_address`, `location`, and `status`, while refresh tokens and passwords are explicitly stripped before any record is written (`sanitizeAuthPayload`, line 338).

## Residual risk / assumptions

- **Sink availability is not guaranteed.** `audit()` catches and warns on RPC errors but does not retry or queue events locally; a transient grobase outage causes silent audit gaps without blocking the auth flow.
- **IP attribution depends on the reverse-proxy chain.** Geolocation is read from Cloudflare and Vercel headers (`cf-ipcountry`, `x-forwarded-for`). An attacker who bypasses those proxies and hits the gateway directly can supply arbitrary header values, poisoning location metadata.
- **No server-side SIEM integration.** Audit rows land in the grobase database. There is no documented export to a SIEM, log-aggregation service, or alerting rule engine; anomaly detection beyond the per-account lockout counter and email notification is not implemented.
- **User-facing alerts require SMTP.** If `hasSmtpConfig()` returns false, the gateway logs a warning and writes a `login_alert_skipped` audit row, but the account owner receives no email — reducing monitoring to the backend-only audit trail.
- **No cross-account or global rate-limit alerting.** The lockout counter (`fail:login:<hash>`) and deduplication key (`notice:<outcome>:<hash>`) are per-account; a distributed low-and-slow credential-stuffing campaign below the per-account threshold produces audit rows but triggers no aggregate alert.
