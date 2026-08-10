//! Who asked, and whether anybody is looking at the pane they asked from.
//!
//! gpg-agent gives us exactly one handle on the outside world: the `ttyname` in
//! an `OPTION`. That names a pane, a pane names a session, and a session names
//! the client with a human in front of it — which is how a prompt finds its way
//! to a screen somebody is watching.
//!
//! The process name comes from the pill's own `@win_proc` stamp rather than
//! from `#{pane_current_command}`, and that is load-bearing rather than
//! cosmetic. tmux names a pane after a process it picks out of the foreground
//! process *group*, and on macOS that is not the leader: a pane running an
//! agent reports `node`. The shell stamps the real name in `preexec` and clears
//! it in `precmd`, so the stamp exists exactly while a command is running,
//! which is exactly when a signing prompt can fire.

use std::process::Command;

/// What we managed to learn about the pane behind a tty.
pub struct Requester {
    /// Process basename, `.exe` stripped — `claude`, `agent`, or a shell's name.
    pub name: String,
    /// The pane's own pty. The askpass lane needs it and has no other way to
    /// get one: it is handed a pane id, while `pinentry-mux-popup` takes a tty
    /// (a tty names a session, a session names the client to paint on). Looking
    /// it up here costs nothing, because the pane list already carries it, and
    /// it keeps the whole shell layer out of the change.
    pub tty: String,
    /// `%3`, for the label.
    pub pane_id: String,
    /// `Main:2`, for the label.
    pub window: String,
    /// True when this pane is NOT what an attached human is currently looking
    /// at. It is the reason the float exists and the reason the dialog turns
    /// yellow.
    pub elsewhere: bool,
    /// True when the name is one of the coding agents in `agent-procs.data`.
    pub is_agent: bool,
}

impl Requester {
    /// `claude · pane %3 (Main:2)` — process first, because that is the part
    /// that decides whether to type.
    pub fn label(&self) -> String {
        format!("{} · pane {} ({})", self.name, self.pane_id, self.window)
    }
}

/// The tmux binary, or None when there is no tmux to ask.
///
/// gpg-agent's PATH is not a login shell's, so `command -v` alone is not
/// enough — the same search the retired shell filter did, for the same reason.
pub fn tmux_bin() -> Option<String> {
    if let Some(b) = std::env::var_os("MUX_TMUX_BIN") {
        let b = b.to_string_lossy().into_owned();
        if is_exec(&b) {
            return Some(b);
        }
    }
    [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]
    .into_iter()
    .find(|c| is_exec(c))
    .map(str::to_string)
}

fn is_exec(path: &str) -> bool {
    std::fs::metadata(path).is_ok_and(|m| {
        use std::os::unix::fs::PermissionsExt;
        m.is_file() && m.permissions().mode() & 0o111 != 0
    })
}

/// The eight fields, separated by a character tmux will not touch.
///
/// The separator must be **printable**. tmux passes its output through
/// `utf8_sanitize` when the locale is not UTF-8, which replaces every
/// non-printable byte with `_` — and gpg-agent hands a pinentry an environment
/// with no `LANG` and no `LC_*` at all, so that path is the normal one for us,
/// not the exotic one. The tab this started with came back as `_`, so every
/// line arrived as a single field and no pane ever matched.
///
/// `session_name` is last on purpose: it is the only field a human names, so it
/// is the only one that could contain the separator, and `splitn` keeps the
/// pieces of a split name in the label instead of shifting the fields that
/// decide where the prompt goes.
const PANE_FORMAT: &str = "#{pane_tty}|#{pane_id}|#{@win_proc}|#{pane_current_command}|\
                           #{window_index}|#{pane_active}|#{window_active}|#{session_name}";

/// How the caller names itself, which differs by lane.
///
/// A pinentry is told a ttyname over Assuan. An askpass helper is told nothing:
/// sudo and ssh both run it with no terminal on any descriptor and no
/// controlling terminal at all, so the only handle back to the mux is the
/// `TMUX_PANE` it inherits in its environment.
#[derive(Debug, Clone, Copy)]
pub enum By<'a> {
    Tty(&'a str),
    Pane(&'a str),
}

impl By<'_> {
    fn matches(&self, tty: &str, pane_id: &str) -> bool {
        match self {
            By::Tty(t) => *t == tty,
            By::Pane(p) => *p == pane_id,
        }
    }
}

