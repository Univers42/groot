//! Phase 7 — Rust-native authentication for the direct `/data/v1` front door.
//!
//! Go remains the SOLE identity authority: Rust never hashes or stores API keys.
//! It only CALLS tenant-control `POST /v1/keys/verify` (Argon2id verification
//! stays in Go) to turn an `X-Baas-Api-Key` into a tenant identity, and
//! adapter-registry `GET /databases/{id}/connect` to resolve the mount's DSN +
//! tier mask. Both use the internal service token.
//!
//! This module is only reachable when the bypass is explicitly enabled
//! (`DATA_PLANE_BYPASS_ENABLED=1`); the existing `/query/v1` → query-router path
//! is untouched, so the front door ships as pure SHADOW.

use serde::Deserialize;

/// Why a bypass request was rejected, mapped to an HTTP status by the route.
#[derive(Debug)]
pub enum AuthError {
    /// Key missing / invalid / expired — 401.
    Unauthorized(String),
    /// An upstream (tenant-control / adapter-registry) failed — 502.
    Upstream(String),
    /// The mount id is unknown for this tenant — 404.
    NotFound(String),
}

#[derive(Debug, Deserialize)]
struct VerifyResponse {
    valid: bool,
    #[serde(default)]
    tenant_id: Option<String>,
    #[serde(default)]
    key_id: Option<String>,
    #[serde(default)]
    scopes: Vec<String>,
    #[serde(default)]
    reason: Option<String>,
}

/// A verified caller identity (the trusted output of tenant-control).
pub struct VerifiedIdentity {
    pub tenant_id: String,
    pub key_id: String,
    pub scopes: Vec<String>,
}

/// Exchange an API key for a tenant identity via tenant-control. Go performs the
/// Argon2id hash compare; Rust trusts the `valid`/`tenant_id` result.
pub async fn verify_key(
    client: &reqwest::Client,
    base_url: &str,
    token: &str,
    key: &str,
) -> Result<VerifiedIdentity, AuthError> {
    let url = format!("{}/v1/keys/verify", base_url.trim_end_matches('/'));
    let resp = client
        .post(&url)
        .header("X-Service-Token", token)
        .json(&serde_json::json!({ "key": key }))
        .send()
        .await
        .map_err(|e| AuthError::Upstream(format!("tenant-control verify: {e}")))?;
    if !resp.status().is_success() {
        return Err(AuthError::Upstream(format!(
            "tenant-control verify status {}",
            resp.status()
        )));
    }
    let body: VerifyResponse = resp
        .json()
        .await
        .map_err(|e| AuthError::Upstream(format!("verify decode: {e}")))?;
    if !body.valid {
        return Err(AuthError::Unauthorized(
            body.reason.unwrap_or_else(|| "invalid api key".into()),
        ));
    }
    Ok(VerifiedIdentity {
        tenant_id: body
            .tenant_id
            .ok_or_else(|| AuthError::Upstream("verify missing tenant_id".into()))?,
        key_id: body.key_id.unwrap_or_default(),
        scopes: body.scopes,
    })
}

#[derive(Debug, Deserialize)]
struct ConnectResponse {
    engine: String,
    connection_string: String,
    #[serde(default)]
    isolation: Option<String>,
    #[serde(default)]
    capability_overrides: Option<serde_json::Value>,
}

/// A resolved mount: engine + DSN + the tenant's tier mask (Phase 4).
pub struct ResolvedMount {
    pub engine: String,
    pub connection_string: String,
    pub isolation: Option<String>,
    pub capability_overrides: Option<serde_json::Value>,
}

/// Resolve a mount (engine + DSN + tier mask) for `(tenant, db_id)` via
/// adapter-registry. The registry scopes `/connect` to the caller tenant, so a
/// cross-tenant db id is a 404 there — the same isolation the query-router relies
/// on. The inline DSN never transits any client.
pub async fn resolve_mount(
    client: &reqwest::Client,
    registry_url: &str,
    token: &str,
    tenant: &str,
    db_id: &str,
) -> Result<ResolvedMount, AuthError> {
    let url = format!(
        "{}/databases/{}/connect",
        registry_url.trim_end_matches('/'),
        db_id
    );
    let resp = client
        .get(&url)
        .header("X-Service-Token", token)
        .header("X-Tenant-Id", tenant)
        .send()
        .await
        .map_err(|e| AuthError::Upstream(format!("adapter-registry connect: {e}")))?;
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(AuthError::NotFound(format!(
            "mount '{db_id}' not found for this tenant"
        )));
    }
    if !resp.status().is_success() {
        return Err(AuthError::Upstream(format!(
            "adapter-registry connect status {}",
            resp.status()
        )));
    }
    let body: ConnectResponse = resp
        .json()
        .await
        .map_err(|e| AuthError::Upstream(format!("connect decode: {e}")))?;
    Ok(ResolvedMount {
        engine: body.engine,
        connection_string: body.connection_string,
        isolation: body.isolation,
        capability_overrides: body.capability_overrides,
    })
}
