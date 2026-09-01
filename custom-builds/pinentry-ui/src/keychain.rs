//! The macOS keychain read — the one external store this pinentry consults.
//!
//! The entry is the one pinentry-mac writes when a passphrase is saved at the
//! console: service `GnuPG`, account = the keygrip gpg-agent hands over in
//! `SETKEYINFO n/<grip>`. pinentry-touchid reads the same entry behind a
//! fingerprint; this module is the same read for the terminal lanes, which is
//! what lets a cold-cache request in a mux float or an SSH pane answer
//! silently instead of asking for a passphrase that is already stored.
//!
//! Read-only on purpose. Writing the entry (first save, or after a passphrase
//! change) stays with pinentry-mac at the console — a smaller surface here,
//! and the ACL story stays simple: this binary asks for read access to one
//! item and nothing else.
//!
//! The externs are self-declared against the Security framework rather than
//! pulled from a crate, honouring Cargo.toml's rule that every dependency is
//! code that could see a passphrase. `SecKeychainFindGenericPassword` is the
//! legacy API and the deliberate choice: it speaks plain C strings, where the
//! modern `SecItemCopyMatching` would drag in CoreFoundation object plumbing —
//! ten times the unsafe surface for the same read.
//!
//! Access control is the load-bearing subtlety, in two halves:
//!
//!   * User interaction is switched OFF before the read. An unsigned or
//!     ungranted binary then fails instantly with `errSecInteractionRequired`
//!     instead of raising a grant dialog on a console nobody is looking at —
//!     and every failure here falls closed into the dialog the caller was
//!     going to draw anyway.
//!   * The grant sticks to the binary's code-signing identity, so the
//!     Makefile signs with the stable per-Mac `pinentry-ui-dev` identity when
//!     one exists. Ad-hoc signatures change every build; without the identity
//!     this module simply never gets an answer, which is the dormant state a
//!     fresh host is supposed to be in.

use crate::secret::Passphrase;
use std::os::raw::{c_char, c_void};

#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecKeychainSetUserInteractionAllowed(state: u8) -> i32;
    fn SecKeychainFindGenericPassword(
        keychain: *const c_void,
        service_len: u32,
        service: *const c_char,
        account_len: u32,
        account: *const c_char,
        pass_len: *mut u32,
        pass: *mut *mut c_void,
        item: *mut *mut c_void,
    ) -> i32;
    fn SecKeychainItemFreeContent(attr_list: *const c_void, data: *mut c_void) -> i32;
}

const SERVICE: &[u8] = b"GnuPG";

/// The stored passphrase for `keygrip`, or `None` for every kind of miss —
/// no entry, keychain locked, access not granted, or a stored value that
/// does not fit the buffer's covenant. Misses are logged with their OSStatus
/// (never the data) because "why did it prompt me" is the question every
/// future debugging session starts with.
pub fn lookup(keygrip: &str) -> Option<Passphrase> {
    // SAFETY: takes a Boolean, returns a status; no memory changes hands.
    unsafe { SecKeychainSetUserInteractionAllowed(0) };

    let mut len: u32 = 0;
    let mut data: *mut c_void = std::ptr::null_mut();
    // SAFETY: service and account point at live buffers with the exact
    // lengths passed; len/data are out-parameters the framework fills on
    // success; the item handle is declined with NULL as documented.
    let status = unsafe {
        SecKeychainFindGenericPassword(
            std::ptr::null(),
            SERVICE.len() as u32,
            SERVICE.as_ptr().cast(),
            keygrip.len() as u32,
            keygrip.as_ptr().cast(),
            &mut len,
            &mut data,
            std::ptr::null_mut(),
        )
    };
    if status != 0 || data.is_null() {
        crate::debug::log(format_args!("keychain: no answer (OSStatus {status})"));
        return None;
    }

    let mut pass = Passphrase::new();
    let mut fits = len > 0;
    for i in 0..len as usize {
        // SAFETY: the framework promises `len` readable bytes at `data`.
        if !pass.push(unsafe { std::ptr::read(data.cast::<u8>().add(i)) }) {
            fits = false;
            break;
        }
    }
    // The framework's buffer holds the passphrase too. Wipe it before
    // handing it back — same volatile discipline as secret.rs, because a
    // plain loop over memory about to be freed is a removable dead store.
    for i in 0..len as usize {
        // SAFETY: same live region as the reads above.
        unsafe { std::ptr::write_volatile(data.cast::<u8>().add(i), 0) };
    }
    // SAFETY: `data` came from the find call above and is freed exactly once.
    unsafe { SecKeychainItemFreeContent(std::ptr::null(), data) };

    if !fits {
        // Empty and oversized alike: neither is a passphrase this program is
        // willing to answer with, and `pass` wipes itself on drop.
        crate::debug::log(format_args!("keychain: entry unusable ({len} bytes)"));
        return None;
    }
    crate::debug::log(format_args!("keychain: served {} chars", pass.chars()));
    Some(pass)
}
