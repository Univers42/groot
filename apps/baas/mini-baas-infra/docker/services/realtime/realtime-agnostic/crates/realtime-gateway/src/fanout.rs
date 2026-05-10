//! Fan-out worker pool — bridges the router's dispatch channel to
//! per-connection send queues.
//!
//! The pool spawns N worker tasks that compete to read from a shared
//! `mpsc` channel. Each [`LocalDispatch`] is forwarded to the target
//! connection via [`ConnectionManager::try_send()`].

use std::sync::Arc;

use realtime_engine::router::{DispatchMessage, LocalDispatch};
use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::connection::{ConnectionManager, SendResult};

/// Fan-out worker pool that delivers events from the router to connections.
pub struct FanOutWorkerPool {
    conn_manager: Arc<ConnectionManager>,
    worker_count: usize,
}

impl FanOutWorkerPool {
    pub const fn new(conn_manager: Arc<ConnectionManager>, worker_count: usize) -> Self {
        Self {
            conn_manager,
            worker_count,
        }
    }

    #[must_use]
    pub fn start(&self) -> mpsc::Sender<DispatchMessage> {
        // Treat 0 as auto-detect: use the number of available CPU cores (min 1).
        let count = if self.worker_count == 0 {
            std::thread::available_parallelism()
                .map(std::num::NonZero::get)
                .unwrap_or(4)
        } else {
            self.worker_count
        };
        let (tx, rx) = mpsc::channel::<DispatchMessage>(65536);
        let shared_rx = Arc::new(tokio::sync::Mutex::new(rx));
        for worker_id in 0..count {
            let cm = Arc::clone(&self.conn_manager);
            let rx = Arc::clone(&shared_rx);
            tokio::spawn(run_worker(worker_id, rx, cm));
        }
        tx
    }
}

async fn run_worker(
    worker_id: usize,
    rx: Arc<tokio::sync::Mutex<mpsc::Receiver<DispatchMessage>>>,
    conn_manager: Arc<ConnectionManager>,
) {
    loop {
        let message = {
            let mut guard = rx.lock().await;
            guard.recv().await
        };
        match message {
            Some(DispatchMessage::Single(d)) => {
                handle_dispatch(worker_id, d, &conn_manager);
            }
            Some(DispatchMessage::Batch { event, targets }) => {
                for (conn_id, sub_id) in targets {
                    let d = LocalDispatch {
                        conn_id,
                        sub_id,
                        event: std::sync::Arc::clone(&event),
                    };
                    handle_dispatch(worker_id, d, &conn_manager);
                }
            }
            None => {
                debug!(worker = worker_id, "Fan-out worker exiting");
                break;
            }
        }
    }
}

fn handle_dispatch(worker_id: usize, dispatch: LocalDispatch, conn_manager: &ConnectionManager) {
    let conn_id = dispatch.conn_id;
    match conn_manager.try_send(conn_id, dispatch.sub_id.to_string(), dispatch.event) {
        SendResult::Sent => {}
        SendResult::DroppedNewest | SendResult::DroppedOldest => {
            debug!(worker = worker_id, conn_id = %conn_id, "Event dropped due to overflow");
        }
        SendResult::Disconnect => {
            warn!(worker = worker_id, conn_id = %conn_id, "Disconnecting slow consumer");
            conn_manager.remove(conn_id);
        }
        SendResult::ConnectionGone => {
            debug!(worker = worker_id, conn_id = %conn_id, "Connection gone");
        }
    }
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use chrono::Utc;
    use realtime_core::{ConnectionMeta, EventEnvelope, OverflowPolicy, SubscriptionId, TopicPath};
    use smol_str::SmolStr;

    #[tokio::test]
    async fn test_fanout_delivery() {
        let conn_manager = Arc::new(ConnectionManager::new(256));
        let pool = FanOutWorkerPool::new(Arc::clone(&conn_manager), 2);
        let dispatch_tx = pool.start();

        let conn_id = conn_manager.next_connection_id();
        let meta = ConnectionMeta {
            conn_id,
            peer_addr: "127.0.0.1:12345".parse().unwrap(),
            connected_at: Utc::now(),
            user_id: None,
            claims: None,
        };
        let (_, mut rx) = conn_manager.register(meta, OverflowPolicy::DropNewest);

        let event = Arc::new(EventEnvelope::new(
            TopicPath::new("test"),
            "test",
            Bytes::from("{}"),
        ));

        dispatch_tx
            .send(DispatchMessage::Single(LocalDispatch {
                conn_id,
                sub_id: SubscriptionId(SmolStr::new("sub-1")),
                event,
            }))
            .await
            .unwrap();

        let received = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
            .await
            .unwrap()
            .unwrap();

        assert_eq!(received.event_type, "test");
    }
}
