//! v1 HMAC service-to-service auth (audit O1) — the Rust caller half of the Go
//! `shared.VerifyServiceRequest`. Under `SERVICE_TOKEN_MODE=hmac` the shared
//! token never transits the wire: each request carries
//!
//! `X-Service-Auth: v1.<ts>.<hex hmac-sha256(token, "<ts>\n<METHOD>\n<PATH>\n<sha256hex(body)>")>`
//!
//! binding time, method, path and body (replay against another endpoint or
//! payload fails). PATH is the URL path only — internal base URLs are
//! origin-only and these routes take no query strings. Default mode is
//! `static` (the plain `X-Service-Token` header), byte-identical to before.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

/// True when `SERVICE_TOKEN_MODE=hmac` (case-insensitive).
#[must_use]
pub fn hmac_mode() -> bool {
    std::env::var("SERVICE_TOKEN_MODE")
        .map(|v| v.trim().eq_ignore_ascii_case("hmac"))
        .unwrap_or(false)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Signature for a fixed timestamp (the testable core).
#[must_use]
pub fn compute_service_auth_at(
    token: &str,
    method: &str,
    path: &str,
    body: &[u8],
    ts: i64,
) -> String {
    let body_hex = hex(&Sha256::digest(body));
    let msg = format!("{ts}\n{}\n{path}\n{body_hex}", method.to_uppercase());
    let mut mac =
        Hmac::<Sha256>::new_from_slice(token.as_bytes()).expect("hmac accepts any key length");
    mac.update(msg.as_bytes());
    format!("v1.{ts}.{}", hex(&mac.finalize().into_bytes()))
}

/// Signature for "now" — the value to send as `X-Service-Auth`.
#[must_use]
pub fn compute_service_auth(token: &str, method: &str, path: &str, body: &[u8]) -> String {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;
    compute_service_auth_at(token, method, path, body, ts)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Golden vectors shared with the Go (`shared/token_test.go`) and TS
    /// implementations — all three languages must sign byte-identically.
    #[test]
    fn golden_vectors_match_go() {
        assert_eq!(
            compute_service_auth_at(
                "test-token",
                "POST",
                "/v1/keys/verify",
                br#"{"key":"abc"}"#,
                1_700_000_000
            ),
            "v1.1700000000.b2e684210cc7e80998388c89afe88d2fbd4fd9a7492289724f7fd3f15075189e"
        );
        assert_eq!(
            compute_service_auth_at(
                "test-token",
                "GET",
                "/databases/db1/connect",
                b"",
                1_700_000_000
            ),
            "v1.1700000000.d53d261c30ba227cb3ab770a0a3c936e0fc0cd7385855339ba60b1a172b21b6b"
        );
    }
}
