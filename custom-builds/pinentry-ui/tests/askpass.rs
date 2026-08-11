//! The askpass lane, end to end: prompt in, secret out.
//!
//! Two paths, and they fail in opposite directions if untested. With a pane the
//! dialog goes into a float and the secret comes back on stdout; with no pane
//! the whole thing is handed to a GUI pinentry over Assuan. Neither can be
//! judged from the Assuan suite, because in this lane there is no Assuan on
//! stdin at all.

use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// `openpty` and `ttyname` are not thread-safe on macOS, and cargo runs these
/// in one process. Serialising the allocation is cheaper than a flaky suite.
static PTY: Mutex<()> = Mutex::new(());

fn exec(path: &Path, body: &str) {
    std::fs::write(path, body).expect("write stub");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
}

/// A scratch HOME with the stubs the float path reaches for.
struct Sandbox {
    dir: std::path::PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("pui-askpass-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(dir.join("bin")).expect("bin");
        std::fs::create_dir_all(dir.join(".local/libexec")).expect("libexec");
        std::fs::create_dir_all(dir.join(".config/mux")).expect("config");
        Self { dir }
    }

    fn path(&self, rel: &str) -> std::path::PathBuf {
        self.dir.join(rel)
    }

    fn home(&self) -> String {
        self.dir.to_string_lossy().into_owned()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.dir).ok();
    }
}

fn open_pty() -> (i32, i32, String) {
    let (mut master, mut slave) = (0, 0);
    let mut ws = libc::winsize {
        ws_row: 40,
        ws_col: 100,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // See dialog_pty.rs: the winsize parameter is `*mut` on macOS and `*const`
    // on Linux, and only a raw pointer satisfies both.
    let ws_ptr: *mut libc::winsize = &mut ws;
    let _held = PTY.lock().unwrap_or_else(|e| e.into_inner());
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            ws_ptr,
        )
    };
    assert_eq!(rc, 0, "openpty: {}", std::io::Error::last_os_error());
    // Close-on-exec, or the child inherits both ends. That is not untidiness:
    // holding the master itself means the pty never closes when this process
    // dies, so a child left over from a failed test blocks forever writing a
    // repaint nobody will read — including inside its own fatal-signal
    // handler, which then cannot exit either. Measured: three such processes
    // survived repeated SIGTERM, each holding /dev/ptmx. The child does not
    // need either fd; it opens the slave by path.
    for fd in [master, slave] {
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    let name = unsafe { libc::ttyname(slave) };
    assert!(!name.is_null(), "ttyname failed");
    let path = unsafe { std::ffi::CStr::from_ptr(name) }
        .to_string_lossy()
        .into_owned();
    (master, slave, path)
}

/// A tmux that knows nothing, kept on disk for the whole run.
///
/// Removing `TMUX_PANE` is no longer enough to mean "no pane". The helper now
/// recovers a pane from its ancestors' tty when the variable is missing, and
/// the ancestors of a `cargo test` run are a real shell in a real pane — so
/// without this, the two no-pane tests would find the developer's own session
/// and open a float on their screen. `MUX_TMUX_BIN` alone will not do it
/// either: an unusable value falls through to the search path, which finds the
/// real tmux. It has to be a tmux that runs and reports nothing.
fn no_tmux() -> String {
    static STUB: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();
    STUB.get_or_init(|| {
        let p = std::env::temp_dir().join(format!("pui-no-tmux-{}", std::process::id()));
        exec(&p, "#!/bin/sh\nexit 0\n");
        p
    })
    .to_string_lossy()
    .into_owned()
}

fn askpass(prompt: &str, env: &[(&str, &str)]) -> Child {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_pinentry-ui"));
    cmd.arg("--askpass")
        .arg(prompt)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        // Same guard as the Assuan suite: never let a test reach the real
        // pinentry-mac, which opens a dialog on the developer's screen and
        // waits for a human who is not there.
        .env("PINENTRY_GUI_BIN", "/nonexistent/no-gui-during-tests")
        .env("MUX_TMUX_BIN", no_tmux())
        .env_remove("TMUX_PANE");
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.spawn().expect("spawn")
}

/// The master end, drained continuously by a thread of its own.
///
/// The draining is the whole reason this is a type. The dialog repaints in full
/// after *every* keystroke — about 1.3KB a time — so a test that types a
/// seven-character passphrase without reading fills the pty's output buffer
/// around the fourth character. The child then blocks writing its repaint,
/// never reaches its next read, and the test waits forever for a process that
/// is waiting for it. Measured: typing only `Enter` always passed, and anything
/// with characters in front of it always hung.
struct Screen {
    master: i32,
    slave: i32,
    seen: std::sync::Arc<Mutex<usize>>,
}

