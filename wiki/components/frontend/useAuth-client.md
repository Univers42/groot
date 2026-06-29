# useAuth — resilient client-side auth (opposite-osiris)

> **In one sentence.** useAuth is a [React hook](glossary.md#react-hook) that securely manages login, registration, and account recovery by POSTing to a [same-origin](glossary.md#same-origin) auth gateway with cookies, retrying gracefully on rate-limits with [exponential backoff](glossary.md#exponential-backoff), and validating email and password strength on the client before submission.

## What it is & why it exists

useAuth encapsulates client-side authentication orchestration for a React app. It abstracts the HTTP conversation with a backend [auth gateway](glossary.md#auth-gateway) (the "opposite" of the app's core logic—auth is a cross-cutting concern), handling credential-carrying POST requests, resilience against transient failures, client-side validation, and support for modern [MFA](glossary.md#mfa) methods like [TOTP](glossary.md#totp) and [WebAuthn](glossary.md#webauthn). The hook returns an object of methods for signing in, registering, recovering accounts, refreshing sessions, and initiating downstream session handoffs to other services (like the [osionos bridge](glossary.md#osionos-bridge)).

## How it works

- On setup, useAuth normalizes the gateway URL (strips trailing slash) and reads max-retry count from options or auth config.
- It creates a `post()` helper that wraps `fetch` with `credentials:'include'` to send cookies with same-origin requests.
- The `post()` helper uses `fetchWithBackoff`, which detects [HTTP 429](glossary.md#http-429) (rate limit) responses and retries with exponential backoff (400ms → 800ms → 1600ms), respecting the server's [Retry-After header](glossary.md#retry-after) if present, and adding [random jitter](glossary.md#random-jitter) to avoid thundering herd.
- Before submitting login or register requests, the hook validates email ([RFC 5322](glossary.md#rfc-5322) compliant) and password (8+ chars, mixed case, digit, symbol) on the client to fail fast.
- It parses gateway responses carefully, extracting [access tokens](glossary.md#access-token), error messages, and redirect URLs, with fallbacks for malformed responses.
- It provides methods for login, register, account recovery, token refresh, logout, MFA enrollment/verification (TOTP, WebAuthn), and bridging to downstream services (osionos).

## The code that does it

**What to look at:** useAuth factory normalizes gateway URL and creates `post()` helper that sends cookies via `credentials:'include'` for same-origin auth requests.

```ts
// apps/opposite-osiris/src/hooks/useAuth.ts:194-202
export function useAuth(options: AuthClientOptions = {}) {
	const gatewayUrl = normalizeGatewayUrl(options.gatewayUrl ?? authConfig.gatewayUrl);
	const maxRetries = options.maxRetries ?? 3;
	const post = async (path: string, body: Record<string, unknown>): Promise<Response> => fetchWithBackoff(`${gatewayUrl}${path}`, {
		method: 'POST',
		headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
		credentials: 'include',
		body: JSON.stringify(body),
	}, maxRetries);
```

**What to look at:** Exponential backoff retry loop: detects 429 (rate limit), respects server's Retry-After header, adds random jitter, and caps total delay at 5 seconds.

```ts
// apps/opposite-osiris/src/hooks/useAuth.ts:180-192
async function fetchWithBackoff(url: string, init: RequestInit, maxRetries: number): Promise<Response> {
	let attempt = 0;
	for (;;) {
		const response = await fetch(url, init);
		if (response.status !== 429 || attempt >= maxRetries) {
			return response;
		}
		const retryAfter = Number(response.headers.get('retry-after'));
		const baseDelay = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 400 * 2 ** attempt;
		await delay(Math.min(baseDelay + randomJitter(150), 5000));
		attempt += 1;
	}
}
```

**What to look at:** Client-side validators: email uses RFC 5322 regex (handles + addressing and quoted-strings), password requires 8+ chars with mixed case, digit, and symbol.

```ts
// apps/opposite-osiris/src/hooks/useAuth.ts:83-89
export function validateEmail(email: string): boolean {
	return RFC_5322_EMAIL_REGEX.test(email.trim());
}

export function validatePassword(password: string): boolean {
	return STRONG_PASSWORD_REGEX.test(password);
}
```

## Where it sits in the app

The user interacts with forms (login, register, password recovery, MFA) in the frontend; those forms call useAuth methods; useAuth POSTs to the same-origin auth gateway (a backend HTTP bridge that enforces strong authentication, rate-limiting, and tokens); the gateway responds with access tokens or redirects; useAuth returns those to the form, which then refreshes the app state or navigates. Access tokens are later used to authenticate requests to other downstream services (like osionos) via Authorization headers.

## Remember this

> useAuth isolates credential-carrying HTTP complexity on the client: cookie handling, rate-limit resilience, client validation, and multi-method MFA—all behind a simple async API.

---
**See also:** [mail-bridge-client.md](mail-bridge-client.md) · [useGraphEngine.md](useGraphEngine.md) · [mail-cache.md](mail-cache.md) · [formula-engine-wasm.md](formula-engine-wasm.md) · [Glossary](glossary.md)
