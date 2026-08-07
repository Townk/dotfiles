//! The client half of the contract (§8), shared by `pbcopy` and `pbpaste` so
//! the wire format has exactly one Rust implementation on both sides of the
//! socket.
//!
//! The §5.2 rule this module exists to hold: **OSC 52 is a fallback for an
//! absent bridge, never for a refusing or overloaded one.** The only signal
//! admitted is the connect result — [`Dial::Refused`] — because anything an
//! attacker can slow down, an attacker can turn into a downgrade. A completed
//! connect that then stalls, resets or refuses fails loudly.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use crate::auth::{self, Token};
use crate::wire::{self, Fields, FrameError, Kind, MAX_BODY, PREAMBLE_LEN};

/// §5.2's client-side timeouts.
pub struct Timeouts {
    pub preamble: Duration,
    pub exchange: Duration,
    pub action: Duration,
}

impl Default for Timeouts {
    fn default() -> Self {
        let preamble = std::env::var("RECOB_HELLO_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map_or(Duration::from_millis(500), Duration::from_millis);
        let exchange = std::env::var("RECOB_TIMEOUT_S")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|s| *s > 0.0)
            .map_or(Duration::from_secs(2), Duration::from_secs_f64);
        // The action deadline gets its own knob: an op that makes the origin
        // DO something can block on a first-use consent dialog, and the
        // caller tuning that wait must not have to shorten-proof the
        // ordinary exchange deadline to do it.
        let action = std::env::var("RECOB_ACTION_TIMEOUT_S")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|s| *s > 0.0)
            .map_or(Duration::from_secs(20), Duration::from_secs_f64);
        Timeouts {
            preamble,
            exchange,
            action,
        }
    }
}

/// The connect result, §5.2's load-bearing distinction.
pub enum Dial {
    /// Nothing bound: the one and only state that permits a less trusted
    /// delivery path.
    Refused,
    Connected(TcpStream),
    /// Reachable-but-failing in any other way — never a fallback license.
    Failed(std::io::Error),
}

pub fn dial(host: &str, port: u16, timeout: Duration) -> Dial {
    use std::net::ToSocketAddrs;
    let addr = match (host, port)
        .to_socket_addrs()
        .ok()
        .and_then(|mut a| a.next())
    {
        Some(addr) => addr,
        None => {
            return Dial::Failed(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "unresolvable address",
            ))
        }
    };
    match TcpStream::connect_timeout(&addr, timeout) {
        Ok(stream) => Dial::Connected(stream),
        Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => Dial::Refused,
        Err(e) => Dial::Failed(e),
    }
}

/// Why a connection could not become a usable session. Every variant reports;
/// none is a fallback license (§8 rule 8).
#[derive(Debug)]
pub enum ClientError {
    /// The peer never wrote a RECOB preamble within the (retried) deadline —
    /// §7.3's diagnostic case, naming what was heard instead.
    NotRecob(String),
    /// Wire version or protocol violation.
    Protocol(String),
    /// An `E` frame: the server's code is the contract (§8 rule 3).
    Server {
        code: String,
        message: String,
    },
    /// §9.2: the endpoint failed to prove itself; nothing it sent may be
    /// believed and nothing carrying user data may be sent.
    Untrusted(String),
    /// §8 rule 7: the operation is absent from the server's `caps`, refused
    /// client-side with §7.1's skew diagnostic. The string is the complete
    /// sentence in the client's voice, ready for the program-name prefix.
    Unsupported(String),
    Io(std::io::Error),
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::NotRecob(what) => write!(out, "not a RECOB endpoint: {what}"),
            ClientError::Protocol(what) => write!(out, "protocol error: {what}"),
            ClientError::Server { code, message } => write!(out, "{code}: {message}"),
            ClientError::Untrusted(what) => write!(out, "untrusted endpoint: {what}"),
            ClientError::Unsupported(what) => write!(out, "{what}"),
            ClientError::Io(e) => write!(out, "i/o error: {e}"),
        }
    }
}

/// §7.1's two side labels: naming the machine is the client's job, because
/// only the client knows which address it dialed.
pub const SIDE_LOCAL: &str = "this machine";
pub const SIDE_TUNNEL: &str = "the machine at the other end of the SSH tunnel";

