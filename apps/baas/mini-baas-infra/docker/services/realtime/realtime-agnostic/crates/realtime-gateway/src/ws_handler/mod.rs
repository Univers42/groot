//! WebSocket connection handler — manages the full lifecycle of a client connection.
//!
//! Each WebSocket connection spawns two tasks:
//!
//! 1. **Writer task** (`writer_loop`) — reads from the per-connection send
//!    channel and a control channel, serializes messages to JSON, and
//!    writes WebSocket text frames. Includes slow-client detection.
//!
//! 2. **Reader task** (`reader_loop`) — reads WebSocket frames, deserializes
//!    [`ClientMessage`]s, and handles auth, subscribe, unsubscribe, publish,
//!    and ping commands.

mod connection;
mod handlers;
mod reader;
mod util;
mod writer;

use std::sync::Arc;

use axum::extract::ws::WebSocketUpgrade;
use axum::extract::State;
use axum::response::IntoResponse;
use realtime_core::AuthProvider;
use realtime_engine::registry::SubscriptionRegistry;

use crate::connection::ConnectionManager;

/// Shared application state injected into Axum handlers via `State`.
#[derive(Clone)]
pub struct AppState {
    pub conn_manager: Arc<ConnectionManager>,
    pub registry: Arc<SubscriptionRegistry>,
    pub auth_provider: Arc<dyn AuthProvider>,
    pub bus_publisher: Arc<dyn realtime_core::EventBusPublisher>,
}

/// Axum handler for WebSocket upgrade requests (`GET /ws`).
#[allow(clippy::unused_async)]
pub async fn ws_upgrade(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| connection::handle_websocket(socket, state))
}
