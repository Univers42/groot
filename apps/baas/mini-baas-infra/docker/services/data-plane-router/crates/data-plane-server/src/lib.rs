//! Lint policy: `result_large_err` is allowed crate-wide — axum handlers
//! here use `Result<T, axum::response::Response>` where the Err is a fully
//! built HTTP error response. That variant is cold by definition (it ends the
//! request) and boxing every error response would touch hundreds of call
//! sites for a perf win on the path we never optimize. Everything else stays
//! under `-D warnings` (the m47 clippy wall).
#![allow(clippy::result_large_err)]

pub mod abac;
pub mod auth;
#[cfg(feature = "control-pg")]
pub mod automations;
pub mod config;
pub mod graph;
pub mod metrics;
#[cfg(feature = "nano")]
pub mod nano;
#[cfg(feature = "one")]
pub mod one;
#[cfg(feature = "one")]
pub mod one_admin;
#[cfg(feature = "pbcompat")]
pub mod pb;
#[cfg(feature = "one")]
pub mod one_email;
#[cfg(feature = "one")]
pub mod one_files;
#[cfg(feature = "one")]
pub mod one_oauth;
#[cfg(feature = "one")]
pub mod one_totp;
#[cfg(feature = "control-pg")]
pub mod outbox;
pub mod ratelimit;
pub mod routes;
pub mod server;
pub mod signal;
