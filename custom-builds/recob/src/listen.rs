//! Endpoints and launch shape (§3): binding both listeners, adopting them from
//! socket activation, the trusted socket's permissions, and the accept loops.
//!
//! Endpoint identity is a property of *which listener accepted the connection*,
//! established here at bind time and never derived from request data — which is
//! what retires `CLIPBOARD_BRIDGE_ENDPOINT` (§3).

use std::fs;
use std::io;
use std::mem::ManuallyDrop;
use std::net::TcpListener;
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::log;
use crate::session::{self, Ctx};

/// Which listener accepted a connection (§3). `local`-tier operations are the
/// ones this distinction exists for; in Phase 1 it reaches the `endpoint` field
/// of the capabilities frame (§5.1) and the recorder's log line (§11.1).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Endpoint {
    Public,
    Trusted,
}

impl Endpoint {
    pub fn as_str(self) -> &'static str {
        match self {
            Endpoint::Public => "public",
            Endpoint::Trusted => "trusted",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "public" => Some(Endpoint::Public),
            "trusted" => Some(Endpoint::Trusted),
            _ => None,
        }
    }
}

pub const DEFAULT_PUBLIC_PORT: u16 = 2489;

pub fn default_trusted_socket() -> PathBuf {
    let mut home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    home.push(".local/state/cb.sock");
    home
}

#[derive(Debug, Default)]
pub struct Bound {
    pub public: Option<TcpListener>,
    pub trusted: Option<UnixListener>,
}

// mode_t is 16 bits on macOS and 32 on Linux; passing the wrong width is an ABI
// mismatch rather than a compile error, so it is spelled out per platform.
#[cfg(target_os = "macos")]
type ModeT = u16;
#[cfg(not(target_os = "macos"))]
type ModeT = u32;

extern "C" {
    fn umask(mask: ModeT) -> ModeT;
}

/// Sets the process umask and restores it on drop. Process-global, which is
/// safe here because binding happens once at startup, before any accept loop
/// exists to race with it.
struct UmaskGuard(ModeT);

impl UmaskGuard {
    fn set(mask: ModeT) -> Self {
        UmaskGuard(unsafe { umask(mask) })
    }
}

impl Drop for UmaskGuard {
    fn drop(&mut self) {
        unsafe { umask(self.0) };
    }
}

pub fn mode_of(path: &Path) -> io::Result<u32> {
    Ok(fs::metadata(path)?.permissions().mode() & 0o7777)
}

/// §3.3 step 1: the mode of a bound Unix socket comes from the umask at bind
/// time, so it is set *before* bind. There is then no instant in which the
/// socket exists world-connectable.
fn bind_umasked(path: &Path) -> io::Result<UnixListener> {
    let _guard = UmaskGuard::set(0o077);
    UnixListener::bind(path)
}

/// §3.3 step 2: an explicit chmod immediately after bind, as belt and braces.
/// Not redundant — it is what makes the mode independent of whatever umask the
/// daemon was launched with.
fn harden_socket(path: &Path) -> io::Result<()> {
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

/// §3.3 step 3: the socket's parent at 0700, so the socket is unreachable even
/// on a platform that ignores socket permission bits.
fn prepare_parent(path: &Path) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("trusted socket path {} has no parent", path.display()),
        )
    })?;
    match fs::metadata(parent) {
        Ok(meta) if meta.is_dir() => {
            let mode = meta.permissions().mode() & 0o777;
            if mode != 0o700 {
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
                log!(
                    "tightened {} from {:04o} to 0700 (§3.3: the trusted socket's parent)",
                    parent.display(),
                    mode
                );
            }
            Ok(())
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("{} exists and is not a directory", parent.display()),
        )),
        Err(_) => fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent),
    }
}

/// A socket file left behind by a dead daemon blocks bind with EADDRINUSE.
/// Removing it is only safe once nothing is listening on it — otherwise this
/// would silently take the endpoint away from a running daemon.
fn clear_stale(path: &Path) -> io::Result<()> {
    if fs::symlink_metadata(path).is_err() {
        return Ok(());
    }
    if UnixStream::connect(path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            format!("another listener is already serving {}", path.display()),
        ));
    }
    fs::remove_file(path)
}

