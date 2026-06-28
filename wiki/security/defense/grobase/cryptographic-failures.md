# Cryptographic Failures — grobase (the BaaS backend)

> grobase never stores a recoverable secret in the database: every API key payload is hashed with a high-entropy CSPRNG token (no brute-force surface), every tenant connection string is sealed with AES-256-GCM under a scrypt-derived per-record key, and every email/password in the one-edition is processed with argon2id off the async runtime.

## What it is (the concept)

**Cryptographic failures** occur when data that must be kept confidential is stored or transmitted in a form an attacker can recover directly — either because no cryptography is applied, or because the primitive chosen is weak (MD5, SHA-1 without a key, symmetric encryption without authentication, a PRNG rather than a **CSPRNG**). The term encompasses absent encryption, broken algorithms, misuse of correct algorithms (e.g., reusing a nonce with AES-GCM, skipping the **authentication tag**), and storage of secrets in cleartext. The correct counter-measure is to select algorithms for their threat model: a **KDF** (key derivation function) for low-entropy secrets like passwords, a **MAC** or authenticated cipher for integrity, and a cryptographically secure random source for all token generation.

## What it defends against

See [Sensitive Data Exposure via Weak/Absent Cryptography](../../attack/cryptographic-failures.md). In the grobase context, the primary threat is a stolen database dump — a copy of the `tenant_api_keys` or `tenant_databases` table that an attacker leverages offline. Without the controls below, such a dump would yield every tenant's API key (enabling impersonation) and every tenant's real database connection string (enabling full read/write access to customer data). A timing side-channel on key comparison would additionally allow prefix-enumeration at scale.

## How grobase implements it

Three independent controls are active, each targeting a different secret surface.

### 1 — API key generation and hashing (Go control plane)

`src/control-plane/internal/tenants/keys.go` — `generateKey()` reads `payloadBytes = 20` (160 bits) from `crypto/rand` for the secret payload and base32-encodes it. Only a hash of that payload is persisted; the cleartext is never written to the database.

`src/control-plane/internal/tenants/keys_hash.go` — `hashPayloadFast()` computes the stored hash:

```go
if pepper := os.Getenv("KEY_HASH_PEPPER"); pepper != "" {
    mac := hmacSHA256([]byte(pepper), salt+payload)
    sum = mac
} else {
    h := sha256.Sum256([]byte(salt + payload))
    sum = h[:]
}
return fastHashTag + b32().EncodeToString([]byte(salt)) + "$" + b32().EncodeToString(sum)
```

SHA-256 is appropriate here: the payload is 160 bits of uniform CSPRNG output, so there is no brute-force surface regardless of hash speed (the comment in `keys_hash.go` explains the choice explicitly). When `KEY_HASH_PEPPER` is set, the stored hash becomes an HMAC-SHA256 keyed on the pepper, meaning a DB dump alone cannot verify keys without the out-of-band pepper value. Legacy keys used argon2id (`m=32768,t=1,p=2`, `src/control-plane/internal/tenants/keys_hash_argon2.go`) and are accepted during a live migration.

`src/control-plane/internal/tenants/keys_hash_argon2.go` — `verifyKeyHash()` routes verification by scheme tag and finalises with `subtle.ConstantTimeCompare`, eliminating timing side-channels:

```go
return subtle.ConstantTimeCompare([]byte(expected), []byte(storedHash)) == 1
```

`src/control-plane/internal/tenants/keys_verify.go` — `matchKeyRows()` calls `verifyKeyHash` per candidate row; on a legacy argon2id match it asynchronously rewrites the hash to the fast scheme (lazy upgrade). No match returns `Reason: "no_match"` without leaking which column was wrong.

### 2 — Tenant DSN encryption at rest (Go control plane)

`src/control-plane/internal/adapterregistry/crypto.go` — `Encrypt()` reads a fresh 16-byte CSPRNG salt and a fresh 16-byte CSPRNG IV per call, then seals plaintext with AES-256-GCM and splits ciphertext from the 16-byte authentication tag across four separate columns (`connection_enc`, `connection_iv`, `connection_tag`, `connection_salt`). `Decrypt()` calls `gcm.Open`, which will error if the ciphertext or tag has been tampered with.

`src/control-plane/internal/adapterregistry/kdf.go` — `deriveKey()` runs `golang.org/x/crypto/scrypt` with `N=16384, r=8, p=1` to stretch the master `VAULT_ENC_KEY` into a 32-byte AES key, seeded by the per-record salt. `gcmForSalt()` builds `cipher.NewGCMWithNonceSize(block, 16)` (a 16-byte nonce, matching the Node.js legacy format for cross-service compatibility). `NewEncryptor` rejects any master key shorter than 16 characters at startup.

`apps/grobase/scripts/db/db-bootstrap.psql` — Lines 92–108 define the four-column envelope:

