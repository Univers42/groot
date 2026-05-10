//! Trait definitions that form the extension points of the engine.
//!
//! Every swappable component is defined here as a trait. Concrete
//! implementations live in their own crates.

mod auth;
mod bus;
mod producer;
mod transport;

pub use auth::*;
pub use bus::*;
pub use producer::*;
pub use transport::*;
