//! `recobd` — the RECOB v1 daemon, specified in `docs/recob-protocol-spec.md`.
//!
//! Phases 1–3 of `docs/recob-implementation-plan.md`: the wire codec (§4), the
//! connection lifecycle (§5), the endpoints and accept loops (§3.1–§3.4), the
//! recording seam (§11.1), authentication and authorization (§9), and the
//! platform layer (§14) — the native pasteboard, the capture behaviors absorbed
//! from the watcher, and the store they write to. The rest of the registry
//! (§6.1) and the clients (§8) are later phases; where a later phase's field or
//! check belongs, this build says so rather than stubbing it.

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
pub mod visited;

// The shared halves live in `recob-wire` (§8: the clients are built from the
// codec crate and must not inherit this crate's AppKit linkage). Re-exported
// under their old paths so both `crate::wire` and `recobd::wire` still hold.
pub use recob_wire::{auth, client, fsfile, wire};

#[cfg(test)]
mod testutil;

pub use recob_wire::log;
