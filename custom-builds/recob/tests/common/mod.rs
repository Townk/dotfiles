//! A minimal client for the integration tests: the peer half of §4.1 and §5.
//!
//! It is deliberately built from the crate's own codec. The observation seam
//! (§11.1) is what checks an *independent* implementation of the contract; these
//! tests check the daemon, so sharing the encoder here costs nothing and keeps
//! the assertions about behavior rather than about bytes.

#![allow(dead_code)]

use std::io::{Read, Write};
use std::sync::Arc;

use recobd::auth::Token;
use recobd::listen::Endpoint;
use recobd::session::{self, Ctx};
use recobd::wire::{self, Fields, FrameError, Kind, MAX_BODY, PREAMBLE_LEN};

#[path = "../../src/testutil.rs"]
pub mod testutil;

/// A fixed credential for the in-process tests, so an assertion can name the
/// value the daemon is checking against. Tests that spawn the binary read the
/// token the daemon bootstrapped instead — the value is not the point, and
/// hard-coding one there would test the fixture rather than the daemon.
pub const TEST_TOKEN: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

pub struct Client<S: Read + Write> {
    pub stream: S,
    pub wire_version: u8,
    pub banner: Fields,
    /// The client's own challenge (§9.2 step 2), kept so `proof` can be checked.
    pub cnonce: Vec<u8>,
}

impl<S: Read + Write> Client<S> {
    /// Reads the six preamble bytes and the banner the server writes on accept.
    pub fn open(mut stream: S) -> Self {
        let mut pre = [0u8; PREAMBLE_LEN];
        let got = wire::fill(&mut stream, &mut pre).unwrap();
        assert_eq!(got, PREAMBLE_LEN, "server preamble was short");
        assert_eq!(&pre[..5], wire::MAGIC);
        let (kind, body) = wire::read_frame(&mut stream, MAX_BODY).unwrap().unwrap();
        assert_eq!(kind, Kind::Hello, "the first server frame is the banner");
        Client {
            stream,
            wire_version: pre[5],
            banner: wire::parse_body(&body).unwrap(),
            cnonce: recobd::auth::random_bytes(recobd::auth::NONCE_BYTES).unwrap(),
        }
    }

    pub fn hello(&mut self, fields: &Fields) {
        let mut out = wire::preamble().to_vec();
        out.extend_from_slice(&wire::encode(Kind::Hello, fields));
        self.stream.write_all(&out).unwrap();
    }

    /// The trusted socket's hello: no credential, since its uid boundary is the
    /// credential (§9.2).
    pub fn hello_default(&mut self) {
        self.hello(
            &Fields::new()
                .with("proto", b"1".to_vec())
                .with("impl", b"spec-test".to_vec()),
        );
    }

    /// The public endpoint's hello (§9.2 step 2): answer the banner's challenge
    /// and issue one of our own.
    pub fn hello_authenticated(&mut self, token: &str) {
        let auth = Token::from_hex(token)
            .expect("test token")
            .client_digest(self.nonce());
        let cnonce = self.cnonce.clone();
        self.hello(
            &Fields::new()
                .with("proto", b"1".to_vec())
                .with("impl", b"spec-test".to_vec())
                .with("auth", auth.into_bytes())
                .with("cnonce", cnonce),
        );
    }

    /// The server's challenge, from the banner.
    pub fn nonce(&self) -> &[u8] {
        self.banner.get("nonce").expect("banner without a nonce")
    }

    /// §9.2 step 3, from the client's side: the capabilities frame must answer the
    /// challenge *this* client chose, or the peer is a squatter.
    pub fn expect_caps_proven(&mut self, token: &str) -> Fields {
        let caps = self.expect_caps();
        let expected = Token::from_hex(token)
            .expect("test token")
            .server_proof(&self.cnonce);
        assert_eq!(
            caps.get("proof")
                .map(|p| String::from_utf8_lossy(p).into_owned()),
            Some(expected),
            "the endpoint did not prove itself"
        );
        caps
    }

    pub fn preamble_only(&mut self, bytes: &[u8]) {
        self.stream.write_all(bytes).unwrap();
    }

    pub fn send_raw(&mut self, bytes: &[u8]) {
        self.stream.write_all(bytes).unwrap();
    }

    pub fn send_request(&mut self, fields: &Fields) {
        self.send_raw(&wire::encode(Kind::Request, fields));
    }

    pub fn request(&mut self, op: &str) -> (Kind, Fields) {
        self.send_request(&Fields::new().with("op", op.as_bytes()));
        self.next().expect("no answer")
    }

    /// The next frame, decoded. `None` is a clean close.
    pub fn next(&mut self) -> Option<(Kind, Fields)> {
        let (kind, body) = self.next_raw()?;
        Some((kind, wire::parse_body(&body).unwrap()))
    }

    pub fn next_raw(&mut self) -> Option<(Kind, Vec<u8>)> {
        wire::read_frame(&mut self.stream, MAX_BODY).unwrap()
    }