impl Screen {
    fn new() -> (Self, String) {
        let (master, slave, path) = open_pty();
        let seen = std::sync::Arc::new(Mutex::new(0usize));
        let counter = std::sync::Arc::clone(&seen);
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                let n = unsafe { libc::read(master, buf.as_mut_ptr().cast(), buf.len()) };
                if n <= 0 {
                    return;
                }
                *counter.lock().unwrap_or_else(|e| e.into_inner()) += n as usize;
            }
        });
        (
            Self {
                master,
                slave,
                seen,
            },
            path,
        )
    }

    /// Block until the dialog has put something on screen.
    fn painted(&self) -> bool {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if *self.seen.lock().unwrap_or_else(|e| e.into_inner()) > 0 {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }

    fn type_at(&self, keys: &[u8]) {
        let n = unsafe { libc::write(self.master, keys.as_ptr().cast(), keys.len()) };
        assert!(n > 0, "could not type at the dialog");
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        // Closing the slave ends the drain thread's read.
        unsafe { libc::close(self.slave) };
        unsafe { libc::close(self.master) };
    }
}

fn finish(mut child: Child) -> (String, i32) {
    let mut out = String::new();
    child
        .stdout
        .take()
        .expect("piped")
        .read_to_string(&mut out)
        .expect("read stdout");
    let status = child.wait().expect("wait");
    (out, status.code().unwrap_or(-1))
}

/// The stubs the float path needs: a tmux that knows one pane, and a popup
/// helper that hands back the same pty so the dialog has somewhere real to
/// draw.
fn stub_float(sb: &Sandbox, pty: &str) {
    std::fs::write(sb.path(".config/mux/agent-procs.data"), "claude\n").expect("agents");
    exec(
        &sb.path("bin/tmux"),
        &format!(
            "#!/bin/sh\ncase \"$1\" in\n\
             list-panes) printf '%s\\n' '{pty}|%9|claude|node|1|1|1|Main' ;;\n\
             list-clients) echo Main ;;\n\
             esac\nexit 0\n"
        ),
    );
    // The backgrounded sleeper must not inherit stdout: the caller reads this
    // script's output to end-of-file, and a job holding the pipe open makes
    // opening the float look like a sixty-second hang.
    exec(
        &sb.path(".local/libexec/pinentry-mux-popup"),
        &format!("#!/bin/sh\nsleep 60 >/dev/null 2>&1 &\necho \"{pty} $!\"\n"),
    );
}

/// The contract sudo relies on: exactly what was typed, one newline, exit 0.
#[test]
fn what_is_typed_in_the_float_comes_back_on_stdout() {
    let sb = Sandbox::new("float");
    let (screen, pty) = Screen::new();
    stub_float(&sb, &pty);

    let child = askpass(
        "Password:",
        &[
            ("HOME", &sb.home()),
            ("MUX_TMUX_BIN", &sb.path("bin/tmux").to_string_lossy()),
            ("TMUX_PANE", "%9"),
        ],
    );

    assert!(screen.painted(), "the dialog never painted");
    screen.type_at(b"hunter2\r");

    let (out, code) = finish(child);
    assert_eq!(out, "hunter2\n", "sudo reads one line and strips it");
    assert_eq!(code, 0);
}

/// A dismissed dialog must not look like an empty password. sudo reports "no
/// password was provided" for a non-zero exit and retries; a bare newline would
/// be an authentication failure instead.
#[test]
fn a_cancelled_dialog_writes_nothing_and_fails() {
    let sb = Sandbox::new("cancel");
    let (screen, pty) = Screen::new();
    stub_float(&sb, &pty);

    let child = askpass(
        "Password:",
        &[
            ("HOME", &sb.home()),
            ("MUX_TMUX_BIN", &sb.path("bin/tmux").to_string_lossy()),
            ("TMUX_PANE", "%9"),
        ],
    );

    assert!(screen.painted());
    screen.type_at(b"secret\x1b"); // typed, then thought better of it

    let (out, code) = finish(child);
    assert_eq!(out, "", "nothing typed may leak on the way out");
    assert_ne!(code, 0);
}

/// No pane means no float, and this lane has no terminal of its own to fall
/// back to — so the conversation goes to a GUI pinentry, which has to be told
/// what to say and must not inherit the token that would send it to a curses
/// one.
#[test]
fn with_no_pane_the_gui_is_asked_instead() {
    let sb = Sandbox::new("gui");
    let log = sb.path("told.log");
    let stub = sb.path("stub-gui");
    exec(
        &stub,
        &format!(
            "#!/bin/sh\n: >{log}\n\
             printf 'user-data:%s\\n' \"${{PINENTRY_USER_DATA-<unset>}}\" >>{log}\n\
             echo \"OK Pleased to meet you, process $$\"\n\
             while IFS= read -r line; do\n\
             printf '%s\\n' \"$line\" >>{log}\n\
             case \"$line\" in\n\
             GETPIN) echo 'D from%25the%25gui'; echo OK ;;\n\
             BYE) echo 'OK closing connection'; exit 0 ;;\n\
             *) echo OK ;;\n\
             esac\n\
             done\n",
            log = log.display()
        ),
    );

    let child = askpass(
        "Password:",
        &[
            ("HOME", &sb.home()),
            ("PINENTRY_GUI_BIN", &stub.to_string_lossy()),
            ("PINENTRY_USER_DATA", "USE_CURSES=1"),
        ],
    );
    let (out, code) = finish(child);
    assert_eq!(out, "from%the%gui\n", "percent-decoded, exactly once");
    assert_eq!(code, 0);

    let told = std::fs::read_to_string(&log).expect("the stub ran");
    let lines: Vec<&str> = told.lines().collect();
    assert_eq!(
        lines[0], "user-data:<unset>",
        "USE_CURSES would send the GUI back to a terminal that is not there"
    );
    assert!(
        lines.contains(&"SETDESC Password:"),
        "the GUI has to be told what to ask: {lines:?}"
    );
    assert!(lines.contains(&"GETPIN"), "{lines:?}");
}

