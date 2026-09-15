# Rate Limiting & Brute-Force Defense — grobase (the BaaS backend)

> grobase enforces layered throttles at every auth-adjacent surface: a Kong per-IP gateway cap
> per route, an application-level OTP attempt cap with constant-time verification and single-use
> codes, an argon2id concurrency semaphore against memory-exhaustion, and a per-tenant token bucket
> in the Rust data plane — together preventing credential brute-force, email-bomb abuse, and
> noisy-tenant DoS from reaching the identity authority or the query path.

---

## What it is (the concept)

**Rate limiting** constrains how many requests a client may issue within a time window; when
exceeded, the server returns **429 Too Many Requests** rather than processing the call. Applied to
authentication surfaces, it is the primary mechanical defense against **brute-force attacks** — the
systematic automated trial of credentials, OTP codes, or API keys — and against **credential
stuffing**, where attacker-held breach lists are replayed against an unrelated service. A
complementary control is the **attempt cap**: a per-resource counter that locks the authentication
object (OTP code, session) independently of the caller's IP or rate, so distributing requests across
many IPs does not bypass it.

---

## What it defends against

See [Brute Force & Credential Stuffing](../../attack/rate-limiting-brute-force.md).

In grobase's threat model the exposed surfaces are: the email-OTP login flow (6-digit code, 10⁶
space), API-key verification (argon2id, expensive by design), admin/provisioning routes (high-value
control-plane writes), and the data-plane query path (per-tenant resource exhaustion). Without
throttling, each of these can be driven to exhaustion by an unauthenticated caller — the OTP space
is small enough to brute-force in minutes at unrestricted rates, and bulk argon2id calls crash the
container under its memory limit.

---

## How grobase implements it

### 1. Email-OTP: attempt cap, constant-time verify, single-use, peppered hash

`src/control-plane/internal/loginotp/otp.go`

The `Request()` function always returns `nil` to the caller regardless of whether the email is
registered, preventing user enumeration via the login channel:

```go
// Request generates a 6-digit code, stores its peppered hash, and emails it. It NEVER
// reveals whether the email is registered (always returns nil to the caller).
func (s *Service) Request(ctx context.Context, email string) error { … }
```

`Verify()` enforces the attempt cap, constant-time comparison, and single-use consumption:

```go
if row.attempts >= s.maxAttempts {
    return "", ErrLocked          // → HTTP 429
}
_ = s.bumpAttempt(ctx, row.id)
if subtle.ConstantTimeCompare([]byte(s.hashCode(email, code)), []byte(row.codeHash)) != 1 {
    return "", ErrInvalid         // → HTTP 401
}
if err := s.consume(ctx, row.id); err != nil { … }
return s.mintProof(email)
```

The stored hash is peppered and email-bound (`sha256(pepper:email:code)`), so a database leak
is useless for offline guessing without the pepper:

```go
func (s *Service) hashCode(email, code string) string {
    sum := sha256.Sum256([]byte(string(s.pepper) + ":" + strings.ToLower(email) + ":" + code))
    return hex.EncodeToString(sum[:])
}
```

On success, `mintProof()` issues a 5-minute `aud:"otp-proof"` HS256 token that the subsequent
login step must present and verify, bounding the proof's usable window.

### 2. Kong gateway: per-route, per-IP rate limits scaled to sensitivity

`infra/docker/services/kong/conf/kong.yml`

Every route carries a declarative `rate-limiting` plugin (`policy: local, limit_by: ip`). Caps are
tiered by the sensitivity of the surface:

| Route | minute cap | hour cap |
|---|---|---|
| `email-routes` (`/email/v1`) | 10 | 200 |
| `auth-otp` (`~/v1/auth/otp/.*`) | 30 | 200 |
| `admin-provision` (`/admin/v1/provision`) | 30 | 500 |
| `admin-tenants` (`/admin/v1/tenants`) | 60 | 1000 |

The email route (lines 912–917):

```yaml
- name: rate-limiting
  config:
    policy: local
    limit_by: ip
    minute: 10
    hour: 200
```

The auth-otp route also carries a `request-size-limiting` plugin, and is gated by the
`EMAIL_OTP_ENABLED` flag — when the flag is off, the upstream returns 404.

**High-volume app paths** (`/query/v1`, `/data/v1`) carry a deliberately high edge cap
(150 000 req/min) because a single-IP app server is the normal deployment shape; throttling on
those paths is delegated to the per-tenant token bucket in the Rust plane (see §4 below). The kong.yml
comment at line 829–835 documents the rationale and references the bench measurement that prompted
raising the limit.

### 3. GoTrue email-send rate cap

`orchestrators/compose/base/auth-api.yml`

GoTrue's built-in email-send throttle caps outbound mail per source IP:

```yaml
GOTRUE_RATE_LIMIT_HEADER: X-Real-IP
GOTRUE_RATE_LIMIT_EMAIL_SENT: ${GOTRUE_RATE_LIMIT_EMAIL_SENT:-100}
```

This bounds email-bomb abuse on the GoTrue `/auth/v1/signup` and `/auth/v1/recover` paths
independently of Kong, keyed on the forwarded real client IP.

### 4. Argon2id concurrency semaphore against memory-exhaustion DoS

`src/control-plane/internal/tenants/keys_hash_argon2.go`

