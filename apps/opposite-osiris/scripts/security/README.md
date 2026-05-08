# Security test suite

This suite performs outside-in security checks against the BaaS gateway owned by this project. It must never be pointed at systems you do not own or do not have explicit permission to test.

## Run

From `opposite-osiris`:

```bash
npm run test:security
```

Run one category:

```bash
npm run test:security -- --category=auth
```

Available categories:

- `cors`: validates legitimate and hostile CORS preflight behavior.
- `auth`: validates password-grant behavior, injected identifiers, oversized passwords, and brute-force rate limiting.
- `injection`: validates PostgREST query parsing against SQL injection-style inputs.
- `xss`: documents whether profile payloads are rejected or returned as literal JSON strings.
- `headers`: validates HTTP hardening headers and gateway fingerprinting.
- `sensitive-data`: verifies password hashes, session tokens, and user tokens are not exposed to the anonymous role.
- `upload-path`: checks storage path traversal attempts; skipped when storage is disabled or unrouted.
- `rate-limit`: checks gateway behavior under parallel requests, large content-length claims, and many custom headers.
- `gdpr`: checks anonymous privacy boundaries, GDPR RPC authentication, and current-user scoping.

## Configuration

The suite reads:

- `PUBLIC_BAAS_URL` — defaults to `http://localhost:8000`.
- `PUBLIC_BAAS_ANON_KEY` — required; can be loaded from `.env.local`.
- `SECURITY_ALLOWED_ORIGIN` — defaults to `http://localhost:4322`.
- `SECURITY_DISALLOWED_ORIGIN` — defaults to `http://evil.example.com`.
- `SECURITY_TEST_EMAIL` — defaults to `john.doe@example.com`.
- `SECURITY_TEST_PASSWORD` — defaults to `Test123!`.

Tests that need authentication obtain tokens by calling the auth endpoint. Tokens are never hardcoded.

## Results

Each category returns pass, fail, and skipped counts. The orchestrator exits with status `1` if any real vulnerability is detected. Skipped checks document inactive profile features, such as storage being disabled in the minimal local profile.
