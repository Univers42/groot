//! [`AuthProvider`] trait implementation for JWT verification.

use async_trait::async_trait;
use jsonwebtoken::decode;
use realtime_core::{
    AuthClaims, AuthContext, AuthProvider, RealtimeError, Result, TopicPath, TopicPattern,
};
use tracing::{debug, warn};

use super::{JwtAuthProvider, JwtClaims};

#[async_trait]
impl AuthProvider for JwtAuthProvider {
    async fn verify(&self, token: &str, _context: &AuthContext) -> Result<AuthClaims> {
        let token = token.strip_prefix("Bearer ").unwrap_or(token);
        let token_data =
            decode::<JwtClaims>(token, &self.decoding_key, &self.validation).map_err(|e| {
                warn!("JWT verification failed: {}", e);
                RealtimeError::AuthFailed(format!("Invalid token: {e}"))
            })?;
        let claims = token_data.claims;
        debug!(sub = %claims.sub, "JWT verified successfully");
        Ok(build_auth_claims(claims))
    }

    async fn authorize_subscribe(&self, claims: &AuthClaims, topic: &TopicPattern) -> Result<()> {
        if claims.can_subscribe_to(topic) {
            Ok(())
        } else {
            Err(RealtimeError::AuthorizationDenied(format!(
                "Not authorized to subscribe to {topic}"
            )))
        }
    }

    async fn authorize_publish(&self, claims: &AuthClaims, topic: &TopicPath) -> Result<()> {
        if claims.can_publish_to(topic) {
            Ok(())
        } else {
            Err(RealtimeError::AuthorizationDenied(format!(
                "Not authorized to publish to {topic}"
            )))
        }
    }
}

fn build_auth_claims(claims: JwtClaims) -> AuthClaims {
    AuthClaims {
        sub: claims.sub,
        namespaces: if claims.namespaces.is_empty() {
            vec!["*".to_string()]
        } else {
            claims.namespaces
        },
        can_publish: claims.can_publish,
        can_subscribe: claims.can_subscribe,
        metadata: claims.metadata,
    }
}