    pub fn next_result(&mut self) -> Result<Option<(Kind, Vec<u8>)>, FrameError> {
        wire::read_frame(&mut self.stream, MAX_BODY)
    }

    pub fn expect_caps(&mut self) -> Fields {
        let (kind, fields) = self.next().expect("no capabilities frame");
        assert_eq!(kind, Kind::Caps, "§4.2: capabilities is its own kind");
        fields
    }

    pub fn expect_error(&mut self) -> Fields {
        let (kind, fields) = self.next().expect("no error frame");
        assert_eq!(kind, Kind::Error, "expected an E frame, got {kind}");
        fields
    }

    pub fn code(&mut self) -> String {
        let fields = self.expect_error();
        String::from_utf8_lossy(fields.get("code").expect("E frame without code")).into_owned()
    }
}

/// Every byte that crossed the connection, in both directions. §11.4 asks for
/// the token's absence from a *full recorded exchange*, which means the wire and
/// not a summary of it.
pub struct Tee<S> {
    inner: S,
    pub sent: Vec<u8>,
    pub received: Vec<u8>,
}

impl<S> Tee<S> {
    pub fn new(inner: S) -> Self {
        Tee {
            inner,
            sent: Vec::new(),
            received: Vec::new(),
        }
    }

    /// Both directions concatenated — what an observer on the wire would have.
    pub fn wire(&self) -> Vec<u8> {
        let mut all = self.sent.clone();
        all.extend_from_slice(&self.received);
        all
    }
}

impl<S: Read> Read for Tee<S> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.received.extend_from_slice(&buf[..n]);
        Ok(n)
    }
}

impl<S: Write> Write for Tee<S> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.sent.extend_from_slice(&buf[..n]);
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// As `served`, with every byte of the connection captured.
pub fn served_teed(
    ctx: Arc<Ctx>,
    endpoint: Endpoint,
) -> Client<Tee<std::os::unix::net::UnixStream>> {
    let (server, client) = std::os::unix::net::UnixStream::pair().unwrap();
    let admission = recobd::limits::Limits::admit(&ctx.limits, endpoint).expect("admitted");
    std::thread::spawn(move || {
        let mut server = server;
        session::serve(&mut server, endpoint, "test", &ctx, admission);
    });
    Client::open(Tee::new(client))
}

