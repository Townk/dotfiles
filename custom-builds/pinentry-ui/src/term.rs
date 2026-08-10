//! The terminal: opening it, owning its mode, and giving it back.
//!
//! Every exit path restores the terminal, including the ones that are not
//! returns. A dialog that dies leaving a pty in raw mode with echo off hands
//! back a shell that looks broken, and this program's whole reason for existing
//! is that a terminal nobody can use is worse than a prompt nobody can see.

use std::io;
use std::os::unix::io::RawFd;
use std::ptr::addr_of_mut;
use std::sync::atomic::{AtomicI32, Ordering};

/// Set once the terminal has been put in raw mode, so the signal handlers know
/// whether there is anything to undo. -1 means "nothing to restore".
static RESTORE_FD: AtomicI32 = AtomicI32::new(-1);
static mut SAVED_TERMIOS: Option<libc::termios> = None;

const ALT_SCREEN_ON: &[u8] = b"\x1b[?1049h";
const ALT_SCREEN_OFF: &[u8] = b"\x1b[?1049l";
const CURSOR_SHOW: &[u8] = b"\x1b[?25h";

pub struct Tty {
    fd: RawFd,
    raw: bool,
}

impl Tty {
    /// Opens `path`, or the controlling terminal when none is given.
    ///
    /// `O_NOCTTY` matters: this process is a child of gpg-agent and must not
    /// acquire a controlling terminal as a side effect of drawing on one.
    pub fn open(path: Option<&str>) -> io::Result<Self> {
        let path = path.unwrap_or("/dev/tty");
        let c_path = std::ffi::CString::new(path)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "tty path has a NUL"))?;
        // SAFETY: a valid NUL-terminated path and constant flags.
        let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDWR | libc::O_NOCTTY) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { fd, raw: false })
    }

    /// Columns then rows — width first, matching `Dialog::size` so the two
    /// cannot be mixed up. They were once: this returned rows first, the caller
    /// read it as columns, and the dialog was drawn at row 45 of a 30-row
    /// screen, where everything scrolled away except the final line.
    ///
    /// Falls back to a conservative 80x24 when the ioctl says nothing useful.
    pub fn size(&self) -> (u16, u16) {
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        // SAFETY: ws is a correctly sized winsize for TIOCGWINSZ.
        let rc = unsafe { libc::ioctl(self.fd, libc::TIOCGWINSZ, &mut ws) };
        if rc == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            (ws.ws_col, ws.ws_row)
        } else {
            (80, 24)
        }
    }

    /// Raw mode, the alternate screen, and the signal handlers that undo both.
    ///
    /// The alternate screen is not decoration: for the in-place prompt this
    /// dialog is drawn over somebody's working shell, and leaving their
    /// scrollback as we found it is the difference between a prompt and a mess.
    pub fn enter(&mut self) -> io::Result<()> {
        let mut termios: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: fd is an open terminal; termios is correctly sized.
        if unsafe { libc::tcgetattr(self.fd, &mut termios) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: single-threaded, and written before any handler is installed.
        unsafe { *addr_of_mut!(SAVED_TERMIOS) = Some(termios) };

        let mut raw = termios;
        // SAFETY: raw is a valid termios owned by us.
        unsafe { libc::cfmakeraw(&mut raw) };
        // ISIG stays off (cfmakeraw clears it) on purpose: Ctrl-C must arrive as
        // a byte we decide about, not as a signal that kills us mid-dialog with
        // the terminal still raw.
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        // SAFETY: fd is an open terminal; raw is a valid termios.
        if unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }

        self.raw = true;
        RESTORE_FD.store(self.fd, Ordering::SeqCst);
        install_signal_handlers();
        self.write(ALT_SCREEN_ON)?;
        Ok(())
    }

    pub fn write(&self, bytes: &[u8]) -> io::Result<()> {
        let mut written = 0;
        while written < bytes.len() {
            // SAFETY: writing a subslice of a live buffer to our own fd.
            let n = unsafe {
                libc::write(
                    self.fd,
                    bytes[written..].as_ptr().cast(),
                    bytes.len() - written,
                )
            };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            written += n as usize;
        }
        Ok(())
    }

    /// One byte, or `None` at end of input.
    pub fn read_byte(&self) -> io::Result<Option<u8>> {
        let mut b = 0u8;
        loop {
            // SAFETY: reading one byte into a live local.
            let n = unsafe { libc::read(self.fd, (&mut b as *mut u8).cast(), 1) };
            if n == 1 {
                return Ok(Some(b));
            }
            if n == 0 {
                return Ok(None);
            }
            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }

    /// True when another byte arrives within `ms`.
    ///
    /// This exists for one job: telling a lone `Esc` apart from the start of an
    /// escape sequence. Under `extended-keys always` almost every special key
    /// arrives as `CSI ... ~`, so without the distinction either Esc cannot
    /// cancel or every arrow key does.
    ///
    /// `select`, not `poll`, and that is not a style choice. On macOS `poll` on
    /// `/dev/tty` returns POLLNVAL rather than POLLIN — measured: after a lone
    /// Esc it returned `revents=32` where select correctly reported nothing
    /// readable. The first version tested `poll(...) > 0`, counted that
    /// POLLNVAL as "more input", and blocked in the escape-sequence branch, so
    /// Esc silently did nothing. The pty suite missed it because a pty slave
    /// opened by path polls correctly; only the controlling terminal is broken.
    /// `a_lone_escape_cancels_on_a_controlling_terminal` now covers that case
    /// and was checked to fail if this reverts to `poll`.
    pub fn wait_readable(&self, ms: i32) -> bool {
        let mut set: libc::fd_set = unsafe { std::mem::zeroed() };
        let mut tv = libc::timeval {
            tv_sec: (ms / 1000) as libc::time_t,
            tv_usec: ((ms % 1000) * 1000) as libc::suseconds_t,
        };
        // SAFETY: a zeroed fd_set is empty, and fd is well below FD_SETSIZE.
        unsafe {
            libc::FD_SET(self.fd, &mut set);
            libc::select(
                self.fd + 1,
                &mut set,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut tv,
            ) > 0
        }
    }
}

