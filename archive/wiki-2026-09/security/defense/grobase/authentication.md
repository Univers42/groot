# Authentication — grobase (the BaaS backend)

> Every request to the grobase data plane must carry a verifiable credential — an API key at the edge, a cryptographically validated JWT for user identity, and a constant-time HMAC-signed token for internal service calls — before any query reaches an upstream engine.

## What it is (the concept)

**Authentication** is the process of proving that a principal (user, service, or API consumer) is who it claims to be before granting access to protected resources. In a multi-tenant BaaS, authentication operates at multiple layers: the **API gateway** validates the credential at the network edge, the **identity provider** issues and expires session tokens, and the **internal service mesh** authenticates plane-to-plane calls without transmitting the raw shared secret. Weak authentication at any layer undermines the isolation guarantees of all higher layers.

## What it defends against

See [Credential Theft / Broken Authentication](../../attack/authentication.md).

In grobase's threat model, the attack surface is broad: anonymous callers reaching multi-engine data routes without any credential, forged or expired JWTs bypassing the `exp`/`iss`/`sub` validation, JWT algorithm-confusion attacks (feeding an RS256 public key as the HMAC secret or submitting `alg:none`), user-enumeration through the password-recovery endpoint's differential response, and internal service tokens being intercepted and replayed across endpoints. OWASP A07:2021 — Identification and Authentication Failures covers all of these.

## How grobase implements it

Four complementary controls are live simultaneously.

### 1. Kong gateway: API key + HS256-pinned JWT on every data route

`infra/docker/services/kong/conf/kong.yml` declares the declarative DB-less Kong configuration loaded at boot. Every data route (`/rest/v1`, `/query/v1`, `/storage/v1`, realtime, the data-plane-direct route) carries both a `key-auth` plugin (requiring an `apikey` header — the anon or service-role key) and a `jwt` plugin:

```yaml
# kong.yml lines 22-29 — consumer 'authenticated' pinning HS256
- username: authenticated
  jwt_secrets:
    - key: __GOTRUE_JWT_ISS__
      secret: __JWT_SECRET__
      algorithm: HS256
```

```yaml
# rest-routes plugin block (lines 185-196)
- name: jwt
  config:
    key_claim_name: iss
    claims_to_verify: [exp]
    anonymous: __KONG_ANON_UUID__
```

The `__JWT_SECRET__` and `__GOTRUE_JWT_ISS__` placeholders are substituted from environment variables at Kong container startup via `sed` in `orchestrators/compose/base/gateway.yml` (lines 67-75), so the raw secret is never present in the YAML on disk.

### 2. Go control-plane: single-algorithm JWT verifier (alg-confusion guard)

`src/control-plane/internal/tenants/jwt.go` implements `JWTVerifier`, constructed at service boot for exactly one algorithm. Its `keyFunc` rejects any token whose signing method does not match the configured algorithm:

```go
// jwt.go lines 102-104 — algorithm-confusion guard
func (v *JWTVerifier) keyFunc(t *jwt.Token) (any, error) {
    if t.Method.Alg() != v.alg {
        return nil, fmt.Errorf("unexpected signing method: %s (want %s)", t.Method.Alg(), v.alg)
    }
```

`jwt.Parse` is additionally called with `jwt.WithValidMethods([]string{v.alg})` (line 82), closing the `alg:none` downgrade path in both the header-level check and the parse-level allowlist. `validateClaims` (lines 116-131) enforces `exp`, an optional `iss` match, and the presence of a non-empty `sub`. In RS256 mode (`JWT_ALG=RS256` + `JWKS_URL`), `src/control-plane/internal/tenants/jwks.go` resolves rotating public keys by `kid` — verify-only, the control plane never holds a private key. `SECURITY.md` §3 documents: "algorithm pinned (no `none`/algorithm swaps)".

### 3. Internal service-to-service auth: constant-time token with HMAC signed-request mode

`src/control-plane/internal/serviceauth/serviceauth.go` and `token.go` authenticate plane-to-plane HTTP calls. In static mode (the default), `verifyStaticToken` evaluates both the current and rotation-previous arms unconditionally — no `||` short-circuit — using `subtle.ConstantTimeCompare` so timing cannot reveal which key matched:

```go
// serviceauth.go lines 51-55
func verifyStaticToken(r *http.Request, expected, prev string) bool {
    got := r.Header.Get("X-Service-Token")
    curOK := SecureCompare(got, expected)
    prevOK := prev != "" && SecureCompare(got, prev)
    return curOK || prevOK
}
```