/// Binds the trusted endpoint with all three of §3.3's requirements, and
/// verifies the outcome rather than assuming it.
pub fn bind_trusted(path: &Path) -> io::Result<UnixListener> {
    prepare_parent(path)?;
    clear_stale(path)?;
    let listener = bind_umasked(path)?;
    let at_bind = mode_of(path)?;
    harden_socket(path)?;
    let after_chmod = mode_of(path)?;
    log!(
        "trusted endpoint on {} (mode {:04o} at bind, {:04o} after chmod, parent {:04o})",
        path.display(),
        at_bind,
        after_chmod,
        mode_of(path.parent().unwrap())?
    );
    if after_chmod & 0o777 != 0o600 {
        return Err(io::Error::other(format!(
            "{} is mode {:04o}, refusing to serve a trusted endpoint that is not 0600",
            path.display(),
            after_chmod
        )));
    }
    Ok(listener)
}

pub fn bind_public(port: u16) -> io::Result<TcpListener> {
    let listener = TcpListener::bind(("127.0.0.1", port))?;
    log!("public endpoint on {}", listener.local_addr()?);
    Ok(listener)
}

/// §3.3: when the socket is supplied rather than bound, the daemon asserts the
/// mode it was handed instead of assuming the unit's `SocketMode=0600` and
/// `DirectoryMode=0700` were set. Refusing is the fail-closed answer: the
/// trusted endpoint's entire security model is same-uid-only.
pub fn assert_adopted_trusted(path: &Path) -> io::Result<()> {
    let socket = mode_of(path)? & 0o777;
    if socket != 0o600 {
        return Err(io::Error::other(format!(
            "activated trusted socket {} is mode {:04o}, not 0600 — set SocketMode=0600 on the .socket unit",
            path.display(),
            socket
        )));
    }
    let parent = path.parent().unwrap_or(Path::new("/"));
    let dir = mode_of(parent)? & 0o777;
    if dir != 0o700 {
        return Err(io::Error::other(format!(
            "{} is mode {:04o}, not 0700 — set DirectoryMode=0700 on the .socket unit (chmod 0700 {} to fix an existing directory)",
            parent.display(),
            dir,
            parent.display()
        )));
    }
    log!(
        "activated trusted socket {} (mode {:04o}, parent {:04o})",
        path.display(),
        socket,
        dir
    );
    Ok(())
}

/// §3.2 socket activation. systemd passes listening descriptors from fd 3 up
/// with `LISTEN_FDS` set; the daemon adopts them and binds nothing. This is the
/// shape a zsh listener could not have — `ztcp -a` refuses a descriptor the
/// process did not create (`bench/listener-feasibility.zsh` Q2).
///
/// `Ok(None)` means no activation, so the caller binds for itself. Everything
/// else is a hard error: a half-understood activation environment must not
/// silently become a self-bind on a port systemd already owns.
pub fn adopt_activated() -> io::Result<Option<Bound>> {
    let Some(count) = std::env::var_os("LISTEN_FDS") else {
        return Ok(None);
    };
    let count: RawFd = count
        .to_string_lossy()
        .trim()
        .parse()
        .map_err(|_| io::Error::other(format!("LISTEN_FDS={count:?} is not a number")))?;

    // sd_listen_fds semantics: the descriptors belong to *this* process. A
    // stale LISTEN_PID inherited by a child must not look like an activation.
    match std::env::var("LISTEN_PID") {
        Ok(pid) if pid.trim() == std::process::id().to_string() => {}
        Ok(pid) => {
            return Err(io::Error::other(format!(
                "LISTEN_PID={} is not this process ({})",
                pid.trim(),
                std::process::id()
            )))
        }
        Err(_) => return Err(io::Error::other("LISTEN_FDS set without LISTEN_PID")),
    }
    if count < 1 {
        return Err(io::Error::other("LISTEN_FDS is set but passes no sockets"));
    }

    let mut bound = Bound::default();
    for fd in 3..3 + count {
        match classify(fd)? {
            Adopted::Unix(path) => {
                if bound.trusted.is_some() {
                    return Err(io::Error::other(
                        "socket activation passed two Unix sockets; the daemon serves one trusted endpoint",
                    ));
                }
                assert_adopted_trusted(&path)?;
                bound.trusted = Some(unsafe { UnixListener::from_raw_fd(fd) });
            }
            Adopted::Tcp => {
                if bound.public.is_some() {
                    return Err(io::Error::other(
                        "socket activation passed two TCP sockets; the daemon serves one public endpoint",
                    ));
                }
                let listener = unsafe { TcpListener::from_raw_fd(fd) };
                log!("activated public endpoint on {}", listener.local_addr()?);
                bound.public = Some(listener);
            }
        }
    }

    // sd_listen_fds(1) unsets these so a child cannot mistake them for its own.
    std::env::remove_var("LISTEN_FDS");
    std::env::remove_var("LISTEN_PID");
    std::env::remove_var("LISTEN_FDNAMES");
    Ok(Some(bound))
}

