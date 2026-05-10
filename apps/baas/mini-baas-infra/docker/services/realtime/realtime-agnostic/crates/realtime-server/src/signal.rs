use tracing::{error, info};

pub async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(e) = tokio::signal::ctrl_c().await {
            error!("Ctrl-C err: {}", e);
        }
    };

    #[cfg(unix)]
    let term = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(e) => error!("Term err: {}", e),
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();

    tokio::select! { () = ctrl_c => {}, () = term => {} }
    info!("Received termination signal, initiating shutdown...");
}