/// §7.1's message shapes, in the client's voice, without the program-name
/// prefix. `server_proto` is the server's from its hello; `None` (an
/// unparseable or absent field) falls through to the caps-authoritative
/// shape, since asserting a version comparison would assert something false.
fn skew_message(op: &str, server_proto: Option<u32>, side: &str) -> String {
    let client_proto = wire::PROTO;
    // "this machine's clipboard bridge" reads as the spec writes it; every
    // other side gets the prepositional form.
    let subject = if side == SIDE_LOCAL {
        "this machine's clipboard bridge".to_string()
    } else {
        format!("the clipboard bridge on {side}")
    };
    match server_proto {
        Some(sp) if sp < client_proto => {
            // The clause is dropped when `since` is not the reason the
            // operation is missing (§7.1).
            let clause = match crate::registry::since(op) {
                Some(since) if since > sp => format!(", and {op} needs proto {since}"),
                _ => String::new(),
            };
            let remedy = if side == SIDE_LOCAL { "here" } else { "there" };
            format!(
                "{subject} is behind — it speaks RECOB proto {sp}, this client \
                 speaks proto {client_proto}{clause}. Run chezmoi apply {remedy}."
            )
        }
        Some(sp) if sp > client_proto => format!(
            "{subject} is ahead of this client (proto {sp} vs {client_proto}) — \
             run chezmoi apply here."
        ),
        // Versions equal (or unknown): the caps set is authoritative over the
        // version integer (§7.1).
        _ => format!("{subject} does not support {op}"),
    }
}

impl From<std::io::Error> for ClientError {
    fn from(e: std::io::Error) -> Self {
        ClientError::Io(e)
    }
}

/// Where a `files.fetch` stream is delivered. Split from a bare `Write` so a
/// caller can judge the `R` head first (the §11 size cap) and so the clean
/// end — the explicit empty `D` — is distinguishable from a truncation the
/// caller must not treat as success.
pub trait StreamSink {
    /// The `R` head, before any body byte. Refusing here aborts the exchange.
    fn head(&mut self, _head: &Fields) -> Result<(), ClientError> {
        Ok(())
    }
    fn chunk(&mut self, bytes: &[u8]) -> Result<(), ClientError>;
    /// The terminating empty `D` arrived: everything the server sent is here.
    fn finish(&mut self) -> Result<(), ClientError> {
        Ok(())
    }
}

/// A validated credential file (§9.2 "Validation on read"): exactly 64
/// lowercase hex characters on a single line, no trailing content beyond one
/// newline, and a mode granting nothing to group or other. Anything else is
/// treated as absent — never partially matched.
pub fn read_pushed_token(path: &Path) -> Option<Token> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(path).ok()?;
    if meta.permissions().mode() & 0o077 != 0 {
        return None;
    }
    let raw = std::fs::read(path).ok()?;
    let first = raw.split_inclusive(|b| *b == b'\n').next()?;
    let line = first.strip_suffix(b"\n").unwrap_or(first);
    if raw.len() > line.len() + 1 {
        return None; // trailing content beyond the single line
    }
    let text = std::str::from_utf8(line).ok()?;
    Token::from_hex(text).ok()
}

/// What a client needs from a socket beyond Read/Write — the trusted endpoint
/// is a Unix socket and the public one is TCP, and the contract binds both.
pub trait ClientStream: Read + Write {
    fn set_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()>;
}

impl ClientStream for TcpStream {
    fn set_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.set_read_timeout(timeout)
    }
}

impl ClientStream for UnixStream {
    fn set_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.set_read_timeout(timeout)
    }
}

/// One established session: preamble exchanged, hello sent, and — on the
/// public endpoint — the server's proof verified before anything else is
/// believed (§8 rule 6).
pub struct Session<S: ClientStream> {
    stream: S,
    pub caps: Vec<String>,
    pub endpoint: String,
    /// The server's `proto` from its hello, for §7.1's comparison.
    pub server_proto: Option<u32>,
    /// §7.1's side label; [`SIDE_LOCAL`] unless the dialer said otherwise.
    side: String,
    timeouts: Timeouts,
}

/// How to authenticate: the trusted socket's uid boundary, or credentials for
/// the public endpoint. §6.6's `auth` field is a NUL-joined list of up to
/// eight digests, because a shared remote may hold pushed tokens for several
/// owning machines and cannot know which one answers this port.
pub enum Credential {
    TrustedSocket,
    Tokens(Vec<Token>),
}

impl Credential {
    pub fn single(token: Token) -> Credential {
        Credential::Tokens(vec![token])
    }
}

