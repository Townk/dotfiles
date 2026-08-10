//! The same dialog, for programs that never learned Assuan.
//!
//! sudo, ssh and git all share one crude convention: run a helper with the
//! prompt as `argv[1]`, read the secret from its stdout, treat a non-zero exit
//! as "no answer". `docs/askpass-design.md` has the measurements; two of them
//! shape everything here.
//!
//! **There is no terminal.** Both sudo and ssh detach the helper completely —
//! no tty on any descriptor, no controlling terminal, `/dev/tty` will not even
//! open. So "draw in the calling pane" is not a fallback that exists in this
//! lane, and the float is not a nicety: `display-popup` needs `$TMUX`, not a
//! tty, which makes it the only way to put a dialog on a screen from here.
//!
//! **The environment usually survives, and `TMUX_PANE` is in it.** That is the
//! first handle back to the mux, which is why the pane is looked up by id
//! rather than by the ttyname the pinentry lane uses. It is not the only one,
//! and assuming it was cost an afternoon: Homebrew launders the environment it
//! passes on, keeping `SUDO_ASKPASS` and dropping both tmux variables, so the
//! helper it invokes has to recover the pane from the process tree instead.
//! See `inherited_tty`.
//!
//! Every prompt here therefore floats, including one from the pane you are
//! staring at. That is a difference from the pinentry lane, and it is forced
//! rather than chosen: there is nowhere else to draw.

use std::io::Write;
use std::process::{Command, ExitCode};
use std::time::Duration;

use crate::dialog::{Dialog, Outcome, Requester, FLOAT_PTY_WIDTH};
use crate::float;
use crate::icons;
use crate::requester::{self, By};
use crate::term::Tty;
use crate::theme::Theme;

/// Names to walk past when looking for who asked: an askpass helper is often
/// reached through a shell, and "sh" tells the human nothing.
const SHELLS: [&str; 6] = ["sh", "zsh", "bash", "dash", "ksh", "fish"];

/// Nothing upstream will ever end this dialog for us.
///
/// sudo's `passwd_timeout` bounds the prompt sudo draws itself, not a helper:
/// given a helper that sleeps, sudo waits the full sleep and then uses whatever
/// it printed. So an unanswered float would hold its caller open forever, and
/// the caller is not always a human at a keyboard — Homebrew runs
/// `sudo -A` unattended during a system update, and a hang there is worse than
/// a refusal, which at least prints a reason and stops.
///
/// Two minutes is long enough to walk back to the machine and short enough that
/// an unattended run fails the same day it started.
///
/// The GUI rung enforces the same span on `pinentry-mac` from the outside, for
/// the same reason and against a worse case: that dialog can be somewhere the
/// person driving the machine cannot see at all.
///
/// Overridable for tests, exactly as the two pinentry binaries are — nothing
/// else waits two minutes to find out whether a deadline works.
pub(crate) fn deadline() -> Duration {
    std::env::var("PINENTRY_UI_DEADLINE_MS")
        .ok()
        .and_then(|ms| ms.parse().ok())
        .map_or(Duration::from_secs(120), Duration::from_millis)
}

