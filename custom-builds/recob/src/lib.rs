//! `recobd` — the RECOB v1 daemon, specified in `docs/recob-protocol-spec.md`.
//!
//! Phases 1–3 of `docs/recob-implementation-plan.md`: the wire codec (§4), the
//! connection lifecycle (§5), the endpoints and accept loops (§3.1–§3.4), the
//! recording seam (§11.1), authentication and authorization (§9), and the
//! platform layer (§14) — the native pasteboard, the capture behaviors absorbed
//! from the watcher, and the store they write to. The rest of the registry
//! (§6.1) and the clients (§8) are later phases; where a later phase's field or
//! check belongs, this build says so rather than stubbing it.

pub mod auth;
pub mod capture;
pub mod exposure;
pub mod host;
pub mod limits;
pub mod listen;
pub mod ops;
pub mod platform;
pub mod record;
pub mod registry;
pub mod session;
pub mod store;
pub mod validate;
pub mod wire;

#[cfg(test)]
mod testutil;

/// Diagnostics go to stderr, where launchd and systemd already timestamp and
/// route them. §3.4 requires the endpoint and the operation on every line.
#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => {
        eprintln!("recobd: {}", format_args!($($arg)*))
    };
}