API-key verification runs argon2id, which allocates 32 MiB per call. Unbounded concurrent
verifications OOM-kill the container (a 16-way bulk provision measured on 2026-06-11 crashed
the container in 8 restart loops under its 64 MiB limit). `keyHasher` bounds parallelism with a
channel-based semaphore:

```go
type keyHasher struct {
    slots chan struct{}   // capacity = ARGON2_MAX_CONCURRENT, default 2
}

func newKeyHasher() *keyHasher {
    return &keyHasher{slots: make(chan struct{}, argon2MaxConcurrent())}
}
```

Each `hashPayload` call acquires a slot before calling `argon2.IDKey` and releases it in a
deferred closure — requests beyond the bound queue rather than triggering an OOM. Peak hash
memory = `slots × 32 MiB`; the default of 2 slots caps this at 64 MiB.

### 5. Per-tenant token bucket in the Rust data plane

`src/data-plane-router/crates/data-plane-server/src/ratelimit.rs`

`TenantRateLimiter` implements a lazy-refill token bucket keyed by `tenant_id`, with `rps`
(refill) and `burst` (capacity) sourced from the tenant's package tier mask:

```rust
pub fn allow(&self, tenant: &str, rps: u32, burst: u32) -> bool {
    if rps == 0 { return true; }   // parity: untiered tenants are unlimited
    …
    let (new_tokens, admitted) = refill_and_take(bucket.tokens, elapsed, rps, burst);
    admitted
}
```

The pure math (`refill_and_take`) is mirrored verbatim in a Redis Lua script so a multi-replica
deployment can share one authoritative bucket per tenant (`DATA_PLANE_RATELIMIT_BACKEND=redis`).
Tier parameters (`rps`, `burst`) arrive inside the mount's `capability_overrides` from the
key-verify response; when no tier mask is set (`rps == 0`), the path is unlimited by design
(parity). The Redis backend fails open — if Redis is unreachable the limiter admits and logs,
so it is never an availability single-point-of-failure.

---

## How we know it is applied

**OTP attempt cap — gate `scripts/verify/m164-email-otp.sh`:** the gate runs a self-contained
container pair (OTP enabled vs. disabled) and asserts the attempt cap fires:

```sh
# wrong code + attempt cap (max=3): request fresh, then 3 wrong → 401, 4th → 429.
[[ "$(otp_req … /v1/auth/otp/verify '{"code":"000000"}')" == "429" ]] \
  || fail "(B) attempt cap not enforced (4th wrong should be 429)"
ok "(B) wrong code → 401; the 4th attempt → 429 (attempt cap enforced)"
```

**Kong 429 fires in practice — `scripts/verify/m23-live-edge-battery.sh`:** the live edge battery
explicitly retries on Kong 429 responses, confirming the rate-limiting plugin fires on the gateway:

```sh
# Retries on Kong 429 (rate limiting under back-to-back gate runs)
if [[ "${code}" == "429" ]] || grep -q 'auth_verify_unavailable' /tmp/m23.json; then
```

**Argon2 semaphore:** constructed in `newKeyHasher()` per `Service` instantiation; every key
hash and verify call passes through the semaphored `hashPayload`. The crash incident (2026-06-11)
that motivated it is documented in the doc comment of `keyHasher`.

**Rust token bucket:** `ratelimit.rs` includes an inline test suite (lines 295–448) covering
unlimited-when-rps-zero, burst-then-deny-then-refill, per-tenant isolation, idle-bucket eviction,
and — under the `ratelimit-redis` feature — a two-instance Redis sharing proof
(`redis_backend_is_one_global_bucket_across_instances`).

---

## Reference

The OWASP Authentication Cheat Sheet ([https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html))
covers the full spectrum of controls that make a login flow resilient, including rate limiting,
account lockout, and safe credential storage. grobase's OTP design draws directly from its
constant-time comparison, attempt-cap, and anti-enumeration recommendations; the per-route
gateway tiering maps to its principle of throttling all authentication-adjacent endpoints, not
only the primary login path.

---

## Residual risk / assumptions

- **Kong `policy: local`** — rate-limit state is in-process per Kong instance. A multi-replica
  Kong deployment (not the default in this stack) means each instance independently enforces the
  cap; a distributed attacker can multiply their effective budget by the replica count. Switching
  to `policy: redis` resolves this.
- **High app-route ceilings** — `/query/v1` and `/data/v1` carry 150 000 req/min edge caps to
  accommodate single-IP app servers. Meaningful brute-force throttling on those paths relies
  entirely on the per-tenant token bucket having a non-zero tier mask; untiered tenants (`rps == 0`)
  are effectively unlimited at the query layer.
- **Rust token bucket is tier-gated** — in the default OSS parity stack no tier mask is assigned,
  so `TenantRateLimiter.allow()` returns `true` unconditionally for all tenants. The bucket
  becomes the real product limiter only once package tiers with `rps`/`burst` masks are provisioned.
- **OTP pepper is an env var** — the pepper's value is critical; if the `OTP_PEPPER` (or equivalent)
  secret is compromised, the anti-offline-guess property of `hashCode` is void. The pepper must be
  rotated with the same care as the JWT signing secret.
- **Constant-time applies to hash comparison only** — timing attacks on the OTP flow are precluded
  for the code-hash comparison step (`subtle.ConstantTimeCompare`), but network jitter at the HTTP
  layer is not controlled. A local-network attacker with sub-millisecond precision could still
  observe timing differences from the DB lookup; this is accepted risk at the current threat model.
