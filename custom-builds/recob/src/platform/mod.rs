//! The platform layer (§14).
//!
//! Everything AppKit-shaped lives behind this module: the native pasteboard
//! (§14.1), the observation loop that absorbs the watcher (§14.2), and the
//! frontmost-application read both the attribution and the password-manager
//! deny-list depend on. §14.7 is the other half of the contract: headless
//! Linux has no pasteboard, so the macOS implementation compiles out entirely
//! and what remains — the store, the sockets, the codec, the policy table and
//! the capture *decision* logic in `crate::capture` — is the whole of the wire
//! and none of the platform. Keeping that split real is what stops the Linux
//! build from rotting.
//!
//! The one piece that lives here on both platforms is the register-type
//! tracker, because it is plain state: §14.6 deletes the `current-regtype`
//! sidecar file and replaces it with the daemon remembering what *it* last
//! wrote.

#[cfg(target_os = "macos")]
pub mod macos;

use std::sync::Mutex;

/// §14.6: regtype without the sidecar file. The daemon holds the register type
/// of the clip it last wrote alongside the `changeCount` at which it wrote it;
/// `clip.get` (Phase 4) answers from that while the counts still match and
/// falls back to the trailing-newline heuristic once the pasteboard has moved
/// on. The sidecar's hash comparison existed only to detect the change the
/// daemon now observes directly, so there is no hash and no file here.
///
/// The same record answers §6.2's echo question: an observed `changeCount`
/// equal to the recorded one is the daemon's own write, not a copy to capture.
#[derive(Default)]
pub struct RegtypeTracker {
    last_write: Mutex<Option<LastWrite>>,
}

struct LastWrite {
    change_count: isize,
    regtype: Option<String>,
}

impl RegtypeTracker {
    /// Record a write the daemon performed: the pasteboard's `changeCount`
    /// after the write, and the register type of what was written (`None` when
    /// the clip has no v/l/b register semantics).
    pub fn record(&self, change_count: isize, regtype: Option<String>) {
        *self.last_write.lock().unwrap() = Some(LastWrite {
            change_count,
            regtype,
        });
    }

    /// Whether an observed change is the daemon's own last write (§6.2): the
    /// capture path skips it, because the write path already stored its row.
    pub fn is_own(&self, change_count: isize) -> bool {
        self.last_write
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|write| write.change_count == change_count)
    }

    /// The register type of the daemon's last write, while the pasteboard
    /// still holds it. `None` means the pasteboard moved on — or the clip
    /// carried no register type — and the caller falls back to today's
    /// trailing-newline heuristic (§14.6).
    pub fn regtype_at(&self, change_count: isize) -> Option<String> {
        self.last_write
            .lock()
            .unwrap()
            .as_ref()
            .filter(|write| write.change_count == change_count)
            .and_then(|write| write.regtype.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tracker_matches_only_the_recorded_change_count() {
        let tracker = RegtypeTracker::default();
        assert!(!tracker.is_own(7), "nothing recorded yet");
        tracker.record(7, Some("b".to_string()));
        assert!(tracker.is_own(7));
        assert_eq!(tracker.regtype_at(7).as_deref(), Some("b"));
        // The pasteboard moved on: the stored value no longer applies, with no
        // hash comparison needed (§14.6).
        assert!(!tracker.is_own(8));
        assert_eq!(tracker.regtype_at(8), None);
    }

    #[test]
    fn a_write_without_register_semantics_still_answers_the_echo_question() {
        let tracker = RegtypeTracker::default();
        tracker.record(3, None);
        assert!(
            tracker.is_own(3),
            "own-write detection is independent of regtype"
        );
        assert_eq!(tracker.regtype_at(3), None);
    }
}