enum Adopted {
    Unix(PathBuf),
    Tcp,
}

/// Asks the kernel what an inherited descriptor is, rather than trusting fd
/// order: the order follows unit configuration and `LISTEN_FDNAMES` is optional,
/// so neither is a contract worth depending on. `local_addr` fails on a
/// descriptor of the wrong family, which is the check — and it keeps this path
/// free of per-platform `sockaddr` parsing.
fn classify(fd: RawFd) -> io::Result<Adopted> {
    let as_unix = ManuallyDrop::new(unsafe { UnixListener::from_raw_fd(fd) });
    if let Ok(addr) = as_unix.local_addr() {
        return match addr.as_pathname() {
            Some(path) => Ok(Adopted::Unix(path.to_path_buf())),
            None => Err(io::Error::other(format!(
                "activated fd {fd} is an unnamed Unix socket; the trusted endpoint needs a path to assert the mode of"
            ))),
        };
    }
    let as_tcp = ManuallyDrop::new(unsafe { TcpListener::from_raw_fd(fd) });
    if as_tcp.local_addr().is_ok() {
        return Ok(Adopted::Tcp);
    }
    Err(io::Error::other(format!(
        "activated fd {fd} is neither a Unix nor a TCP listening socket"
    )))
}

/// §3.4: a task per connection, not a process. A thread is the boundary a panic
/// cannot cross, so a handler failure closes one connection and the accept loop
/// carries on. No fork, therefore no reaping and no descriptor inheritance.
pub fn serve_forever(bound: Bound, ctx: Arc<Ctx>) -> io::Result<()> {
    let mut loops = Vec::new();
    if let Some(listener) = bound.public {
        let ctx = Arc::clone(&ctx);
        loops.push(
            thread::Builder::new()
                .name("accept-public".into())
                .spawn(move || accept_public(listener, ctx))?,
        );
    }
    if let Some(listener) = bound.trusted {
        let ctx = Arc::clone(&ctx);
        loops.push(
            thread::Builder::new()
                .name("accept-trusted".into())
                .spawn(move || accept_trusted(listener, ctx))?,
        );
    }
    if loops.is_empty() {
        return Err(io::Error::other("no endpoints to serve"));
    }
    for handle in loops {
        let _ = handle.join();
    }
    Ok(())
}

fn accept_public(listener: TcpListener, ctx: Arc<Ctx>) {
    loop {
        match listener.accept() {
            Ok((stream, peer)) => {
                let ctx = Arc::clone(&ctx);
                let peer = peer.to_string();
                let label = peer.clone();
                let spawned = thread::Builder::new()
                    .name("conn-public".into())
                    .spawn(move || {
                        let mut stream = stream;
                        if let Err(e) = set_timeouts(
                            |d| stream.set_read_timeout(d),
                            |d| stream.set_write_timeout(d),
                            ctx.exchange_timeout,
                        ) {
                            log!("public {peer}: cannot set timeouts: {e}");
                            return;
                        }
                        session::serve(&mut stream, Endpoint::Public, &peer, &ctx);
                    });
                if let Err(e) = spawned {
                    log!("public {label}: cannot spawn handler: {e}");
                }
            }
            Err(e) => accept_error("public", e),
        }
    }
}

