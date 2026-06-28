# Authentication Controls — auth-gateway (the auth BFF)

> The auth-gateway enforces server-side password complexity at registration and returns
> structurally identical failure responses for every login attempt, so neither weak credentials
> nor account existence can be inferred from the HTTP exchange.

## What it is (the concept)

**Authentication** is the process of verifying that a caller is who they claim to be before
granting access to a protected resource. A secure implementation must satisfy two complementary
properties: **credential strength** (passwords must be hard to guess or brute-force) and
**oracle resistance** (error responses must not reveal whether an account exists or why the
attempt failed). Violating either property creates a foothold for automated attacks even when
the underlying session mechanism is otherwise sound.

## What it defends against

See [Credential Theft / Broken Authentication](../../attack/authentication.md).

In this application, the auth-gateway is the single choke point for every sign-up, sign-in, and
password-recovery request. Without server-side complexity enforcement a client-side-only check
can be bypassed with a raw HTTP call, allowing trivially weak passwords into the system.
Without uniform failure responses, an attacker can enumerate registered emails by observing
differences in status codes or response bodies — a prerequisite for targeted credential-stuffing
or phishing campaigns.

## How auth-gateway implements it

### 1 — Password complexity enforced at the only account-creation path

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)
defines a compiled regex at **line 88**:

```js
const PASSWORD_REGEX = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$/;
```

The **`isValidRegistrationContext`** guard (lines 718–724) is the only gate before any GoTrue or
admin-API call is issued. It requires all four conditions to hold simultaneously: the email must
pass `EMAIL_REGEX`, the password must pass `PASSWORD_REGEX`, `profile.confirmPassword` must
equal `password`, and (in production) `email_verification_consent` must be `true`. If any
condition fails, `handleRegister` (lines 826–828) returns a `422` with the message
`'Invalid email or password policy.'` and halts — no account is created.

### 2 — Uniform failure responses that prevent account enumeration

`handleLogin` (lines 905–907) always emits a fixed `401` body on any failed authentication:

```js
// Generic message and fixed 401 — never leak whether the email exists,
// the lockout counter, or GoTrue internals to an unauthenticated caller.
json(response, 401, { message: 'Invalid credentials.' });
```

The lockout counter increment and the GoTrue error payload are consumed internally — they are
never forwarded. The same design applies to password recovery: `handleRecover` (line 929) emits
a constant `200` message regardless of whether an account exists for the supplied email:

```js
json(response, 200, { message: 'If an account exists for that email, a reset link has been sent.' });
```

## How we know it is applied

[`apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs`](../../../../apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs)
is an integration test suite that runs against the live gateway. The check
`'failed login returns a generic 401 with no enumeration/internal leak'` (lines 118–144):

1. Posts a login for a randomly generated, certainly non-existent email with a wrong password,
   asserts the response is `401` with body `{ message: 'Invalid credentials.' }`, and asserts
   `noInternalLeak()` on the serialised body.
2. Posts the same wrong password for a **known** test account and then asserts:

```js
assert.deepEqual(knownBody, unknownBody,
  'known vs unknown email login bodies differ — enables enumeration');
```

A non-identical response body causes the test to fail with an explicit enumeration warning. The
suite skips (never fails) when the gateway is unreachable on a bare checkout, so it does not
block offline CI, but it runs to completion whenever the stack is up.

## Reference

The [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
specifies both the minimum complexity criteria a password policy must meet and the requirement
that authentication failures expose no distinguishing information to the caller. The controls
documented here map directly onto those normative requirements: the regex enforces complexity
at the server boundary, and the uniform `401` body satisfies the non-distinguishable-failure
requirement.

## Residual risk / assumptions

- **Complexity does not imply entropy.** `PASSWORD_REGEX` accepts `Password1!` which satisfies
  all four character classes and the minimum length but is trivially in any breach corpus. There
  is no dictionary or haveibeenpwned check at registration time.
- **No CAPTCHA or proof-of-work at registration.** Bot-driven account creation with compliant
  passwords is not blocked by this control alone; the rate-limiting layer (covered separately)
  must compensate.
- **GoTrue is a trusted downstream.** The gateway normalises and re-emits a generic error, but
  if GoTrue itself leaks information in a side channel (e.g. response timing), the enumeration
  guarantee weakens. The current implementation does not add artificial timing equalisation.
- **`EMAIL_REGEX` is a syntactic check only.** Domain deliverability is validated separately via
  `hasDeliverableEmailDomain`; the regex alone does not prevent disposable-email abuse.
- **Known-email leg of the test requires service-role credentials.** If `ensureSecurityTestUser`
  cannot provision a test account (missing service key), only the unknown-email leg runs; the
  `deepEqual` assertion is skipped with a `passed` result rather than a failure, so the
  byte-identity guarantee is not machine-verified in that configuration.
