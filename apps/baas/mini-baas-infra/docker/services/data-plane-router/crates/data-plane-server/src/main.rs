use data_plane_server::config::ServerConfig;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;
use tracing_subscriber::EnvFilter;

/// Allocator choice, measured 2026-06-12 on the c=64 matrix:
/// - musl malloc: global lock serializes small allocs — list capped ~12k RPS;
///   returns memory immediately (idle 7.8 MiB).
/// - mimalloc: list 71-75k RPS but NEVER returns freed argon2 arenas
///   (378 MiB retained after 200 logins) — fails the idle budgets.
/// - jemalloc (default for nano/one): list throughput on par with mimalloc,
///   and decay-based purging + a background thread return freed pages within
///   ~2 s. `narenas:4` bounds per-arena retention.
#[cfg(all(feature = "jemalloc-alloc", not(feature = "mimalloc-alloc")))]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

#[cfg(all(feature = "jemalloc-alloc", not(feature = "mimalloc-alloc")))]
#[allow(non_upper_case_globals)]
#[export_name = "malloc_conf"]
pub static malloc_conf: &[u8] =
    b"background_thread:true,narenas:4,dirty_decay_ms:2000,muzzy_decay_ms:2000\0";

/// Opt-in mimalloc, kept for A/B benchmarking only (retains memory).
#[cfg(feature = "mimalloc-alloc")]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if std::env::args().any(|arg| arg == "--healthcheck") {
        return healthcheck();
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(true)
        .init();

    let config = ServerConfig::from_env();

    // binocle-one ("our PocketBase"): nano + user accounts/JWT — the superset
    // single-binary edition. Checked FIRST because `one` implies `nano`.
    #[cfg(feature = "one")]
    {
        return data_plane_server::one::run(config).await;
    }

    // Nano edition: one static binary, embedded SQLite, in-process auth —
    // the control-plane round-trips below never exist in this build.
    #[cfg(all(feature = "nano", not(feature = "one")))]
    {
        return data_plane_server::nano::run(config).await;
    }

    #[cfg(not(feature = "nano"))]
    {
        tracing::info!(
            product_mode = %config.product_mode,
            adapter_registry_url = %config.adapter_registry_url,
            "starting Rust data-plane-router"
        );
        data_plane_server::server::run(config).await
    }
}

fn healthcheck() -> anyhow::Result<()> {
    let host =
        std::env::var("DATA_PLANE_ROUTER_HEALTH_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("DATA_PLANE_ROUTER_PORT").unwrap_or_else(|_| "4011".to_string());
    let addr = format!("{host}:{port}")
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow::anyhow!("healthcheck address did not resolve"))?;
    TcpStream::connect_timeout(&addr, Duration::from_secs(2))?;
    Ok(())
}
