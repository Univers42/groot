use std::net::SocketAddr;
use std::sync::Arc;

use axum::extract::ws::WebSocket;
use chrono::Utc;
use futures::StreamExt;
use realtime_core::{ConnectionId, ConnectionMeta, OverflowPolicy};
use tokio::sync::mpsc;
use tracing::info;

use super::reader::reader_loop;
use super::writer::writer_loop;
use super::AppState;

fn default_peer_addr() -> SocketAddr {
    SocketAddr::from(([0, 0, 0, 0], 0))
}

fn create_connection_meta(conn_id: ConnectionId) -> ConnectionMeta {
    ConnectionMeta {
        conn_id,
        peer_addr: default_peer_addr(),
        connected_at: Utc::now(),
        user_id: None,
        claims: None,
    }
}

pub async fn handle_websocket(socket: WebSocket, state: AppState) {
    let conn_id = state.conn_manager.next_connection_id();
    let meta = create_connection_meta(conn_id);
    let (_, send_rx) = state
        .conn_manager
        .register(meta, OverflowPolicy::DropNewest);
    let (ws_sink, ws_stream) = socket.split();
    let (ctrl_tx, ctrl_rx) = mpsc::channel::<String>(64);
    let registry = Arc::clone(&state.registry);
    let conn_manager = Arc::clone(&state.conn_manager);
    let writer = tokio::spawn(writer_loop(ws_sink, send_rx, ctrl_rx, conn_id));
    let reader = tokio::spawn(reader_loop(ws_stream, conn_id, state, ctrl_tx));
    tokio::select! {
        _ = writer => {}
        _ = reader => {}
    }
    registry.remove_connection(conn_id);
    conn_manager.remove(conn_id);
    info!(conn_id = %conn_id, "WebSocket connection closed");
}
