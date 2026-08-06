//! This machine's wire identity — the `host` field of the banner (§5.1) and of
//! `host.identity`'s response (§6.1).
//!
//! Precedence mirrors `clip::self_host` (`home/dot_local/lib/clipboard-store-core.zsh`):
//! a validated first line of `$XDG_STATE_HOME/clipboard/self-name`, else
//! `scutil --get LocalHostName`, else `hostname -s`.
//!
//! §3.4 forbids caching the first of those: `ssh-prepare-connection` rewrites
//! the file at connect time while the daemon runs, so a value read once at
//! startup would be wrong for the rest of the daemon's life. The two fallbacks
//! are not rewritten by another process at connect time and cost a subprocess
//! each, which §1.1 is emphatic about not paying per connection — so the file is
//! re-read per request and only the fallback is resolved once.

use std::path::{Path, PathBuf};
use std::process::Command;

/// §6.6: `[A-Za-z0-9][A-Za-z0-9.-]*`, at most 253 bytes. The value reaches a
/// store row and, on a peer, a mount key, so an unchecked one is a hazard.
pub fn valid_host(host: &str) -> bool {
    if host.is_empty() || host.len() > 253 {
        return false;
    }
    let mut bytes = host.bytes();
    let first = bytes.next().unwrap();
    if !first.is_ascii_alphanumeric() {
        return false;
    }
    bytes.all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

pub struct HostIdentity {
    self_name: PathBuf,
    fallback: Option<String>,
}

impl HostIdentity {
    /// Resolves the subprocess-backed fallback once, at startup.
    pub fn resolve() -> Self {
        HostIdentity {
            self_name: self_name_path(),
            fallback: system_host(),
        }
    }

    pub fn with_paths(self_name: PathBuf, fallback: Option<String>) -> Self {
        HostIdentity {
            self_name,
            fallback,
        }
    }

    /// The identity as of right now. Re-reads the self-name file every call.
    pub fn current(&self) -> Option<String> {
        if let Some(name) = read_self_name(&self.self_name) {
            return Some(name);
        }
        self.fallback.clone()
    }
}

fn self_name_path() -> PathBuf {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let mut home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
            home.push(".local/state");
            home
        });
    state.join("clipboard/self-name")
}

fn read_self_name(path: &Path) -> Option<String> {
    let raw = std::fs::read(path).ok()?;
    let line = raw.split(|b| *b == b'\n').next()?;
    let name = std::str::from_utf8(line).ok()?.trim_end_matches('\r');
    if valid_host(name) {
        Some(name.to_string())
    } else {
        None
    }
}

fn system_host() -> Option<String> {
    for (cmd, args) in [
        ("scutil", &["--get", "LocalHostName"][..]),
        ("hostname", &["-s"][..]),
    ] {
        if let Ok(out) = Command::new(cmd).args(args).output() {
            if out.status.success() {
                let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if valid_host(&name) {
                    return Some(name);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_shape_is_enforced() {
        assert!(valid_host("boxA"));
        assert!(valid_host("a.b-c.0"));
        assert!(!valid_host(""));
        assert!(!valid_host("-boxA"));
        assert!(!valid_host(".boxA"));
        assert!(!valid_host("box A"));
        assert!(!valid_host("box\nA"));
        assert!(!valid_host(&"a".repeat(254)));
    }

    #[test]
    fn the_self_name_file_wins_and_is_not_cached() {
        let dir = crate::testutil::tempdir("host-self-name");
        let path = dir.path().join("self-name");
        std::fs::write(&path, "boxA\nignored\n").unwrap();
        let id = HostIdentity::with_paths(path.clone(), Some("fallback".into()));
        assert_eq!(id.current().as_deref(), Some("boxA"));

        std::fs::write(&path, "boxB\n").unwrap();
        assert_eq!(
            id.current().as_deref(),
            Some("boxB"),
            "§3.4: the file is re-read, never cached"
        );

        std::fs::remove_file(&path).unwrap();
        assert_eq!(id.current().as_deref(), Some("fallback"));
    }

    #[test]
    fn a_malformed_self_name_falls_through_to_the_fallback() {
        let dir = crate::testutil::tempdir("host-bad-self-name");
        let path = dir.path().join("self-name");
        std::fs::write(&path, "not a hostname\n").unwrap();
        let id = HostIdentity::with_paths(path, Some("fallback".into()));
        assert_eq!(id.current().as_deref(), Some("fallback"));
    }
}
