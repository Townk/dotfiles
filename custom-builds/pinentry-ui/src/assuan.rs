//! The Assuan half: what gpg-agent says to us, and what we say back.
//!
//! Every response in here was measured against `pinentry-curses` 1.3.3 rather
//! than recalled, by driving it with pipes and a pty. The greeting wording, the
//! `D`-then-`OK` shape of a data reply, the percent-encoding of the payload and
//! the two error numbers are all copied from what that binary actually emits,
//! because gpg-agent is entitled to expect a pinentry to behave like one.
//!
//! The rule that governs this file: **one response per command, and never one
//! more.** A surplus `OK` is read by the agent as the answer to the next
//! command, and when that next command is `GETPIN` the answer is an empty
//! result — "No passphrase given" — while a perfectly good dialog sits on
//! screen. That is not hypothetical; it is the bug that killed the shell filter
//! this program replaces, and the reason the filter could never be fixed in
//! place. Here we own both directions, so the invariant is ours to keep.

use std::io::{BufRead, Write};

use crate::secret::Passphrase;

/// `(GPG_ERR_SOURCE_PINENTRY, GPG_ERR_CANCELED)`, confirmed with `gpg-error`.
/// This is what tells gpg-agent the human said no, as opposed to anything
/// having gone wrong.
const ERR_CANCELED: &str = "ERR 83886179 Operation cancelled <Pinentry>";
/// `(GPG_ERR_SOURCE_USER_1, GPG_ERR_ASS_UNKNOWN_CMD)` — the exact line
/// pinentry-curses returns for a verb it does not know.
const ERR_UNKNOWN: &str = "ERR 536871187 Unknown IPC command <User defined source 1>";
/// `(GPG_ERR_SOURCE_PINENTRY, GPG_ERR_TIMEOUT)`, confirmed with `gpg-error`.
/// Nobody came back to the prompt within `SETTIMEOUT`.
pub const ERR_TIMEOUT: &str = "ERR 83886142 Timeout <Pinentry>";

/// What the agent has told us so far. Everything here arrives before `GETPIN`
/// and describes the dialog we are then asked to draw.
#[derive(Default)]
pub struct Session {
    pub desc: Option<String>,
    pub prompt: Option<String>,
    pub title: Option<String>,
    pub error: Option<String>,
    pub ok: Option<String>,
    pub cancel: Option<String>,
    pub ttyname: Option<String>,
    pub ttytype: Option<String>,
    /// The keygrip from `SETKEYINFO n/<grip>` — the name under which an
    /// external password store files this key's passphrase (the macOS
    /// keychain entry pinentry-mac writes: service "GnuPG", account = grip).
    pub keyinfo: Option<String>,
    /// gpg-agent's `OPTION allow-external-password-cache`. Its absence is the
    /// agent's policy against answering from a store, not an omission.
    pub external_cache: bool,
    /// Seconds the dialog may sit unanswered, from `SETTIMEOUT`. This carries
    /// `pinentry-timeout` out of gpg-agent's config, and honouring it is what
    /// lets an unanswered prompt fail and release the agent's global entry lock
    /// instead of holding it until the machine is rebooted.
    pub timeout: Option<u64>,
    /// Every state-setting line exactly as received, in order. Only used when
    /// we hand the conversation to `pinentry-curses`: it has to be told
    /// everything we were told, or it would draw a dialog with no text in it.
    pub replay: Vec<String>,
}

/// What a `GETPIN` produced.
pub enum Answer {
    Pin(Passphrase),
    Cancelled,
    /// The dialog could not be shown at all. Carries the Assuan error line to
    /// send, so the caller decides how a failure is described rather than this
    /// module guessing.
    Failed(String),
    /// There is no terminal to draw on — a GUI app asked, with no `GPG_TTY` and
    /// no pane behind it. Not a failure: it is a request for a pinentry that
    /// does not want a terminal in the first place. Nothing has been answered,
    /// so the conversation can still be handed over whole.
    NoTerminal,
}

/// Which pinentry a handover goes to. Not a preference — the two cases want
/// opposite things. A verb we do not implement needs a full-featured *terminal*
/// pinentry; a prompt with nowhere to draw needs one that never wanted a
/// terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Handover {
    Curses,
    Gui,
}

