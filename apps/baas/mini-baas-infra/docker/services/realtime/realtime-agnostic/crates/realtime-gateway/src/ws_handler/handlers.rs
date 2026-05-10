use std::net::SocketAddr;

use bytes::Bytes;
use chrono::Utc;
use realtime_core::{
    filter::FilterExpr, AuthContext, ConnectionId, EventEnvelope, ServerMessage, SubscribeItem,
    Subscription, SubscriptionId, TopicPath, TopicPattern,
};
use smol_str::SmolStr;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use super::reader::{Action, AuthState};
use super::util::{parse_sub_config, send_ctrl};
use super::AppState;

pub(super) async fn handle_auth(
    token: String,
    conn_id: ConnectionId,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
    auth: &mut AuthState,
) -> Action {
    let ctx = AuthContext {
        peer_addr: SocketAddr::from(([0, 0, 0, 0], 0)),
        transport: "websocket".into(),
    };
    match state.auth_provider.verify(&token, &ctx).await {
        Ok(claims) => {
            auth.authenticated = true;
            auth.claims = Some(claims);
            info!(conn_id = %conn_id, "Client authenticated");
            let msg = ServerMessage::AuthOk {
                conn_id: conn_id.to_string(),
                server_time: Utc::now().to_rfc3339(),
            };
            send_ctrl(ctrl_tx, &msg).await;
            Action::Continue
        }
        Err(e) => {
            warn!(conn_id = %conn_id, "Auth failed: {}", e);
            send_ctrl(ctrl_tx, &ServerMessage::error("AUTH_FAILED", e.to_string())).await;
            Action::Close
        }
    }
}

#[allow(clippy::too_many_arguments, clippy::cognitive_complexity)]
pub(super) async fn handle_subscribe(
    sub_id: String,
    topic: String,
    filter: Option<serde_json::Value>,
    options: Option<realtime_core::SubOptions>,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Subscribe before auth");
        return Action::Continue;
    }
    let pattern = TopicPattern::parse(&topic);
    if let Some(ref c) = auth.claims {
        if state
            .auth_provider
            .authorize_subscribe(c, &pattern)
            .await
            .is_err()
        {
            warn!(conn_id = %conn_id, "Subscribe denied");
            return Action::Continue;
        }
    }
    let sub = Subscription {
        sub_id: SubscriptionId(SmolStr::new(&sub_id)),
        conn_id,
        topic: pattern,
        filter: filter.and_then(|f| FilterExpr::from_json(&f)),
        config: parse_sub_config(options),
    };
    if let Err(e) = state.registry.subscribe(sub, None) {
        warn!(conn_id = %conn_id, sub_id = %sub_id, "Subscribe rejected: {}", e);
        send_ctrl(
            ctrl_tx,
            &ServerMessage::error("CAPACITY_EXCEEDED", e.to_string()),
        )
        .await;
        return Action::Continue;
    }
    debug!(conn_id = %conn_id, sub_id = %sub_id, "Subscribed");
    send_ctrl(ctrl_tx, &ServerMessage::Subscribed { sub_id, seq: 0 }).await;
    Action::Continue
}

pub(super) async fn handle_subscribe_batch(
    subscriptions: Vec<SubscribeItem>,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Subscribe batch before auth");
        return Action::Continue;
    }
    for item in subscriptions {
        let sub = Subscription {
            sub_id: SubscriptionId(SmolStr::new(&item.sub_id)),
            conn_id,
            topic: TopicPattern::parse(&item.topic),
            filter: item.filter.and_then(|f| FilterExpr::from_json(&f)),
            config: parse_sub_config(item.options),
        };
        if let Err(e) = state.registry.subscribe(sub, None) {
            warn!(conn_id = %conn_id, sub_id = %item.sub_id, "Subscribe rejected: {}", e);
            send_ctrl(
                ctrl_tx,
                &ServerMessage::error("CAPACITY_EXCEEDED", e.to_string()),
            )
            .await;
            continue;
        }
        send_ctrl(
            ctrl_tx,
            &ServerMessage::Subscribed {
                sub_id: item.sub_id,
                seq: 0,
            },
        )
        .await;
    }
    Action::Continue
}

pub(super) async fn handle_unsubscribe(
    sub_id: String,
    conn_id: ConnectionId,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
) -> Action {
    state.registry.unsubscribe(conn_id, &sub_id);
    debug!(conn_id = %conn_id, sub_id = %sub_id, "Unsubscribed");
    send_ctrl(ctrl_tx, &ServerMessage::Unsubscribed { sub_id }).await;
    Action::Continue
}

#[allow(clippy::cognitive_complexity)]
pub(super) async fn handle_publish(
    topic: String,
    event_type: String,
    payload: serde_json::Value,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Publish before auth");
        return Action::Continue;
    }
    debug!(conn_id = %conn_id, topic = %topic, event_type = %event_type, "PUBLISH received");
    let payload_bytes = match serde_json::to_vec(&payload) {
        Ok(b) => b,
        Err(e) => {
            warn!(conn_id = %conn_id, "Invalid publish payload: {}", e);
            return Action::Continue;
        }
    };
    let envelope = EventEnvelope::new(
        TopicPath::new(&topic),
        &event_type,
        Bytes::from(payload_bytes),
    );
    if let Err(e) = state
        .bus_publisher
        .publish(envelope.topic.as_str(), &envelope)
        .await
    {
        error!(conn_id = %conn_id, "Failed to publish event: {}", e);
    }
    Action::Continue
}