/// Ask tmux who this is. None when there is no tmux, no server, or no matching
/// pane — all of which are ordinary, and mean the caller has to find somewhere
/// else to draw.
pub fn resolve(by: By) -> Option<Requester> {
    let tmux = tmux_bin()?;
    let panes = run(&tmux, &["list-panes", "-a", "-F", PANE_FORMAT])?;
    let attached = run(&tmux, &["list-clients", "-F", "#{client_session}"]).unwrap_or_default();
    let agents = agent_procs();
    // The raw text, not a summary of it. The separator bug was invisible in any
    // summary: the fields looked plausible, they were simply all one field.
    crate::debug::log(format_args!(
        "tmux={tmux} panes={panes:?} attached={attached:?} agents={agents:?}"
    ));
    let who = parse(by, &panes, &attached, &agents);
    crate::debug::log(format_args!(
        "resolved {by:?} -> {:?}",
        who.as_ref()
            .map(|r| (&r.name, &r.pane_id, r.is_agent, r.elsewhere))
    ));
    who
}

fn run(tmux: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(tmux).args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The agent basenames, from the table chezmoi projects for us. An empty list
/// (no file) means nothing is ever treated as an agent, so every prompt is
/// drawn in place — the safe direction: a prompt on your own screen is a
/// nuisance, a prompt on a screen nobody watches is the bug.
fn agent_procs() -> Vec<String> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let path = std::path::Path::new(&home).join(".config/mux/agent-procs.data");
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect()
}

