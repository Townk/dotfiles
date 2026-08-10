//! Driving a GUI pinentry from the askpass lane.
//!
//! When there is no pane there is nowhere to float, and this lane has no
//! terminal of its own to fall back to — so the only screen left is the
//! desktop, and the only thing that can draw on it is `pinentry-mac`. Which
//! speaks Assuan, and expects to be the one being asked.
//!
//! So this is the mirror of `delegate`: there we hand a conversation over and
//! get out of the way; here we conduct one. It is the only place in the program
//! that is an Assuan *client*.
//!
//! Nothing subtle in the protocol — four commands and one answer — but one
//! inherited trap. `pinentry-mac` honours `USE_CURSES` in `PINENTRY_USER_DATA`
//! by re-execing a curses pinentry, and that token is exactly what routed the
//! request to this program in the first place. Passing it down sends the
//! request back to a terminal that does not exist; it was measured as
//! `S ERROR mac.isatty`, which reads like a broken handover rather than an
//! environment variable nobody dropped.

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, ExitCode, Stdio};

use zeroize::Zeroize;

/// Ask the GUI, and print what it says on our stdout. Non-zero on any refusal,
/// which is all a caller can act on anyway.
pub fn ask(prompt: &str, title: &str) -> ExitCode {
    match converse(prompt, title) {
        Ok(Some(mut secret)) => {
            let mut out = std::io::stdout().lock();
            let wrote = out
                .write_all(secret.as_bytes())
                .and_then(|()| out.write_all(b"\n"))
                .and_then(|()| out.flush());
            // The one copy of the secret this program does not keep in a
            // Passphrase: it arrives as a line from the child, so it lands in
            // an ordinary String. It cannot be locked after the fact, but it
            // can be wiped, and it is.
            secret.zeroize();
            crate::debug::log(format_args!("the GUI answered"));
            if wrote.is_ok() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Ok(None) => {
            crate::debug::log(format_args!("the GUI was dismissed"));
            ExitCode::FAILURE
        }
        Err(e) => {
            crate::debug::log(format_args!("no GUI to ask: {e}"));
            ExitCode::FAILURE
        }
    }
}

fn converse(prompt: &str, title: &str) -> std::io::Result<Option<String>> {
    let bin = crate::delegate::gui_bin();
    crate::debug::log(format_args!("asking {bin}"));
    let mut child = Command::new(&bin)
        .env_remove("PINENTRY_USER_DATA")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;

    let mut input = child.stdin.take().expect("piped");
    let mut output = BufReader::new(child.stdout.take().expect("piped"));

    let mut line = String::new();
    output.read_line(&mut line)?; // its greeting answers nothing we asked

    let mut say = |cmd: &str| -> std::io::Result<()> {
        writeln!(input, "{cmd}")?;
        input.flush()?;
        line.clear();
        output.read_line(&mut line)?;
        Ok(())
    };
    say(&format!("SETTITLE {}", encode(title)))?;
    say(&format!("SETPROMPT {}", encode(title)))?;
    say(&format!("SETDESC {}", encode(prompt.trim_end())))?;

    writeln!(input, "GETPIN")?;
    input.flush()?;

    // `D <secret>` then `OK`, or a bare `OK` for an empty answer, or `ERR` for
    // a dismissed dialog.
    let mut secret = None;
    loop {
        let mut reply = String::new();
        if output.read_line(&mut reply)? == 0 {
            break;
        }
        let trimmed = reply.trim_end_matches(['\r', '\n']);
        if let Some(data) = trimmed.strip_prefix("D ") {
            secret = Some(decode(data));
        } else if trimmed.starts_with("OK") || trimmed.starts_with("ERR") {
            reply.zeroize();
            break;
        }
        reply.zeroize();
    }

    let _ = writeln!(input, "BYE");
    drop(input);
    let _ = child.wait();
    Ok(secret)
}

/// Assuan percent-encoding, for the two strings we send. Only the three bytes
/// that would break the line need it.
fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '%' => out.push_str("%25"),
            '\r' => out.push_str("%0D"),
            '\n' => out.push_str("%0A"),
            _ => out.push(c),
        }
    }
    out
}

fn decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b as char);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_three_bytes_that_would_break_a_line_are_escaped() {
        assert_eq!(encode("100% sure\nreally"), "100%25 sure%0Areally");
        assert_eq!(encode("Password:"), "Password:");
    }

    /// A passphrase with a literal `%` in it comes back triple-encoded, and
    /// getting this wrong corrupts exactly the passwords nobody tests with.
    #[test]
    fn what_comes_back_is_decoded() {
        assert_eq!(decode("100%25 sure"), "100% sure");
        assert_eq!(decode("plain"), "plain");
        assert_eq!(decode("trailing%"), "trailing%");
    }
}
