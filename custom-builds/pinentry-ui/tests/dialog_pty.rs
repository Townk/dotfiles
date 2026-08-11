//! The dialog driven through a real pty.
//!
//! Everything here is about what reaches the buffer, which is the half of this
//! program a human validating the look cannot check: you cannot see from the
//! screen whether the four bullets in front of you are four characters or four
//! characters plus the tail of an escape sequence.
//!
//! The binary never prints the passphrase, so the assertions are on its report
//! — byte and character counts — which is the same discipline the design puts
//! on the harness as on the dialog.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// `openpty` and `ttyname` are both non-reentrant on macOS — the first fails
/// spuriously with a garbage errno under concurrency, and the second returns a
/// pointer into static storage that the next caller overwrites. Cargo runs
/// these examples on parallel threads, so allocating a terminal is serialised.
static PTY: Mutex<()> = Mutex::new(());

/// A dialog running on its own pty, with the screen it has painted so far.
///
/// The parent holds the slave fd open for the whole session. That is not
/// bookkeeping: with no slave holder, the master reports end-of-input in the
/// window before the child opens it, and the capture then stays empty no matter
/// what the dialog goes on to draw. A background reader thread hit exactly that
/// and made every example look like the dialog had never started.
struct Session {
    master: i32,
    slave: i32,
    child: Child,
    screen: Vec<u8>,
}

impl Session {
    /// The dialog handed the pty's path, which is how gpg-agent's `ttyname`
    /// reaches it in production.
    fn start(args: &[&str], cols: u16, rows: u16) -> Self {
        Self::spawn(args, cols, rows, false)
    }

    /// The dialog in its own session with the pty as its **controlling**
    /// terminal, opening `/dev/tty` for itself.
    ///
    /// The distinction is not academic. macOS `poll` answers correctly for a
    /// pty slave opened by path and wrongly for the controlling terminal, so
    /// every example above passed for the whole time Esc was broken in tmux.
    /// A terminal the child owns is the only way to reproduce that from a test.
    fn start_owning_the_terminal(args: &[&str], cols: u16, rows: u16) -> Self {
        Self::spawn(args, cols, rows, true)
    }

