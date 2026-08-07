//! `recob-wire` — the halves of RECOB both ends share: the codec (§4), the
//! credential primitives (§9.2), and the client contract (§8).
//!
//! **This crate must never grow a platform dependency.** The clients are built
//! from it alone, and §8's hard rule — no AppKit in a client — is enforced by
//! this crate boundary plus the `otool -L` assertion in the daemon's suite.

pub mod auth;
pub mod cli;
pub mod client;
pub mod fsfile;
pub mod paste_files;
pub mod registry;
pub mod wire;

#[cfg(test)]
#[path = "../../src/testutil.rs"]
mod testutil;

/// Diagnostics go to stderr, where launchd and systemd already timestamp and
/// route them. §3.4 requires the endpoint and the operation on every line.
#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => {
        eprintln!("recobd: {}", format_args!($($arg)*))
    };
}
