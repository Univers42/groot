# Input Validation — auth-gateway (the auth BFF)

> Every request body is structurally validated — email format, username shape, body size — before
> any backend call is issued, and every email-accepting endpoint also confirms that the claimed
> domain can actually receive mail.

## What it is (the concept)

**Input validation** is the practice of asserting that data received from an untrusted source
conforms to an expected **type, format, and length** before the application acts on it. A strict
**allowlist** (positive validation) rejects anything that does not match a known-good pattern,
rather than attempting to block known-bad values. **Size bounding** prevents oversized payloads from
exhausting memory or exploiting length-sensitive parsing bugs downstream.

## What it defends against

See [Injection Attacks (SQLi, XSS, Command Injection)](../../attack/input-validation.md).

Malformed identity strings (email, username) can slip through a lenient BaaS and later re-surface as
stored XSS payloads, SQL fragment injections, or SMTP-header-injection vectors once they reach
downstream email or database layers. Oversized bodies can trigger unbounded memory growth in a
Node.js stream reader. Unverifiable email domains enable disposable-account spam and email-bomb
staging — an attacker registers thousands of accounts targeting a victim address with no SMTP
deliverability ever confirmed.

## How auth-gateway implements it

All validation logic lives in
[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs).

### 1. Compiled regex constants (lines 84–89)

Three regex constants are defined once at module load and reused across every handler:

```js
const EMAIL_REGEX = new RegExp(
  String.raw`^${EMAIL_LOCAL_PART}@(?:${EMAIL_DOMAIN_LABEL}\.)+[A-Za-z]{2,63}$`
);
const PASSWORD_REGEX = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$/;
const USERNAME_REGEX = /^\w[\w.-]{2,31}$/;
```

`EMAIL_REGEX` implements a strict RFC-ish local-part + domain-label grammar (2–63 character TLD).
`USERNAME_REGEX` constrains usernames to word characters, dots, and hyphens, 3–32 characters total.
`PASSWORD_REGEX` enforces complexity (mixed-case, digit, symbol, minimum 8 characters).

### 2. 32 KB body cap — `readJson` (lines 144–151)

Every handler that parses a JSON request body calls `readJson`, which accumulates chunks and aborts
immediately if the running total exceeds 32 768 bytes:

```js
async function readJson(request) {
  let body = '';
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 32_768) throw Object.assign(new Error('Request body too large.'), { status: 413 });
  }
  return body ? JSON.parse(body) : {};
}
```

The thrown error is mapped to HTTP 413 before any further processing occurs.

### 3. Registration gate — `isValidRegistrationContext` (lines 718–724)

Registration collects email, password, and username in a single structured object.
`isValidRegistrationContext` asserts all three regexes and that `confirmPassword` matches before any
BaaS call:

```js
function isValidRegistrationContext({ email, password, profile }) {
  return EMAIL_REGEX.test(email)
    && PASSWORD_REGEX.test(password)
    && USERNAME_REGEX.test(profile.username)
    && profile.confirmPassword === password
    && (!config.requireEmailVerification || profile.email_verification_consent);
}
```

A `cleanText` helper (line 674–676) hard-truncates any free-text field to a caller-supplied
`maxLength` before it reaches this check: `String(value ?? '').trim().slice(0, maxLength)`.

### 4. Login handler — `handleLogin` (lines 874–920)

Email and password are validated inline before the credential check; any mismatch returns 422 and
the function returns without calling the BaaS:

```js
if (!EMAIL_REGEX.test(email) || password.length === 0) {
  json(response, 422, { message: 'Invalid credentials.' });
  return;
}
```

### 5. Email-domain deliverability gate — `hasDeliverableEmailDomain` (lines 212–223)

Registration (`handleRegister`, line 830), password recovery (`handleRecover`, line 925), and
newsletter subscription (`handleNewsletterSubscribe`, line 975) all gate on
`hasDeliverableEmailDomain` before proceeding:

```js
async function hasDeliverableEmailDomain(email) {
  if (isAllowedEmailDomain(email)) return true;           // allowlist fast-path
  const domain = emailDomain(email);
  const cacheKey = `mxcache:${domain}`;
  const cached = await store.get(cacheKey);
  if (cached !== null) return cached === '1';
  const timeout = new Promise((r) => globalThis.setTimeout(() => r(false), DNS_LOOKUP_TIMEOUT_MS));
  const lookup = Promise.allSettled([resolveMx(domain), resolve4(domain), resolve6(domain)])
    .then((results) => results.some((r) => r.status === 'fulfilled' && r.value?.length > 0));
  const valid = await Promise.race([lookup, timeout]);
  await store.set(cacheKey, valid ? '1' : '0', Math.floor(MAIL_DOMAIN_CACHE_MS / 1000));
  return valid;
}
```

The DNS probe races against a 3 500 ms timeout (`DNS_LOOKUP_TIMEOUT_MS = 3500`); results are cached
for 10 minutes (`MAIL_DOMAIN_CACHE_MS = 10 * 60 * 1000`) to avoid hammering resolvers. An explicit
allowlist (`allowedEmailDomains`, lines 195–210) covers the sender domain and local-dev hostnames,
giving the check a fast path that bypasses DNS for trusted domains.

## How we know it is applied

The validators are not optional middleware — they are synchronous guards placed **before** every
`await` call to the BaaS or SMTP layer inside each handler. Because the module has no conditional
import or feature flag for these checks, they fire on every request reaching those routes.

Concrete wiring evidence:
- `handleLogin` (line 878): `EMAIL_REGEX.test(email)` runs before `signInWithPassword`.
- `handleRegister` (line 826): `isValidRegistrationContext(context)` runs before `hasDeliverableEmailDomain` and before the BaaS account-creation call.
- `handleNewsletterSubscribe` (line 971): `EMAIL_REGEX.test(email)` then `hasDeliverableEmailDomain` run before `requestNewsletterOptIn`.
- `readJson` (line 148): body cap fires during chunk iteration, before `JSON.parse` is ever reached.

## Reference

[Input Validation — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html)

The OWASP cheat sheet formalises the principle that validation must occur **server-side** using
allowlist rules, and must be applied **before** the input is passed to any interpreter (SQL engine,
HTML renderer, mail transport). auth-gateway's design follows this model exactly: regex allowlists
are enforced at the HTTP boundary inside the BFF, so no raw user string reaches GoTrue, PostgREST,
or the SMTP relay unchecked.

## Residual risk / assumptions

- **Coverage is handler-scoped, not middleware-global.** A future handler that calls `readJson`
  without subsequently invoking `EMAIL_REGEX.test` or `isValidRegistrationContext` would admit
  unvalidated input. There is no framework-level middleware enforcing validation uniformly.
- **Username uniqueness is checked via `identityAvailability` against the BaaS**, not enforced by
  the regex alone; a race condition between the check and the insert could allow duplicates under
  high concurrency.
- **DNS deliverability is not SPF/DKIM/DMARC verification.** A domain that has MX records but whose
  mail infrastructure is misconfigured or compromised will pass this gate.
- **The 32 KB cap applies to JSON body reads; multipart or streamed uploads are not routed through
  `readJson`** and would need their own size enforcement if ever introduced.
- **`cleanText` truncates but does not sanitise** (no HTML escaping, no Unicode normalisation);
  downstream renderers must handle output encoding independently.