/// The credential a spawned daemon created for itself at startup (§9.2's
/// bootstrap), read the way a pushed client copy is read. Waits, because the
/// daemon writes it while the test is already running.
pub fn wait_for_token(state_home: &std::path::Path) -> String {
    let path = state_home.join("clipboard/accepted-token");
    for _ in 0..200 {
        if let Ok(token) = recobd::auth::read_token(&path) {
            return token.as_str().to_string();
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    panic!("no credential appeared at {}", path.display());
}

pub fn text(fields: &Fields, name: &str) -> String {
    String::from_utf8_lossy(
        fields
            .get(name)
            .unwrap_or_else(|| panic!("no field {name}")),
    )
    .into_owned()
}

/// A served connection with no listener in the way: the daemon's own
/// `session::serve` on one end of a socket pair, a test client on the other.
///
/// The admission comes from the real limiter, so §3.5's accounting is exercised
/// here rather than bypassed.
pub fn served(ctx: Arc<Ctx>, endpoint: Endpoint) -> Client<std::os::unix::net::UnixStream> {
    let (server, client) = std::os::unix::net::UnixStream::pair().unwrap();
    let admission = recobd::limits::Limits::admit(&ctx.limits, endpoint).expect("admitted");
    std::thread::spawn(move || {
        let mut server = server;
        session::serve(&mut server, endpoint, "test", &ctx, admission);
    });
    Client::open(client)
}

/// A `recobd` child process started the way systemd starts one: the listening
/// sockets are created here, handed over as fds 3 and 4, and `LISTEN_FDS` /
/// `LISTEN_PID` describe them (§3.2). The daemon binds nothing.
///
/// This is the contract `bench/listener-feasibility.zsh` Q2 showed a zsh
/// listener cannot honour — `ztcp -a` refuses a descriptor the process did not
/// create — so exercising it is exercising one of the reasons the daemon is
/// compiled.
pub struct Daemon {
    child: std::process::Child,
    pub port: u16,
    pub socket: std::path::PathBuf,
    pub stderr: std::path::PathBuf,
}

impl Daemon {
    pub fn activated(dir: &std::path::Path, args: &[&str], env: &[(&str, &str)]) -> Daemon {
        Daemon::activated_with(dir, args, env, |_| {})
    }

    /// `tweak` runs against the bound Unix socket just before the daemon is
    /// started, so a test can hand over the socket a misconfigured unit would.
    pub fn activated_with(
        dir: &std::path::Path,
        args: &[&str],
        env: &[(&str, &str)],
        tweak: impl FnOnce(&std::path::Path),
    ) -> Daemon {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::PermissionsExt;
        use std::os::unix::process::CommandExt;
        use std::process::{Command, Stdio};

        let socket = dir.join("cb.sock");
        let stderr = dir.join("stderr");

        let tcp = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = tcp.local_addr().unwrap().port();
        let unix = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        // What the .socket unit's SocketMode=0600 and DirectoryMode=0700 give the
        // daemon; it asserts both rather than assuming them (§3.3).
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
        tweak(&socket);

        // dup2's targets are 3 and 4, so neither source may sit there. Cloning
        // walks both descriptors above the targets; the intermediates stay alive
        // until exec so the low numbers are not handed back out.
        let mut parked: Vec<Box<dyn std::any::Any>> = Vec::new();
        let mut tcp = tcp;
        while tcp.as_raw_fd() <= 4 {
            let next = tcp.try_clone().unwrap();
            parked.push(Box::new(tcp));
            tcp = next;
        }
        let mut unix = unix;
        while unix.as_raw_fd() <= 4 {
            let next = unix.try_clone().unwrap();
            parked.push(Box::new(unix));
            unix = next;
        }
        let (tcp_fd, unix_fd) = (tcp.as_raw_fd(), unix.as_raw_fd());

        extern "C" {
            fn dup2(from: i32, to: i32) -> i32;
        }

        // `sh` only exists here to set LISTEN_PID to the pid that will run the
        // daemon: `$$` survives the exec, which is how systemd's own value is
        // correct. Nothing else about the shell matters.
        let mut cmd = Command::new("/bin/sh");
        cmd.arg("-c")
            .arg(r#"export LISTEN_PID=$$; exec "$0" "$@""#)
            .arg(env!("CARGO_BIN_EXE_recobd"))
            .args(args)
            .env("LISTEN_FDS", "2")
            .env_remove("LISTEN_PID")
            .stdout(Stdio::null())
            .stderr(Stdio::from(std::fs::File::create(&stderr).unwrap()));
        for (key, value) in env {
            cmd.env(key, value);
        }
        unsafe {
            cmd.pre_exec(move || {
                if dup2(tcp_fd, 3) < 0 || dup2(unix_fd, 4) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = cmd.spawn().expect("spawn recobd");
        drop(parked);

        Daemon {
            child,
            port,
            socket,
            stderr,
        }
    }

    /// A daemon that binds for itself — the launchd shape, and the one a human
    /// gets from a terminal. `port` is meaningless unless the caller passed one.
    pub fn spawned(dir: &std::path::Path, args: &[&str], env: &[(&str, &str)]) -> Daemon {
        use std::process::{Command, Stdio};
        let stderr = dir.join("stderr");
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_recobd"));
        cmd.args(args)
            .env_remove("LISTEN_FDS")
            .env_remove("LISTEN_PID")
            .stdout(Stdio::null())
            .stderr(Stdio::from(std::fs::File::create(&stderr).unwrap()));
        for (key, value) in env {
            cmd.env(key, value);
        }
        Daemon {
            child: cmd.spawn().expect("spawn recobd"),
            port: 0,
            socket: dir.join("cb.sock"),
            stderr,
        }
    }

    pub fn exited(&mut self) -> std::process::ExitStatus {
        for _ in 0..200 {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        panic!("the daemon is still running:\n{}", self.stderr());
    }

    pub fn connect_public(&self) -> Client<std::net::TcpStream> {
        let stream = std::net::TcpStream::connect(("127.0.0.1", self.port)).unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        Client::open(stream)
    }

    pub fn connect_trusted(&self) -> Client<std::os::unix::net::UnixStream> {
        let stream = std::os::unix::net::UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        Client::open(stream)
    }

    pub fn stderr(&self) -> String {
        std::fs::read_to_string(&self.stderr).unwrap_or_default()
    }

    /// Waits for a line to appear in the daemon's log, so a test asserts against
    /// a started daemon rather than racing one.
    pub fn wait_for_log(&self, needle: &str) {
        for _ in 0..200 {
            if self.stderr().contains(needle) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        panic!("{needle:?} never appeared in the log:\n{}", self.stderr());
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A context whose identity comes from a self-name file the test controls, so
/// `host.identity` has a value that does not depend on the machine, and whose
/// credential is `TEST_TOKEN` in a private file the test owns.
pub fn ctx_with_host(dir: &std::path::Path, host: &str) -> Arc<Ctx> {
    Arc::new(ctx_mut(dir, host))
}

/// The same, unwrapped, for a test that needs to adjust a field before serving.
pub fn ctx_mut(dir: &std::path::Path, host: &str) -> Ctx {
    let path = dir.join("self-name");
    std::fs::write(&path, format!("{host}\n")).unwrap();
    let token_path = dir.join("accepted-token");
    recobd::listen::write_private(&token_path, format!("{TEST_TOKEN}\n").as_bytes()).unwrap();
    let mut ctx = Ctx::new(
        recobd::host::HostIdentity::with_paths(path, Some("fallback".into())),
        "test-impl".to_string(),
        std::time::Duration::from_secs(2),
    );
    ctx.token_path = token_path;
    // Every in-process test serves against a store inside the test's own
    // directory — never the live one.
    ctx.db_path = dir.join("history.db");
    ctx
}
