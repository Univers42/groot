//! Event bus configuration.

use serde::{Deserialize, Serialize};

/// Event bus backend selection.
///
/// Currently only `InProcess` is supported. Future variants could include
/// Redis Streams, NATS `JetStream`, or Apache Kafka.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum EventBusConfig {
    #[serde(rename = "inprocess")]
    InProcess {
        #[serde(default = "default_bus_capacity")]
        capacity: usize,
    },
}

impl Default for EventBusConfig {
    fn default() -> Self {
        Self::InProcess {
            capacity: default_bus_capacity(),
        }
    }
}

const fn default_bus_capacity() -> usize {
    65536
}
