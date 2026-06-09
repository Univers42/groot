//! [`IrcBus`] — an [`EventBus`] backend that bridges the gateway to an IRC
//! server. A background task owns the TCP connection; publishers send raw lines
//! to it over an mpsc channel, subscribers receive inbound events from a
//! broadcast channel.

use async_trait::async_trait;
use realtime_core::{EventBus, EventBusPublisher, EventBusSubscriber, EventEnvelope, Result};
use tokio::sync::{broadcast, mpsc};
use tracing::info;

use crate::client::{run_client, SessionConfig};
use crate::publisher::IrcPublisher;
use crate::subscriber::IrcSubscriber;
use crate::IrcBusConfig;

/// IRC-backed event bus (service-identity connection).
pub struct IrcBus {
    cmd_tx: mpsc::Sender<String>,
    inbound: broadcast::Sender<EventEnvelope>,
    namespace: String,
}

impl IrcBus {
    /// Connect to the configured IRC server and start the session task.
    #[must_use]
    pub fn new(config: IrcBusConfig) -> Self {
        let (cmd_tx, cmd_rx) = mpsc::channel::<String>(1024);
        let (inbound, _) = broadcast::channel::<EventEnvelope>(config.capacity);

        let session = SessionConfig {
            host: config.host,
            port: config.port,
            password: config.password,
            nick: config.nick,
            user: config.user,
            realname: config.realname,
            channels: config.channels,
            namespace: config.namespace.clone(),
        };

        let inbound_tx = inbound.clone();
        tokio::spawn(async move {
            run_client(session, cmd_rx, inbound_tx).await;
        });

        info!(namespace = %config.namespace, "IRC event bus created");
        Self {
            cmd_tx,
            inbound,
            namespace: config.namespace,
        }
    }
}

#[async_trait]
impl EventBus for IrcBus {
    async fn publisher(&self) -> Result<Box<dyn EventBusPublisher>> {
        Ok(Box::new(IrcPublisher::new(
            self.cmd_tx.clone(),
            self.namespace.clone(),
        )))
    }

    async fn subscriber(&self, _topic_pattern: &str) -> Result<Box<dyn EventBusSubscriber>> {
        Ok(Box::new(IrcSubscriber::new(self.inbound.subscribe())))
    }

    async fn health_check(&self) -> Result<()> {
        if self.cmd_tx.is_closed() {
            return Err(realtime_core::RealtimeError::EventBusError(
                "IRC session task has stopped".to_string(),
            ));
        }
        Ok(())
    }

    async fn shutdown(&self) -> Result<()> {
        info!("IRC event bus shutting down");
        Ok(())
    }
}
