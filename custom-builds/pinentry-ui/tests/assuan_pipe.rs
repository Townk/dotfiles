//! The protocol half, driven the way gpg-agent drives it: Assuan on pipes.
//!
//! The dialog needs a human eye; this does not, and that asymmetry is the whole
//! reason the two halves were built in the order they were. Everything here is
//! an assertion about bytes on a wire.
//!
//! The invariant under test, in every example, is **one response per command**.
//! The shell filter this program replaces died of an off-by-one in exactly that
//! count: a single surplus `OK` is read by the agent as the answer to the next
//! command, and when that command is `GETPIN` the answer is an empty result —
//! "No passphrase given" — while a perfectly good dialog sits on screen. It
//! took a session to find, because nothing looks wrong.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::io::AsRawFd;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// `openpty` and `ttyname` are non-reentrant on macOS and cargo runs these on
/// parallel threads. Same discipline as the drawing tests.
static PTY: Mutex<()> = Mutex::new(());

struct Agent {
    child: Child,
    stdin: ChildStdin,
    out: BufReader<std::process::ChildStdout>,
    /// Master side of the terminal the dialog draws on, when there is one.
    master: Option<i32>,
    slave: Option<i32>,
}

impl Agent {
    /// A conversation with no terminal behind it — enough for everything that
    /// does not draw.
    fn start() -> Self {
        Self::spawn(None, &[])
    }

    /// A conversation whose `OPTION ttyname=` points at a real pty, so `GETPIN`
    /// can actually paint and be typed into.
    fn with_terminal() -> Self {
        Self::with_terminal_and_env(&[]).0
    }