impl<S: ClientStream> Session<S> {
    /// §8 rules 1, 2 and 6 in one place. On the public endpoint the hello
    /// waits for the banner's nonce, answers it, issues its own challenge, and
    /// refuses to proceed unless the capabilities frame proves the server.
    pub fn establish(
        stream: S,
        credential: Credential,
        timeouts: Timeouts,
    ) -> Result<Session<S>, ClientError> {
        let mut stream = stream;
        // The preamble goes out immediately on connect (§8 rule 1).
        stream.write_all(&wire::preamble())?;

        // §5.2: the short preamble deadline, retried once before reporting.
        stream.set_timeout(Some(timeouts.preamble))?;
        let mut head = [0u8; PREAMBLE_LEN];
        let mut got = 0;
        for attempt in 0..2 {
            match fill_some(&mut stream, &mut head, &mut got) {
                Ok(true) => break,
                Ok(false) if attempt == 0 => continue,
                Ok(false) => {
                    return Err(ClientError::NotRecob(format!(
                        "no preamble within the deadline ({got} bytes heard)"
                    )))
                }
                Err(e) => return Err(ClientError::Io(e)),
            }
        }
        if &head[..5] != wire::MAGIC {
            return Err(ClientError::NotRecob(format!(
                "first bytes {:?}",
                String::from_utf8_lossy(&head[..got.min(5)])
            )));
        }
        if head[5] != wire::WIRE_VERSION {
            return Err(ClientError::Protocol(format!(
                "wire version {} against this client's {}",
                head[5],
                wire::WIRE_VERSION
            )));
        }

        stream.set_timeout(Some(timeouts.exchange))?;
        let banner = read_fields(&mut stream, Kind::Hello)?;
        let server_proto = banner
            .get("proto")
            .and_then(|raw| std::str::from_utf8(raw).ok())
            .and_then(|text| text.trim().parse::<u32>().ok());

        let mut hello = Fields::new()
            .with("proto", wire::PROTO.to_string().into_bytes())
            .with(
                "impl",
                env!("CARGO_PKG_VERSION").replace('.', "-").into_bytes(),
            );
        let cnonce = match &credential {
            Credential::TrustedSocket => None,
            Credential::Tokens(tokens) => {
                if tokens.is_empty() {
                    return Err(ClientError::Untrusted(
                        "no pushed token for this endpoint's owner — reconnect so                          ssh-prepare-connection can push one"
                            .to_string(),
                    ));
                }
                let Some(nonce) = banner.get("nonce") else {
                    return Err(ClientError::Protocol(
                        "the public banner carried no nonce".to_string(),
                    ));
                };
                let cnonce = auth::random_bytes(auth::NONCE_BYTES)
                    .map_err(|e| ClientError::Protocol(format!("no randomness: {e}")))?;
                // §6.6 caps the list at eight entries; offering more would be
                // refused as a shape error, so the client trims deliberately.
                let digests: Vec<String> = tokens
                    .iter()
                    .take(8)
                    .map(|token| token.client_digest(nonce))
                    .collect();
                hello.push("auth", digests.join("\0").into_bytes());
                hello.push("cnonce", cnonce.clone());
                Some(cnonce)
            }
        };
        stream.write_all(&wire::encode(Kind::Hello, &hello))?;

        let caps_frame = read_fields(&mut stream, Kind::Caps)?;
        if let (Credential::Tokens(tokens), Some(cnonce)) = (&credential, &cnonce) {
            // §9.2 step 3: the server must answer the challenge *this* client
            // chose, with a proof derived from one of the tokens this client
            // actually holds. Until it has, nothing in `C` — caps, impl,
            // endpoint — may drive a decision; an unverified peer's inventory
            // is a claim. Every held token is checked, constant-time each,
            // with no early exit on a match.
            let proven = caps_frame
                .get("proof")
                .map(|proof| {
                    use subtle::ConstantTimeEq;
                    let mut ok = false;
                    for token in tokens.iter().take(8) {
                        let expected = token.server_proof(cnonce);
                        if bool::from(proof.ct_eq(expected.as_bytes())) {
                            ok = true;
                        }
                    }
                    ok
                })
                .unwrap_or(false);
            if !proven {
                return Err(ClientError::Untrusted(
                    "the endpoint did not prove it holds this machine's token".to_string(),
                ));
            }
        }

        let caps = caps_frame
            .get("caps")
            .map(|raw| {
                String::from_utf8_lossy(raw)
                    .split('\0')
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let endpoint = caps_frame
            .get("endpoint")
            .map(|raw| String::from_utf8_lossy(raw).into_owned())
            .unwrap_or_default();
        Ok(Session {
            stream,
            caps,
            endpoint,
            server_proto,
            side: SIDE_LOCAL.to_string(),
            timeouts,
        })
    }

    /// §7.1: name the machine by the address dialed. The dialer of the
    /// forwarded tunnel port calls this with [`SIDE_TUNNEL`]; everything else
    /// keeps the [`SIDE_LOCAL`] default.
    pub fn set_side(&mut self, side: &str) {
        self.side = side.to_string();
    }

    /// §8 rule 7: after the first exchange, an operation absent from `caps`
    /// is a client-side refusal with the skew diagnostic's ingredients.
    pub fn supports(&self, op: &str) -> bool {
        self.caps.iter().any(|name| name == op)
    }

    /// §8 rule 7's enforcement point: this client reads `caps` during
    /// establish, so every exchange is a "second and later" one and the
    /// pre-flight always applies. An empty caps list means the server
    /// declared nothing — there is no inventory to check against, and the
    /// server's own `unknown-op` remains the diagnostic (§7.2).
    fn preflight(&self, fields: &Fields) -> Result<(), ClientError> {
        if self.caps.iter().all(|name| name.is_empty()) {
            return Ok(());
        }
        let Some(op) = fields.get("op") else {
            return Ok(());
        };
        let op = String::from_utf8_lossy(op);
        if self.supports(&op) {
            return Ok(());
        }
        Err(ClientError::Unsupported(skew_message(
            &op,
            self.server_proto,
            &self.side,
        )))
    }

    /// One request, one `R` — the exchange shape every operation but
    /// `files.fetch` uses. `action` selects §5.2's longer deadline.
    pub fn exchange(&mut self, fields: &Fields, action: bool) -> Result<Fields, ClientError> {
        self.preflight(fields)?;
        let timeout = if action {
            self.timeouts.action
        } else {
            self.timeouts.exchange
        };
        self.stream.set_timeout(Some(timeout))?;
        self.stream
            .write_all(&wire::encode(Kind::Request, fields))?;
        read_response(&mut self.stream)
    }

    /// `files.fetch`: the `R` head, then the `D` stream delivered to `sink`.
    /// §6.4: the absence of the terminating empty `D` *is* the truncation
    /// signal, and a mid-stream `E` terminates the exchange, not the
    /// connection.
    ///
    /// The sink sees the head before any byte of the body, which is what lets
    /// a caller enforce a size policy — §11's per-item cap — before pulling
    /// anything rather than after paying for it.
    pub fn fetch(
        &mut self,
        fields: &Fields,
        sink: &mut dyn StreamSink,
    ) -> Result<Fields, ClientError> {
        self.preflight(fields)?;
        self.stream.set_timeout(Some(self.timeouts.action))?;
        self.stream
            .write_all(&wire::encode(Kind::Request, fields))?;
        let head = read_response(&mut self.stream)?;
        sink.head(&head)?;
        loop {
            match next_frame(&mut self.stream)? {
                (Kind::Data, chunk) if chunk.is_empty() => {
                    sink.finish()?;
                    return Ok(head);
                }
                (Kind::Data, chunk) => sink.chunk(&chunk)?,
                (Kind::Error, body) => return Err(server_error(&body)),
                (kind, _) => {
                    return Err(ClientError::Protocol(format!(
                        "a {kind} frame inside a stream"
                    )))
                }
            }
        }
    }
}

fn server_error(body: &[u8]) -> ClientError {
    match wire::parse_body(body) {
        Ok(fields) => ClientError::Server {
            code: fields
                .get("code")
                .map(|code| String::from_utf8_lossy(code).into_owned())
                .unwrap_or_else(|| "unknown".to_string()),
            message: fields
                .get("message")
                .map(|message| String::from_utf8_lossy(message).into_owned())
                .unwrap_or_default(),
        },
        Err(err) => ClientError::Protocol(err.to_string()),
    }
}

fn next_frame<S: ClientStream>(stream: &mut S) -> Result<(Kind, Vec<u8>), ClientError> {
    match wire::read_frame(stream, MAX_BODY) {
        Ok(Some(frame)) => Ok(frame),
        Ok(None) => Err(ClientError::Protocol(
            "the connection closed mid-exchange".to_string(),
        )),
        Err(FrameError::Idle) => Err(ClientError::Protocol(
            "the bridge is not responding".to_string(),
        )),
        Err(FrameError::Proto(err)) => Err(ClientError::Protocol(err.to_string())),
        Err(e) => Err(ClientError::Protocol(e.to_string())),
    }
}

fn read_response<S: ClientStream>(stream: &mut S) -> Result<Fields, ClientError> {
    match next_frame(stream)? {
        (Kind::Response, body) => {
            wire::parse_body(&body).map_err(|err| ClientError::Protocol(err.to_string()))
        }
        (Kind::Error, body) => Err(server_error(&body)),
        (kind, _) => Err(ClientError::Protocol(format!(
            "expected R or E, heard {kind}"
        ))),
    }
}

fn read_fields<S: ClientStream>(stream: &mut S, expected: Kind) -> Result<Fields, ClientError> {
    match next_frame(stream)? {
        (kind, body) if kind == expected => {
            wire::parse_body(&body).map_err(|err| ClientError::Protocol(err.to_string()))
        }
        // §9.2: an `E` before the proof is renderable but unactionable.
        (Kind::Error, body) => Err(server_error(&body)),
        (kind, _) => Err(ClientError::Protocol(format!(
            "expected {expected}, heard {kind}"
        ))),
    }
}

/// Accumulates preamble bytes across short reads; `Ok(true)` once full,
/// `Ok(false)` on a timeout with the count preserved for the diagnostic.
fn fill_some<S: ClientStream>(
    stream: &mut S,
    buf: &mut [u8; PREAMBLE_LEN],
    got: &mut usize,
) -> std::io::Result<bool> {
    while *got < PREAMBLE_LEN {
        match stream.read(&mut buf[*got..]) {
            Ok(0) => return Ok(false),
            Ok(n) => *got += n,
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                return Ok(false)
            }
            Err(e) => return Err(e),
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_skew_diagnostic_takes_the_specified_shapes() {
        // §7.1's worked example, far side behind, clause included: proto 0
        // does not exist, so a v1 op against a proto-0 server carries the
        // "needs proto 1" clause.
        assert_eq!(
            skew_message("clip.set.files", Some(0), SIDE_TUNNEL),
            "the clipboard bridge on the machine at the other end of the SSH \
             tunnel is behind — it speaks RECOB proto 0, this client speaks \
             proto 1, and clip.set.files needs proto 1. Run chezmoi apply there."
        );
        // An operation this client's registry does not know cannot claim an
        // age: the clause drops rather than asserting something false.
        assert_eq!(
            skew_message("no.such.op", Some(0), SIDE_LOCAL),
            "this machine's clipboard bridge is behind — it speaks RECOB \
             proto 0, this client speaks proto 1. Run chezmoi apply here."
        );
        // This side behind: the remedy is updating the client, always here.
        assert_eq!(
            skew_message("clip.get", Some(2), SIDE_LOCAL),
            "this machine's clipboard bridge is ahead of this client \
             (proto 2 vs 1) — run chezmoi apply here."
        );
        // Versions equal: the caps set is authoritative over the integer.
        assert_eq!(
            skew_message("osd.notify", Some(1), SIDE_TUNNEL),
            "the clipboard bridge on the machine at the other end of the SSH \
             tunnel does not support osd.notify"
        );
        // An unparseable server proto must not invent a comparison.
        assert_eq!(
            skew_message("clip.get", None, SIDE_LOCAL),
            "this machine's clipboard bridge does not support clip.get"
        );
    }

    #[test]
    fn the_action_deadline_defaults_to_twenty_seconds() {
        // The value is not shell-observable (it never crosses the wire), so
        // this is where it is pinned. RECOB_ACTION_TIMEOUT_S tunes it; the
        // spec suite asserts the mapping at the invoker seam.
        if std::env::var_os("RECOB_ACTION_TIMEOUT_S").is_none() {
            assert_eq!(Timeouts::default().action, Duration::from_secs(20));
        }
    }

    #[test]
    fn every_registry_operation_declares_since_one_at_proto_one() {
        // Until the first proto bump, a `since` above PROTO could only be a
        // typo — the daemon's registry has the same assertion on its side.
        for (op, since) in crate::registry::OPS {
            assert!(
                *since >= 1 && *since <= wire::PROTO,
                "{op} declares since {since} against proto {}",
                wire::PROTO
            );
        }
    }

    #[test]
    fn a_pushed_token_is_validated_before_use() {
        use std::os::unix::fs::PermissionsExt;
        let dir = crate::testutil::tempdir("client-token");
        let path = dir.path().join("tunnel-token");
        let good = "ab".repeat(32);

        std::fs::write(&path, format!("{good}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(
            read_pushed_token(&path).is_some(),
            "a clean 0600 file reads"
        );

        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        assert!(
            read_pushed_token(&path).is_none(),
            "§9.2: group/other bits mean absent"
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();

        std::fs::write(&path, format!("{good}\ntrailing junk\n")).unwrap();
        assert!(
            read_pushed_token(&path).is_none(),
            "trailing content means absent"
        );

        std::fs::write(&path, format!("{}\n", "XY".repeat(32))).unwrap();
        assert!(read_pushed_token(&path).is_none(), "not hex means absent");

        assert!(read_pushed_token(&dir.path().join("missing")).is_none());
    }
}
