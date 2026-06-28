# Input Validation — opposite-osiris (marketing + auth website)

> Every auth request is validated against strict regex policies on both the client and the server, and every outbound email template variable is HTML-escaped and every header field is stripped of CRLF before transmission.

## What it is (the concept)

**Input validation** is the practice of enforcing a well-defined set of rules on all data entering a system before that data is trusted or acted upon. **Allowlist (positive) validation** — accepting only inputs that match an explicit pattern — is preferred over denylist approaches because it eliminates entire classes of malformed input by construction. In this application, validation operates at two distinct trust boundaries: the browser (for immediate user feedback) and the Node.js auth gateway (as the authoritative enforcement point that cannot be bypassed). A second dimension of input validation covers **output encoding**: ensuring that data written into structured formats such as SMTP headers or HTML email templates cannot carry injected structure.

## What it defends against

See [Injection Attacks (SQLi, XSS, Command Injection)](../../attack/input-validation.md).

A weak or absent password policy permits brute-force and credential-stuffing attacks that lead to account takeover (OWASP A07:2021 Identification and Authentication Failures). In this app, users submit email addresses, passwords, and usernames through public auth endpoints; any of these fields can carry injection payloads if they reach downstream systems unvalidated. SMTP header injection (OWASP A03:2021 Injection) is a specific risk: if a display name or address containing `\r\n` is interpolated into a raw MIME message, an attacker can append arbitrary headers or additional recipients. HTML injection into email templates allows phishing content to reach legitimate users.

## How opposite-osiris implements it

### Client-side validation (immediate feedback)

[`apps/opposite-osiris/src/hooks/useAuth.ts`](../../../../apps/opposite-osiris/src/hooks/useAuth.ts) defines the canonical regex constants and runs them before any network call:

```ts
// lines 18-19
export const RFC_5322_EMAIL_REGEX = new RegExp(String.raw`^${EMAIL_LOCAL_PART}@(?:${EMAIL_DOMAIN_LABEL}\.)+[A-Za-z]{2,63}$`);
export const STRONG_PASSWORD_REGEX = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$/;
```

`validationMessage` (line 91) gates `signIn`, and `registrationValidationMessage` (line 107) additionally enforces the username pattern `/^\w[\w.-]{2,31}$/` and password-confirmation equality before any `fetch` is issued.

[`apps/opposite-osiris/src/scripts/password-strength.ts`](../../../../apps/opposite-osiris/src/scripts/password-strength.ts) drives a live strength meter through `checkPasswordStrength`. The meter checks six rules including a built-in blocklist of twenty common passwords (`COMMON_PASSWORDS`). `checkPasswordStrength(...).passed` is `true` only when the level is `good` or `strong`; the reset-password page wires this directly to the submit button's `disabled` attribute (line 103 of `reset-password.astro`).

### Server-side validation (authoritative enforcement)

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) re-declares the same three regex constants independently (lines 87-89) so that client-side checks cannot be bypassed by crafting a direct HTTP request to the gateway:

```js
// lines 87-89
const EMAIL_REGEX = new RegExp(/* identical RFC-5322 construction */);
const PASSWORD_REGEX = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$/;
const USERNAME_REGEX = /^\w[\w.-]{2,31}$/;
```

`isValidRegistrationContext` (line 718) applies all three and checks confirmation equality; `handleRegister` (line 826) calls it and returns HTTP 422 immediately on failure. `handleLogin` (line 878) tests `EMAIL_REGEX` and a non-empty password. `handleRecover` (line 925) silently no-ops invalid addresses while always returning HTTP 200 to prevent email-enumeration.

### SMTP header-injection prevention

`smtpBody` (lines 529-545) strips all `\r` and `\n` characters from the configured `smtpFromName` and `smtpFromAddress` before they are written into raw MIME header lines:

```js
// lines 530-531
const fromName = config.smtpFromName.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
const fromAddress = config.smtpFromAddress.replaceAll('\r', '').replaceAll('\n', '').trim();
```

`Auto-Submitted: auto-generated` and `X-Auto-Response-Suppress: All` headers are added unconditionally to suppress mail-loop amplification.

### HTML-escaping of email template variables

`escapeHtml` (line 350) encodes `&`, `<`, `>`, `"`, and `'` into their HTML entity equivalents. `renderEmailTemplate` (line 375) applies it to every `{{var}}` substitution before the HTML body is handed to `smtpBody`:

```js
// line 379
return escapeHtml(variables[key] ?? variables[rawKey] ?? 'unknown');
```

This ensures that user-controlled values such as email addresses cannot inject HTML into verification, reset, or notification emails.

### TLS-authenticated SMTP transport

`connectTlsSmtpSocket` (line 622) sets `rejectUnauthorized: true` for both implicit SSL and STARTTLS upgrade, preventing credential or email interception over an untrusted relay. `authenticateSmtp` (line 632) enforces that SMTP credentials must be supplied as a complete pair; a half-configured credential set raises a `503` rather than attempting an unauthenticated connection.

## How we know it is applied

The server-side enforcement is structural: `handleRegister`, `handleLogin`, and `handleRecover` are the sole registered handlers for `POST /api/auth/register`, `POST /api/auth/login`, and `POST /api/auth/recover` (line 1128 router table). Every request through those routes passes through `isValidRegistrationContext` or the inline `EMAIL_REGEX` guard before any downstream call to the BaaS (GoTrue/PostgREST). There is no alternative code path that skips validation.

On the UI side, the reset-password page wires the submit button directly to the validator result:

```js
// apps/opposite-osiris/src/pages/auth/reset-password.astro — line 103
button.disabled = !(checkPasswordStrength(password.value).passed && updateMatch(password.value, confirm.value) && Boolean(token));
```

The button starts with the HTML `disabled` attribute set (line 45) and is only enabled at runtime once all three conditions hold; disabling JavaScript in the browser leaves the button permanently disabled.

## Reference

The OWASP Input Validation Cheat Sheet ([https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html)) establishes that allowlist validation at every trust boundary — not just the client — is the foundational control against injection-class vulnerabilities. The implementation here follows its core guidance by mirroring the same regex policy in both the browser hook and the server handler, ensuring that stripping or bypassing the client layer does not weaken enforcement.

## Residual risk / assumptions

- **`to` field is not sanitized in `smtpBody`.** The recipient address in `RCPT TO` is taken from caller-controlled values (e.g., the registered email) without CRLF-stripping; in practice the SMTP protocol layer separates the `RCPT TO` command from the `DATA` phase, so CRLF in a recipient address would cause an SMTP protocol error rather than header injection, but the field is not explicitly scrubbed.
- **The blocklist of common passwords is 20 entries.** It covers the most trivial cases; it is not a full dictionary or credential-stuffing corpus. A determined user can choose a technically policy-compliant password that is still in public breach datasets.
- **Server-side validation trusts the configured regex constants, not a shared import.** The client and server regex strings are textually identical but independently declared. A future change to one without updating the other would create a policy divergence that is not caught at compile time.
- **Template injection is prevented only for `{{var}}` placeholders.** If an email template file itself were writable by an attacker (e.g., through a path-traversal in `emailTemplateDir`), the escaping of variables would not mitigate the threat; filesystem access controls on the template directory are the relevant second layer.
- **DNS deliverability check (`hasDeliverableEmailDomain`) is advisory, not a hard security gate.** It reduces spam registrations but a valid-looking domain with MX records and a passing regex can still represent an attacker-controlled address.
