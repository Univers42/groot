use axum::extract::ws::{Message, WebSocket};
use chrono::Utc;
use futures::stream::SplitStream;
use futures::StreamExt;
use realtime_core::{AuthClaims, ClientMessage, ConnectionId, ServerMessage};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use super::util::send_ctrl;

use super::handlers;
use super::AppState;

#[derive(Default)]
pub(super) struct AuthState {
    pub authenticated: bool,
    pub claims: Option<AuthClaims>,
}

#[derive(PartialEq, Eq)]
pub(super) enum Action {
    Continue,
    Close,
}

pub(super) async fn reader_loop(
    mut ws_stream: SplitStream<WebSocket>,
    conn_id: ConnectionId,
    state: AppState,
    ctrl_tx: mpsc::Sender<String>,
) {
    let mut auth = AuthState::default();
    while let Some(result) = ws_stream.next().await {
        match result {
            Ok(Message::Text(text)) => {
                let action = dispatch_text(&text, conn_id, &state, &ctrl_tx, &mut auth).await;
                if action == Action::Close {
                    return;
                }
            }
            Ok(Message::Close(_)) => {
                info!(conn_id = %conn_id, "Client initiated close");
                return;
            }
            Err(e) => {
                debug!(conn_id = %conn_id, "WebSocket read error: {}", e);
                return;
            }
            _ => {}
        }
    }
}

async fn dispatch_text(
    text: &str,
    conn_id: ConnectionId,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
    auth: &mut AuthState,
) -> Action {
    let Ok(msg) = serde_json::from_str::<ClientMessage>(text) else {
        warn!(conn_id = %conn_id, "Invalid client message");
        return Action::Continue;
    };
    match msg {
        ClientMessage::Auth { token } => {
            handlers::handle_auth(token, conn_id, state, ctrl_tx, auth).await
        }
        ClientMessage::Subscribe {
            sub_id,
            topic,
            filter,
            options,
        } => {
            handlers::handle_subscribe(
                sub_id, topic, filter, options, conn_id, auth, state, ctrl_tx,
            )
            .await
        }
        ClientMessage::SubscribeBatch { subscriptions } => {
            handlers::handle_subscribe_batch(subscriptions, conn_id, auth, state, ctrl_tx).await
        }
        ClientMessage::Unsubscribe { sub_id } => {
            handlers::handle_unsubscribe(sub_id, conn_id, state, ctrl_tx).await
        }
        ClientMessage::Publish {
            topic,
            event_type,
            payload,
        } => handlers::handle_publish(topic, event_type, payload, conn_id, auth, state).await,
        ClientMessage::Ping => handle_ping(conn_id, ctrl_tx).await,
    }
}

async fn handle_ping(conn_id: ConnectionId, ctrl_tx: &mpsc::Sender<String>) -> Action {
    debug!(conn_id = %conn_id, "Ping received");
    let msg = ServerMessage::Pong {
        server_time: Utc::now().to_rfc3339(),
    };
    send_ctrl(ctrl_tx, &msg).await;
    Action::Continue
}
