//! Test support shared by the unit tests and the integration tests.
//!
//! Included by path from `tests/`, so it must not reach into the crate. It
//! exists because a throwaway directory is the only thing the tests need from
//! what would otherwise be a dependency.

use std::path::{Path, PathBuf};

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A private (0700) directory under the system temp dir, removed on drop. The
/// mode matters: the trusted socket's parent has to be 0700 (§3.3), so a test
/// that binds inside a 0755 temp dir would be testing the wrong thing.
pub fn tempdir(label: &str) -> TempDir {
    use std::os::unix::fs::DirBuilderExt;
    use std::sync::atomic::{AtomicU32, Ordering};
    static SEQ: AtomicU32 = AtomicU32::new(0);

    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let mut path = std::env::temp_dir();
    path.push(format!("recobd-test-{label}-{}-{seq}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&path)
        .expect("create temp dir");
    TempDir(path)
}