pub fn run(prompt: &str) -> ExitCode {
    let theme = Theme::load();
    let chain = parents();
    let title = title(prompt, &commands(&chain));
    let pane = std::env::var("TMUX_PANE").unwrap_or_default();
    let who = if pane.is_empty() {
        None
    } else {
        requester::resolve(By::Pane(&pane))
    };
    // Second chance for a caller whose environment was laundered on the way
    // here. See `inherited_tty`.
    let who = who.or_else(|| {
        let tty = inherited_tty(&chain)?;
        crate::debug::log(format_args!("no TMUX_PANE; the tree says {tty}"));
        requester::resolve(By::Tty(&tty))
    });

    let Some(who) = who else {
        crate::debug::log(format_args!("no pane behind {pane:?}: asking the GUI"));
        return crate::gui::ask(prompt, &title);
    };

    let mut dialog = Dialog {
        title: Some(title.clone()),
        description: vec![prompt.trim_end().to_string()],
        key: None,
        requester: Some(Requester {
            glyph: icons::glyph_for(&who.name),
            label: who.label(),
            elsewhere: who.elsewhere,
        }),
        error: None,
        width: FLOAT_PTY_WIDTH,
        frame: false,
        timeout: Some(deadline()),
    };

    let (w, h) = dialog.size();
    let opened = float::open(&who.tty, w + 2, h + 2, &who.name);
    crate::debug::log(format_args!(
        "float {}x{} for {} -> {:?}",
        w + 2,
        h + 2,
        who.name,
        opened.as_ref().map(|f| &f.tty)
    ));
    let Some(float) = opened else {
        crate::debug::log(format_args!("no float for {}: asking the GUI", who.tty));
        return crate::gui::ask(prompt, &title);
    };

    let answer = draw(&mut dialog, &float.tty, &theme);
    drop(float);

    match answer {
        Some(Outcome::Accepted(pass)) => {
            let mut out = std::io::stdout().lock();
            // A newline is the terminator, which is also the one thing an
            // askpass secret may not contain. The dialog cannot produce one —
            // Enter submits — so this is a property of the field, not a check.
            if pass.write_askpass_line(&mut out).is_err() || out.flush().is_err() {
                return ExitCode::FAILURE;
            }
            // That it was answered, and nothing about the answer. Length is
            // not the secret, but it is a fact about the secret, and this file
            // exists to be read by someone debugging routing.
            crate::debug::log(format_args!("answered"));
            ExitCode::SUCCESS
        }
        // Cancelled, timed out, or never drawn. All the same to the caller:
        // no secret on stdout and a non-zero exit, which sudo reports as "no
        // password was provided" rather than as a wrong one.
        other => {
            crate::debug::log(format_args!(
                "no answer ({})",
                match other {
                    Some(Outcome::Cancelled) => "cancelled",
                    Some(Outcome::TimedOut) => "timed out",
                    _ => "could not draw",
                }
            ));
            ExitCode::FAILURE
        }
    }
}

/// Draw on the float's pty and read. None when it could not be drawn at all.
fn draw(dialog: &mut Dialog, tty: &str, theme: &Theme) -> Option<Outcome> {
    let mut tty = Tty::open(Some(tty)).ok()?;
    tty.enter().ok()?;
    let outcome = dialog.run(&mut tty, theme);
    // The terminal first, then the caller drops the float: restoring writes to
    // a pty the float still owns.
    drop(tty);
    outcome.ok()
}

/// The title is who asked, because the prompt itself often does not say.
///
/// sudo's is the literal string `Password:` — accurate and useless in a float
/// that appeared while you were looking at something else. The process tree
/// knows: our parent is sudo, or ssh, or git, possibly through a shell that
/// has to be walked past. Falls back to what the prompt looks like, then to
/// something neutral.
fn title(prompt: &str, parents: &[String]) -> String {
    if let Some(name) = asker(parents) {
        return name;
    }
    if prompt.to_ascii_lowercase().contains("passphrase") {
        "Passphrase".to_string()
    } else {
        "Password".to_string()
    }
}

/// First name up the tree that is not a shell.
fn asker<'a>(chain: impl IntoIterator<Item = &'a String>) -> Option<String> {
    chain
        .into_iter()
        .map(|c| c.trim())
        .map(|c| c.rsplit('/').next().unwrap_or(c))
        .find(|c| !c.is_empty() && !SHELLS.contains(c))
        .map(str::to_string)
}

/// One ancestor: what it is, and what terminal it was started from.
pub struct Ancestor {
    pub comm: String,
    /// As `ps` prints it — `ttys003`, `pts/3`, or `??` for none.
    pub tty: String,
}

/// The pane, recovered from the family rather than from the environment.
///
/// `TMUX_PANE` is the handle when it survives, and it usually does. Homebrew is
/// the measured exception: it launders its environment through an allowlist,
/// which keeps `SUDO_ASKPASS` but drops `TMUX` and `TMUX_PANE`, so a helper
/// invoked by `brew`'s own `sudo -A` arrives with no idea where it came from.
/// It went to the GUI instead — onto the desktop of a machine being driven over
/// SSH, where nobody could see it.
///
/// The tree is the handle that survives that. Neither we nor sudo has a
/// controlling terminal, but the processes above us kept theirs, and it is the
/// pane's own tty — which is exactly what the pinentry lane already looks panes
/// up by. `tmux` itself needs no `$TMUX` to answer: with the variable gone it
/// falls back to the default socket, which is the one it was on.
fn inherited_tty(chain: &[Ancestor]) -> Option<String> {
    chain
        .iter()
        .map(|a| a.tty.trim())
        .find(|tty| !tty.is_empty() && *tty != "??" && *tty != "?")
        .map(|tty| format!("/dev/{tty}"))
}

fn commands(chain: &[Ancestor]) -> Vec<String> {
    chain.iter().map(|a| a.comm.clone()).collect()
}