/// Split out from `resolve` so the interesting logic is testable without a tmux
/// server: this is where the wrong answer would be silent.
fn parse(by: By, panes: &str, attached: &str, agents: &[String]) -> Option<Requester> {
    let watched: Vec<&str> = attached.lines().map(str::trim).collect();

    for line in panes.lines() {
        // `|`, and not the tab this used to use, because tmux runs its output
        // through utf8_sanitize when the locale is not UTF-8 — and gpg-agent
        // hands a pinentry an environment with no LANG or LC_* at all. Every
        // tab came back as `_`, so the whole line was one field, no pane ever
        // matched, and every prompt fell back to the unwatched pane it was
        // supposed to rescue. Verified both ways: tabs `_` out under `env -i`,
        // `|` survives. Non-ASCII in a session name is still sanitised, which
        // is why session_name is only ever a label here — and why both sides
        // of the `watched` comparison come from the same mangling.
        //
        // splitn, with the one free-form field last: a session name may
        // contain a `|`, and if it does the extra pieces stay in the label
        // rather than shifting the fields that decide where the prompt goes.
        let f: Vec<&str> = line.splitn(8, '|').collect();
        if f.len() < 8 || !by.matches(f[0], f[1]) {
            continue;
        }
        let (pane_id, win_proc, cur, window, pane_active, window_active, session) = (
            f[1],
            f[2].trim(),
            f[3].trim(),
            f[4],
            f[5],
            f[6],
            f[7].trim(),
        );

        let name = if win_proc.is_empty() { cur } else { win_proc };
        let name = name.strip_suffix(".exe").unwrap_or(name).to_string();

        // "Somebody is looking at this" takes all three. `pane_active` alone is
        // not enough and reads as though it were: EVERY window has an active
        // pane, so on a real server four panes claim it at once. Without the
        // window test a prompt from a background window would be treated as
        // one the human is watching — which is the exact bug this program was
        // written to fix, reintroduced by a format string.
        let looked_at = pane_active == "1" && window_active == "1" && watched.contains(&session);

        return Some(Requester {
            is_agent: agents.contains(&name),
            name,
            tty: f[0].to_string(),
            pane_id: pane_id.to_string(),
            window: format!("{session}:{window}"),
            elsewhere: !looked_at,
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shaped like the real thing, including the trap: `%3` is the active pane
    /// of its window, but that window is not the current one.
    const PANES: &str = "/dev/ttys001|%0|agent|node|1|1|1|Main\n\
                         /dev/ttys002|%3||zsh|2|1|0|Main\n\
                         /dev/ttys003|%9|claude.exe|node|4|1|1|Work\n\
                         /dev/ttys004|%5||zsh|1|0|1|Main\n";

    fn agents() -> Vec<String> {
        vec!["agent".to_string(), "claude".to_string()]
    }

    /// The measured case: tmux says `node`, the stamp says `agent`, and the
    /// stamp wins. Getting this backwards names every agent "node".
    #[test]
    fn the_stamp_beats_what_tmux_guessed() {
        let r = parse(By::Tty("/dev/ttys001"), PANES, "Main\n", &agents()).unwrap();
        assert_eq!(r.name, "agent");
        assert!(r.is_agent);
        assert_eq!(r.label(), "agent · pane %0 (Main:1)");
    }

    /// A vendor's platform suffix must not decide whether a prompt is visible.
    #[test]
    fn a_dot_exe_suffix_is_not_a_different_program() {
        let r = parse(By::Tty("/dev/ttys003"), PANES, "Work\n", &agents()).unwrap();
        assert_eq!(r.name, "claude");
        assert!(r.is_agent);
    }

    #[test]
    fn a_shell_falls_back_to_what_tmux_says() {
        let r = parse(By::Tty("/dev/ttys002"), PANES, "Main\n", &agents()).unwrap();
        assert_eq!(r.name, "zsh");
        assert!(!r.is_agent);
    }

    #[test]
    fn the_active_pane_of_an_attached_session_is_being_watched() {
        let r = parse(By::Tty("/dev/ttys001"), PANES, "Main\n", &agents()).unwrap();
        assert!(!r.elsewhere);
    }

    /// The whole reason the float exists: a pane nobody has in front of them.
    /// `%3` IS its window's active pane — every window has one — but the window
    /// is not current, so nobody can see it.
    #[test]
    fn the_active_pane_of_a_background_window_is_still_elsewhere() {
        let r = parse(By::Tty("/dev/ttys002"), PANES, "Main\n", &agents()).unwrap();
        assert!(
            r.elsewhere,
            "an active pane in a background window is unwatched"
        );
    }

    #[test]
    fn a_split_you_are_not_focused_on_is_elsewhere() {
        let r = parse(By::Tty("/dev/ttys004"), PANES, "Main\n", &agents()).unwrap();
        assert!(r.elsewhere, "current window, but not the focused pane");
    }

    #[test]
    fn a_detached_session_is_elsewhere_however_active_the_pane() {
        let r = parse(By::Tty("/dev/ttys001"), PANES, "", &agents()).unwrap();
        assert!(r.elsewhere);
    }

    #[test]
    fn an_unknown_tty_is_simply_not_ours() {
        assert!(parse(By::Tty("/dev/ttys999"), PANES, "Main\n", &agents()).is_none());
    }

    /// The askpass lane's only handle. sudo and ssh run their helper with no
    /// terminal at all, so `TMUX_PANE` is all there is to go on — and it has to
    /// find the same pane, including the pane's own tty, which is what the
    /// float opener takes.
    #[test]
    fn a_pane_id_finds_the_same_pane_a_tty_would() {
        let by_tty = parse(By::Tty("/dev/ttys003"), PANES, "Work\n", &agents()).unwrap();
        let by_pane = parse(By::Pane("%9"), PANES, "Work\n", &agents()).unwrap();
        assert_eq!(by_pane.name, by_tty.name);
        assert_eq!(by_pane.pane_id, "%9");
        assert_eq!(
            by_pane.tty, "/dev/ttys003",
            "the float is opened from the tty, not the pane id"
        );
    }

    /// The two keys must not be confusable. Matching a pane id against the tty
    /// field (or the reverse) would silently prompt on some other pane.
    #[test]
    fn the_two_keys_do_not_cross() {
        assert!(parse(By::Pane("/dev/ttys003"), PANES, "Work\n", &agents()).is_none());
        assert!(parse(By::Tty("%9"), PANES, "Work\n", &agents()).is_none());
        assert!(parse(By::Pane("%404"), PANES, "Work\n", &agents()).is_none());
    }

    /// The bug this separator exists for. tmux sanitises non-printable bytes to
    /// `_` whenever the locale is not UTF-8, and gpg-agent's environment has no
    /// locale at all — so a control character here silently collapses every
    /// line into one field, no pane matches, and every prompt lands on the
    /// unwatched pane this program was written to rescue. It fails as a
    /// fallback rather than as an error, which is why it survived a full test
    /// suite and was only found on a live signature.
    #[test]
    fn the_field_separator_survives_a_locale_less_environment() {
        assert!(
            !PANE_FORMAT.chars().any(|c| c.is_ascii_control()),
            "tmux would replace a control character with `_`: {PANE_FORMAT:?}"
        );
        assert_eq!(PANE_FORMAT.matches('|').count(), 7, "eight fields");
    }

    /// A human may put anything in a session name, including the separator.
    /// The label is allowed to look odd; the routing is not allowed to move.
    #[test]
    fn a_separator_in_a_session_name_does_not_shift_the_fields() {
        let panes = "/dev/ttys001|%0|claude|node|1|1|1|we|rd\n";
        let r = parse(By::Tty("/dev/ttys001"), panes, "we|rd\n", &agents()).unwrap();
        assert_eq!(r.name, "claude");
        assert!(r.is_agent, "the routing fields must still line up");
        assert!(!r.elsewhere);
        assert_eq!(r.window, "we|rd:1");
    }

    /// No projected list must never mean "everything is an agent".
    #[test]
    fn without_the_agent_table_nothing_is_an_agent() {
        let r = parse(By::Tty("/dev/ttys001"), PANES, "Main\n", &[]).unwrap();
        assert!(!r.is_agent);
    }
}
