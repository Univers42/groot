use serde::{Deserialize, Serialize};
use std::fmt;
use uuid::Uuid;

/// Globally unique event identifier using `UUIDv7` (time-sortable).
///
/// # Purpose
/// Provides globally unique, time-sortable event identification without
/// coordination between nodes.
///
/// # Example
/// ```
/// use realtime_core::EventId;
/// let id = EventId::new();
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EventId(pub Uuid);

impl EventId {
    /// Generate a new `UUIDv7` event identifier.
    ///
    /// # Purpose
    /// Each call produces a globally unique, time-sortable ID.
    ///
    /// # Returns
    /// A fresh `EventId` wrapping a `UUIDv7`.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::now_v7())
    }
}

impl Default for EventId {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Display for EventId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}