fn accept_trusted(listener: UnixListener, ctx: Arc<Ctx>) {
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                let ctx = Arc::clone(&ctx);
                let spawned = thread::Builder::new()
                    .name("conn-trusted".into())
                    .spawn(move || {
                        let mut stream = stream;
                        if let Err(e) = set_timeouts(
                            |d| stream.set_read_timeout(d),
                            |d| stream.set_write_timeout(d),
                            ctx.exchange_timeout,
                        ) {
                            log!("trusted: cannot set timeouts: {e}");
                            return;
                        }
                        session::serve(&mut stream, Endpoint::Trusted, "same-uid", &ctx);
                    });
                if let Err(e) = spawned {
                    log!("trusted: cannot spawn handler: {e}");
                }
            }
            Err(e) => accept_error("trusted", e),
        }
    }
}

fn set_timeouts(
    read: impl FnOnce(Option<Duration>) -> io::Result<()>,
    write: impl FnOnce(Option<Duration>) -> io::Result<()>,
    timeout: Duration,
) -> io::Result<()> {
    read(Some(timeout))?;
    write(Some(timeout))
}

/// §3.4: the accept loop survives a connection reset. A descriptor exhaustion
/// error would otherwise spin, so it costs a short pause.
fn accept_error(endpoint: &str, e: io::Error) {
    log!("{endpoint}: accept failed: {e}");
    thread::sleep(Duration::from_millis(10));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil;
    use std::sync::Mutex;

    // umask is process-global and cargo runs tests in threads, so the tests
    // that touch it are serialized against each other. Poisoning is ignored so
    // one failing assertion does not cascade into five.
    static UMASK: Mutex<()> = Mutex::new(());

    fn serialized() -> std::sync::MutexGuard<'static, ()> {
        UMASK.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn bind_leaves_the_socket_0600_under_a_0700_parent() {
        let _lock = serialized();
        let dir = testutil::tempdir("bind-trusted");
        let sock = dir.path().join("cb.sock");
        let _listener = bind_trusted(&sock).unwrap();
        assert_eq!(mode_of(&sock).unwrap() & 0o777, 0o600);
        assert_eq!(mode_of(dir.path()).unwrap() & 0o777, 0o700);
    }

    #[test]
    fn the_umask_half_stands_on_its_own() {
        let _lock = serialized();
        let dir = testutil::tempdir("umask-half");
        let bare = dir.path().join("bare.sock");
        let masked = dir.path().join("masked.sock");
        // The permissive umask a login shell or launchd would hand the daemon.
        // bind() masks a base mode of 0777, so this is what a bind that trusted
        // the ambient umask would produce — the 0755 `bench/listener-feasibility.zsh`
        // Q3 measured for `zsocket -l`.
        let ambient = UmaskGuard::set(0o022);
        let _loose = UnixListener::bind(&bare).unwrap();
        assert_eq!(mode_of(&bare).unwrap() & 0o777, 0o755);
        // The same ambient umask, through the daemon's bind.
        let _listener = bind_umasked(&masked).unwrap();
        drop(ambient);
        assert_eq!(
            mode_of(&masked).unwrap() & 0o077,
            0,
            "§3.3 step 1: the socket is never created permissive"
        );
    }

    #[test]
    fn the_chmod_half_stands_on_its_own() {
        let _lock = serialized();
        let dir = testutil::tempdir("chmod-half");
        let sock = dir.path().join("cb.sock");
        let _listener = bind_umasked(&sock).unwrap();
        // Whatever the umask produced, the explicit chmod is what fixes the mode.
        fs::set_permissions(&sock, fs::Permissions::from_mode(0o666)).unwrap();
        assert_eq!(mode_of(&sock).unwrap() & 0o777, 0o666);
        harden_socket(&sock).unwrap();
        assert_eq!(mode_of(&sock).unwrap() & 0o777, 0o600);
    }

    #[test]
    fn a_loose_parent_is_tightened_to_0700() {
        let _lock = serialized();
        let dir = testutil::tempdir("loose-parent");
        let nest = dir.path().join("state");
        fs::create_dir(&nest).unwrap();
        fs::set_permissions(&nest, fs::Permissions::from_mode(0o755)).unwrap();
        let sock = nest.join("cb.sock");
        let _listener = bind_trusted(&sock).unwrap();
        assert_eq!(mode_of(&nest).unwrap() & 0o777, 0o700);
    }

    #[test]
    fn a_missing_parent_is_created_0700() {
        let _lock = serialized();
        let dir = testutil::tempdir("missing-parent");
        let sock = dir.path().join("deep/nest/cb.sock");
        let _listener = bind_trusted(&sock).unwrap();
        assert_eq!(mode_of(sock.parent().unwrap()).unwrap() & 0o777, 0o700);
        assert_eq!(mode_of(&sock).unwrap() & 0o777, 0o600);
    }

    #[test]
    fn a_stale_socket_is_replaced_but_a_live_one_is_not() {
        let _lock = serialized();
        let dir = testutil::tempdir("stale-socket");
        let sock = dir.path().join("cb.sock");
        let first = bind_trusted(&sock).unwrap();
        let err = bind_trusted(&sock).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::AddrInUse);
        drop(first);
        // The file outlives the listener; the next bind may reclaim it.
        assert!(fs::symlink_metadata(&sock).is_ok());
        let _second = bind_trusted(&sock).unwrap();
        assert_eq!(mode_of(&sock).unwrap() & 0o777, 0o600);
    }

    #[test]
    fn an_adopted_socket_with_the_wrong_mode_is_refused() {
        let _lock = serialized();
        let dir = testutil::tempdir("adopt-assert");
        let sock = dir.path().join("cb.sock");
        let _listener = bind_trusted(&sock).unwrap();
        assert_adopted_trusted(&sock).unwrap();

        // What a .socket unit missing SocketMode=0600 would hand over.
        fs::set_permissions(&sock, fs::Permissions::from_mode(0o660)).unwrap();
        let err = assert_adopted_trusted(&sock).unwrap_err();
        assert!(err.to_string().contains("not 0600"), "{err}");

        harden_socket(&sock).unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        let err = assert_adopted_trusted(&sock).unwrap_err();
        assert!(err.to_string().contains("not 0700"), "{err}");
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn classify_tells_the_two_families_apart() {
        use std::os::fd::AsRawFd;
        let _lock = serialized();
        let dir = testutil::tempdir("classify");
        let sock = dir.path().join("cb.sock");
        let unix = bind_umasked(&sock).unwrap();
        let tcp = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        assert!(matches!(
            classify(unix.as_raw_fd()).unwrap(),
            Adopted::Unix(p) if p == sock
        ));
        assert!(matches!(classify(tcp.as_raw_fd()).unwrap(), Adopted::Tcp));
    }

    #[test]
    fn activation_without_listen_pid_is_a_hard_error() {
        // Serialized with the umask tests only to keep env mutation off other
        // threads' backs.
        let _lock = serialized();
        std::env::set_var("LISTEN_FDS", "1");
        std::env::remove_var("LISTEN_PID");
        let err = adopt_activated().unwrap_err();
        std::env::remove_var("LISTEN_FDS");
        assert!(err.to_string().contains("without LISTEN_PID"), "{err}");
    }

    #[test]
    fn no_listen_fds_means_bind_for_yourself() {
        let _lock = serialized();
        std::env::remove_var("LISTEN_FDS");
        assert!(adopt_activated().unwrap().is_none());
    }
}
