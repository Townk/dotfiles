//! Private-file plumbing shared by the credential paths on both ends: a file
//! no other uid can ever read, with no instant in which it exists permissive.
//! The `umask` here is the one libc call this workspace makes by hand.

use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::Path;

use crate::log;

// mode_t is 16 bits on macOS and 32 on Linux; passing the wrong width is an ABI
// mismatch rather than a compile error, so it is spelled out per platform.
#[cfg(target_os = "macos")]
type ModeT = u16;
#[cfg(not(target_os = "macos"))]
type ModeT = u32;

extern "C" {
    fn umask(mask: ModeT) -> ModeT;
}

/// Sets the process umask and restores it on drop. Process-global, which is
/// safe at the call sites this crate has: credential bootstrap at startup and
/// socket binding, both before any accept loop exists to race with.
pub struct UmaskGuard(ModeT);

impl UmaskGuard {
    pub fn set(mask: u32) -> Self {
        UmaskGuard(unsafe { umask(mask as ModeT) })
    }
}

impl Drop for UmaskGuard {
    fn drop(&mut self) {
        unsafe { umask(self.0) };
    }
}

pub fn mode_of(path: &Path) -> io::Result<u32> {
    Ok(fs::metadata(path)?.permissions().mode() & 0o7777)
}

/// The 0700 parent a private file or socket lives under, created or tightened.
pub fn ensure_private_dir(parent: &Path) -> io::Result<()> {
    match fs::metadata(parent) {
        Ok(meta) if meta.is_dir() => {
            let mode = meta.permissions().mode() & 0o777;
            if mode != 0o700 {
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
                log!("tightened {} from {:04o} to 0700", parent.display(), mode);
            }
            Ok(())
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("{} exists and is not a directory", parent.display()),
        )),
        Err(_) => fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent),
    }
}

/// Writes a file no other uid can read: umask before the write so it is never
/// created permissive, an explicit chmod after so the mode does not depend on
/// what the process started with.
pub fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    {
        let _guard = UmaskGuard::set(0o077);
        fs::write(path, bytes)?;
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}
