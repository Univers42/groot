# Authentication — opposite-osiris (marketing + auth website)

> The gateway enforces uniform, opaque error responses for all failed authentication attempts, ensuring no outcome — account existence, lockout state, or upstream error — can be inferred by an unauthenticated caller.

## What it is (the concept)

**Authentication** is the process of verifying that a caller is who they claim to be before granting access to a protected resource. A critical property of secure authentication is **response uniformity**: every failed attempt, regardless of the actual reason for failure (wrong password, unknown account, rate-limit, upstream error), must return a response that is **byte-identical** to every other failure. Deviating from this leaks **account existence** to an attacker, a technique called **username enumeration**. The same principle applies to **password recovery**: confirming that an address is registered gives an attacker exactly the same information as a successful login probe.

## What it defends against

See [Credential Theft / Broken Authentication](../../attack/authentication.md).

Username enumeration is a low-cost, high-value reconnaissance step: an attacker sends login or password-reset requests for a list of email addresses and observes which ones return a different response. In this app, opposite-osiris is the public-facing entry point for both account login and password recovery, making it the highest-value enumeration surface. Without uniform responses, any behavioral difference — a different HTTP status, a distinct error message, a timing difference, or an internal upstream error exposed in the body — converts the login or recovery endpoint into an oracle for building a confirmed victim list.

## How opposite-osiris implements it

**Login — uniform 401:**
`apps/opposite-osiris/scripts/auth-gateway.mjs` lines 905–908 terminate every failed login path — wrong password, unknown account, lockout triggered, or GoTrue upstream error — with a single fixed branch:

```js
// Generic message and fixed 401 — never leak whether the email exists,
// the lockout counter, or GoTrue internals to an unauthenticated caller.
json(response, 401, { message: 'Invalid credentials.' });
return;
```

There is no branching on account existence or lockout state visible to the caller: the lockout counter is incremented and the security alert is attempted internally, but the only external signal is this fixed `{ message: 'Invalid credentials.' }` body.

**Password recovery — unconditional 200:**
`apps/opposite-osiris/scripts/auth-gateway.mjs` lines 922–930 implement `handleRecover`. The GoTrue recovery email is attempted only when the address passes format and deliverability checks, but regardless of whether that attempt was made the response is always:

```js
json(response, 200, { message: 'If an account exists for that email, a reset link has been sent.' });
```

The `200` and the identical body are returned whether the email is registered, unregistered, or fails the deliverability pre-check — the caller learns nothing.

## How we know it is applied

`apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs` lines 117–143 contain a live test case that runs against the running gateway:

```
name: 'failed login returns a generic 401 with no enumeration/internal leak'
description: 'Unknown and known emails with a wrong password return the SAME 401 generic body, leaking nothing.'
```

The test:
1. POSTs a login for a **disposable unknown address** with a wrong password, asserts `status === 401`, asserts `body.message === 'Invalid credentials.'`, and calls `noInternalLeak()` on the serialized body.
2. POSTs the **identical wrong password** for a **known provisioned account**, then calls `assert.deepEqual(knownBody, unknownBody)` — any byte-level divergence between the two failure bodies causes the assertion to fail.

This is an integration gate, not a unit test: it requires `auth-gateway` to be reachable and skips only the known-account leg when no service-role credential is available.

## Reference

The [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) codifies the requirement that authentication failure messages be generic and indistinguishable across all failure modes, precisely to prevent enumeration. The controls above implement this directly at the gateway layer: the gateway is the single point of enforcement, so no frontend variation can accidentally introduce a distinguishing signal.

## Residual risk / assumptions

- **Timing oracle:** The current implementation does not apply a fixed-duration artificial delay to equalize response time across all failure paths. A network-local attacker capable of sub-millisecond timing resolution could potentially distinguish paths where the GoTrue upstream call is skipped (pure-format rejection) from paths where it proceeds. The `hasDeliverableEmailDomain` pre-check in `handleRecover` reduces the call surface but does not eliminate the timing channel.
- **Known-account leg dependency:** The `deepEqual` assertion in `10-gateway-hardening.mjs` requires provisioning a test user via service-role credentials. In environments without a live BaaS or service-role key, that leg is skipped and only the unknown-email path is verified.
- **GoTrue upstream errors:** If GoTrue returns an unexpected non-401 error (e.g., `503`), the current code returns the fixed `401 Invalid credentials.` only after the failed-login branch is reached. An upstream error that causes the outer `protectedAction` wrapper to throw before that branch is reached could surface a different status code; this path is not covered by the hardening test.
- **No MFA enforcement:** The gateway controls enumeration at the login response level but does not enforce a second factor. Credential stuffing against valid accounts is mitigated by the rate-limiter and lockout (separate controls), not by this response-uniformity control.
