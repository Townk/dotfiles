//! §9.6: subtractive exposure — the one kind of configuration v1 gets.
//!
//! A local file may declare that this machine does not answer a given operation
//! on a given endpoint. It can only ever make something stop working: the check
//! sits in the same call site as the §9.3 policy lookup and is evaluated *after*
//! it, so withdrawing can remove a capability the table granted and can never
//! restore one it denied.
//!
//! Two things this deliberately does not do. It does not filter `caps` (§9.6:
//! that would make a withdrawn operation indistinguishable from an older build
//! and break §7.1's diagnostic), and it cannot name a *new* operation — additive
//! configuration is refused, because it converts a stolen token from "clipboard
//! access" into arbitrary execution.
//!
//! Format, one rule per line, `#` comments and blank lines ignored:
//!
//! ```text
//! public   osd.notify        # no toasts from across the tunnel
//! trusted  window.fullscreen.toggle
//! ```
//!
//! Re-read per request rather than cached, per §3.4's rule about state another
//! process can change: an operator editing the file expects the next request to
//! honour it, not the next daemon restart.

use std::path::{Path, PathBuf};

use crate::listen::Endpoint;
use crate::log;

pub struct Exposure {
    path: Option<PathBuf>,
}

impl Default for Exposure {
    fn default() -> Self {
        Exposure {
            path: Some(default_path()),
        }
    }
}

impl Exposure {
    /// No exposure file at all — nothing is ever withdrawn.
    pub fn none() -> Self {
        Exposure { path: None }
    }

    pub fn at(path: PathBuf) -> Self {
        Exposure { path: Some(path) }
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Whether this machine declines to answer `op` on `endpoint`.
    ///
    /// A malformed line is reported and ignored rather than being allowed to
    /// withdraw something by accident: an operator typo must not silently
    /// disable an operation, and it must not silently enable one either.
    pub fn withdrawn(&self, op: &str, endpoint: Endpoint) -> bool {
        let Some(path) = &self.path else {
            return false;
        };
        let Ok(text) = std::fs::read_to_string(path) else {
            return false;
        };
        for (n, line) in text.lines().enumerate() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let mut parts = line.split_whitespace();
            let (Some(want_endpoint), Some(want_op), None) =
                (parts.next(), parts.next(), parts.next())
            else {
                log!(
                    "{}:{}: expected `<endpoint> <operation>`, ignoring {line:?}",
                    path.display(),
                    n + 1
                );
                continue;
            };
            let Some(want_endpoint) = Endpoint::parse(want_endpoint) else {
                log!(
                    "{}:{}: {want_endpoint:?} is neither public nor trusted, ignoring",
                    path.display(),
                    n + 1
                );
                continue;
            };
            if want_endpoint == endpoint && want_op == op {
                return true;
            }
        }
        false
    }
}

fn default_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let mut home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
            home.push(".config");
            home
        });
    base.join("clipboard/exposure")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil;

    fn exposure_with(contents: &str) -> (testutil::TempDir, Exposure) {
        let dir = testutil::tempdir("exposure");
        let path = dir.path().join("exposure");
        std::fs::write(&path, contents).unwrap();
        (dir, Exposure::at(path))
    }

    #[test]
    fn a_rule_withdraws_one_operation_from_one_endpoint() {
        let (_dir, exposure) = exposure_with("public osd.notify\n");
        assert!(exposure.withdrawn("osd.notify", Endpoint::Public));
        assert!(!exposure.withdrawn("osd.notify", Endpoint::Trusted));
        assert!(!exposure.withdrawn("host.identity", Endpoint::Public));
    }

    #[test]
    fn comments_blank_lines_and_extra_spacing_are_tolerated() {
        let (_dir, exposure) = exposure_with(
            "# withdraw toasts\n\n   trusted   window.fullscreen.toggle   \npublic osd.notify # why\n",
        );
        assert!(exposure.withdrawn("window.fullscreen.toggle", Endpoint::Trusted));
        assert!(exposure.withdrawn("osd.notify", Endpoint::Public));
    }

    #[test]
    fn a_malformed_line_withdraws_nothing() {
        let (_dir, exposure) = exposure_with("public\nnowhere osd.notify\npublic a b\n");
        assert!(!exposure.withdrawn("osd.notify", Endpoint::Public));
        assert!(!exposure.withdrawn("osd.notify", Endpoint::Trusted));
        assert!(!exposure.withdrawn("a", Endpoint::Public));
    }

    #[test]
    fn a_missing_file_withdraws_nothing() {
        let dir = testutil::tempdir("exposure-absent");
        let exposure = Exposure::at(dir.path().join("does-not-exist"));
        assert!(!exposure.withdrawn("host.identity", Endpoint::Public));
        assert!(!Exposure::none().withdrawn("host.identity", Endpoint::Public));
    }

    #[test]
    fn the_file_is_re_read_not_cached() {
        // §3.4: an operator editing it expects the next request to honour it.
        let (dir, exposure) = exposure_with("# nothing yet\n");
        assert!(!exposure.withdrawn("host.identity", Endpoint::Public));
        std::fs::write(dir.path().join("exposure"), "public host.identity\n").unwrap();
        assert!(exposure.withdrawn("host.identity", Endpoint::Public));
    }
}
