# Session Management — grobase (the BaaS backend)

> grobase enforces short-lived access tokens, mandatory refresh-token rotation with single-use consumption enforced at the database row level, revocation of all sessions on password reset, and optional TOTP MFA — across both the GoTrue auth service and the binocle-one Rust edition.

## What it is (the concept)

**Session management** is the discipline of creating, maintaining, and terminating authenticated sessions in a way that limits the damage if a session credential is stolen. A **session token** (here a signed **JWT**) proves identity for one request window; a **refresh token** exchanges for a new access token when the old one expires. Correct session management means tokens expire, cannot be reused after consumption, and are fully revoked when a user signals a security event such as a password reset.

## What it defends against

See [Session Hijacking / Session Fixation](../../attack/session-management.md). In grobase's context the primary threats are:

- **Stolen refresh tokens**: an attacker who intercepts a long-lived refresh token can silently mint new access tokens indefinitely — rotation and single-use consumption close this window.
- **Persistent sessions after account takeover**: if an attacker changes a password, pre-existing sessions must be invalidated; without explicit revocation they remain live.
- **Single-factor account takeover**: TOTP MFA means a stolen password alone is insufficient to complete a login.

## How grobase implements it

### GoTrue session hardening (default edition)

The GoTrue auth service is configured exclusively via environment variables on the `gotrue` container in [`apps/grobase/orchestrators/compose/base/auth-api.yml`](../../../../apps/grobase/orchestrators/compose/base/auth-api.yml) (lines 29–45):

```yaml
GOTRUE_JWT_EXP: 3600                                       # access token: 1-hour hard cap
GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED: "true"     # each refresh mints a new token
GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL: 10           # 10 s replay-grace; a second use is flagged
GOTRUE_MFA_ENABLED: "true"                                  # TOTP 2FA is available
GOTRUE_SECURITY_MFA_MAX_ENROLLED_FACTORS: 5
GOTRUE_SECURITY_MFA_MAX_VERIFIED_FACTORS: 5
GOTRUE_PASSWORD_MIN_LENGTH: 8
GOTRUE_RATE_LIMIT_HEADER: X-Real-IP
```

The `GOTRUE_JWT_SECRET` variable is bound from `${JWT_SECRET}`, which is provisioned by vault42 (or auto-generated in no-vault mode) and is never a literal value in the compose file. `GOTRUE_JWT_ISSUER` is pinned to the canonical external URL, ensuring downstream verifiers (PostgREST via `PGRST_JWT_SECRET`) reject tokens from any other issuer.

### Opaque rotating refresh tokens — binocle-one Rust edition

The `one` cargo feature of the data-plane-server implements its own auth layer in [`apps/grobase/src/data-plane-router/crates/data-plane-server/src/one.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/one.rs).

**Minting** (`mint_refresh`, line 632): a raw token of the form `nrt_<12-char-rowid>.<64-char-secret>` is generated using two UUIDs from the OS CSPRNG, and only its `SHA-256` digest is persisted in the `one_refresh` SQLite table with a `expires_at = now + 30 days` bound:

```rust
conn.execute(
    "INSERT INTO one_refresh (id, user_id, digest, expires_at) VALUES (?1, ?2, ?3, ?4)",
    rusqlite::params![row_id, user_id, sha256_hex(&raw), expires],
)?;
```

**Single-use consumption** (`consume_refresh`, line 651): the row is DELETEd unconditionally on first lookup — even if the digest check subsequently fails — so a guessed or replayed token cannot be verified a second time:

```rust
let _ = conn.execute("DELETE FROM one_refresh WHERE id = ?1", [&row_id]);
if !ct_eq(&sha256_hex(raw), &digest) || chrono::Utc::now().timestamp() >= expires_at {
    return None;
}
```

The constant-time comparison (`ct_eq`, line 83) prevents a timing side-channel on the digest comparison.

**Revocation on password reset** (`revoke_user_refresh`, line 372): a single `DELETE FROM one_refresh WHERE user_id = ?1` removes every outstanding refresh token for the user before the new password hash is stored, ensuring no pre-reset session survives.

**TOTP MFA** (one edition, gate `m42-one-mfa.sh`): the `one_totp` table stores a confirmed TOTP secret per user; once enrolled and confirmed, subsequent logins return `mfa_required` and the caller must supply a valid RFC-6238 code before a session is issued.

## How we know it is applied

**GoTrue controls (default edition):** the environment values are applied directly to the running `mini-baas-gotrue` container at boot — they are not documentation; they are container environment. The healthcheck at lines 70–75 of `auth-api.yml` (`wget -qO- http://localhost:9999/health`) is a liveness gate on every `make all` run. The value `GOTRUE_JWT_EXP=3600` is also cross-referenced in [`apps/grobase/SECURITY.md`](../../../../apps/grobase/SECURITY.md) line 54.

**binocle-one rotation (one edition):** gate `scripts/verify/m40-one.sh` (step 6/8) exercises the rotation live:

```sh
step "6/8 refresh rotation + logout"
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF_A}\"}")
[[ "$(status_of "$R")" == "200" ]] || fail "refresh: $R"
REF_A2=$(field refresh "$R")
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF_A}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "consumed refresh must 401: $R"
ok "rotation single-use; logout revokes"
```

Gate `scripts/verify/m42-one-mfa.sh` (step 2/6) asserts that after a password reset the pre-reset refresh token is explicitly revoked:

```sh
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF_G}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "pre-reset refresh token must be revoked: $R"
ok "reset works, old password + old refresh dead, no enumeration"
```

The same gate (step 4/6) verifies the full TOTP enroll → confirm → challenge → upgrade-to-session flow using an RFC-6238 code computed in-gate with Python's `hmac`/`struct` modules.

## Reference

The [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) defines the canonical requirements for token generation strength, expiry, rotation, and revocation that grobase's controls directly address. It is particularly relevant to the choice of SHA-256 digest storage (never plaintext token persistence), the constant-time comparison to prevent timing oracles, and the full-revocation requirement on a credential change event.

## Residual risk / assumptions

- **GoTrue rotation applies only to the GoTrue path.** Tenants using direct PostgREST access with a long-lived API key (`mbk_*`) bypass GoTrue entirely; those keys have no automatic rotation and must be rotated manually via the control plane.
- **binocle-one is a separate product shape.** The Rust single-use rotation and revocation described above apply only when the `one` cargo feature is compiled in (`make one-up`). The default multi-engine edition delegates all auth to GoTrue; the two paths do not share a session store.
- **The 10-second reuse interval on GoTrue** is a grace window for legitimate concurrent requests, not a full replay-prevention guarantee within that window.
- **TOTP MFA is opt-in per user.** It is enabled at the server level but not enforced globally; an account that has not enrolled a TOTP factor logs in with a single factor.
- **JWT revocation is stateless.** A GoTrue access token that has been issued remains valid until its 1-hour `exp` even if the issuing session is revoked; only the refresh token is immediately invalidated. Out-of-band revocation of access tokens requires a denylist that is not currently implemented.
