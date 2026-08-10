//! Process-wide protections applied before anything is read.
//!
//! These are the rules from `docs/pinentry-ui-design.md` that are properties of
//! the process rather than of the buffer: keep the secret out of crash
//! artefacts, and keep it out of any message we print on the way down.

/// Call once, first thing in `main`, before a tty is opened or a key is read.
pub fn apply() {
    no_core_dumps();
    #[cfg(target_os = "linux")]
    linux_only();
    silence_panics();
}

/// Rule 5. A core dump of this process is a file containing the passphrase.
fn no_core_dumps() {
    let limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: a well-formed rlimit for a valid resource; the call only lowers
    // our own limit and cannot fail in a way that matters here.
    unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) };
}

/// The Linux half of rule 5, which has no macOS equivalent.
///
/// `PR_SET_DUMPABLE(0)` does double duty: it suppresses the core dump that
/// `systemd-coredump` would otherwise persist to disk, and it denies
/// `ptrace` from other processes running as the same user — the one exposure
/// where Linux is weaker than macOS, and the reason this program can be
/// stricter than the `pinentry-curses` it replaces.
#[cfg(target_os = "linux")]
fn linux_only() {
    // SAFETY: prctl with a valid option and no pointer arguments.
    unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
}

/// Rule 8. A panic prints a message and, with `RUST_BACKTRACE`, a good deal
/// more — into gpg-agent's log, since that is where our stderr goes. No secret
/// is ever formatted into a panic message today, but this makes that true by
/// construction rather than by inspection.
fn silence_panics() {
    std::panic::set_hook(Box::new(|_| {
        eprintln!("pinentry-ui: internal error");
    }));
}
