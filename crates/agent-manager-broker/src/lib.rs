//! Contract-first broker core for Agent Manager.
//!
//! M1 adds an embedded stdio broker while retaining the contract-first provider
//! boundaries established in M0.

pub mod codex;
pub mod embedded;
mod framing;
pub mod protocol;
pub mod replay;
mod runtime;
pub mod worker;

pub const BROKER_VERSION: &str = env!("CARGO_PKG_VERSION");
