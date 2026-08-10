//! pinentry-ui — a pinentry that owns its dialog.
//!
//! Three modes. With no arguments it is what gpg-agent runs: Assuan on stdin
//! and stdout, drawing its own dialog on the terminal it is pointed at, in a
//! tmux float when the pane that asked belongs to an agent nobody is watching.
//!
//! `--askpass` is the same dialog for sudo, ssh and git, which do not speak
//! Assuan: the prompt arrives as an argument and the secret leaves on stdout.
//! See `docs/askpass-design.md`.
//!
//! `--demo` is the third, and it is not a leftover. The dialog is the only part
//! of this program a test cannot judge, so it stays runnable on its own, from
//! canned text, reporting *about* what it read and never revealing it.
//!
//!   pinentry-ui                                        (gpg-agent runs this)
//!   pinentry-ui --askpass PROMPT                       (SUDO_ASKPASS et al)
//!   pinentry-ui --demo [--tty PATH] [--error TEXT] [--no-frame] [--title TEXT]
//!                      [--requester NAME] [--elsewhere] [--timeout-ms N]

mod askpass;
mod assuan;
mod debug;
mod delegate;
mod dialog;
mod float;
mod gui;
mod hardening;
mod icons;
mod keyinfo;
mod prompt;
mod requester;
mod secret;
mod term;
mod theme;

use std::io::{BufReader, Write};
use std::process::ExitCode;
use std::time::Duration;

use dialog::{Dialog, KeyInfo, Outcome, Requester, FLOAT_WIDTH, MIN_WIDTH};
use term::Tty;
use theme::Theme;

fn main() -> ExitCode {
    hardening::apply();

    let args: Vec<String> = std::env::args().skip(1).collect();
    if debug::on() {
        debug::log(format_args!(
            "--- pinentry-ui {} starting, args {args:?}",
            env!("CARGO_PKG_VERSION")
        ));
    }
    if let Some(i) = args.iter().position(|a| a == "--askpass") {
        // Everything after the flag is the prompt. sudo passes one argument,
        // but a prompt with spaces reaching us unquoted must not lose half of
        // itself.
        return askpass::run(args[i + 1..].join(" ").trim_end());
    }
    if !args.iter().any(|a| a == "--demo") {
        return serve(&args);
    }
    demo(&args)
}

/// The real thing. Anything that goes wrong before a single byte is written
/// hands the whole conversation to `pinentry-curses`, because a broken pinentry
/// must never be the reason a signature cannot happen.
fn serve(args: &[String]) -> ExitCode {
    let stdin = std::io::stdin();
    let mut input = BufReader::new(stdin.lock());
    let stdout = std::io::stdout();
    let mut out = stdout.lock();

    match assuan::serve(&mut input, &mut out, &mut prompt::Ui) {
        Ok(assuan::Served::Done(code)) => ExitCode::from(code),
        Ok(assuan::Served::Delegate {
            to,
            trigger,
            replay,
        }) => {
            // The child has to be told everything we were told, or it draws a
            // dialog with no text in it.
            match delegate::hand_over(to, &replay, &trigger, &mut input, &mut out, args) {
                Ok(code) => ExitCode::from(code),
                // Even the handover failed. Describe what actually went wrong:
                // "unknown command" would be a lie about a prompt that simply
                // had no screen and no GUI pinentry to borrow one from.
                Err(e) => {
                    let err = match to {
                        assuan::Handover::Curses => assuan::UNKNOWN_COMMAND.to_string(),
                        assuan::Handover::Gui => {
                            assuan::err_no_dialog(&format!("no terminal, and no GUI pinentry: {e}"))
                        }
                    };
                    let _ = writeln!(out, "{err}");
                    let _ = out.flush();
                    ExitCode::FAILURE
                }
            }
        }
        Err(_) => ExitCode::FAILURE,
    }
}