    fn spawn(args: &[&str], cols: u16, rows: u16, own_terminal: bool) -> Self {
        let mut master = 0;
        let mut slave = 0;
        let mut ws = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // Through a pointer because the parameter is not the same type on both
        // platforms: macOS declares it `*mut winsize`, Linux `*const`. A `&mut`
        // is required by one and a clippy error under the other; a raw pointer
        // coerces to either.
        let ws_ptr: *mut libc::winsize = &mut ws;
        let path = {
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
            assert_eq!(rc, 0, "openpty failed: {}", std::io::Error::last_os_error());

            let name = unsafe { libc::ttyname(slave) };
            assert!(!name.is_null(), "ttyname failed");
            unsafe { std::ffi::CStr::from_ptr(name) }
                .to_string_lossy()
                .into_owned()
        };

        let mut cmd = Command::new(env!("CARGO_BIN_EXE_pinentry-ui"));
        cmd.arg("--demo");
        if !own_terminal {
            cmd.arg("--tty").arg(&path);
        }
        cmd.args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        if own_terminal {
            // Between fork and exec: leave the test runner's session, then
            // claim the pty, which is what makes the child's `/dev/tty` resolve
            // to it. stdio stays on pipes so the report and the drawing do not
            // land in the same stream.
            unsafe {
                cmd.pre_exec(move || {
                    if libc::setsid() < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if libc::ioctl(slave, libc::TIOCSCTTY as _, 0) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }

        let child = cmd.spawn().expect("spawn");

        Self {
            master,
            slave,
            child,
            screen: Vec::new(),
        }
    }

    /// Collect whatever has been drawn, waiting up to `ms` for the first byte.
    /// Polling rather than blocking keeps the read from outliving the child.
    fn drain(&mut self, ms: i32) {
        loop {
            let mut pfd = libc::pollfd {
                fd: self.master,
                events: libc::POLLIN,
                revents: 0,
            };
            if unsafe { libc::poll(&mut pfd, 1, ms) } <= 0 {
                return;
            }
            let mut buf = [0u8; 4096];
            let n = unsafe { libc::read(self.master, buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                return;
            }
            self.screen.extend_from_slice(&buf[..n as usize]);
        }
    }

    fn drawn(&self) -> String {
        String::from_utf8_lossy(&self.screen).into_owned()
    }

    fn wait_for(&mut self, needle: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            self.drain(50);
            if self.drawn().contains(needle) {
                return;
            }
            // An early exit means the dialog refused to start, and its stderr
            // says why — better than five seconds of silence followed by a
            // timeout that blames the assertion.
            if let Ok(Some(status)) = self.child.try_wait() {
                let err = self.stderr();
                panic!("dialog exited {status} before drawing {needle:?}: {err}");
            }
        }
        panic!("dialog never drew {needle:?}; drew {:?}", self.drawn());
    }

    fn send(&mut self, bytes: &[u8]) {
        let n = unsafe { libc::write(self.master, bytes.as_ptr().cast(), bytes.len()) };
        assert_eq!(n, bytes.len() as isize, "short write to pty");
        // Each keystroke repaints; pacing them keeps the sequence deterministic
        // rather than racing the child's read loop.
        self.drain(20);
    }

    fn stderr(&mut self) -> String {
        let mut s = String::new();
        if let Some(mut e) = self.child.stderr.take() {
            let _ = e.read_to_string(&mut s);
        }
        s
    }

    /// Wait for the dialog to finish, draining as it goes so the last repaint
    /// is not lost, and return (stdout, exit code).
    fn finish(&mut self) -> (String, i32) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let code = loop {
            self.drain(50);
            match self.child.try_wait() {
                Ok(Some(status)) => break status.code().unwrap_or(-1),
                Ok(None) if Instant::now() < deadline => continue,
                _ => {
                    let _ = self.child.kill();
                    panic!("dialog never exited; drew {:?}", self.drawn());
                }
            }
        };
        self.drain(50);
        let mut out = String::new();
        if let Some(mut o) = self.child.stdout.take() {
            let _ = o.read_to_string(&mut out);
        }
        (out, code)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        unsafe {
            libc::close(self.master);
            libc::close(self.slave);
        }
    }
}

/// Runs the dialog, feeds it `keys` once it has painted, and returns
/// (stdout, exit code, everything the dialog drew).
fn run_dialog(args: &[&str], keys: &[&[u8]]) -> (String, i32, String) {
    let mut s = Session::start(args, 100, 30);
    // Keys sent before the terminal is in raw mode would be echoed and
    // line-buffered, so wait for the dialog to appear first.
    s.wait_for("Passphrase");
    for chunk in keys {
        s.send(chunk);
    }
    let (out, code) = s.finish();
    (out, code, s.drawn())
}

#[test]
fn accepts_a_typed_passphrase() {
    let (out, code, _) = run_dialog(&[], &[b"hunter2", b"\r"]);
    assert!(out.contains("7 bytes, 7 characters"), "got {out:?}");
    assert_eq!(code, 0);
}

#[test]
fn escape_sequences_never_reach_the_buffer() {
    // The bug this exists for: under `extended-keys always` a modified keypress
    // arrives as CSI, and a dialog that only asks "is this byte printable"
    // stores the tail. A typed "1234" reached gpg as "1234[27;8;49~" and the
    // signature failed as though the passphrase had been mistyped.
    let (out, code, _) = run_dialog(
        &[],
        &[
            b"1234",
            b"\x1b[A",        // Up
            b"\x1b[27;8;49~", // Ctrl-Alt-Shift-1 under extended keys
            b"\x1bOP",        // F1, in SS3 form
            b"\r",
        ],
    );
    assert!(out.contains("4 bytes, 4 characters"), "got {out:?}");
    assert_eq!(code, 0);
}

/// gpg-agent serialises every pinentry on one global lock, so a prompt nobody
/// answers does not just stall its own signature — it kills every request made
/// while it sits there. `SETTIMEOUT` is the release valve, and half-typing then
/// walking away must not defuse it.
#[test]
fn an_abandoned_dialog_gives_up_on_its_own() {
    let started = Instant::now();
    let (out, code, _) = run_dialog(&["--timeout-ms", "700"], &[b"half"]);
    assert!(out.contains("timed out"), "got {out:?}");
    assert_eq!(code, 1);
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the deadline should end this, not the harness"
    );
}

#[test]
fn backspace_removes_one_character() {
    let (out, _, _) = run_dialog(&[], &[b"abcd", b"\x7f", b"\r"]);
    assert!(out.contains("3 bytes, 3 characters"), "got {out:?}");
}

#[test]
fn backspace_removes_a_whole_multibyte_character() {
    // "aé" is three bytes. Popping one would leave a dangling lead byte the
    // human can neither see nor delete.
    let (out, _, _) = run_dialog(&[], &["aé".as_bytes(), b"\x7f", b"\r"]);
    assert!(out.contains("1 bytes, 1 characters"), "got {out:?}");
}

#[test]
fn ctrl_u_clears_the_field() {
    let (out, _, _) = run_dialog(&[], &[b"abcd", b"\x15", b"xy", b"\r"]);
    assert!(out.contains("2 bytes, 2 characters"), "got {out:?}");
}

#[test]
fn ctrl_c_cancels() {
    let (out, code, _) = run_dialog(&[], &[b"secret", b"\x03"]);
    assert!(out.contains("cancelled"), "got {out:?}");
    assert_eq!(code, 1);
}

#[test]
fn a_lone_escape_cancels() {
    let (out, code, _) = run_dialog(&[], &[b"ab", b"\x1b"]);
    assert!(out.contains("cancelled"), "got {out:?}");
    assert_eq!(code, 1);
}

/// The same key on a terminal the dialog owns — the shape it has in tmux, and
/// the one that was broken while the example above was green. Verified to fail
/// against the `poll` implementation and pass against `select`.
#[test]
fn a_lone_escape_cancels_on_a_controlling_terminal() {
    let mut s = Session::start_owning_the_terminal(&[], 100, 30);
    s.wait_for("Passphrase");
    s.send(b"ab");
    s.send(b"\x1b");
    let (out, code) = s.finish();
    assert!(out.contains("cancelled"), "got {out:?}");
    assert_eq!(code, 1);
}

/// The other half of the same decision: an arrow key is an escape SEQUENCE and
/// must not cancel. Guards against "fix Esc by treating every Esc as a cancel",
/// which would pass the example above and break every special key.
#[test]
fn an_arrow_key_does_not_cancel_on_a_controlling_terminal() {
    let mut s = Session::start_owning_the_terminal(&[], 100, 30);
    s.wait_for("Passphrase");
    s.send(b"ab");
    s.send(b"\x1b[A");
    s.send(b"\r");
    let (out, code) = s.finish();
    assert!(out.contains("2 bytes, 2 characters"), "got {out:?}");
    assert_eq!(code, 0);
}

#[test]
fn the_mask_shows_bullets_and_never_the_bytes() {
    let (_, _, drawn) = run_dialog(&[], &[b"abcdef", b"\r"]);
    assert!(
        drawn.contains("\u{2022}".repeat(6).as_str()),
        "mask missing from the draw"
    );
    for secret in ["abcdef", "abcde", "abcd"] {
        assert!(!drawn.contains(secret), "{secret:?} was drawn on screen");
    }
}

#[test]
fn the_error_line_is_drawn_when_set() {
    let (_, _, drawn) = run_dialog(&["--error", "Bad Passphrase (try 2 of 3)"], &[b"\x03"]);
    assert!(drawn.contains("Bad Passphrase (try 2 of 3)"));
}

#[test]
fn the_terminal_is_handed_back() {
    // Leaving the alternate screen is what puts the human's shell back the way
    // they left it; a dialog that skips it eats their scrollback.
    let (_, _, drawn) = run_dialog(&[], &[b"\x03"]);
    assert!(drawn.contains("\x1b[?1049h"), "never entered alt screen");
    assert!(drawn.contains("\x1b[?1049l"), "never left alt screen");
}

/// Replay a stream of cursor moves and text onto a grid, the way a terminal
/// would.
///
/// The assertions above all pass on the byte stream alone, and that is exactly
/// how the dialog once shipped drawing itself at row 45 of a 30-row screen:
/// every string it should emit was emitted, and every one of them scrolled off
/// the top before a human saw it. Checking the text is not checking the layout.
fn render(stream: &str, cols: usize, rows: usize) -> Vec<String> {
    let mut grid = vec![vec![' '; cols]; rows];
    let (mut r, mut c) = (0usize, 0usize);
    let bytes: Vec<char> = stream.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == '\x1b' {
            let rest: String = bytes[i..].iter().collect();
            if let Some(m) = regex_csi(&rest) {
                let (params, cmd, len) = m;
                if cmd == 'H' {
                    let p: Vec<usize> = params
                        .split(';')
                        .filter(|x| !x.is_empty())
                        .filter_map(|x| x.parse().ok())
                        .collect();
                    r = p.first().copied().unwrap_or(1).saturating_sub(1);
                    c = p.get(1).copied().unwrap_or(1).saturating_sub(1);
                }
                i += len;
                continue;
            }
            i += 1;
            continue;
        }
        match bytes[i] {
            '\n' => r += 1,
            '\r' => c = 0,
            ch => {
                assert!(r < rows, "drew at row {} of a {}-row screen", r + 1, rows);
                assert!(c < cols, "drew at col {} of a {}-col screen", c + 1, cols);
                grid[r][c] = ch;
                c += 1;
            }
        }
        i += 1;
    }
    grid.into_iter()
        .map(|row| row.into_iter().collect::<String>().trim_end().to_string())
        .collect()
}

