//! Server assembly — wires every crate together into a running HTTP/WS server.
//!
//! This module is the **composition root** of the system. It reads
//! [`ServerConfig`], instantiates the event bus,
//! auth provider, router, fan-out pool, database producers, and HTTP routes,
//! then binds a TCP listener.

use std::sync::Arc;

use axum::{
    routing::{get, post},
    Router,
};
use realtime_auth::NoAuthProvider;
use realtime_bus_inprocess::InProcessBus;
use realtime_core::{AuthProvider, DatabaseProducer, EventBus, EventBusPublisher};
use realtime_engine::{
    registry::SubscriptionRegistry, router::EventRouter, sequence::SequenceGenerator,
    ProducerRegistry,
};
use realtime_gateway::{
    connection::ConnectionManager,
    fanout::FanOutWorkerPool,
    rest_api,
    ws_handler::{self, AppState},
};
use tokio::sync::mpsc;
use tower_http::cors::CorsLayer;
use tracing::{error, info};

use crate::config::{AuthConfig, EventBusConfig, ServerConfig};

/// Build and run the full realtime server.
///
/// Assembles all components from the given configuration and blocks
/// until the server is shut down.
///
/// # Errors
///
/// Returns an error if any component fails to initialize or the server
/// cannot bind to the configured address.
pub async fn run(config: ServerConfig) -> anyhow::Result<()> {
    let bus = build_event_bus(&config);
    let publisher: Arc<dyn EventBusPublisher> = Arc::from(bus.publisher().await?);
    let auth_provider = build_auth_provider(&config)?;
    let (registry, sequence_gen, conn_manager) = build_core(&config);
    let dispatch_tx = build_fanout(&conn_manager, config.performance.fanout_workers);
    let router = wire_router(&registry, &sequence_gen, dispatch_tx);
    spawn_bus_loop(&bus, &router).await?;
    start_producers(&config, &publisher);
    let app = build_http_router(
        conn_manager,
        registry,
        auth_provider,
        publisher,
        &config.static_dir,
    );

    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!("Realtime server listening on {}", addr);

    axum::serve(listener, app)
        .with_graceful_shutdown(crate::signal::shutdown_signal())
        .await?;

    bus.shutdown().await.ok();
    Ok(())
}

fn build_event_bus(config: &ServerConfig) -> Arc<dyn EventBus> {
    let bus: Arc<dyn EventBus> = match &config.event_bus {
        EventBusConfig::InProcess { capacity } => Arc::new(InProcessBus::new(*capacity)),
    };
    bus
}

fn build_auth_provider(config: &ServerConfig) -> anyhow::Result<Arc<dyn AuthProvider>> {
    match &config.auth {
        AuthConfig::NoAuth => Ok(Arc::new(NoAuthProvider::new())),
        AuthConfig::Jwt {
            secret,
            issuer,
            audience,
        } => {
            let mut jwt = realtime_auth::JwtConfig::hmac(secret.clone());
            jwt.issuer.clone_from(issuer);
            jwt.audience.clone_from(audience);
            Ok(Arc::new(realtime_auth::JwtAuthProvider::new(&jwt)?))
        }
    }
}

type CoreComponents = (
    Arc<SubscriptionRegistry>,
    Arc<SequenceGenerator>,
    Arc<ConnectionManager>,
);

fn build_core(config: &ServerConfig) -> CoreComponents {
    let registry = Arc::new(SubscriptionRegistry::with_limits(
        config.engine.limits.clone(),
    ));
    let sequence_gen = Arc::new(SequenceGenerator::new());
    let conn_mgr = Arc::new(ConnectionManager::new(
        config.performance.send_queue_capacity,
    ));
    (registry, sequence_gen, conn_mgr)
}

fn build_fanout(
    conn_manager: &Arc<ConnectionManager>,
    workers: usize,
) -> mpsc::Sender<realtime_engine::router::DispatchMessage> {
    let pool = FanOutWorkerPool::new(Arc::clone(conn_manager), workers);
    pool.start()
}

fn wire_router(
    registry: &Arc<SubscriptionRegistry>,
    seq_gen: &Arc<SequenceGenerator>,
    dispatch_tx: mpsc::Sender<realtime_engine::router::DispatchMessage>,
) -> Arc<EventRouter> {
    Arc::new(EventRouter::new(
        Arc::clone(registry),
        Arc::clone(seq_gen),
        dispatch_tx,
    ))
}

async fn spawn_bus_loop(bus: &Arc<dyn EventBus>, router: &Arc<EventRouter>) -> anyhow::Result<()> {
    let subscriber = bus.subscriber("*").await?;
    let r = Arc::clone(router);
    tokio::spawn(async move { r.run_with_subscriber(subscriber).await });
    Ok(())
}

fn start_producers(config: &ServerConfig, publisher: &Arc<dyn EventBusPublisher>) {
    let registry = default_producer_registry();
    if let Ok(adapters) = registry.adapters() {
        info!("Available adapters: {:?}", adapters);
    }
    for db_cfg in &config.databases {
        match registry.create_producer(&db_cfg.adapter, db_cfg.config.clone()) {
            Ok(producer) => {
                let name = db_cfg.adapter.clone();
                spawn_producer_task(producer, Arc::clone(publisher), name);
            }
            Err(e) => error!(adapter = %db_cfg.adapter, "Failed to create producer: {}", e),
        }
    }
}

fn build_http_router(
    conn_manager: Arc<ConnectionManager>,
    registry: Arc<SubscriptionRegistry>,
    auth_provider: Arc<dyn AuthProvider>,
    bus_publisher: Arc<dyn EventBusPublisher>,
    static_dir: &str,
) -> Router {
    let state = AppState {
        conn_manager,
        registry,
        auth_provider,
        bus_publisher,
    };
    Router::new()
        .route("/ws", get(ws_handler::ws_upgrade))
        .route("/v1/publish", post(rest_api::publish_event))
        .route("/v1/publish/batch", post(rest_api::publish_batch))
        .route("/v1/health", get(rest_api::health_check))
        .fallback_service(tower_http::services::ServeDir::new(static_dir))
        .layer(CorsLayer::permissive())
        .with_state(state)
}

/// Build the default [`ProducerRegistry`] with built-in adapters.
#[must_use]
pub fn default_producer_registry() -> ProducerRegistry {
    let registry = ProducerRegistry::new();
    let _ = registry.register(Box::new(realtime_db_postgres::PostgresFactory));
    let _ = registry.register(Box::new(realtime_db_mongodb::MongoFactory));
    registry
}

fn spawn_producer_task(
    producer: Box<dyn DatabaseProducer>,
    bus_pub: Arc<dyn EventBusPublisher>,
    adapter_name: String,
) {
    tokio::spawn(async move {
        match producer.start().await {
            Ok(mut stream) => {
                while let Some(event) = stream.next_event().await {
                    if let Err(e) = bus_pub.publish(event.topic.as_str(), &event).await {
                        error!(adapter = %adapter_name, "Failed to publish event: {}", e);
                    }
                }
            }
            Err(e) => error!(adapter = %adapter_name, "Failed to start producer: {}", e),
        }
    });
}
