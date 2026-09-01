//! From a `Session` to an answer: decide where the dialog goes, draw it, read.
//!
//! This is the join between the two halves — the protocol, which is
//! machine-checkable, and the dialog, which is not — and it is deliberately
//! thin. Everything it decides is a routing question:
//!
//!   * whose pane asked, and is anybody looking at it
//!   * float or in place
//!   * how big, which only this program can answer because only this program
//!     lays the dialog out
//!
//! Every failure lands on the caller's own terminal rather than nowhere. A
//! prompt in an awkward place still lets you sign; a prompt that never appears
//! does not.

use std::time::Duration;

use crate::assuan::{self, Answer, Session};
use crate::dialog::{Dialog, Outcome, Requester, FLOAT_PTY_WIDTH, FLOAT_WIDTH, MIN_WIDTH};
use crate::float;
use crate::icons;
use crate::keyinfo;
use crate::requester;
use crate::term::Tty;
use crate::theme::Theme;

pub struct Ui;

impl assuan::Prompt for Ui {
    fn ask(&mut self, s: &Session) -> Answer {
        let theme = Theme::load();
        let caller = s.ttyname.as_deref().unwrap_or("/dev/tty");
        let who = requester::resolve(requester::By::Tty(caller));

        let described = keyinfo::parse(s.desc.as_deref().unwrap_or_default());
        let requester_line = who.as_ref().map(|r| Requester {
            glyph: icons::glyph_for(&r.name),
            label: r.label(),
            elsewhere: r.elsewhere,
        });

        let mut dialog = Dialog {
            title: Some(title_from(s)),
            description: described.intro,
            key: described.key,
            requester: requester_line,
            error: s.error.clone(),
            width: FLOAT_PTY_WIDTH,
            frame: false,
            timeout: s.timeout.map(Duration::from_secs),
        };

        // An agent's pane is the case this program exists for: a tty nobody is
        // watching. Anyone else gets the prompt where they are already looking.
        let float = if who.as_ref().is_some_and(|r| r.is_agent) {
            let (w, h) = dialog.size();
            let name = who.as_ref().map(|r| r.name.as_str()).unwrap_or_default();
            let f = float::open(caller, w + 2, h + 2, name);
            crate::debug::log(format_args!(
                "float {}x{} for {name} -> {:?}",
                w + 2,
                h + 2,
                f.as_ref().map(|f| &f.tty)
            ));
            f
        } else {
            crate::debug::log(format_args!("no float: nobody agent-ish behind {caller}"));
            None
        };

        let target = match &float {
            Some(f) => f.tty.clone(),
            None => {
                // In place, the dialog draws its own border and has to fit the
                // terminal it is standing on.
                dialog.frame = true;
                caller.to_string()
            }
        };

        crate::debug::log(format_args!("drawing on {target}"));
        // A terminal that will not open is the GUI case, not an error: a commit
        // from an editor's source-control panel has no GPG_TTY and no pane
        // behind it, so `ttyname` is missing or names something dead. Saying
        // "no" there would fail a signature that a GUI pinentry can complete.
        let mut tty = match Tty::open(Some(&target)) {
            Ok(t) => t,
            Err(e) => {
                crate::debug::log(format_args!("cannot open {target}: {e}"));
                drop(float);
                return Answer::NoTerminal;
            }
        };
        if float.is_none() {
            dialog.width = FLOAT_WIDTH.min(tty.size().0).max(MIN_WIDTH);
        }
        // Opening succeeded but it is not a terminal — `/dev/null`, a pipe, a
        // character device that has no termios. Same conclusion as above, one
        // syscall later.
        if let Err(e) = tty.enter() {
            crate::debug::log(format_args!("{target} is not a terminal: {e}"));
            drop(tty);
            drop(float);
            return Answer::NoTerminal;
        }

        let outcome = dialog.run(&mut tty, &theme);
        // Order matters on the way out: hand the terminal back, THEN close the
        // float. Dropping the float first would take the pty out from under a
        // restore that is still writing to it.
        drop(tty);
        drop(float);

        match outcome {
            Ok(Outcome::Accepted(pass)) => Answer::Pin(pass),
            Ok(Outcome::Cancelled) => Answer::Cancelled,
            Ok(Outcome::TimedOut) => Answer::Failed(assuan::ERR_TIMEOUT.to_string()),
            Err(e) => Answer::Failed(assuan::err_no_dialog(&e.to_string())),
        }
    }

    // The macOS keychain, behind the gates `serve` enforces (agent
    // permission, keygrip, no pending error, once per connection). Off macOS
    // the trait's default None keeps every request on the dialog path — there
    // is no store to read.
    #[cfg(target_os = "macos")]
    fn stored(&mut self, keygrip: &str) -> Option<crate::secret::Passphrase> {
        crate::keychain::lookup(keygrip)
    }
}

/// gpg's `SETPROMPT` is the title, because it is the one element that is
/// identical on every prompt — which is what makes the dialog recognisable —
/// and it already distinguishes a passphrase from a PIN from a confirmation.
/// It arrives with a trailing colon that the dialog's own layout supplies.
fn title_from(s: &Session) -> String {
    let raw = s
        .prompt
        .as_deref()
        .or(s.title.as_deref())
        .unwrap_or("Passphrase");
    let t = raw.trim().trim_end_matches(':').trim();
    if t.is_empty() {
        "Passphrase".to_string()
    } else {
        t.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(prompt: Option<&str>, title: Option<&str>) -> Session {
        Session {
            prompt: prompt.map(str::to_string),
            title: title.map(str::to_string),
            ..Default::default()
        }
    }

    #[test]
    fn the_prompt_becomes_the_title_without_its_colon() {
        assert_eq!(
            title_from(&session(Some("Passphrase:"), None)),
            "Passphrase"
        );
        assert_eq!(title_from(&session(Some("PIN"), None)), "PIN");
    }

    #[test]
    fn the_title_is_the_fallback_and_then_a_default() {
        assert_eq!(title_from(&session(None, Some("Unlock"))), "Unlock");
        assert_eq!(title_from(&session(None, None)), "Passphrase");
        assert_eq!(title_from(&session(Some("  :  "), None)), "Passphrase");
    }
}
