/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   connection.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use std::net::SocketAddr;
use std::sync::Arc;

use axum::extract::ws::WebSocket;
use bytes::Bytes;
use chrono::Utc;
use futures::StreamExt;
use realtime_core::{
    ConnectionId, ConnectionMeta, EventBusPublisher, EventEnvelope, OverflowPolicy, PresenceMember,
    TopicPath,
};
use realtime_engine::PresenceTracker;
use tokio::sync::mpsc;
use tracing::{error, info};

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
    let presence = Arc::clone(&state.presence);
    let bus_publisher = Arc::clone(&state.bus_publisher);
    let writer = tokio::spawn(writer_loop(ws_sink, send_rx, ctrl_rx, conn_id));
    let reader = tokio::spawn(reader_loop(ws_stream, conn_id, state, ctrl_tx));
    tokio::select! {
        _ = writer => {}
        _ = reader => {}
    }
    // Emit a presence LEAVE for every topic this connection was tracking, then
    // tear down its subscriptions. Done before `remove_connection` so the
    // published snapshots reflect the post-departure membership.
    cleanup_presence(conn_id, &presence, bus_publisher.as_ref()).await;
    registry.remove_connection(conn_id);
    conn_manager.remove(conn_id);
    info!(conn_id = %conn_id, "WebSocket connection closed");
}

/// On disconnect, drop the connection from every presence set it joined and
/// publish a fresh snapshot per affected topic over the bus so remaining
/// subscribers (local and remote) observe the leave.
async fn cleanup_presence(
    conn_id: ConnectionId,
    presence: &PresenceTracker,
    bus_publisher: &dyn EventBusPublisher,
) {
    for (topic, members) in presence.remove_connection(conn_id) {
        publish_presence_snapshot(&topic, &members, bus_publisher, conn_id).await;
    }
}

/// Publish a presence snapshot (`event_type` `"presence"`) for a topic.
async fn publish_presence_snapshot(
    topic: &str,
    members: &[PresenceMember],
    bus_publisher: &dyn EventBusPublisher,
    conn_id: ConnectionId,
) {
    let body = serde_json::json!({ "topic": topic, "members": members });
    let Ok(payload_bytes) = serde_json::to_vec(&body) else {
        return;
    };
    let envelope =
        EventEnvelope::new(TopicPath::new(topic), "presence", Bytes::from(payload_bytes));
    if let Err(e) = bus_publisher.publish(topic, &envelope).await {
        error!(conn_id = %conn_id, "Failed to publish presence on disconnect: {}", e);
    }
}
