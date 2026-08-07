//! The client's own copy of §6.1's operation registry — names and `since`
//! only. §7.1 needs it for the clause "and <op> needs proto <n>": that fact
//! cannot be derived from the version integers, so every operation carries
//! the `proto` it first appeared in. Every v1 operation is `since: 1`; the
//! column starts carrying information at the first `proto` bump.
//!
//! The daemon's `registry::OPS` is the authority (§9.3: one table, declared
//! once); a test beside that table pins this copy to it name-for-name and
//! since-for-since, so the two cannot drift apart silently.

pub const OPS: &[(&str, u32)] = &[
    ("host.identity", 1),
    ("osd.notify", 1),
    ("clip.get", 1),
    ("clip.set", 1),
    ("clip.set.rich", 1),
    ("clip.set.files", 1),
    ("clip.restore", 1),
    ("files.list", 1),
    ("files.grant", 1),
    ("files.fetch", 1),
    ("store.persist.text", 1),
    ("store.persist.files", 1),
    ("window.fullscreen.toggle", 1),
    ("window.fullscreen.state", 1),
];

/// The `proto` in which `op` first appeared, if this client knows the
/// operation at all.
pub fn since(op: &str) -> Option<u32> {
    OPS.iter()
        .find(|(name, _)| *name == op)
        .map(|(_, since)| *since)
}
