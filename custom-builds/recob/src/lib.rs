//! `recobd` — the RECOB v1 daemon, specified in `docs/recob-protocol-spec.md`.
//!
//! Phase 1 of `docs/recob-implementation-plan.md`: the wire codec (§4), the
//! connection lifecycle (§5), the endpoints and accept loops (§3.1–§3.4) and the
//! recording seam (§11.1). Authentication (§9), the macOS pasteboard (§14), the
//! rest of the registry (§6.1) and the clients (§8) are later phases; where a
//! later phase's field or check belongs, this build says so rather than stubbing
//! it.

pub mod host;
pub mod listen;
pub mod record;
pub mod registry;
pub mod session;
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