    /// As above, and the pty's path, for tests that need to name it themselves.
    fn with_terminal_and_env(env: &[(&str, &str)]) -> (Self, String) {
        let mut master = 0;
        let mut slave = 0;
        let mut ws = libc::winsize {
            ws_row: 40,
            ws_col: 100,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let path = {
            let _held = PTY.lock().unwrap_or_else(|e| e.into_inner());
            let rc = unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut ws,
                )
            };
            assert_eq!(rc, 0, "openpty failed: {}", std::io::Error::last_os_error());
            let name = unsafe { libc::ttyname(slave) };
            assert!(!name.is_null(), "ttyname failed");
            unsafe { std::ffi::CStr::from_ptr(name) }
                .to_string_lossy()
                .into_owned()
        };
        let mut a = Self::spawn(Some((master, slave)), env);
        assert_eq!(a.cmd(&format!("OPTION ttyname={path}")), "OK");
        assert_eq!(a.cmd("OPTION ttytype=xterm-256color"), "OK");
        (a, path)
    }

    fn spawn(pty: Option<(i32, i32)>, env: &[(&str, &str)]) -> Self {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_pinentry-ui"));
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // Point both handover targets at nothing before the test says anything.
        // This is not tidiness: a `GETPIN` with no terminal now hands over to
        // pinentry-mac, and the default path is the real one — a test that
        // reaches it opens an actual dialog on the developer's screen and then
        // blocks until somebody dismisses it. Measured, once. A test that wants
        // a handover names its own stub and overrides these.
        cmd.env("PINENTRY_GUI_BIN", "/nonexistent/no-gui-during-tests")
            .env("PINENTRY_CURSES_BIN", "/nonexistent/no-curses-during-tests");
        for (k, v) in env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().expect("spawn");
        let stdin = child.stdin.take().expect("piped");
        let out = BufReader::new(child.stdout.take().expect("piped"));
        let mut a = Self {
            child,
            stdin,
            out,
            master: pty.map(|p| p.0),
            slave: pty.map(|p| p.1),
        };
        assert!(
            a.line().starts_with("OK Pleased to meet you, process "),
            "a pinentry greets the way gpg-agent expects"
        );
        a
    }

    /// One line of response, or a failure — never a hang. A test that blocks
    /// forever on a pinentry that stopped answering tells you nothing.
    ///
    /// **Waiting means draining the terminal too.** The dialog repaints in full
    /// after every keystroke — some 2.5 kB of escapes and colour — so a waiter
    /// that watches only the Assuan pipe fills the pty's output buffer and
    /// blocks the child inside a `write` it will never finish. It then looks
    /// exactly like a pinentry that stopped answering, which cost an hour of
    /// suspecting the program: the demo path, which has no protocol in it at
    /// all, failed the same way in the same harness.
    fn line(&mut self) -> String {
        let fd = self.out.get_ref().as_raw_fd();
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut sink = [0u8; 8192];
        while self.out.buffer().is_empty() {
            assert!(Instant::now() <= deadline, "no response within 10s");

            let mut set: libc::fd_set = unsafe { std::mem::zeroed() };
            let mut max = fd;
            unsafe { libc::FD_SET(fd, &mut set) };
            if let Some(m) = self.master {
                unsafe { libc::FD_SET(m, &mut set) };
                max = max.max(m);
            }
            let mut tv = libc::timeval {
                tv_sec: 0,
                tv_usec: 100_000,
            };
            let n = unsafe {
                libc::select(
                    max + 1,
                    &mut set,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut tv,
                )
            };
            if n <= 0 {
                continue;
            }
            if let Some(m) = self.master {
                if unsafe { libc::FD_ISSET(m, &set) } {
                    unsafe { libc::read(m, sink.as_mut_ptr().cast(), sink.len()) };
                }
            }
            if unsafe { libc::FD_ISSET(fd, &set) } {
                break;
            }
        }
        let mut s = String::new();
        self.out.read_line(&mut s).expect("read");
        s.trim_end_matches(['\r', '\n']).to_string()
    }

    fn send(&mut self, line: &str) {
        writeln!(self.stdin, "{line}").expect("write");
        self.stdin.flush().expect("flush");
    }

    fn cmd(&mut self, line: &str) -> String {
        self.send(line);
        self.line()
    }

    /// Type at the dialog once it has painted something.
    fn type_at_the_dialog(&mut self, keys: &[u8]) {
        let master = self.master.expect("no terminal on this conversation");
        let mut seen = 0;
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut buf = [0u8; 4096];
        while seen == 0 && Instant::now() < deadline {
            let mut set: libc::fd_set = unsafe { std::mem::zeroed() };
            unsafe { libc::FD_SET(master, &mut set) };
            let mut tv = libc::timeval {
                tv_sec: 0,
                tv_usec: 100_000,
            };
            let n = unsafe {
                libc::select(
                    master + 1,
                    &mut set,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut tv,
                )
            };
            if n > 0 {
                seen = unsafe { libc::read(master, buf.as_mut_ptr().cast(), buf.len()) }.max(0);
            }
        }
        assert!(
            seen > 0,
            "the dialog never painted, so there is nothing to type into"
        );
        let mut f = unsafe { <std::fs::File as std::os::unix::io::FromRawFd>::from_raw_fd(master) };
        f.write_all(keys).expect("type");
        f.flush().ok();
        std::mem::forget(f); // the fd belongs to the session, not to this File
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        for fd in [self.master, self.slave].into_iter().flatten() {
            unsafe { libc::close(fd) };
        }
    }
}

#[test]
fn it_greets_and_answers_getinfo_like_a_pinentry() {
    let mut a = Agent::start();
    assert_eq!(a.cmd("GETINFO flavor"), "D curses");
    assert_eq!(a.line(), "OK");
    assert_eq!(a.cmd("BYE"), "OK closing connection");
}

/// Count the responses, not their contents. This is the bug that killed the
/// filter, written down as an example.
#[test]
fn a_full_conversation_produces_exactly_one_response_per_command() {
    let mut a = Agent::start();
    let script = [
        "OPTION ttyname=/dev/ttys999",
        "OPTION lc-ctype=UTF-8",
        "SETDESC Please%20enter%20the%20passphrase",
        "SETPROMPT Passphrase",
        "SETERROR Bad%20Passphrase",
        "SETOK OK",
        "SETCANCEL Cancel",
        "SETTITLE pinentry",
        "NOP",
        "RESET",
    ];
    for cmd in script {
        assert_eq!(a.cmd(cmd), "OK", "{cmd} should answer once, with OK");
    }
    assert_eq!(a.cmd("BYE"), "OK closing connection");
}

