//! Contract-first broker core for Agent Manager.
//!
//! M0 deliberately exposes only protocol types, replay sequencing, and the
//! exact Codex App Server process boundary. Editor-facing lifecycle and UI
//! arrive in later milestones.

pub mod codex;
mod framing;
pub mod protocol;
pub mod replay;
pub mod worker;

pub const BROKER_VERSION: &str = env!("CARGO_PKG_VERSION");
