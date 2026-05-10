//! REST API handlers for event publishing and health checks.
//!
//! | Method | Path                | Description                    |
//! |--------|---------------------|--------------------------------|
//! | `POST` | `/v1/publish`       | Publish a single event         |
//! | `POST` | `/v1/publish/batch` | Publish up to 1000 events      |
//! | `GET`  | `/v1/health`        | Health check + connection stats|

use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use bytes::Bytes;
use realtime_core::{
    BatchPublishRequest, BatchPublishResponse, EventEnvelope, HealthResponse, PublishRequest,
    PublishResponse, TopicPath,
};
use tracing::{debug, error};

use crate::ws_handler::AppState;

type ApiError = (StatusCode, Json<serde_json::Value>);

fn validate_and_create_envelope(req: &PublishRequest) -> Result<EventEnvelope, ApiError> {
    if req.topic.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "Topic is required" })),
        ));
    }
    let bytes = serde_json::to_vec(&req.payload).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": format!("Invalid payload: {e}") })),
        )
    })?;
    if bytes.len() > 65_536 {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(serde_json::json!({ "error": "Payload exceeds 64KB limit" })),
        ));
    }
    Ok(EventEnvelope::new(
        TopicPath::new(&req.topic),
        &req.event_type,
        Bytes::from(bytes),
    ))
}

fn validate_batch(req: &BatchPublishRequest) -> Result<Vec<(String, EventEnvelope)>, ApiError> {
    if req.events.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "At least one event is required" })),
        ));
    }
    if req.events.len() > 1000 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "Maximum 1000 events per batch" })),
        ));
    }
    let mut events = Vec::with_capacity(req.events.len());
    for item in &req.events {
        let bytes = serde_json::to_vec(&item.payload).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({ "error": format!("Invalid payload: {e}") })),
            )
        })?;
        if bytes.len() > 65_536 {
            return Err((
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(serde_json::json!({ "error": "Payload exceeds 64KB" })),
            ));
        }
        let ev = EventEnvelope::new(
            TopicPath::new(&item.topic),
            &item.event_type,
            Bytes::from(bytes),
        );
        events.push((item.topic.clone(), ev));
    }
    Ok(events)
}

pub async fn publish_event(
    State(state): State<AppState>,
    Json(req): Json<PublishRequest>,
) -> impl IntoResponse {
    let event = match validate_and_create_envelope(&req) {
        Ok(e) => e,
        Err(resp) => return resp,
    };
    match state.bus_publisher.publish(&req.topic, &event).await {
        Ok(receipt) => {
            debug!(event_id = %receipt.event_id, topic = %req.topic, "Event published");
            (
                StatusCode::OK,
                Json(serde_json::json!(PublishResponse {
                    event_id: receipt.event_id.to_string(),
                    sequence: receipt.sequence,
                    delivered_to_bus: receipt.delivered_to_bus,
                })),
            )
        }
        Err(e) => {
            error!("Failed to publish event: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": format!("Publish failed: {e}") })),
            )
        }
    }
}

pub async fn publish_batch(
    State(state): State<AppState>,
    Json(req): Json<BatchPublishRequest>,
) -> impl IntoResponse {
    let events = match validate_batch(&req) {
        Ok(e) => e,
        Err(resp) => return resp,
    };
    match state.bus_publisher.publish_batch(&events).await {
        Ok(receipts) => {
            let results: Vec<PublishResponse> = receipts
                .iter()
                .map(|r| PublishResponse {
                    event_id: r.event_id.to_string(),
                    sequence: r.sequence,
                    delivered_to_bus: r.delivered_to_bus,
                })
                .collect();
            (
                StatusCode::OK,
                Json(serde_json::json!(BatchPublishResponse { results })),
            )
        }
        Err(e) => {
            error!("Failed to publish batch: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": format!("Batch failed: {e}") })),
            )
        }
    }
}

#[allow(clippy::unused_async)]
pub async fn health_check(State(state): State<AppState>) -> impl IntoResponse {
    let filter_snapshot = state.registry.filter_index_snapshot();

    // Status is "degraded" if the circuit breaker has recently bypassed evaluations.
    let status = if filter_snapshot.circuit_bypassed > 0 {
        "degraded"
    } else {
        "ok"
    };

    let resp = HealthResponse {
        status: status.to_string(),
        connections: state.conn_manager.connection_count() as u64,
        subscriptions: state.registry.subscription_count() as u64,
        uptime_seconds: 0,
        filter_index: serde_json::to_value(&filter_snapshot).ok(),
        dispatch: None,
    };
    (StatusCode::OK, Json(resp))
}