/// Nothing above us will ever end this. sudo waits for a helper for as long as
/// the helper takes — measured, twelve seconds for a helper that sleeps twelve
/// — so an unanswered prompt would hold its caller open forever, and the caller
/// is not always a person: Homebrew runs `sudo -A` in the middle of an
/// unattended update.
#[test]
fn an_unanswered_float_gives_the_caller_its_refusal_back() {
    let sb = Sandbox::new("deadline-float");
    let (screen, pty) = Screen::new();
    stub_float(&sb, &pty);

    let started = Instant::now();
    let child = askpass(
        "Password:",
        &[
            ("HOME", &sb.home()),
            ("MUX_TMUX_BIN", &sb.path("bin/tmux").to_string_lossy()),
            ("TMUX_PANE", "%9"),
            ("PINENTRY_UI_DEADLINE_MS", "400"),
        ],
    );

    assert!(screen.painted(), "the dialog never painted");
    let (out, code) = finish(child); // and nobody types
    assert_eq!(out, "", "an expiry is a refusal, not an empty password");
    assert_ne!(code, 0);
    assert!(
        started.elapsed() < Duration::from_secs(20),
        "it waited far past its deadline"
    );
}

/// The same promise on the rung where it matters most: a GUI dialog can be on a
/// desktop the person driving the machine cannot see at all. Our own dialog's
/// deadline cannot reach inside pinentry-mac, so it is enforced on the process.
#[test]
fn a_gui_that_never_answers_is_closed_rather_than_waited_on() {
    let sb = Sandbox::new("deadline-gui");
    let stub = sb.path("stub-mute-gui");
    // Greets, takes every command, and simply never answers GETPIN.
    exec(
        &stub,
        "#!/bin/sh\necho 'OK greetings'\n\
         while IFS= read -r line; do\n\
         case \"$line\" in\n\
         GETPIN) while :; do sleep 1; done ;;\n\
         *) echo OK ;;\n\
         esac\n\
         done\n",
    );

    let started = Instant::now();
    let child = askpass(
        "Password:",
        &[
            ("HOME", &sb.home()),
            ("PINENTRY_GUI_BIN", &stub.to_string_lossy()),
            ("PINENTRY_UI_DEADLINE_MS", "400"),
        ],
    );
    let (out, code) = finish(child);
    assert_eq!(out, "");
    assert_ne!(code, 0);
    assert!(
        started.elapsed() < Duration::from_secs(20),
        "the GUI held the caller past its deadline"
    );
}

/// Homebrew keeps `SUDO_ASKPASS` and `HOME` and drops everything else of ours,
/// so no variable can turn tracing on for a helper it invoked. A file can:
/// measured, the first attempt to trace that call reported "helper never ran"
/// when it had run perfectly, because the variable naming the log was stripped
/// on the way in.
#[test]
fn a_caller_that_keeps_no_variables_can_still_be_traced() {
    let sb = Sandbox::new("marker");
    std::fs::create_dir_all(sb.path(".cache")).expect("cache");
    let trace = sb.path(".cache/pinentry-ui.trace");
    std::fs::write(&trace, "").expect("touch the marker");

    // Note what is *not* passed: no PINENTRY_UI_DEBUG, no PINENTRY_USER_DATA.
    let child = askpass("Password:", &[("HOME", &sb.home())]);
    let (_, code) = finish(child);
    assert_ne!(code, 0, "no pane and no GUI, so it should refuse");

    let logged = std::fs::read_to_string(&trace).expect("read the trace");
    assert!(
        logged.contains("starting"),
        "the marker did not turn tracing on: {logged:?}"
    );
    assert!(
        logged.contains("asking the GUI"),
        "and a trace has to say where the request went: {logged:?}"
    );
}

/// With nowhere to draw and no GUI to borrow, say nothing and fail. Printing a
/// blank line here would be read as an empty password.
#[test]
fn with_no_pane_and_no_gui_it_stays_quiet() {
    let sb = Sandbox::new("nothing");
    let child = askpass("Password:", &[("HOME", &sb.home())]);
    let (out, code) = finish(child);
    assert_eq!(out, "");
    assert_ne!(code, 0);
}