```sql
connection_enc   BYTEA NOT NULL,
connection_iv    BYTEA NOT NULL,
connection_tag   BYTEA NOT NULL,
connection_salt  BYTEA,
```

No plaintext DSN column exists anywhere in the schema.

### 3 — Argon2id password hashing (Rust `one` edition)

`src/data-plane-router/crates/data-plane-server/src/one.rs` — `hash_password()` uses `argon2::Argon2::default().hash_password` with a `SaltString` drawn from `rand::rngs::OsRng` (a CSPRNG backed by the OS). `verify_password()` parses the PHC string via `PasswordHash::new` and calls `Argon2::default().verify_password`; the function returns `false` on any parse error, which means the OAuth sentinel value (`!oauth-only` — not a valid PHC string) always fails closed, preventing password-login takeover of OAuth-provisioned accounts.

`src/data-plane-router/crates/data-plane-server/Cargo.toml` — The `one` cargo feature opts in `dep:argon2` (argon2id) and `dep:jsonwebtoken`:

```
# argon2id (passwords ARE low-entropy) + HS256 JWTs minted/verified in-process
one = ["nano", ..., "dep:argon2", "dep:jsonwebtoken", ...]
```

The `kdf_blocking` helper (lines 159–180 in `one.rs`) runs argon2 inside `tokio::task::spawn_blocking`, bounding concurrent KDF work via a semaphore so argon2 cannot exhaust the async runtime.

## How we know it is applied

**API key hashing** — `scripts/verify/m37-nano.sh`, step 4/7, exercises fail-closed auth against the live stack:

```bash
[[ "$(status_of "$R")" == "401" ]] || fail "bogus key must 401: $R"
[[ "$(status_of "$R")" == "401" ]] || fail "missing key must 401: $R"
```

This gate fails if a bogus or absent key ever resolves successfully, proving hash/verify is wired end-to-end. The `keys_security_test.go` and `keys_test.go` unit tests in the same `tenants` package exercise `hashPayload`, `hashPayloadFast`, and `verifyKeyHash` directly under `make go-control-plane-check` (`go test ./...`).

**DSN encryption** — `scripts/verify/m65-vault-enforce.sh` boots the adapter-registry under `SECURITY_MODE=max` with a known placeholder `VAULT_ENC_KEY` and asserts the container exits non-zero with the explicit refusal message:

```
REFUSAL_SUBSTR="SECURITY_MODE=max requires a Vault-backed"
```

The gate then asserts the positive arm (real key + `VAULT_ADDR` boots and serves `/health/live`) and the parity arm (default mode with the placeholder still serves — the fail-closed behavior is gated to `SECURITY_MODE=max` only). `VAULT_ENC_KEY` itself is generated at deploy time in `scripts/env/generate-env.sh` (line 68):

```sh
VAULT_ENC_KEY="$(openssl rand -hex 16)"
```

**Argon2id password hashing** — `one.rs` lines 1365–1369 contain an inline unit test executed under `make rust-data-plane-test`:

```rust
let h = hash_password("correct horse battery").unwrap();
assert!(h.starts_with("$argon2"), "PHC string format: {h}");
assert!(verify_password("correct horse battery", &h));
assert!(!verify_password("wrong", &h));
```

Line 1441 directly tests the OAuth sentinel: `assert!(!verify_password("anything", "!oauth-only"))`.

## Reference

[A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/) categorises the full range of cryptographic misuse, from absent encryption to weak primitives to authentication-tag omission. The controls above address the two highest-impact sub-cases for a multi-tenant BaaS: credential theft from a leaked database and offline recovery of connection strings that grant direct engine access.

## Residual risk / assumptions

- **`KEY_HASH_PEPPER` is optional.** Without it, SHA-256(salt+payload) is stored; a DB dump is sufficient to verify keys by brute force — although the 160-bit uniform payload makes that computationally infeasible, a misconfigured shorter key would narrow the surface. Operators should set the pepper.
- **`VAULT_ENC_KEY` master key security.** The scrypt derivation is only as strong as the master key. If the master key is leaked alongside the database dump, decryption of all DSNs becomes feasible. The key must be stored out-of-band (e.g., vault42 or a secrets manager), never committed to the repo.
- **`SECURITY_MODE=max` is opt-in.** In the default mode, the adapter-registry starts with a self-generated key rather than a Vault-backed one (consistent with the zero-config no-vault mode documented in the project). The fail-closed guarantee applies only when `SECURITY_MODE=max` is explicitly set.
- **The `one` edition is not the default.** Argon2id password hashing applies only to the `binocle-one` product shape (cargo feature `one`). The default edition uses GoTrue for auth, which handles its own credential storage externally.
- **Timing oracle on prefix lookup.** The DB query filters by the cleartext `key_prefix`, so an adversary can distinguish "prefix exists" (slower, candidate rows returned) from "prefix does not exist" (fast, zero rows). The payload comparison itself is constant-time, but the lookup step leaks prefix existence under a high-precision timing channel.