/// Whoever can turn a `Session` into an answer. A trait rather than a direct
/// call so the protocol can be tested end to end without a terminal, which is
/// the whole reason the Assuan half is the machine-checkable one.
pub trait Prompt {
    fn ask(&mut self, session: &Session) -> Answer;

    /// A passphrase the key's owner already stored somewhere this pinentry
    /// can read — the macOS keychain, in practice. Consulted before any
    /// dialog, only under the gates `serve` enforces. The default is the
    /// non-macOS answer and the test default alike: there is no store.
    fn stored(&mut self, _keygrip: &str) -> Option<Passphrase> {
        None
    }
}

/// What `serve` decided to do with the conversation.
pub enum Served {
    /// Ran to completion. Carries the process exit code.
    Done(u8),
    /// Hit something we cannot serve — a verb we refuse to implement, or a
    /// `GETPIN` with no terminal to draw on. The conversation is untouched and
    /// nothing has been answered, so the caller can hand the whole thing to
    /// another pinentry — which needs both the command that triggered this and
    /// everything we were told before it.
    Delegate {
        to: Handover,
        trigger: String,
        replay: Vec<String>,
    },
}

pub fn serve<R: BufRead, W: Write, P: Prompt>(
    input: &mut R,
    out: &mut W,
    prompt: &mut P,
) -> std::io::Result<Served> {
    let mut s = Session::default();
    let mut store_answered = false;
    writeln!(
        out,
        "OK Pleased to meet you, process {}",
        std::process::id()
    )?;
    out.flush()?;

    let mut line = String::new();
    loop {
        line.clear();
        if input.read_line(&mut line)? == 0 {
            return Ok(Served::Done(0));
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            continue;
        }
        // Inbound only, and that is a rule rather than an omission: the agent
        // never sends a passphrase to a pinentry, so nothing arriving here can
        // be a secret. Tracing this would have made the SETKEYINFO handover
        // obvious in one run.
        crate::debug::log(format_args!("<- {line}"));

        let (verb, rest) = match line.split_once(' ') {
            Some((v, r)) => (v, r),
            None => (line, ""),
        };

        match verb.to_ascii_uppercase().as_str() {
            "SETDESC" => set(&mut s.desc, rest, line, &mut s.replay),
            "SETPROMPT" => set(&mut s.prompt, rest, line, &mut s.replay),
            "SETTITLE" => set(&mut s.title, rest, line, &mut s.replay),
            "SETERROR" => set(&mut s.error, rest, line, &mut s.replay),
            "SETOK" => set(&mut s.ok, rest, line, &mut s.replay),
            "SETCANCEL" => set(&mut s.cancel, rest, line, &mut s.replay),
            "OPTION" => {
                match rest.split_once('=') {
                    Some(("ttyname", v)) => s.ttyname = Some(decode(v)),
                    Some(("ttytype", v)) => s.ttytype = Some(decode(v)),
                    None if rest.trim() == "allow-external-password-cache" => {
                        s.external_cache = true
                    }
                    _ => {}
                }
                s.replay.push(line.to_string());
            }
            // The keygrip, offered so a pinentry can find the passphrase in an
            // external password manager — which, since the keychain
            // integration, we are. Only the `n/` (normal key) form names a
            // cacheable entry; `--clear` and the smartcard forms leave the
            // grip empty, and with it the store unconsulted. It must be
            // *accepted* regardless: gpg-agent sends it before every single
            // GETPIN, and leaving it to the catch-all below once handed every
            // real signature straight to pinentry-curses, on the unwatched
            // tty this program exists to avoid.
            "SETKEYINFO" => {
                s.keyinfo = rest
                    .trim()
                    .strip_prefix("n/")
                    .filter(|g| !g.is_empty())
                    .map(str::to_string);
                s.replay.push(line.to_string());
            }
            "SETTIMEOUT" => {
                // 0 is pinentry's "wait forever".
                s.timeout = rest.trim().parse::<u64>().ok().filter(|n| *n > 0);
                s.replay.push(line.to_string());
            }
            "NOP" => {}
            "RESET" => {
                // Everything the dialog draws goes; the terminal does not, and
                // neither does the deadline — both belong to the connection
                // rather than to one prompt's text. gpg-agent sends RESET
                // between prompts on one connection and does NOT repeat the
                // ttyname, so dropping it here would send the retry to whatever
                // tty we happened to inherit.
                s.desc = None;
                s.prompt = None;
                s.title = None;
                s.error = None;
                s.ok = None;
                s.cancel = None;
                // The keygrip goes with the text: gpg-agent re-sends
                // SETKEYINFO per prompt, and a grip leaking across RESET
                // could answer a prompt for a different key from the wrong
                // keychain entry. `external_cache` stays — it is an OPTION,
                // scoped to the connection like the terminal is.
                s.keyinfo = None;
                s.replay
                    .retain(|l| l.starts_with("OPTION ") || l.starts_with("SETTIMEOUT"));
            }
            "GETINFO" => {
                match rest {
                    "pid" => writeln!(out, "D {}", std::process::id())?,
                    "version" => writeln!(out, "D {}", env!("CARGO_PKG_VERSION"))?,
                    "flavor" => writeln!(out, "D curses")?,
                    // Same shape as the stock answer; the agent logs it and
                    // does not parse it.
                    "ttyinfo" => writeln!(
                        out,
                        "D {} {} - - {}/{} 0",
                        s.ttyname.as_deref().unwrap_or("-"),
                        s.ttytype.as_deref().unwrap_or("-"),
                        // SAFETY: getuid and getgid cannot fail.
                        unsafe { libc::getuid() },
                        unsafe { libc::getgid() },
                    )?,
                    _ => {}
                }
                writeln!(out, "OK")?;
                out.flush()?;
                continue;
            }
            "GETPIN" => {
                // The store is consulted before any dialog, under four gates:
                // the agent allowed it, a keygrip names the entry, no
                // SETERROR is pending (a stored passphrase the agent just
                // rejected must not be served again), and at most once per
                // connection — a retry without an intervening SETERROR should
                // not happen, and if it does, looping the store's answer
                // would be worse than drawing the dialog.
                let stored = match &s.keyinfo {
                    Some(grip) if s.external_cache && s.error.is_none() && !store_answered => {
                        store_answered = true;
                        prompt.stored(grip)
                    }
                    _ => None,
                };
                let answer = match stored {
                    Some(pass) => {
                        crate::debug::log(format_args!("answered from the external store"));
                        Answer::Pin(pass)
                    }
                    None => prompt.ask(&s),
                };
                match answer {
                    // The kind of answer, never the answer.
                    Answer::Pin(pass) => {
                        crate::debug::log(format_args!(
                            "-> a passphrase of {} chars",
                            pass.chars()
                        ));
                        pass.write_assuan_data(out)?;
                        writeln!(out, "OK")?;
                    }
                    Answer::Cancelled => {
                        crate::debug::log(format_args!("-> cancelled"));
                        writeln!(out, "{ERR_CANCELED}")?
                    }
                    Answer::Failed(err) => {
                        crate::debug::log(format_args!("-> failed: {err}"));
                        writeln!(out, "{err}")?
                    }
                    // Answered nothing, so the stream is still in step and the
                    // whole conversation can go to a pinentry with no terminal
                    // to lose.
                    Answer::NoTerminal => {
                        crate::debug::log(format_args!("nowhere to draw: handing to the GUI"));
                        return Ok(Served::Delegate {
                            to: Handover::Gui,
                            trigger: line.to_string(),
                            replay: s.replay,
                        });
                    }
                }
                out.flush()?;
                // An error line is a complete answer, so the agent may well ask
                // again on the same connection. Only the one-shot text is
                // dropped; a stale SETERROR on a second prompt would tell the
                // human their correct passphrase had just been rejected.
                s.error = None;
                s.replay.retain(|l| !l.starts_with("SETERROR"));
                continue;
            }
            "BYE" => {
                writeln!(out, "OK closing connection")?;
                out.flush()?;
                return Ok(Served::Done(0));
            }
            // Everything else — CONFIRM, MESSAGE, SETREPEAT, SETQUALITYBAR and
            // the rest of the 29 verbs. We have answered nothing yet for this
            // command, so the conversation is still in step and can be handed
            // over whole.
            _ => {
                crate::debug::log(format_args!("delegating: {verb} is not ours"));
                return Ok(Served::Delegate {
                    to: Handover::Curses,
                    trigger: line.to_string(),
                    replay: s.replay,
                });
            }
        }
        writeln!(out, "OK")?;
        out.flush()?;
    }
}

