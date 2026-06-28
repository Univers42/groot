# MFA & Passkeys — grobase (the BaaS backend)

> grobase enforces phishing-resistant, password-independent authentication through two complementary mechanisms: full WebAuthn/passkey ceremonies in the Go control plane (enterprise, flag-gated) and RFC 6238 TOTP MFA in the Rust data-plane `one` edition — so a stolen password alone is never sufficient to obtain a session.

## What it is (the concept)

**Multi-factor authentication (MFA)** requires a principal to prove identity through two or more independent factors before a session is issued. **Passkeys** (WebAuthn / FIDO2) replace or augment passwords with a **public-key credential** bound to an **authenticator** (hardware security key, platform biometric, or software token): the private key never leaves the authenticator and the **relying-party origin** is baked into the signed assertion, making the credential inherently phishing-resistant. **TOTP (Time-Based One-Time Password)** per RFC 6238 adds a second factor based on a shared secret and a time window, protecting accounts even when an attacker has captured the primary credential.

## What it defends against

See [Credential Phishing & Password-Based Account Takeover](../../attack/mfa-passkeys.md).

In grobase's context, an attacker who steals a user's password (via breach, keylogger, or phishing) cannot complete a WebAuthn login: the assertion must be signed by the private key bound to the registered origin, and that key never left the authenticator. In the `one` edition, even a fully-leaked password only yields an `mfa_token` that expires in 300 seconds; a valid TOTP code or unused recovery code is required to upgrade it to a real session. Disabling TOTP also requires a live factor, so a hijacked session cannot silently strip the second factor.

## How grobase implements it

### WebAuthn / passkeys (Go control plane — enterprise Track-D, `PASSKEYS_ENABLED`)

[`src/control-plane/internal/passkeys/service.go`](../../../../apps/grobase/src/control-plane/internal/passkeys/service.go) builds the relying party via `go-webauthn`:

```go
wa, err := webauthn.New(&webauthn.Config{
    RPID:          cfg.RPID,
    RPDisplayName: cfg.RPDisplayName,
    RPOrigins:     cfg.RPOrigins,
})
```

`RPOrigins` is the exact-match allowlist of permitted client origins; a mismatch is rejected by the library before any application code runs. `BeginRegister` mints a server-side `SessionData` under a one-time `challengeID` (never sent back from the client as a trust anchor); `FinishRegister` calls `sessions.take(challengeID)` — a single-use, TTL-bounded pop that returns `ErrChallengeNotFound` on any missing, expired, or replayed id. Already-registered credentials are passed as exclusions so the same authenticator cannot be double-registered. The library's `CreateCredential` / `ValidateDiscoverableLogin` paths verify the attestation / assertion signature against the stored COSE public key and advance the `sign_count` for clone detection.

[`src/control-plane/internal/passkeys/session_jwt.go`](../../../../apps/grobase/src/control-plane/internal/passkeys/session_jwt.go) mints the resulting session as an HS256 JWT with `amr=webauthn`, mirroring GoTrue's claim shape so the existing `JWTVerifier` accepts it without a second algorithm:

```go
"amr": []map[string]any{{"method": "webauthn", "timestamp": now.Unix()}},
```

The routes are mounted only when `PASSKEYS_ENABLED=1` is set (`handler.go:24`, `store.go:29`); a missing env var means the `/v1/auth/passkeys/*` subtree is physically absent from the router — byte-parity with the OSS edition by construction.

### RFC 6238 TOTP MFA (Rust data plane — `one` cargo feature)

[`src/data-plane-router/crates/data-plane-server/src/one_totp.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/one_totp.rs) implements the full TOTP stack in-tree: HMAC-SHA1 via the `hmac` crate, 6 digits, 30-second period, ±1 step drift:

```rust
fn totp_verify(secret_b32: &str, code: &str, unix: u64) -> bool {
    // ...
    [-1i64, 0, 1].iter().any(|drift| {
        let t = unix.saturating_add_signed(drift * PERIOD as i64);
        format!("{:06}", totp_at(&secret, t)) == code
    })
}
```

Enrolment is two-step: `POST /one/v1/auth/totp/enroll` stores a pending base32 secret (20 bytes from `uuid::Uuid::new_v4()`, getrandom-backed); `POST /one/v1/auth/totp/confirm` accepts the first valid TOTP code, flips the secret live, and emits eight single-use recovery codes whose SHA-256 digests are stored (plaintext codes are returned exactly once and never stored). Disabling TOTP (`POST /one/v1/auth/totp/disable`) requires a live TOTP code or recovery code — a stolen session alone cannot strip the factor.

[`src/data-plane-router/crates/data-plane-server/src/one.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/one.rs) `finish_login()` returns:

