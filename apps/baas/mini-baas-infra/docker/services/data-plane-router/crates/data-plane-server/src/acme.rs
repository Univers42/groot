//! In-binary automatic HTTPS — PB's `--https` equivalent.
//!
//! `ONE_HTTPS_DOMAIN=example.com[,www.example.com]` turns on an additional
//! TLS listener (`ONE_HTTPS_ADDR`, default 0.0.0.0:8443) whose certificates
//! come from ACME TLS-ALPN-01, cached under `{data_dir}/acme` so restarts
//! never re-issue. Knobs:
//!   - `ONE_ACME_CONTACT`   — mailto contact for the account;
//!   - `ONE_ACME_DIRECTORY` — directory URL (default Let's Encrypt
//!     production; point it at pebble in tests);
//!   - `ONE_ACME_INSECURE=1` — trust ANY directory TLS cert. Test servers
//!     (pebble) self-sign; never set this against a real CA.

use std::sync::Arc;

// the rustls VERSION must match what rustls-acme was built against — use its
// re-export instead of a direct (possibly diverging) dependency
use rustls_acme::futures_rustls::rustls;

use crate::routes::AppState;

/// Danger: accepts any server certificate — for ACME *test directories* only.
#[derive(Debug)]
struct NoVerify(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

/// Spawn the HTTPS listener when configured. Returns whether it started.
pub(crate) fn maybe_serve(
    state: AppState,
    data_dir: &std::path::Path,
    make_router: impl Fn(AppState) -> axum::Router + Send + 'static,
) -> bool {
    let Ok(domains_raw) = std::env::var("ONE_HTTPS_DOMAIN") else {
        return false;
    };
    let domains: Vec<String> = domains_raw
        .split(',')
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(String::from)
        .collect();
    if domains.is_empty() {
        return false;
    }
    let contact = std::env::var("ONE_ACME_CONTACT").unwrap_or_else(|_| "admin@localhost".into());
    let addr: std::net::SocketAddr = std::env::var("ONE_HTTPS_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:8443".into())
        .parse()
        .unwrap_or_else(|_| ([0, 0, 0, 0], 8443).into());
    let cache_dir = data_dir.join("acme");
    let directory = std::env::var("ONE_ACME_DIRECTORY")
        .unwrap_or_else(|_| rustls_acme::acme::LETS_ENCRYPT_PRODUCTION_DIRECTORY.to_string());
    let insecure = std::env::var("ONE_ACME_INSECURE").ok().as_deref() == Some("1");

    tokio::spawn(async move {
        // AcmeConfig::new requires a default client config (hidden behind
        // crate features); building from an explicit rustls client config
        // keeps the dependency surface fixed.
        let provider = rustls::crypto::ring::default_provider();
        let base_client = rustls::ClientConfig::builder_with_provider(provider.clone().into())
            .with_safe_default_protocol_versions()
            .expect("tls versions")
            .with_root_certificates(rustls::RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            })
            .with_no_client_auth();
        let mut config = rustls_acme::AcmeConfig::new_with_client_config(
            domains.clone(),
            Arc::new(base_client),
        )
            .contact_push(format!("mailto:{contact}"))
            .cache(rustls_acme::caches::DirCache::new(cache_dir))
            .directory(&directory);
        if insecure {
            tracing::warn!(target: "acme", "ONE_ACME_INSECURE=1 — directory TLS verification is OFF (test directories only)");
            let client = rustls::ClientConfig::builder_with_provider(provider.clone().into())
                .with_safe_default_protocol_versions()
                .expect("tls versions")
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(NoVerify(provider.into())))
                .with_no_client_auth();
            config = config.client_tls_config(Arc::new(client));
        }
        let mut acme_state = config.state();
        let rustls_config = acme_state.default_rustls_config();
        let acceptor = acme_state.axum_acceptor(rustls_config);

        tokio::spawn(async move {
            use tokio_stream::StreamExt;
            while let Some(event) = acme_state.next().await {
                match event {
                    Ok(ok) => tracing::info!(target: "acme", "acme event: {ok:?}"),
                    Err(err) => tracing::warn!(target: "acme", "acme error: {err:?}"),
                }
            }
        });

        tracing::info!(target: "acme", %addr, domains = %domains.join(","), %directory,
            "HTTPS listener with automatic certificates starting");
        if let Err(e) = axum_server::bind(addr)
            .acceptor(acceptor)
            .serve(make_router(state).into_make_service_with_connect_info::<std::net::SocketAddr>())
            .await
        {
            tracing::warn!(target: "acme", "https listener failed: {e}");
        }
    });
    true
}