fn set(field: &mut Option<String>, rest: &str, line: &str, replay: &mut Vec<String>) {
    *field = Some(decode(rest));
    replay.push(line.to_string());
}

/// Assuan percent-decoding. gpg sends `%0A` for the newlines in a description
/// and `%25` for a literal per cent, so a dialog that skipped this would draw
/// the escapes and lose the line breaks the key block is built from.
pub fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(v) = hex(b[i + 1]).zip(hex(b[i + 2])).map(|(h, l)| h * 16 + l) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// The line for a dialog that could not be drawn. Not a cancel: the human never
/// saw anything, and telling the agent they declined would be a lie that costs
/// them a retry.
pub fn err_no_dialog(detail: &str) -> String {
    // (GPG_ERR_SOURCE_PINENTRY, GPG_ERR_ENOENT) — the same code the stock
    // pinentry returns when it cannot open the terminal it was pointed at.
    format!("ERR 83918929 {detail} <Pinentry>")
}

pub const UNKNOWN_COMMAND: &str = ERR_UNKNOWN;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    struct Canned(Vec<Answer>);
    impl Prompt for Canned {
        fn ask(&mut self, _s: &Session) -> Answer {
            if self.0.is_empty() {
                Answer::Cancelled
            } else {
                self.0.remove(0)
            }
        }
    }

    struct Capture(Vec<String>);
    impl Prompt for Capture {
        fn ask(&mut self, s: &Session) -> Answer {
            self.0.push(format!(
                "desc={:?} prompt={:?} error={:?} tty={:?}",
                s.desc, s.prompt, s.error, s.ttyname
            ));
            Answer::Cancelled
        }
    }

    fn converse(script: &str, prompt: &mut impl Prompt) -> (Vec<String>, bool) {
        let mut input = Cursor::new(script.to_string().into_bytes());
        let mut out: Vec<u8> = Vec::new();
        let served = serve(&mut input, &mut out, prompt).expect("serve");
        let lines = String::from_utf8(out)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        (lines, matches!(served, Served::Delegate { .. }))
    }

    /// The invariant the whole file exists for. Count responses, not contents:
    /// the failure that motivated this program was an off-by-one in exactly
    /// this number.
    #[test]
    fn every_command_gets_exactly_one_response() {
        let script = "OPTION ttyname=/dev/ttys1\nSETDESC hi\nSETPROMPT PIN\n\
                      SETTITLE T\nSETOK ok\nSETCANCEL no\nSETERROR bad\nNOP\nRESET\nBYE\n";
        let (lines, _) = converse(script, &mut Canned(vec![]));
        // greeting + one per command
        assert_eq!(lines.len(), 1 + 10, "got {lines:#?}");
        assert!(lines[0].starts_with("OK Pleased to meet you, process "));
        assert!(lines[1..9].iter().all(|l| l == "OK"), "got {lines:#?}");
        assert_eq!(lines[10], "OK closing connection");
    }

    /// The stream gpg-agent 2.5.21 actually sends for a signature, captured off
    /// the wire by standing a logging shim in for this binary. Values are
    /// neutered; the verbs and their order are not.
    ///
    /// This test exists because the suite it sits in was green while every real
    /// signature was quietly delegating: `SETKEYINFO` and `SETTIMEOUT` are both
    /// in the setup gpg-agent sends before `SETDESC`, neither was implemented,
    /// and the catch-all handed the whole conversation to pinentry-curses — on
    /// the unwatched tty this program was written to get away from. Invented
    /// scripts cannot catch that class of bug. Only the real one can.
    const REAL_STREAM: &str = "\
OPTION pinentry-user-data=USE_CURSES=1
OPTION no-grab
OPTION ttyname=/dev/ttys001
OPTION ttytype=dumb
OPTION lc-ctype=en_US.UTF-8
OPTION lc-messages=en_US.UTF-8
OPTION allow-external-password-cache
OPTION default-ok=_OK
OPTION default-cancel=_Cancel
OPTION default-yes=_Yes
OPTION default-no=_No
OPTION default-prompt=PIN:
OPTION default-pwmngr=_Save in password manager
OPTION default-cf-visi=Do you really want to make your passphrase visible on the screen?
OPTION default-tt-visi=Make passphrase visible
OPTION default-tt-hide=Hide passphrase
OPTION default-capshint=Caps Lock is on
SETTIMEOUT 900
OPTION touch-file=/dev/null
OPTION owner=1000/1000 host
GETINFO flavor
GETINFO version
GETINFO ttyinfo
GETINFO pid
SETKEYINFO n/0000000000000000000000000000000000000000
SETDESC Please%20enter%20the%20passphrase%20to%20unlock%20the%20OpenPGP%20secret%20key:%0A%22Example%20Key%20<key@example.invalid>%22%0A255-bit%20EDDSA%20key,%20ID%200123456789ABCDEF,%0Acreated%202025-03-08.%0A
SETPROMPT Passphrase:
GETPIN
BYE
";

    #[test]
    fn we_answer_everything_gpg_agent_really_sends() {
        let (lines, delegated) = converse(REAL_STREAM, &mut Canned(vec![Answer::Cancelled]));
        assert!(
            !delegated,
            "a real signature must never reach pinentry-curses"
        );
        // Greeting, then exactly one response per command, except the four
        // GETINFOs which each answer with a `D` line before their `OK`.
        let commands = REAL_STREAM.lines().count();
        assert_eq!(lines.len(), 1 + commands + 4, "got {lines:#?}");
        assert_eq!(lines.last().unwrap(), "OK closing connection");
    }

    #[test]
    fn the_deadline_is_kept_and_outlives_a_reset() {
        struct Seen(Vec<Option<u64>>);
        impl Prompt for Seen {
            fn ask(&mut self, s: &Session) -> Answer {
                self.0.push(s.timeout);
                Answer::Cancelled
            }
        }
        let mut seen = Seen(vec![]);
        converse("SETTIMEOUT 900\nGETPIN\nRESET\nGETPIN\n", &mut seen);
        assert_eq!(seen.0, vec![Some(900), Some(900)]);

        // 0 is pinentry's "wait forever", not "give up at once".
        let mut zero = Seen(vec![]);
        converse("SETTIMEOUT 0\nGETPIN\n", &mut zero);
        assert_eq!(zero.0, vec![None]);
    }

    #[test]
    fn getinfo_answers_with_data_then_ok() {
        let (lines, _) = converse("GETINFO flavor\nGETINFO version\n", &mut Canned(vec![]));
        assert_eq!(lines[1], "D curses");
        assert_eq!(lines[2], "OK");
        assert_eq!(lines[3], format!("D {}", env!("CARGO_PKG_VERSION")));
        assert_eq!(lines[4], "OK");
    }

    #[test]
    fn a_passphrase_comes_back_percent_encoded_then_ok() {
        let mut pass = Passphrase::new();
        for b in b"ab%cd" {
            pass.push(*b);
        }
        let (lines, _) = converse("GETPIN\n", &mut Canned(vec![Answer::Pin(pass)]));
        assert_eq!(
            lines[1], "D ab%25cd",
            "must match pinentry-curses byte for byte"
        );
        assert_eq!(lines[2], "OK");
    }

    #[test]
    fn a_cancel_is_the_code_gpg_agent_expects() {
        let (lines, _) = converse("GETPIN\n", &mut Canned(vec![Answer::Cancelled]));
        assert_eq!(lines[1], "ERR 83886179 Operation cancelled <Pinentry>");
        assert_eq!(
            lines.len(),
            2,
            "a cancel is ONE line, not an error plus an OK"
        );
    }

    #[test]
    fn the_agent_is_told_what_the_dialog_should_say() {
        let mut cap = Capture(vec![]);
        converse(
            "SETDESC Enter%20the%20passphrase%0Afor%20key\nSETPROMPT PIN\n\
             SETERROR Bad%20Passphrase\nOPTION ttyname=/dev/ttys7\nGETPIN\n",
            &mut cap,
        );
        assert_eq!(
            cap.0[0],
            "desc=Some(\"Enter the passphrase\\nfor key\") prompt=Some(\"PIN\") \
             error=Some(\"Bad Passphrase\") tty=Some(\"/dev/ttys7\")"
        );
    }

    /// A rejected passphrase means a second GETPIN on the same connection. The
    /// error belongs to the attempt that produced it.
    #[test]
    fn the_error_does_not_survive_into_the_next_prompt() {
        let mut cap = Capture(vec![]);
        converse("SETERROR Bad\nGETPIN\nGETPIN\n", &mut cap);
        assert!(cap.0[0].contains("error=Some(\"Bad\")"));
        assert!(cap.0[1].contains("error=None"), "got {:?}", cap.0[1]);
    }

    /// RESET clears the text but must not forget where the dialog goes.
    #[test]
    fn reset_keeps_the_terminal_and_drops_the_text() {
        let mut cap = Capture(vec![]);
        converse(
            "OPTION ttyname=/dev/ttys7\nSETDESC hello\nRESET\nGETPIN\n",
            &mut cap,
        );
        assert!(cap.0[0].contains("desc=None"), "got {:?}", cap.0[0]);
        assert!(
            cap.0[0].contains("tty=Some(\"/dev/ttys7\")"),
            "got {:?}",
            cap.0[0]
        );
    }

    /// The handover point. Nothing may have been answered for the triggering
    /// command, or the real pinentry starts a line out of step.
    #[test]
    fn an_unimplemented_verb_hands_over_without_answering_it() {
        let mut input = Cursor::new(b"SETDESC hi\nCONFIRM\n".to_vec());
        let mut out: Vec<u8> = Vec::new();
        let served = serve(&mut input, &mut out, &mut Canned(vec![])).unwrap();
        let lines: Vec<&str> = std::str::from_utf8(&out).unwrap().lines().collect();
        assert_eq!(lines.len(), 2, "greeting and SETDESC's OK only: {lines:#?}");
        match served {
            Served::Delegate {
                to,
                trigger,
                replay,
            } => {
                assert_eq!(to, Handover::Curses, "a verb needs a terminal pinentry");
                assert_eq!(trigger, "CONFIRM");
                // The child must be told what we were told, verbatim.
                assert_eq!(replay, vec!["SETDESC hi".to_string()]);
            }
            _ => panic!("should have delegated"),
        }
    }

    /// A GUI app signing with no `GPG_TTY`. The handover must be to a pinentry
    /// that wants no terminal, and — like every other handover — must not have
    /// answered the command that triggered it.
    #[test]
    fn a_getpin_with_no_terminal_goes_to_the_gui_in_step() {
        struct Blind;
        impl Prompt for Blind {
            fn ask(&mut self, _s: &Session) -> Answer {
                Answer::NoTerminal
            }
        }
        let mut input = Cursor::new(b"SETDESC hi\nGETPIN\n".to_vec());
        let mut out: Vec<u8> = Vec::new();
        let served = serve(&mut input, &mut out, &mut Blind).unwrap();
        let lines: Vec<&str> = std::str::from_utf8(&out).unwrap().lines().collect();
        assert_eq!(lines.len(), 2, "greeting and SETDESC's OK only: {lines:#?}");
        match served {
            Served::Delegate {
                to,
                trigger,
                replay,
            } => {
                assert_eq!(to, Handover::Gui);
                assert_eq!(trigger, "GETPIN");
                assert_eq!(replay, vec!["SETDESC hi".to_string()]);
            }
            _ => panic!("should have handed over"),
        }
    }

    /// A store that always has the passphrase, and counts what actually got
    /// consulted — the seam the keychain integration hangs off.
    struct Vault {
        grips: Vec<String>,
        asks: usize,
    }
    impl Vault {
        fn new() -> Self {
            Vault {
                grips: vec![],
                asks: 0,
            }
        }
    }
    impl Prompt for Vault {
        fn ask(&mut self, _s: &Session) -> Answer {
            self.asks += 1;
            Answer::Cancelled
        }
        fn stored(&mut self, keygrip: &str) -> Option<Passphrase> {
            self.grips.push(keygrip.to_string());
            let mut p = Passphrase::new();
            for b in b"hunter2" {
                p.push(*b);
            }
            Some(p)
        }
    }

    /// The happy path of the whole integration: agent permission plus a
    /// keygrip means the stored passphrase goes out as data, and no dialog is
    /// ever drawn.
    #[test]
    fn a_stored_passphrase_is_served_without_a_dialog() {
        let mut vault = Vault::new();
        let (lines, _) = converse(
            "OPTION allow-external-password-cache\nSETKEYINFO n/AAAA\nGETPIN\n",
            &mut vault,
        );
        assert_eq!(lines[3], "D hunter2", "got {lines:#?}");
        assert_eq!(lines[4], "OK");
        assert_eq!(vault.asks, 0, "no dialog may have been drawn");
        assert_eq!(vault.grips, vec!["AAAA".to_string()]);
    }

    /// SETERROR means the agent just rejected an answer. Serving the store
    /// again would loop the same wrong passphrase forever; the human gets the
    /// prompt instead.
    #[test]
    fn a_pending_error_bypasses_the_store() {
        let mut vault = Vault::new();
        converse(
            "OPTION allow-external-password-cache\nSETKEYINFO n/AAAA\nSETERROR Bad\nGETPIN\n",
            &mut vault,
        );
        assert_eq!(vault.asks, 1);
        assert!(vault.grips.is_empty(), "the store must not be consulted");
    }

    /// `allow-external-password-cache` is gpg-agent's permission switch, and
    /// its absence is a policy, not an omission.
    #[test]
    fn without_the_agents_permission_the_store_is_never_consulted() {
        let mut vault = Vault::new();
        converse("SETKEYINFO n/AAAA\nGETPIN\n", &mut vault);
        assert_eq!(vault.asks, 1);
        assert!(vault.grips.is_empty());
    }

    /// No keygrip, nothing to look up — `--clear` and plain absence alike.
    #[test]
    fn without_a_keygrip_the_store_is_never_consulted() {
        let mut vault = Vault::new();
        converse(
            "OPTION allow-external-password-cache\nSETKEYINFO --clear\nGETPIN\n",
            &mut vault,
        );
        converse("OPTION allow-external-password-cache\nGETPIN\n", &mut vault);
        assert_eq!(vault.asks, 2);
        assert!(vault.grips.is_empty());
    }

    /// One serve per connection. A second GETPIN without an intervening
    /// SETERROR should not happen, but if it does, answering from the store
    /// again could loop — the dialog is the safe side.
    #[test]
    fn the_store_answers_at_most_once_per_connection() {
        let mut vault = Vault::new();
        converse(
            "OPTION allow-external-password-cache\nSETKEYINFO n/AAAA\nGETPIN\nGETPIN\n",
            &mut vault,
        );
        assert_eq!(vault.grips.len(), 1);
        assert_eq!(vault.asks, 1, "the second GETPIN must reach the human");
    }

    /// RESET is the boundary between prompts; a keygrip must not leak across
    /// it onto a prompt for some other key.
    #[test]
    fn reset_forgets_the_keygrip() {
        let mut vault = Vault::new();
        converse(
            "OPTION allow-external-password-cache\nSETKEYINFO n/AAAA\nRESET\nGETPIN\n",
            &mut vault,
        );
        assert_eq!(vault.asks, 1);
        assert!(vault.grips.is_empty());
    }

    #[test]
    fn decoding_handles_escapes_and_leaves_the_rest_alone() {
        assert_eq!(decode("a%20b"), "a b");
        assert_eq!(decode("100%25"), "100%");
        assert_eq!(decode("one%0Atwo"), "one\ntwo");
        assert_eq!(decode("nothing to do"), "nothing to do");
        // A stray per cent is data, not the start of an escape.
        assert_eq!(decode("50% off"), "50% off");
        assert_eq!(decode("%zz"), "%zz");
    }
}
