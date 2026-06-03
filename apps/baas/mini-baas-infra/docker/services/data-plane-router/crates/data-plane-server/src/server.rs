use crate::{config::ServerConfig, routes, signal};
use std::time::Duration;

/// How often the background reaper runs: drains idle pools past their
/// `idle_ttl_ms` and rolls back + unpins transactions past their TTL. 15s is
/// short relative to both the default pool idle TTL (30s) and the tx TTL (30s),
/// so an idle pool / abandoned tx is reclaimed within roughly one extra tick.
const REAPER_INTERVAL: Duration = Duration::from_secs(15);

pub async fn run(config: ServerConfig) -> anyhow::Result<()> {
    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    // R2 + R3: the registry is built inside [`routes::AppState::new`] —
    // one `Arc<dyn EngineAdapter>` per engine. Adding engines (R7 MySQL,
    // etc.) is a one-line vec edit there, not a server.rs change.
    let state = routes::AppState::new(config);

    // Background reaper: without this, idle pools never drain past their
    // idle_ttl and an abandoned (begun-but-never-finalised) transaction pins
    // its pool forever. `AppState` is a cheap Arc-backed clone, so the task
    // shares the same registry + transaction map the request path uses.
    let reaper_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(REAPER_INTERVAL);
        loop {
            interval.tick().await;
            reaper_state.reap_once().await;
        }
    });

    let app = routes::router(state);

    tracing::info!(address = %addr, "Rust data-plane-router listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(signal::shutdown_signal())
        .await?;
    Ok(())
}