/// Ancestors, nearest first. Deep enough to climb out of Homebrew — helper,
/// sudo, ruby, the worker and its shell all sit between us and the pane — and
/// still stop well short of launchd.
fn parents() -> Vec<Ancestor> {
    // SAFETY: getppid cannot fail and touches nothing.
    let mut pid = unsafe { libc::getppid() };
    let mut chain = Vec::new();
    for _ in 0..12 {
        let Some((ppid, it)) = ps(pid) else { break };
        chain.push(it);
        if ppid <= 1 {
            break;
        }
        pid = ppid;
    }
    chain
}

fn ps(pid: i32) -> Option<(i32, Ancestor)> {
    let out = Command::new("/bin/ps")
        .args(["-o", "ppid=,tty=,comm=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    parse_ps(text.trim())
}

/// `comm` goes last because it is the only field that can contain a space, and
/// the columns are padded — `ps` right-aligns the pid, so a plain split on
/// whitespace would hand back empty fields.
fn parse_ps(line: &str) -> Option<(i32, Ancestor)> {
    let (ppid, rest) = line.trim_start().split_once(char::is_whitespace)?;
    let (tty, comm) = rest.trim_start().split_once(char::is_whitespace)?;
    Some((
        ppid.parse().ok()?,
        Ancestor {
            comm: comm.trim().to_string(),
            tty: tty.trim().to_string(),
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chain(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    fn tree(pairs: &[(&str, &str)]) -> Vec<Ancestor> {
        pairs
            .iter()
            .map(|(comm, tty)| Ancestor {
                comm: comm.to_string(),
                tty: tty.to_string(),
            })
            .collect()
    }

    /// The measured shape under `sudo -A`: neither we nor sudo has a terminal,
    /// and the pane's tty is two hops further up.
    #[test]
    fn the_pane_is_recovered_from_the_first_ancestor_that_kept_a_terminal() {
        let seen = tree(&[("sudo", "??"), ("zsh", "??"), ("agent", "ttys003")]);
        assert_eq!(inherited_tty(&seen), Some("/dev/ttys003".to_string()));
    }

    #[test]
    fn a_family_with_no_terminal_anywhere_yields_nothing_to_guess_from() {
        assert_eq!(
            inherited_tty(&tree(&[("sudo", "??"), ("launchd", "?")])),
            None
        );
        assert_eq!(inherited_tty(&[]), None);
    }

    /// `ps` right-aligns the pid and comm can contain a space; splitting on
    /// whitespace naively drops the tty into the pid and truncates the name.
    #[test]
    fn the_padded_columns_of_ps_are_read_correctly() {
        let (ppid, it) = parse_ps("  1234 ttys003 -zsh").expect("parses");
        assert_eq!(ppid, 1234);
        assert_eq!(it.tty, "ttys003");
        assert_eq!(it.comm, "-zsh");

        let (_, spaced) = parse_ps("99 ?? /Applications/My App.app/Contents/x").expect("parses");
        assert_eq!(spaced.tty, "??");
        assert_eq!(spaced.comm, "/Applications/My App.app/Contents/x");
    }

    /// The measured shape: `SUDO_ASKPASS` pointing at a script means the
    /// helper's parent is a shell, and reporting "sh" would waste the one line
    /// that says what is going on.
    #[test]
    fn a_shell_in_the_way_is_not_who_asked() {
        assert_eq!(
            asker(&chain(&["/bin/sh", "sudo", "zsh"])),
            Some("sudo".to_string())
        );
    }

    #[test]
    fn the_nearest_real_program_wins_and_loses_its_path() {
        assert_eq!(
            asker(&chain(&["/usr/bin/ssh", "zsh"])),
            Some("ssh".to_string())
        );
        assert_eq!(asker(&chain(&[])), None);
        assert_eq!(asker(&chain(&["zsh", "bash"])), None);
    }

    /// Only reached when the tree says nothing, but it is the difference
    /// between a titled dialog and a blank one.
    #[test]
    fn the_prompt_names_the_secret_when_the_tree_will_not() {
        assert_eq!(
            title("Enter passphrase for \"/tmp/k\": ", &[]),
            "Passphrase"
        );
        assert_eq!(title("Password:", &[]), "Password");
    }

    /// Both measured prompts, with the tree that really produced them.
    #[test]
    fn who_asked_beats_what_they_asked_for() {
        assert_eq!(title("Password:", &chain(&["/bin/sh", "sudo"])), "sudo");
        assert_eq!(
            title("Enter passphrase for \"/tmp/k\": ", &chain(&["ssh-keygen"])),
            "ssh-keygen"
        );
    }
}
