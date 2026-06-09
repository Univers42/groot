//! Publisher side: gateway PUBLISH -> IRC PRIVMSG.

use async_trait::async_trait;
use realtime_core::{
    EventBusPublisher, EventEnvelope, PublishReceipt, RealtimeError, Result,
};
use tokio::sync::mpsc;

use crate::mapping::topic_to_channel;

/// Publishes events onto IRC by sending raw lines to the session task.
pub struct IrcPublisher {
    cmd_tx: mpsc::Sender<String>,
    namespace: String,
}

impl IrcPublisher {
    pub(crate) const fn new(cmd_tx: mpsc::Sender<String>, namespace: String) -> Self {
        Self { cmd_tx, namespace }
    }
}

/// Extract a human-readable message from an event payload.
///
/// Accepts a bare JSON string, a `{ "text": "..." }` object, or falls back to
/// the lossy UTF-8 rendering of the raw bytes.
fn payload_text(event: &EventEnvelope) -> String {
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&event.payload) {
        if let Some(s) = value.as_str() {
            return s.to_string();
        }
        if let Some(s) = value.get("text").and_then(serde_json::Value::as_str) {
            return s.to_string();
        }
        return value.to_string();
    }
    String::from_utf8_lossy(&event.payload).to_string()
}

#[async_trait]
impl EventBusPublisher for IrcPublisher {
    async fn publish(&self, topic: &str, event: &EventEnvelope) -> Result<PublishReceipt> {
        let Some(channel) = topic_to_channel(topic, &self.namespace) else {
            // Outside the bridged namespace: nothing to do on IRC.
            return Ok(PublishReceipt {
                event_id: event.event_id.clone(),
                sequence: event.sequence,
                delivered_to_bus: false,
            });
        };

        let mut text = payload_text(event);
        // Service-relay attribution: prefix the originating user when known.
        if let Some(source) = &event.source {
            if !source.id.is_empty() {
                text = format!("<{}> {}", source.id, text);
            }
        }

        let line = format!("PRIVMSG {channel} :{text}");
        self.cmd_tx
            .send(line)
            .await
            .map_err(|e| RealtimeError::EventBusError(format!("IRC session unavailable: {e}")))?;

        Ok(PublishReceipt {
            event_id: event.event_id.clone(),
            sequence: event.sequence,
            delivered_to_bus: true,
        })
    }

    async fn publish_batch(
        &self,
        events: &[(String, EventEnvelope)],
    ) -> Result<Vec<PublishReceipt>> {
        let mut receipts = Vec::with_capacity(events.len());
        for (topic, event) in events {
            receipts.push(self.publish(topic, event).await?);
        }
        Ok(receipts)
    }
}