Under `SERVICE_TOKEN_MODE=hmac`, `verifyHMAC` requires an `X-Service-Auth: v1.<ts>.<sig>` header where the HMAC-SHA256 signature binds the timestamp, HTTP method, path, and SHA-256 of the body (computed in `token.go` line 64):

```
msg = "<ts>\n<METHOD>\n<PATH>\n<sha256hex(body)>"
```

A captured signature cannot be replayed against a different endpoint, body, or outside the `±SERVICE_AUTH_SKEW_SECS` clock window (default 120 s, `serviceauth.go` lines 88-96). `INTERNAL_SERVICE_TOKEN_PREV` enables a zero-downtime rotation window where both the current and previous tokens are accepted. The identical HMAC logic is implemented in all three planes:

- Go: `src/control-plane/internal/serviceauth/token.go` (`ComputeServiceSignature`)
- Rust: `src/data-plane-router/crates/data-plane-pool/src/service_auth.rs` (`compute_service_auth_at`)
- TypeScript: `src/libs/common/src/security/service-auth.ts` (`computeServiceAuth`)

All three sign byte-identically; `service_auth.rs` carries cross-language golden-vector tests (`golden_vectors_match_go`, line 121).

### 4. User-enumeration fix: bundled mailpit SMTP sink

`orchestrators/compose/base/auth-api.yml` wires `mailpit` as a health-checked dependency of `gotrue` (lines 68-69: `mailpit: condition: service_healthy`). The inline comment at line 81-83 documents the threat directly:

> without a sink, `/auth/v1/recover` 500s for real users (mail send fails) but 200s for unknown ones — a user-enumeration differential. A bundled sink makes recovery mail "send" so `/recover` returns 200 uniformly.

`SECURITY.md` §5 table row F4 confirms the fix: "bundled mailpit SMTP sink so recovery mail sends and `/recover` returns 200 uniformly — `m156`".

## How we know it is applied

**Gate m156** (`scripts/verify/m156-recover-no-enumeration.sh`) is the live proof for the enumeration fix. It asserts that the HTTP status for a recovery request is identical for a seeded address and a random unknown address, and that neither is a 500:

```bash
# m156, lines 40-43
C_EXIST=$(rec "$EXIST")
C_BOGUS=$(rec "$BOGUS")
[ "$C_EXIST" != "500" ] || fail "recover(existing) still 500 — SMTP send failing"
[ "$C_EXIST" = "$C_BOGUS" ] || fail "ENUMERATION: existing=$C_EXIST vs bogus=$C_BOGUS differ"
```

For JWT verification, `src/control-plane/internal/tenants/jwt_test.go` and `jwks_test.go` cover algorithm pinning and JWKS rotation, run under `make go-control-plane-check` (`go test ./...`). The service-auth HMAC path is covered by `src/control-plane/internal/serviceauth/token_test.go` and `serviceauth_fuzz_test.go` (also under `go test ./...`), and by the Rust golden-vector test `golden_vectors_match_go` in `service_auth.rs` (under `cargo test --workspace`).

## Reference

The [Authentication Cheat Sheet (OWASP)](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) identifies algorithm pinning, constant-time secret comparison, and uniform responses on credential-related endpoints as foundational controls. Grobase implements all three mechanically — in code and verified in CI — not as operational policy.

## Residual risk / assumptions

- **HS256 is a shared-secret scheme**: if `JWT_SECRET` is compromised, any party can forge valid tokens for any user. The RS256/JWKS path (`JWT_ALG=RS256`) removes this risk in production but is not the default; `SECURITY.md` §3 notes it as the recommended go-live configuration.
- **Kong admin is not bound to a public interface** (gate `m157` verifies this), but the DB-less config means a container compromise with filesystem read access exposes the templated `kong.yml` (with substituted secrets) in memory — the secrets are ephemeral and live only in the running container's environment.
- **Mailpit is a development SMTP sink**: it accepts any mail without authentication (`MP_SMTP_AUTH_ACCEPT_ANY: "true"`). The anti-enumeration property depends on GoTrue's SMTP delivery succeeding; if mailpit is replaced by a real SMTP relay in production, that relay must also return success for the recovery endpoint to remain non-oracular.
- **Service-auth HMAC mode is opt-in**: the default `static` mode transmits the raw token in `X-Service-Token`. Operators who do not set `SERVICE_TOKEN_MODE=hmac` do not get replay protection, only constant-time comparison.
- **Clock skew window**: the 120-second default skew for HMAC signatures is generous; a compromised internal network with NTP manipulation could extend the effective replay window.