impl Drop for Tty {
    fn drop(&mut self) {
        if self.raw {
            let _ = self.write(CURSOR_SHOW);
            let _ = self.write(ALT_SCREEN_OFF);
            // SAFETY: written once in `enter`, single-threaded.
            if let Some(saved) = unsafe { *addr_of_mut!(SAVED_TERMIOS) } {
                // SAFETY: fd is still open here; saved came from this terminal.
                unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, &saved) };
            }
            RESTORE_FD.store(-1, Ordering::SeqCst);
        }
        // SAFETY: our own fd, closed exactly once.
        unsafe { libc::close(self.fd) };
    }
}

/// Also called the moment a float is opened, which is before there is a
/// terminal to restore: gpg-agent can kill a pinentry at any point, and a float
/// whose owner died between opening it and drawing on it is a pane nobody can
/// reclaim.
pub fn install_signal_handlers() {
    // SIGINT belongs here even though Ctrl-C never arrives as a signal: raw
    // mode clears ISIG, so the dialog reads 0x03 as a byte. This is for an
    // interrupt from somewhere else — and it was in the retired filter's trap
    // list for the same reason.
    for sig in [libc::SIGTERM, libc::SIGHUP, libc::SIGQUIT, libc::SIGINT] {
        // SAFETY: installing a handler that only makes async-signal-safe calls.
        unsafe { libc::signal(sig, handle_fatal_signal as *const () as libc::sighandler_t) };
    }
}

/// Restore and leave. `Drop` cannot run for a signal, so this is the same
/// teardown written in the subset of calls a handler is allowed to make —
/// `write`, `tcsetattr`, `kill` and `_exit`.
///
/// Closing the float here is not belt-and-braces. It was measured: send this
/// process a TERM with a dialog up and, without these three lines, the holder
/// outlives it and the float stays on screen ignoring every signal a keystroke
/// can send — a terminal nobody can reclaim, which is a worse failure than the
/// invisible prompt this whole project exists to fix. The retired shell filter
/// needed a watcher subshell for the same reason; owning both ends only removes
/// the problem for the exits that unwind.
extern "C" fn handle_fatal_signal(_sig: libc::c_int) {
    let holder = crate::float::holder_pid();
    if holder > 0 {
        // SAFETY: kill is async-signal-safe; a pid that has already gone is an
        // ESRCH we do not care about.
        unsafe { libc::kill(holder, libc::SIGUSR1) };
    }

    let fd = RESTORE_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        // SAFETY: async-signal-safe calls on an fd that was open when the
        // handler was installed, using state written before installation.
        unsafe {
            libc::write(fd, CURSOR_SHOW.as_ptr().cast(), CURSOR_SHOW.len());
            libc::write(fd, ALT_SCREEN_OFF.as_ptr().cast(), ALT_SCREEN_OFF.len());
            if let Some(saved) = *addr_of_mut!(SAVED_TERMIOS) {
                libc::tcsetattr(fd, libc::TCSANOW, &saved);
            }
        }
    }
    // SAFETY: _exit performs no cleanup and is async-signal-safe by definition.
    unsafe { libc::_exit(130) };
}
