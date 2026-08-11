//! Handing the conversation to another pinentry, in step.
//!
//! Two things trigger this, and they want opposite binaries. A verb we do not
//! implement goes to `pinentry-curses`: we cover fourteen, and the other
//! fifteen belong to passphrase changes, key generation and confirmation
//! dialogs, where writing a second-rate version of each would be a lot of code
//! guarding a path already solved by the binary on disk. A `GETPIN` with no
//! terminal to draw on goes to `pinentry-mac` instead — that is a GUI app
//! signing with no `GPG_TTY`, and the answer is a pinentry that never wanted a
//! terminal, not a better error message.
//!
//! Two things make this safe here and made it impossible in the shell filter
//! this program replaces. We have answered **nothing** for the triggering
//! command, so the stream is still in step. And we own the response direction,
//! so the `OK`s produced by replaying the state we have already been told are
//! ours to swallow rather than surplus lines the agent would misread as the
//! answer to its next command.
//!
//! This is also the general safety net: any failure anywhere ends here, at the
//! prompt that works today.

use std::io::{BufRead, BufReader, StdinLock, StdoutLock, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::process::{Command, Stdio};

use zeroize::Zeroize;

use crate::assuan::Handover;

/// The stock pinentry, overridable for tests exactly as the retired filter had
/// it.
pub fn curses_bin() -> String {
    if let Ok(b) = std::env::var("PINENTRY_CURSES_BIN") {
        return b;
    }
    // Every rung above this one can decline; this one cannot, so it is worth a
    // search rather than one guess. `/usr/bin/pinentry` last because on Linux it
    // is usually an alternatives symlink that already points at the curses build.
    for c in [
        "/opt/homebrew/bin/pinentry-curses",
        "/usr/local/bin/pinentry-curses",
        "/usr/bin/pinentry-curses",
        "/usr/bin/pinentry",
    ] {
        if std::fs::metadata(c).is_ok() {
            return c.to_string();
        }
    }
    "/opt/homebrew/bin/pinentry-curses".to_string()
}

/// The pinentry for a request with no terminal at all, or empty where there is
/// no such thing.
///
/// Empty off macOS, and deliberately rather than by omission: the Linux hosts
/// this runs on are headless, so there is no desktop for a GUI dialog to appear
/// on, and choosing between GTK and Qt for a machine that has neither would be
/// guessing at a rung nobody could see. A tty-less prompt there fails as it
/// always has. Empty rather than a plausible path so the failure says that,
/// instead of naming a Homebrew binary on a machine that has no Homebrew.
pub fn gui_bin() -> String {
    if let Ok(b) = std::env::var("PINENTRY_GUI_BIN") {
        return b;
    }
    if cfg!(target_os = "macos") {
        return "/opt/homebrew/bin/pinentry-mac".to_string();
    }
    String::new()
}

/// Whether a buffered line should be told to the pinentry taking over.
///
/// Everything is, with one exception, and it is the exception the live check
/// found: handing `ttyname` to the GUI hands it the reason we gave up. We only
/// go to `pinentry-mac` because that terminal would not open, and pinentry-mac
/// opens the ttyname it is given before deciding anything — so it fails on the
/// same stone we did, with `mac.open_tty_for_read`, and the caller gets an
/// error instead of the dialog that was sitting one line away. `ttytype`
/// describes the same absent terminal and goes with it.
///
/// The curses lane keeps both: it was handed a working terminal and needs to
/// know which one.
fn worth_replaying(to: Handover, cmd: &str) -> bool {
    if to == Handover::Curses {
        return true;
    }
    let Some(rest) = cmd.strip_prefix("OPTION ") else {
        return true;
    };
    let key = rest.trim_start_matches('-');
    let key = key
        .split(|c: char| c == '=' || c.is_whitespace())
        .next()
        .unwrap_or("");
    !key.eq_ignore_ascii_case("ttyname") && !key.eq_ignore_ascii_case("ttytype")
}

/// `PINENTRY_USER_DATA` as the GUI should see it: without `USE_CURSES`.
///
/// pinentry-mac reads that token and re-execs a curses pinentry — it is how the
/// GPGTools build lets a terminal client opt out of the GUI, and it is how this
/// program gets chosen in the first place. Passing it down sends the request
/// straight back to a terminal, which is the one thing we have just established
/// does not exist. It does not fail loudly either: pinentry-mac gets as far as
/// the terminal checks and reports `mac.open_tty_for_read`, or `mac.isatty`
/// once the ttyname is gone. Both look like a broken handover rather than a
/// token we forgot to drop.
///
/// Returns `None` when nothing is left, so the variable is unset rather than
/// passed down empty. Other tokens — `PINENTRY_UI_DEBUG` among them — survive.
fn user_data_for_gui(raw: Option<&str>) -> Option<String> {
    let kept: Vec<&str> = raw?
        .split([',', ' ', ';'])
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .filter(|t| {
            !t.split('=')
                .next()
                .unwrap_or_default()
                .eq_ignore_ascii_case("USE_CURSES")
        })
        .collect();
    (!kept.is_empty()).then(|| kept.join(" "))
}

/// Replay `replay` into a fresh pinentry, send `trigger`, then relay both
/// directions until the conversation ends. Returns its exit code.
pub fn hand_over(
    to: Handover,
    replay: &[String],
    trigger: &str,
    ours_in: &mut BufReader<StdinLock<'static>>,
    ours_out: &mut StdoutLock<'static>,
    args: &[String],
) -> std::io::Result<u8> {
    let bin = match to {
        Handover::Curses => curses_bin(),
        Handover::Gui => gui_bin(),
    };
    if bin.is_empty() {
        crate::debug::log(format_args!(
            "nothing to hand {trigger} to on this platform"
        ));
        return Err(std::io::Error::other("no GUI pinentry on this platform"));
    }
    crate::debug::log(format_args!("handing {trigger} to {bin}"));
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if to == Handover::Gui {
        match user_data_for_gui(std::env::var("PINENTRY_USER_DATA").ok().as_deref()) {
            Some(v) => cmd.env("PINENTRY_USER_DATA", v),
            None => cmd.env_remove("PINENTRY_USER_DATA"),
        };
    }
    let mut child = cmd.spawn()?;

    let mut child_in = child.stdin.take().expect("piped");
    let mut child_out = BufReader::new(child.stdout.take().expect("piped"));

    // Its greeting answers nothing the agent asked; the agent already has ours.
    // Swallowing it is the first half of staying in step.
    let mut line = String::new();
    child_out.read_line(&mut line)?;

    // Everything we were told, told again — otherwise it draws a dialog with no
    // text in it. One OK comes back per line, and every one of them is ours.
    for cmd in replay.iter().filter(|c| worth_replaying(to, c)) {
        writeln!(child_in, "{cmd}")?;
        child_in.flush()?;
        line.clear();
        child_out.read_line(&mut line)?;
    }

    // From here the child answers the agent, starting with the command we
    // refused: the first of its responses the agent is entitled to see.
    writeln!(child_in, "{trigger}")?;
    child_in.flush()?;

    // Anything the reader pulled in past the trigger line belongs to the child.
    // Reading by line means a fast agent's next command may already be sitting
    // in our buffer, and dropping down to raw descriptors without draining it
    // first would silently eat it.
    let pending = ours_in.buffer().to_vec();
    if !pending.is_empty() {
        child_in.write_all(&pending)?;
        child_in.flush()?;
        ours_in.consume(pending.len());
    }

    relay(
        ours_in.get_ref().as_raw_fd(),
        ours_out.as_raw_fd(),
        child_in.as_raw_fd(),
        child_out.get_ref().as_raw_fd(),
    )?;
    drop(child_in);

    let status = child.wait()?;
    Ok(status.code().unwrap_or(0) as u8)
}

/// Pump both directions until the child is done.
///
/// `select` over raw descriptors rather than a thread per direction: the
/// standard streams are not `Send`, and a single loop is easier to reason about
/// than two halves racing to decide the conversation is over.
///
/// The child's answers may include a passphrase, so this is the one place in
/// the program where a secret crosses memory we did not lock. It cannot be
/// avoided — a child cannot be handed our stdout after the fact, and handing it
/// ours from the start is exactly what would let the replay `OK`s reach the
/// agent — so the buffer is small, reused, and wiped after every write instead
/// of being left holding the last thing that passed through it.
fn relay(
    ours_in: RawFd,
    ours_out: RawFd,
    child_in: RawFd,
    child_out: RawFd,
) -> std::io::Result<()> {
    let mut buf = [0u8; 4096];
    let mut upstream_open = true;
    loop {
        let mut set: libc::fd_set = unsafe { std::mem::zeroed() };
        let mut max = child_out;
        // SAFETY: a zeroed fd_set is empty and both fds are well below
        // FD_SETSIZE.
        unsafe {
            libc::FD_SET(child_out, &mut set);
            if upstream_open {
                libc::FD_SET(ours_in, &mut set);
                max = max.max(ours_in);
            }
        }
        // SAFETY: set is initialised above; a null timeout blocks until ready.
        let n = unsafe {
            libc::select(
                max + 1,
                &mut set,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if n < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Ok(());
        }

        // SAFETY: set was filled by select.
        if unsafe { libc::FD_ISSET(child_out, &set) } {
            let got = unsafe { libc::read(child_out, buf.as_mut_ptr().cast(), buf.len()) };
            if got <= 0 {
                return Ok(()); // the child is finished; so are we
            }
            let got = got as usize;
            write_all(ours_out, &buf[..got]);
            buf[..got].zeroize();
        }

        // SAFETY: as above.
        if upstream_open && unsafe { libc::FD_ISSET(ours_in, &set) } {
            let got = unsafe { libc::read(ours_in, buf.as_mut_ptr().cast(), buf.len()) };
            if got <= 0 {
                // The agent hung up. The child may still have an answer in
                // flight, so keep draining it rather than tearing down here.
                upstream_open = false;
            } else {
                write_all(child_in, &buf[..got as usize]);
            }
        }
    }
}

fn write_all(fd: RawFd, mut bytes: &[u8]) {
    while !bytes.is_empty() {
        // SAFETY: writing a live subslice to a descriptor we own.
        let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if n <= 0 {
            return;
        }
        bytes = &bytes[n as usize..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gui_is_not_told_about_the_terminal_that_would_not_open() {
        for cmd in [
            "OPTION ttyname=/dev/does-not-exist",
            "OPTION ttytype=xterm-256color",
            "OPTION --ttyname=/dev/ttys003",
            "OPTION TTYNAME=/dev/ttys003",
        ] {
            assert!(!worth_replaying(Handover::Gui, cmd), "{cmd}");
        }
    }

    #[test]
    fn everything_else_still_reaches_the_gui() {
        // Dropping more than the terminal would cost the dialog its text, which
        // is the failure the replay exists to prevent in the first place.
        for cmd in [
            "SETDESC Enter%20the%20passphrase",
            "SETPROMPT PIN",
            "SETKEYINFO n/ABCD",
            "OPTION lc-ctype=en_US.UTF-8",
            "OPTION allow-external-password-cache",
            "SETTIMEOUT 30",
        ] {
            assert!(worth_replaying(Handover::Gui, cmd), "{cmd}");
        }
    }

    #[test]
    fn the_gui_is_not_told_to_go_back_to_a_terminal() {
        assert_eq!(user_data_for_gui(Some("USE_CURSES=1")), None);
        assert_eq!(
            user_data_for_gui(Some("USE_CURSES=1,PINENTRY_UI_DEBUG=/tmp/t.log")),
            Some("PINENTRY_UI_DEBUG=/tmp/t.log".to_string()),
            "the other tokens are none of our business"
        );
        assert_eq!(user_data_for_gui(None), None);
    }

    #[test]
    fn the_curses_lane_keeps_the_terminal_it_was_given() {
        assert!(worth_replaying(
            Handover::Curses,
            "OPTION ttyname=/dev/ttys003"
        ));
    }
}
