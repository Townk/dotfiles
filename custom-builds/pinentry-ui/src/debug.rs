//! Optional tracing for the decisions nobody can see from outside.
//!
//! This exists because of how the two shipped bugs were found. Both were in the
//! routing — which verb we answered, which pane the ttyname resolved to — and
//! both failed as a *fallback* rather than as an error, so the only symptom was
//! a prompt in the wrong place. Finding each one cost a throwaway logging shim
//! standing in for this binary and a round of temporary `eprintln`s, because
//! there was no way to ask the program what it had decided.
//!
//! stderr would not do. gpg-agent discards a pinentry's stderr unless the agent
//! itself has a `log-file`, and the agent-spawned case is the one that needs
//! tracing — so the variable names a file and we open it ourselves.
//!
//! Three ways in, because each caller keeps a different amount of what it was
//! given: a variable, a token inside `PINENTRY_USER_DATA`, and a marker file
//! for callers that keep neither. See `marker`.
//!
//! **What may be written here is bounded by rule 7: never the passphrase.**
//! Inbound Assuan commands are fair game, because the agent never sends a
//! secret *to* a pinentry — the passphrase only ever travels the other way.
//! Nothing on the outbound side is traced, and neither is the delegation relay,
//! whose buffer carries the child's `D` lines. `the_trace_never_holds_the_
//! passphrase` in the pty suite is the standing check on that.

use std::fmt::Arguments;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::sync::{Mutex, OnceLock};

const VAR: &str = "PINENTRY_UI_DEBUG";

static SINK: OnceLock<Option<Mutex<File>>> = OnceLock::new();

/// The third channel, for a caller that keeps no variables at all.
///
/// Homebrew launders the environment it passes on against an allowlist —
/// `SUDO_ASKPASS` and `HOME` survive, both tmux variables and anything of ours
/// do not — so neither channel below can reach a helper that brew's `sudo -A`
/// invoked. That is not a hypothetical gap: the first attempt to trace exactly
/// that call reported "helper never ran" when it had run perfectly, because the
/// variable naming the log had been stripped on the way in.
///
/// A file cannot be stripped. Its presence is the switch and it is also the
/// log, so there is one path to remember and deleting it turns tracing off.
fn marker() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    std::path::Path::new(&home).join(".cache/pinentry-ui.trace")
}

/// Where to write: the environment, `PINENTRY_USER_DATA`, or the marker file.
///
/// The second channel is not a convenience. gpg-agent hands a pinentry the
/// agent's *own* environment, so `PINENTRY_UI_DEBUG=… gpg -s` never reaches us
/// — tracing a real signature would mean restarting the agent. `gpg` does
/// forward `PINENTRY_USER_DATA` from the calling shell, which is how
/// `USE_CURSES` already gets here, so the same token works per-invocation with
/// nothing restarted.
fn target() -> Option<String> {
    if let Some(v) = std::env::var_os(VAR) {
        let s = v.to_string_lossy().into_owned();
        if !s.is_empty() {
            return Some(s);
        }
    }
    if let Ok(user_data) = std::env::var("PINENTRY_USER_DATA") {
        if let Some(p) = user_data
            .split([',', ' ', ';'])
            .find_map(|t| t.trim().strip_prefix(&format!("{VAR}=")))
            .filter(|p| !p.is_empty())
        {
            return Some(p.to_string());
        }
    }
    let marker = marker();
    marker
        .exists()
        .then(|| marker.to_string_lossy().into_owned())
}

fn sink() -> Option<&'static Mutex<File>> {
    SINK.get_or_init(|| {
        let path = target()?;
        // 0600: pane titles and session names are not secrets, but they are
        // nobody else's business either. Appended, so a sequence of prompts
        // reads as one story.
        OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(path)
            .ok()
            .map(Mutex::new)
    })
    .as_ref()
}

pub fn on() -> bool {
    sink().is_some()
}

/// Take `format_args!(…)`, so a disabled trace costs no allocation.
///
/// Every failure is swallowed: a debug setting must never be able to fail a
/// signature.
pub fn log(args: Arguments) {
    let Some(file) = sink() else { return };
    let Ok(mut file) = file.lock() else { return };
    let _ = writeln!(file, "[{}] {args}", std::process::id());
    let _ = file.flush();
}