/// No terminal is the GUI case, not a failure. A commit from an editor's
/// source-control panel has no `GPG_TTY` and no pane, so the whole conversation
/// goes to a pinentry that never wanted a terminal — carrying the state we
/// already absorbed, or it would draw an empty dialog.
#[test]
fn a_getpin_with_no_terminal_is_handed_to_the_gui() {
    let dir = std::env::temp_dir().join(format!("pui-gui-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let log = dir.join("told.log");
    let stub = dir.join("stub-gui");
    std::fs::write(
        &stub,
        format!(
            "#!/bin/sh\n: >{log}\n\
             printf 'user-data:%s\\n' \"${{PINENTRY_USER_DATA-<unset>}}\" >>{log}\n\
             echo \"OK Pleased to meet you, process $$\"\n\
             while IFS= read -r line; do\n\
             printf '%s\\n' \"$line\" >>{log}\n\
             case \"$line\" in\n\
             GETPIN) echo 'D from-the-gui'; echo OK ;;\n\
             BYE) echo 'OK closing connection'; exit 0 ;;\n\
             *) echo OK ;;\n\
             esac\n\
             done\n",
            log = log.display()
        ),
    )
    .expect("write stub");
    std::fs::set_permissions(
        &stub,
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o755),
    )
    .expect("chmod");

    let mut a = Agent::spawn(
        None,
        &[
            ("PINENTRY_GUI_BIN", &stub.to_string_lossy()),
            ("PINENTRY_USER_DATA", "USE_CURSES=1"),
        ],
    );
    assert_eq!(a.cmd("OPTION ttyname=/dev/does-not-exist"), "OK");
    assert_eq!(a.cmd("SETDESC Enter%20the%20passphrase"), "OK");
    assert_eq!(a.cmd("GETPIN"), "D from-the-gui");
    assert_eq!(a.line(), "OK");
    assert_eq!(a.cmd("BYE"), "OK closing connection");
    drop(a);

    // Everything we absorbed, minus the terminal that would not open — telling
    // the GUI about that is telling it to fail the way we just did. Measured
    // against the real pinentry-mac, which answered
    // `S ERROR mac.open_tty_for_read` instead of drawing anything.
    let told = std::fs::read_to_string(&log).expect("the stub was run");
    assert_eq!(
        told.lines().collect::<Vec<_>>(),
        vec![
            // Nor may it inherit USE_CURSES: pinentry-mac obeys that token by
            // re-execing a curses pinentry, sending the request back to the
            // terminal we just failed to find.
            "user-data:<unset>",
            "SETDESC Enter%20the%20passphrase",
            "GETPIN",
            "BYE"
        ],
        "the GUI has to be told what we were told, except where to draw"
    );
    std::fs::remove_dir_all(&dir).ok();
}

/// With no terminal *and* no GUI pinentry to borrow one from, say so. An error,
/// never a cancel: the human saw nothing, and reporting that they declined
/// would cost them a retry. (The harness points both handover targets at
/// nothing, so this is the default state.)
#[test]
fn with_no_terminal_and_no_gui_it_fails_rather_than_pretending() {
    let mut a = Agent::start();
    assert_eq!(a.cmd("OPTION ttyname=/dev/does-not-exist"), "OK");
    let reply = a.cmd("GETPIN");
    assert!(reply.starts_with("ERR "), "got {reply}");
    assert!(reply.contains("<Pinentry>"), "got {reply}");
    assert!(
        !reply.contains("83886179"),
        "must not be reported as a cancel: {reply}"
    );
}

/// End to end: gpg-agent's side is a pipe, the human's side is a terminal.
#[test]
fn a_typed_passphrase_comes_back_percent_encoded_then_ok() {
    let mut a = Agent::with_terminal();
    assert_eq!(a.cmd("SETDESC Enter%20the%20passphrase"), "OK");
    assert_eq!(a.cmd("SETPROMPT Passphrase"), "OK");
    a.send("GETPIN");
    a.type_at_the_dialog(b"ab%cd\r");
    assert_eq!(
        a.line(),
        "D ab%25cd",
        "must match pinentry-curses byte for byte"
    );
    assert_eq!(a.line(), "OK");
}

/// The trace has to be worth turning on and safe to leave on. Both halves are
/// asserted here: it records the conversation that decides where a prompt goes,
/// and it does not record the one thing that must never reach a file — a
/// passphrase, whole or in part.
#[test]
fn the_trace_records_the_routing_and_never_the_passphrase() {
    let log = std::env::temp_dir().join(format!("pui-trace-{}.log", std::process::id()));
    std::fs::remove_file(&log).ok();
    let (mut a, _) = Agent::with_terminal_and_env(&[("PINENTRY_UI_DEBUG", &log.to_string_lossy())]);
    assert_eq!(a.cmd("SETKEYINFO n/DEADBEEF"), "OK");
    assert_eq!(a.cmd("SETDESC Enter%20the%20passphrase"), "OK");
    a.send("GETPIN");
    a.type_at_the_dialog(b"correct-horse\r");
    assert_eq!(a.line(), "D correct-horse");
    assert_eq!(a.line(), "OK");
    drop(a);

    let trace = std::fs::read_to_string(&log).expect("the trace file");
    assert!(trace.contains("<- GETPIN"), "got {trace}");
    assert!(trace.contains("<- SETKEYINFO n/DEADBEEF"), "got {trace}");
    assert!(
        trace.contains("13 chars"),
        "the length, not the bytes: {trace}"
    );
    for leak in ["correct-horse", "correct", "horse"] {
        assert!(!trace.contains(leak), "{leak:?} reached the trace: {trace}");
    }
    std::fs::remove_file(&log).ok();
}

#[test]
fn escape_cancels_with_the_code_gpg_agent_expects() {
    let mut a = Agent::with_terminal();
    assert_eq!(a.cmd("SETDESC Enter%20the%20passphrase"), "OK");
    a.send("GETPIN");
    a.type_at_the_dialog(b"\x1b");
    assert_eq!(a.line(), "ERR 83886179 Operation cancelled <Pinentry>");
}

/// The float, driven through stubs for the two things it talks to: tmux, which
/// says whose pane asked, and the popup helper, which opens the pane.
///
/// The example is about the exit path, and it is here because the real thing
/// failed it. `Drop` closes the float on every exit that unwinds, and
/// gpg-agent killing its pinentry is not one of those: measured, the holder
/// outlived the dialog and left a float on screen that swallowed every
/// keystroke and answered to nothing — strictly worse than the invisible
/// prompt this program was written to fix.
#[test]
fn a_killed_pinentry_still_takes_its_float_with_it() {
    let dir = std::env::temp_dir().join(format!("pui-float-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("bin")).expect("bin dir");
    std::fs::create_dir_all(dir.join(".local/libexec")).expect("libexec");
    std::fs::create_dir_all(dir.join(".config/mux")).expect("config");
    std::fs::write(dir.join(".config/mux/agent-procs.data"), "claude\n").expect("agent list");

    let exec = |p: &std::path::Path, body: &str| {
        std::fs::write(p, body).expect("write stub");
        std::fs::set_permissions(
            p,
            <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o755),
        )
        .expect("chmod");
    };

    // Spawn first: the stubs have to name the pty, and the pty only exists once
    // the session holding it does. Nothing reads them until GETPIN.
    let tmux = dir.join("bin/tmux");
    let (mut a, path) = Agent::with_terminal_and_env(&[
        ("HOME", &dir.to_string_lossy()),
        ("MUX_TMUX_BIN", &tmux.to_string_lossy()),
    ]);

    // The pane line goes through printf as an ARGUMENT, never as the format
    // string: `%9` is a field width, and the pane id would silently disappear
    // into it. Fields are `|`-separated, matching what the real tmux emits in
    // an environment with no locale — see `PANE_FORMAT`.
    exec(
        &tmux,
        &format!(
            "#!/bin/sh\ncase \"$1\" in\n\
             list-panes) printf '%s\\n' '{path}|%9|claude|node|1|1|1|Main' ;;\n\
             list-clients) echo Main ;;\n\
             esac\nexit 0\n"
        ),
    );
    // Prints the float's tty and the pid of something holding it open, exactly
    // as the real helper does — and the same pty, so the dialog has somewhere
    // real to draw. A bare `sleep` dies on USR1 by default, which is the signal
    // the real holder installs a handler for.
    let holder_pid_file = dir.join("holder.pid");
    // `>/dev/null` on the sleeper is load-bearing, not tidiness: a background
    // job inherits this script's stdout, and the caller reads that pipe to
    // end-of-file. Leave it attached and the holder keeps it open for its whole
    // life, so opening the float appears to hang for sixty seconds. The real
    // helper redirects every background job for the same reason.
    exec(
        &dir.join(".local/libexec/pinentry-mux-popup"),
        &format!(
            "#!/bin/sh\nsleep 60 >/dev/null 2>&1 &\necho $! >{pid}\necho \"{path} $!\"\n",
            pid = holder_pid_file.display()
        ),
    );

    assert_eq!(a.cmd("SETDESC Enter%20the%20passphrase"), "OK");
    a.send("GETPIN");
    // Wait for the dialog to paint, which means the float is up.
    a.type_at_the_dialog(b"");

    let holder: i32 = std::fs::read_to_string(&holder_pid_file)
        .expect("the float helper ran")
        .trim()
        .parse()
        .expect("a pid");
    assert_eq!(
        unsafe { libc::kill(holder, 0) },
        0,
        "the holder should be alive while the dialog is up"
    );

    unsafe { libc::kill(a.child.id() as i32, libc::SIGTERM) };
    std::thread::sleep(Duration::from_millis(600));
    assert_eq!(
        unsafe { libc::kill(holder, 0) },
        -1,
        "a killed pinentry must take the float with it, or the pane is stuck"
    );

    drop(a);
    std::fs::remove_dir_all(&dir).ok();
}

/// The handover. Both halves matter: the stock pinentry has to be told
/// everything we were told, and the agent must not see one extra line for it.
#[test]
fn an_unimplemented_verb_is_handed_over_in_step() {
    let dir = std::env::temp_dir().join(format!("pui-delegate-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let log = dir.join("told.log");
    let stub = dir.join("stub-pinentry");
    std::fs::write(
        &stub,
        format!(
            "#!/bin/sh\n: >{log}\n\
             echo \"OK Pleased to meet you, process $$\"\n\
             while IFS= read -r line; do\n\
             printf '%s\\n' \"$line\" >>{log}\n\
             case \"$line\" in\n\
             BYE) echo 'OK closing connection'; exit 0 ;;\n\
             *) echo OK ;;\n\
             esac\n\
             done\n",
            log = log.display()
        ),
    )
    .expect("write stub");
    std::fs::set_permissions(
        &stub,
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o755),
    )
    .expect("chmod");

    let mut a = Agent::spawn(None, &[("PINENTRY_CURSES_BIN", &stub.to_string_lossy())]);
    assert_eq!(a.cmd("SETDESC hello%20world"), "OK");
    assert_eq!(a.cmd("SETPROMPT PIN"), "OK");
    // Ours would have been the greeting plus two OKs; from here the answers are
    // the child's, and there is still exactly one per command.
    assert_eq!(a.cmd("CONFIRM"), "OK");
    assert_eq!(a.cmd("BYE"), "OK closing connection");
    drop(a);

    let told = std::fs::read_to_string(&log).expect("the stub was run");
    assert_eq!(
        told.lines().collect::<Vec<_>>(),
        vec!["SETDESC hello%20world", "SETPROMPT PIN", "CONFIRM", "BYE"],
        "the state we absorbed has to be replayed, or it draws an empty dialog"
    );
    std::fs::remove_dir_all(&dir).ok();
}
