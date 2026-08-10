//! The tmux float: opening one, and making sure it closes.
//!
//! None of the hard parts are here. `pinentry-mux-popup --open` already
//! resolves the tty to a session, picks the most recently active client of
//! that session, refuses a client too small, opens a non-dismissable popup and
//! fires the OSD alert. That logic was measured into shape over several
//! sessions and is not about Assuan, so it survives the rewrite untouched.
//!
//! What changes is who decides the size. The shell filter had to guess, because
//! the dimensions follow from `SETDESC` and that arrives 23 commands after the
//! `OPTION ttyname=` the float has to be opened from — and a tmux popup cannot
//! be resized after creation. This program lays the dialog out itself, so it
//! knows the exact size before it asks for a canvas, and passes it in.
//!
//! The other change is lifetime. The filter needed a watcher subshell polling a
//! child, because its stdin could stay open long after the dialog had gone —
//! and when that went wrong the float stayed on screen swallowing every
//! keystroke, which is a worse failure than the one it was built to fix. Here
//! one process owns both, so closing is a `Drop`.

use std::process::Command;
use std::sync::atomic::{AtomicI32, Ordering};

/// The holder's pid, where the signal handler can reach it.
///
/// `Drop` covers every exit that unwinds; this covers the ones that do not. A
/// pinentry killed by its agent must still take the float with it, or the human
/// is left with a pane that swallows every keystroke and answers to nothing.
static HOLDER: AtomicI32 = AtomicI32::new(-1);

pub fn holder_pid() -> i32 {
    HOLDER.load(Ordering::SeqCst)
}

pub struct Float {
    /// The float's own pty — where the dialog is drawn.
    pub tty: String,
    holder: i32,
}

/// Open a float for `caller_tty` sized `w`x`h`, or None to prompt in place.
///
/// Every failure returns None. A float that will not open must never fail the
/// signature: the prompt lands in the calling pane instead, which is exactly
/// what happened before any of this existed.
pub fn open(caller_tty: &str, w: u16, h: u16, requester: &str) -> Option<Float> {
    let home = std::env::var_os("HOME")?;
    let popup = std::path::Path::new(&home).join(".local/libexec/pinentry-mux-popup");

    // Armed before the float exists rather than after. The window between
    // opening a float and putting the terminal in raw mode is small, but a
    // signal landing in it would leave the float with no owner and no handler
    // to close it.
    crate::term::install_signal_handlers();

    let out = Command::new(popup)
        .arg("--open")
        .arg(caller_tty)
        .arg(w.to_string())
        .arg(h.to_string())
        .arg(requester)
        // Nothing downstream may share our stdin: it is gpg-agent's half of the
        // Assuan conversation, and a helper that reads one line of it swallows
        // part of the protocol.
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }

    // "<popup_tty> <holder_pid>"
    let line = String::from_utf8_lossy(&out.stdout);
    let (tty, pid) = line.trim().split_once(' ')?;
    if !tty.starts_with("/dev/") {
        return None;
    }
    let holder: i32 = pid.trim().parse().ok()?;
    HOLDER.store(holder, Ordering::SeqCst);
    Some(Float {
        tty: tty.to_string(),
        holder,
    })
}

impl Float {
    /// USR1, not TERM. The holder deliberately ignores every signal a stray
    /// keystroke can produce — that is what makes the float non-dismissable
    /// while a passphrase is half-typed — so this is the one channel that
    /// reliably closes it.
    fn close(&self) {
        if self.holder > 0 {
            // SAFETY: kill with a pid we were handed by the opener; a dead pid
            // is an ESRCH we do not care about.
            unsafe { libc::kill(self.holder, libc::SIGUSR1) };
        }
        HOLDER.store(-1, Ordering::SeqCst);
    }
}

impl Drop for Float {
    fn drop(&mut self) {
        self.close();
    }
}
