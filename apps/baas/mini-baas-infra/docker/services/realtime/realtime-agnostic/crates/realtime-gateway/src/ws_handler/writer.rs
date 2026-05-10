use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket};
use futures::stream::SplitSink;
use futures::SinkExt;
use realtime_core::{ConnectionId, EventEnvelope, EventPayload, ServerMessage};
use tokio::sync::mpsc;
use tracing::{debug, error, warn};

enum SendStatus {
    Ok,
    SlowClient,
    Failed,
}

fn serialize_event(sub_id: &str, event: &EventEnvelope) -> Option<String> {
    let payload = EventPayload::from_envelope(event);
    let msg = ServerMessage::Event {
        sub_id: sub_id.to_owned(),
        event: payload,
    };
    serde_json::to_string(&msg).ok()
}

fn check_slow_client(elapsed: Duration, slow_count: &mut u32, conn_id: ConnectionId) -> SendStatus {
    if elapsed > Duration::from_millis(100) {
        *slow_count += 1;
    } else {
        *slow_count = 0;
    }
    if *slow_count > 10 {
        warn!(conn_id = %conn_id, "Client consistently slow, disconnecting");
        return SendStatus::SlowClient;
    }
    SendStatus::Ok
}

async fn send_frame(
    ws_sink: &mut SplitSink<WebSocket, Message>,
    json: String,
    conn_id: ConnectionId,
    slow_count: &mut u32,
) -> SendStatus {
    let start = Instant::now();
    let result = tokio::time::timeout(
        Duration::from_millis(500),
        ws_sink.send(Message::Text(json)),
    )
    .await;
    match result {
        Ok(Ok(())) => check_slow_client(start.elapsed(), slow_count, conn_id),
        Ok(Err(e)) => {
            debug!(conn_id = %conn_id, "WebSocket write error: {}", e);
            SendStatus::Failed
        }
        Err(_) => {
            warn!(conn_id = %conn_id, "WebSocket write timeout");
            SendStatus::Failed
        }
    }
}

pub(super) async fn writer_loop(
    mut ws_sink: SplitSink<WebSocket, Message>,
    mut send_rx: mpsc::Receiver<(String, Arc<EventEnvelope>)>,
    mut ctrl_rx: mpsc::Receiver<String>,
    conn_id: ConnectionId,
) {
    let mut slow_count = 0u32;
    loop {
        let json = tokio::select! {
            Some((sub_id, ev)) = send_rx.recv() => if let Some(j) = serialize_event(&sub_id, &ev) { j } else {
                error!(conn_id = %conn_id, "Failed to serialize event");
                continue;
            },
            Some(ctrl) = ctrl_rx.recv() => ctrl,
            else => break,
        };
        match send_frame(&mut ws_sink, json, conn_id, &mut slow_count).await {
            SendStatus::Ok => {}
            SendStatus::SlowClient | SendStatus::Failed => return,
        }
    }
}
