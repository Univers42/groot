use bytes::Bytes;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::{EventId, EventSource, PayloadEncoding, TopicPath, TraceId};

/// Canonical event representation — the *lingua franca* of the engine.
///
/// # Purpose
/// Every event flowing through the system is normalized into this
/// envelope before entering the bus, regardless of origin.
///
/// # Design
/// * `Bytes` payload — reference-counted, zero-copy fan-out via `Arc`.
/// * `UUIDv7` `event_id` — time-sortable, globally unique.
/// * 64 KB payload limit — enforced at ingestion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventEnvelope {
    /// Globally unique, producer-assigned. `UUIDv7` (time-sortable).
    pub event_id: EventId,
    /// Logical topic this event is published to.
    pub topic: TopicPath,
    /// Server-stamped timestamp (RFC 3339).
    pub timestamp: DateTime<Utc>,
    /// Logical sequence number within the topic.
    pub sequence: u64,
    /// Semantic label for the event type.
    pub event_type: String,
    /// Opaque payload bytes. Max 64KB enforced at ingestion.
    #[serde(with = "bytes_serde")]
    pub payload: Bytes,
    /// Content-type of payload bytes.
    pub payload_encoding: PayloadEncoding,
    /// Source that produced this event.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<EventSource>,
    /// Correlation ID for distributed tracing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<TraceId>,
    /// TTL in milliseconds for ephemeral events.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttl_ms: Option<u32>,
}

impl EventEnvelope {
    /// Create an envelope with minimal required fields.
    ///
    /// # Arguments
    /// * `topic` — Target topic path.
    /// * `event_type` — Semantic label (e.g. `"inserted"`).
    /// * `payload` — Opaque payload bytes (must be ≤64 KB).
    ///
    /// # Returns
    /// A new envelope with auto-generated `UUIDv7` id and UTC timestamp.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn new(topic: TopicPath, event_type: impl Into<String>, payload: Bytes) -> Self {
        Self {
            event_id: EventId::new(),
            topic,
            timestamp: Utc::now(),
            sequence: 0,
            event_type: event_type.into(),
            payload,
            payload_encoding: PayloadEncoding::Json,
            source: None,
            trace_id: None,
            ttl_ms: None,
        }
    }

    /// Return payload size in bytes.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub const fn payload_size(&self) -> usize {
        self.payload.len()
    }

    /// Check if the payload exceeds 64 KB.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub const fn is_payload_too_large(&self) -> bool {
        self.payload.len() > 65_536
    }
}

/// Custom serde helper for the `Bytes` payload field.
///
/// Inlines valid JSON directly; falls back to raw byte serialization.
mod bytes_serde {
    use bytes::Bytes;
    use serde::{self, Deserialize, Deserializer, Serialize, Serializer};

    /// Serialize `Bytes` — inlines valid JSON, otherwise raw bytes.
    pub fn serialize<S>(bytes: &Bytes, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(bytes) {
            val.serialize(serializer)
        } else {
            serializer.serialize_bytes(bytes)
        }
    }

    /// Deserialize into `Bytes` — parses JSON value then re-serializes.
    pub fn deserialize<'de, D>(deserializer: D) -> Result<Bytes, D::Error>
    where
        D: Deserializer<'de>,
    {
        let v = serde_json::Value::deserialize(deserializer)?;
        let b = serde_json::to_vec(&v).map_err(serde::de::Error::custom)?;
        Ok(Bytes::from(b))
    }
}
