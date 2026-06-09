//! # realtime-bus-irc
//!
//! An [`EventBus`](realtime_core::EventBus) backend that bridges the
//! realtime-agnostic gateway to an external RFC 2812 IRC server (e.g. `ircserv`).
//!
//! Gateway topics in the configured namespace (default `chat`) map to IRC
//! channels: a WebSocket `PUBLISH` on `chat/general` becomes a `PRIVMSG #general`,
//! and an inbound `PRIVMSG #general` becomes an `EVENT` on `chat/general`. Topics
//! outside the namespace are ignored by this bus.
//!
//! v1 uses a single service-identity connection (a relay). Per-user IRC sessions
//! (true presence) are the next iteration — see `IrcBusConfig::namespace` and the
//! `EventSource` carried on each event, which already identifies the originating
//! user for that work.

mod bus;
mod client;
mod mapping;
mod publisher;
mod subscriber;

pub use bus::IrcBus;

/// Configuration for the IRC event-bus backend.
#[derive(Debug, Clone)]
pub struct IrcBusConfig {
    /// IRC server host.
    pub host: String,
    /// IRC server port.
    pub port: u16,
    /// Server password (`PASS`). Empty to skip.
    pub password: String,
    /// Service nickname used by the relay connection.
    pub nick: String,
    /// IRC username (`USER`).
    pub user: String,
    /// IRC realname (`USER` trailing).
    pub realname: String,
    /// Channels to auto-join on connect.
    pub channels: Vec<String>,
    /// Gateway topic namespace bridged to IRC (e.g. `chat`).
    pub namespace: String,
    /// Inbound broadcast channel capacity.
    pub capacity: usize,
}

impl Default for IrcBusConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 6667,
            password: String::new(),
            nick: "platform-gw".to_string(),
            user: "platform".to_string(),
            realname: "Realtime Gateway".to_string(),
            channels: Vec::new(),
            namespace: "chat".to_string(),
            capacity: 65_536,
        }
    }
}