```rust
Ok(json!({ "mfa_required": true, "mfa_token": token, "expires_in": 300 }))
```

when `totp_enabled` is true — minting an `mfa`-typed HS256 challenge token with a 300-second TTL. `verify_mfa_token()` checks `claims.typ == "mfa"` before the second-factor handler upgrades to a full session. The `one` feature is compiled only when `one = [... "dep:hmac", "dep:sha1", ...]` is selected in `Cargo.toml` (line 56); it is not present in the `default` or `nano` feature sets.

## How we know it is applied

**Passkeys** — `scripts/verify/m107-passkeys.sh` drives a full A/B/C/D test matrix against a live `tenant-control` binary:

- **(A)** register → login returns HTTP 200 and a session JWT; `sign_count` in `webauthn_credentials` is verified to have incremented after login.
- **(B, load-bearing)** an assertion signed by the **wrong key** against a registered credential id → `401`; a **replayed/consumed** `challenge_id` → `404`/`401`, and no `access_token` is ever present in the body.
- **(C, load-bearing)** U2 cannot authenticate as U1 using U1's credential id and U2's key → `401`.
- **(D)** with `PASSKEYS_ENABLED` unset, every `/v1/auth/passkeys/*` route returns `404` (physical absence confirmed).

The gate also confirms the startup log line `"passkeys / WebAuthn enabled"` before tests run. Go unit tests in `src/control-plane/internal/passkeys/passkeys_test.go` cover `TestSessionStore_SingleUse`, `TestSessionStore_TTLExpiry`, `TestSessionMinter_RoundTrip`, and `TestSessionMinter_WrongSecretRejected`.

**TOTP** — `src/data-plane-router/crates/data-plane-server/src/one_totp.rs` embeds `#[cfg(test)]` tests that run under `cargo test --features one`:

```
totp_matches_rfc6238_vectors   — asserts RFC 6238 appendix-B reference values
verify_accepts_drift_and_rejects_garbage — asserts ±1 window, out-of-window fail, wrong-length fail, bad-secret fail
```

The `one` cargo feature is the compile-time gate; without it, `one_totp.rs` is not compiled into any binary.

## Reference

The [OWASP MFA Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html) defines the minimum requirements for phishing-resistant authentication factors: out-of-band codes must be time-limited and single-use, hardware-backed authenticators must bind to the relying-party origin, and disabling MFA must itself require proof of a live factor. Both grobase controls satisfy all three requirements: WebAuthn origin-binds every assertion; TOTP challenge tokens expire in 300 seconds; recovery codes are single-use; and disabling TOTP requires a current code.

## Residual risk / assumptions

- **WebAuthn is enterprise-only (`PASSKEYS_ENABLED`).** OSS and `nano`/`one` users receive no WebAuthn; they must rely on TOTP or password-only login.
- **TOTP is `one`-edition only.** The default `data-plane-router` binary (feature set `engines-full, control-pg, ratelimit-redis`) ships without TOTP. A deployment that does not build with `--features one` has no second factor in the data plane.
- **`GOTRUE_JWT_SECRET` / `ONE_JWT_SECRET` trust boundary.** Both HS256 session tokens (WebAuthn and TOTP) depend on the secrecy of the shared JWT secret (`GOTRUE_JWT_SECRET` for passkeys, `ONE_JWT_SECRET` for the `one` edition). Compromise of the secret collapses both the first and second factor.
- **Software authenticators.** The WebAuthn ceremonies accept software authenticators (used by the m107 gate itself via a test sidecar). A deployment that does not restrict `authenticatorAttachment` to `platform` or `cross-platform` hardware does not guarantee the private key is resident in a secure enclave.
- **Recovery codes are shown once.** If a user loses both the TOTP device and the recovery codes before saving them, account recovery requires an out-of-band admin action not currently documented in the API.
- **TOTP drift window.** The ±1 step (±30 seconds) window is standard but means a code is valid for up to 90 seconds. No explicit replay-prevention for TOTP codes within the window is implemented (the `one` store does not track last-used counter for TOTP, only for recovery codes).