fn demo(args: &[String]) -> ExitCode {
    let mut tty_path = None;
    let mut error = None;
    let mut title = Some("Passphrase".to_string());
    let mut requester = None;
    let mut elsewhere = false;
    let mut frame = true;
    let mut timeout = None;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--tty" => tty_path = it.next().cloned(),
            "--error" => error = it.next().cloned(),
            "--title" => title = it.next().cloned(),
            "--requester" => requester = it.next().cloned(),
            "--elsewhere" => elsewhere = true,
            "--no-frame" => frame = false,
            // Milliseconds here, where gpg's SETTIMEOUT is seconds: this exists
            // so a test can watch the deadline expire without waiting out a
            // real one.
            "--timeout-ms" => {
                timeout = it
                    .next()
                    .and_then(|v| v.parse().ok())
                    .map(Duration::from_millis)
            }
            _ => {}
        }
    }

    let theme = Theme::load();
    let mut tty = match Tty::open(tty_path.as_deref()) {
        Ok(tty) => tty,
        Err(e) => {
            eprintln!("pinentry-ui: cannot open terminal: {e}");
            return ExitCode::FAILURE;
        }
    };

    // The float is a fixed width, but a terminal narrower than one is not a
    // reason to draw off the edge of it.
    let width = FLOAT_WIDTH.min(tty.size().0).max(MIN_WIDTH);
    let dialog = Dialog {
        title,
        description: vec![
            "Please enter the passphrase to unlock the OpenPGP secret key:".to_string(),
        ],
        key: Some(KeyInfo {
            user_id: "\"Example Key <key@example.invalid>\"".to_string(),
            // nf-md-lock, fa-address-card, nf-md-calendar. Written as escapes
            // because the literals do not survive every editor in the chain,
            // and verified against the symbol table for the font this repo
            // builds (`~/.local/share/fonts/nerd-font/symbols.db`). The
            // 0x10xxxx one is Font Awesome 7, which that build relocates to
            // `0x100000 + native` so it does not clobber the Nerd Font copy.
            facts: vec![
                ("\u{f033e}".to_string(), "4096-bit RSA key".to_string()),
                ("\u{10f2bb}".to_string(), "ID 0123456789ABCDEF".to_string()),
                ("\u{f00ed}".to_string(), "created in 2020-01-01".to_string()),
            ],
        }),
        // --requester takes a process BASENAME, exactly what the real binary
        // will resolve from the requesting pane, so the demo exercises the same
        // lookup: `claude` wears its tab glyph, anything unlisted wears the
        // generic run one. The pane half of the label is canned.
        requester: requester.map(|name| Requester {
            glyph: icons::glyph_for(&name),
            label: format!("{name} · pane %3 (Main:2)"),
            elsewhere,
        }),
        error,
        width,
        frame,
        timeout,
    };

    let (w, h) = dialog.size();
    if let Err(e) = tty.enter() {
        eprintln!("pinentry-ui: cannot configure terminal: {e}");
        return ExitCode::FAILURE;
    }

    let outcome = dialog.run(&mut tty, &theme);
    drop(tty); // restores the terminal before anything is printed below

    match outcome {
        // Rule 7 binds this harness too: length and shape, never the bytes. The
        // ASCII check is the one that matters during validation — an escape
        // sequence leaking into the buffer is precisely the bug that made a
        // typed "1234" arrive as "1234[27;8;49~".
        Ok(Outcome::Accepted(pass)) => {
            println!(
                "accepted: {} bytes, {} characters, canvas {}x{}, mlock {}",
                pass.len(),
                pass.chars(),
                w,
                h,
                if pass.is_locked() { "yes" } else { "REFUSED" }
            );
            ExitCode::SUCCESS
        }
        Ok(Outcome::Cancelled) => {
            println!("cancelled");
            ExitCode::from(1)
        }
        Ok(Outcome::TimedOut) => {
            println!("timed out");
            ExitCode::from(1)
        }
        Err(e) => {
            eprintln!("pinentry-ui: {e}");
            ExitCode::FAILURE
        }
    }
}