/// The 1-based row and column the last repaint parked the cursor at — the final
/// `CSI r;c H` in the stream, since the dialog draws nothing after parking it.
fn final_cursor(stream: &str) -> (usize, usize) {
    let chars: Vec<char> = stream.chars().collect();
    let mut at = (1, 1);
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\x1b' {
            let rest: String = chars[i..].iter().collect();
            if let Some((params, 'H', len)) = regex_csi(&rest) {
                let p: Vec<usize> = params.split(';').filter_map(|x| x.parse().ok()).collect();
                at = (
                    p.first().copied().unwrap_or(1),
                    p.get(1).copied().unwrap_or(1),
                );
                i += len;
                continue;
            }
        }
        i += 1;
    }
    at
}

/// Minimal CSI matcher: returns (params, final byte, length consumed).
fn regex_csi(s: &str) -> Option<(String, char, usize)> {
    let mut chars = s.char_indices();
    chars.next()?; // ESC
    let (_, br) = chars.next()?;
    if br != '[' {
        return None;
    }
    let mut params = String::new();
    for (idx, ch) in chars {
        if ch.is_ascii_alphabetic() {
            return Some((params, ch, idx + 1));
        }
        params.push(ch);
    }
    None
}

#[test]
fn the_dialog_lands_on_screen_and_centred() {
    let (cols, rows) = (100usize, 30usize);
    let mut s = Session::start(&[], cols as u16, rows as u16);
    s.wait_for("Passphrase");
    s.send(b"abc");
    // Capture before accepting: the last repaint with the mask on screen is the
    // frame under test, and Enter clears the alternate screen behind it.
    let drawn = s.drawn();
    s.send(b"\r");
    let _ = s.finish();

    // `render` itself asserts that nothing was drawn outside the screen.
    let grid = render(&drawn, cols, rows);

    let top = grid
        .iter()
        .position(|l| l.contains('╭'))
        .expect("no top border on screen");
    let bottom = grid
        .iter()
        .rposition(|l| l.contains('╰'))
        .expect("no bottom border on screen");
    assert!(bottom > top, "border rows out of order");

    // Character positions, not byte offsets: the box-drawing glyphs are three
    // bytes each, so `find` would report a column three times too far right.
    let top_line: Vec<char> = grid[top].chars().collect();
    let left = top_line.iter().position(|&c| c == '╭').unwrap();
    let right = top_line.iter().rposition(|&c| c == '╮').unwrap();
    let width = right - left + 1;
    // The ai-playbook float geometry: 57 columns, and the demo's prompt plus
    // its four-line key block make 19 rows of it.
    assert_eq!(width, 57, "unexpected dialog width:\n{}", grid.join("\n"));
    assert_eq!(
        bottom - top + 1,
        19,
        "unexpected dialog height:\n{}",
        grid.join("\n")
    );

    // Centred within a column, which is all the arithmetic promises.
    let expected_left = (cols - width) / 2;
    assert!(
        left.abs_diff(expected_left) <= 1,
        "box at column {left}, expected about {expected_left}"
    );

    let body = grid[top..=bottom].join("\n");
    assert!(body.contains("Passphrase"), "prompt missing:\n{body}");
    assert!(
        body.contains("\u{2022}\u{2022}\u{2022}"),
        "mask missing:\n{body}"
    );

    // The chrome that makes this the ai-playbook widget rather than a box with
    // text in it: the ▓▓▓ title marker over its rule, the entry in its own
    // rounded box behind a key glyph, and the hints on the bottom border.
    assert!(
        body.contains("▓▓▓ Passphrase"),
        "title marker missing:\n{body}"
    );
    assert!(
        body.contains(&"━".repeat(51)),
        "title rule missing:\n{body}"
    );
    assert!(
        body.contains("\u{10f084} \u{2022}\u{2022}\u{2022}"),
        "entry should be a key glyph, one space, then the mask:\n{body}"
    );
    assert!(
        grid[bottom - 1].contains("submit") && grid[bottom - 1].contains("cancel"),
        "hints should sit directly above the bottom border:\n{body}"
    );

    // The key block: the user ID over a tree, last branch closed with ╰.
    assert!(
        body.contains(" ├ \u{f033e} 4096-bit RSA key"),
        "key facts missing:\n{body}"
    );
    assert!(
        body.contains(" ╰ \u{f00ed} created"),
        "tree should close on the last fact:\n{body}"
    );
}

#[test]
fn the_cursor_sits_on_the_entry_row_after_the_last_bullet() {
    // It sat one row low, on the box's bottom rule, because the row was counted
    // back from the end of the draw and the count was off by one.
    let (cols, rows) = (100usize, 30usize);
    let mut s = Session::start(&[], cols as u16, rows as u16);
    s.wait_for("Passphrase");
    s.send(b"abc");
    let drawn = s.drawn();
    s.send(b"\r");
    let _ = s.finish();

    let grid = render(&drawn, cols, rows);
    let (row, col) = final_cursor(&drawn);
    let entry = grid
        .iter()
        .position(|l| l.contains('\u{2022}'))
        .expect("no mask on screen");
    assert_eq!(
        row,
        entry + 1,
        "cursor row, with the mask on row {}:\n{}",
        entry + 1,
        grid.join("\n")
    );

    let row_chars: Vec<char> = grid[entry].chars().collect();
    let last = row_chars.iter().rposition(|&c| c == '\u{2022}').unwrap();
    assert_eq!(col, last + 2, "cursor should follow the last bullet");
}
