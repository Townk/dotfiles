//! The wire format: preamble, frames, named fields (spec §4) and the error
//! taxonomy they are reported through (§10).
//!
//! All integers are big-endian and unsigned; values are arbitrary bytes and
//! nothing is escaped or delimited, which is the property §4.3 chose named
//! length-prefixed fields for.

use std::fmt;
use std::io::{self, Read};

/// §4.1 preamble: `"RECOB"` then one `wire_version` byte.
pub const MAGIC: &[u8; 5] = b"RECOB";
pub const WIRE_VERSION: u8 = 1;
pub const PREAMBLE_LEN: usize = MAGIC.len() + 1;

/// §5.1 semantic protocol version. Bumped when the registry, a field set or an
/// authorization requirement changes — never for framing, which `WIRE_VERSION`
/// governs.
pub const PROTO: u32 = 1;

/// §4.2 default body cap. A decoder takes its cap from the operation's registry
/// entry rather than hardcoding this, which is why `read_frame` takes it as an
/// argument.
pub const MAX_BODY: usize = 64 * 1024 * 1024;

/// §4.3 field-name length limit.
pub const MAX_NAME: usize = 32;

/// §4.2 frame kinds. `Caps` is its own kind rather than a second `Hello` or a
/// first `Response` for the reason §4.2 gives at length: it is the one frame a
/// client parses before it has verified the server's proof.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Hello,
    Caps,
    Request,
    Response,
    Error,
    Data,
}

impl Kind {
    pub fn byte(self) -> u8 {
        match self {
            Kind::Hello => b'H',
            Kind::Caps => b'C',
            Kind::Request => b'Q',
            Kind::Response => b'R',
            Kind::Error => b'E',
            Kind::Data => b'D',
        }
    }

    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            b'H' => Some(Kind::Hello),
            b'C' => Some(Kind::Caps),
            b'Q' => Some(Kind::Request),
            b'R' => Some(Kind::Response),
            b'E' => Some(Kind::Error),
            b'D' => Some(Kind::Data),
            _ => None,
        }
    }
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.byte() as char)
    }
}

/// A body: named fields in wire order. Order is not significant to a reader
/// (§4.3) but it is preserved so an encoder can reproduce a byte-exact frame,
/// which is what the §4.4 worked example asserts.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Fields(Vec<(String, Vec<u8>)>);

impl Fields {
    pub fn new() -> Self {
        Fields(Vec::new())
    }

    /// Appends a field. Duplicate names are a protocol error on the wire
    /// (§4.3); a caller that pushes one is a bug in this build, so it is caught
    /// here rather than emitted.
    pub fn push(&mut self, name: &str, value: impl Into<Vec<u8>>) -> &mut Self {
        debug_assert!(valid_name(name.as_bytes()), "invalid field name {name:?}");
        debug_assert!(self.get(name).is_none(), "duplicate field name {name:?}");
        self.0.push((name.to_string(), value.into()));
        self
    }

    pub fn with(mut self, name: &str, value: impl Into<Vec<u8>>) -> Self {
        self.push(name, value);
        self
    }

    pub fn get(&self, name: &str) -> Option<&[u8]> {
        self.0
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_slice())
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &[u8])> {
        self.0.iter().map(|(n, v)| (n.as_str(), v.as_slice()))
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Names present, in wire order — used to report the first unrecognized one.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.0.iter().map(|(n, _)| n.as_str())
    }
}

/// An `E` frame's payload (§10): a stable machine-readable `code`, a human
/// `message` that is explicitly not a contract, and operation-specific detail.
/// `closes` is §10's Connection column.
#[derive(Clone, Debug)]
pub struct ProtoError {
    pub code: String,
    pub message: String,
    pub detail: Fields,
    pub closes: bool,
}

impl ProtoError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        ProtoError {
            code: code.to_string(),
            message: message.into(),
            detail: Fields::new(),
            closes: code_closes(code),
        }
    }

    pub fn with(mut self, name: &str, value: impl Into<Vec<u8>>) -> Self {
        self.detail.push(name, value);
        self
    }

    /// Forces the connection closed for a case §10 leaves open but the stream
    /// cannot survive — an unparseable frame header desynchronizes the reader,
    /// so there is no next frame boundary to resume at.
    pub fn closing(mut self) -> Self {
        self.closes = true;
        self
    }

    pub fn body(&self) -> Fields {
        let mut f = Fields::new();
        f.push("code", self.code.as_bytes());
        f.push("message", self.message.as_bytes());
        for (n, v) in self.detail.iter() {
            f.push(n, v);
        }
        f
    }

    pub fn frame(&self) -> Vec<u8> {
        encode(Kind::Error, &self.body())
    }
}

impl fmt::Display for ProtoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

/// §10's Connection column, for the codes this build can emit.
fn code_closes(code: &str) -> bool {
    matches!(code, "wire-version-mismatch" | "too-large" | "busy")
}

/// §4.3: names are `[a-z][a-z0-9_.]*`, at most 32 bytes.
pub fn valid_name(name: &[u8]) -> bool {
    if name.is_empty() || name.len() > MAX_NAME {
        return false;
    }
    if !name[0].is_ascii_lowercase() {
        return false;
    }
    name[1..]
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_' || *b == b'.')
}

pub fn encode_body(fields: &Fields) -> Vec<u8> {
    let mut out = Vec::new();
    for (name, value) in fields.iter() {
        out.push(name.len() as u8);
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value);
    }
    out
}

pub fn encode(kind: Kind, fields: &Fields) -> Vec<u8> {
    let body = encode_body(fields);
    let mut out = Vec::with_capacity(5 + body.len());
    out.push(kind.byte());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    out
}

pub fn encode_raw(kind: Kind, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + body.len());
    out.push(kind.byte());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(body);
    out
}

pub fn preamble() -> [u8; PREAMBLE_LEN] {
    [
        MAGIC[0],
        MAGIC[1],
        MAGIC[2],
        MAGIC[3],
        MAGIC[4],
        WIRE_VERSION,
    ]
}

/// Parses a body into fields. Framing is length-delimited, so every error here
/// leaves the reader positioned at the next frame boundary and the connection
/// can carry on — which is why these are `closes: false` per §10.
pub fn parse_body(body: &[u8]) -> Result<Fields, ProtoError> {
    let mut fields = Fields::new();
    let mut i = 0usize;
    while i < body.len() {
        let name_len = body[i] as usize;
        i += 1;
        if name_len == 0 {
            return Err(ProtoError::new("bad-request", "zero-length field name"));
        }
        if name_len > MAX_NAME {
            return Err(ProtoError::new(
                "bad-request",
                format!("field name longer than {MAX_NAME} bytes"),
            ));
        }
        if body.len() - i < name_len {
            return Err(ProtoError::new("bad-request", "truncated field name"));
        }
        let name = &body[i..i + name_len];
        i += name_len;
        if !valid_name(name) {
            return Err(ProtoError::new(
                "bad-request",
                "field name outside [a-z][a-z0-9_.]*",
            ));
        }
        if body.len() - i < 4 {
            return Err(ProtoError::new("bad-request", "truncated field length"));
        }
        let value_len =
            u32::from_be_bytes([body[i], body[i + 1], body[i + 2], body[i + 3]]) as usize;
        i += 4;
        if body.len() - i < value_len {
            return Err(ProtoError::new("bad-request", "field value past body end"));
        }
        let value = &body[i..i + value_len];
        i += value_len;

        // §4.3: a duplicate field name is `bad-field`, named so the sender can
        // tell which one.
        let name = String::from_utf8_lossy(name).into_owned();
        if fields.get(&name).is_some() {
            return Err(ProtoError::new("bad-field", "duplicate field").with("field", name));
        }
        fields.0.push((name, value.to_vec()));
    }
    Ok(fields)
}

/// What went wrong reading a frame. Separate from `ProtoError` because most of
/// these have no peer left to answer.
#[derive(Debug)]
pub enum FrameError {
    /// The read timed out at a frame boundary: the peer is idle, not broken.
    Idle,
    /// The stream ended or stalled part-way through a frame.
    Truncated,
    Io(io::Error),
    Proto(ProtoError),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FrameError::Idle => write!(f, "idle timeout"),
            FrameError::Truncated => write!(f, "truncated frame"),
            FrameError::Io(e) => write!(f, "io error: {e}"),
            FrameError::Proto(e) => write!(f, "{e}"),
        }
    }
}

fn is_timeout(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
    )
}

/// Reads until `buf` is full. Returns how many bytes were read; short means the
/// peer stopped (EOF or timeout), and `Err` is a real IO failure.
pub fn fill<R: Read>(r: &mut R, buf: &mut [u8]) -> Result<usize, io::Error> {
    let mut got = 0usize;
    while got < buf.len() {
        match r.read(&mut buf[got..]) {
            Ok(0) => return Ok(got),
            Ok(n) => got += n,
            Err(ref e) if is_timeout(e) => return Ok(got),
            Err(e) => return Err(e),
        }
    }
    Ok(got)
}

/// Reads one frame. `Ok(None)` is a clean close at a frame boundary, which §5
/// permits either side to do after any complete exchange.
///
/// `cap` is the body limit that applies to this read, per §4.2: the caller
/// supplies it from the operation's registry entry (or, pre-auth, from §3.5)
/// rather than the decoder assuming 64 MiB.
pub fn read_frame<R: Read>(r: &mut R, cap: usize) -> Result<Option<(Kind, Vec<u8>)>, FrameError> {
    let mut head = [0u8; 5];
    let got = fill(r, &mut head).map_err(FrameError::Io)?;
    if got == 0 {
        return Ok(None);
    }
    if got < head.len() {
        return Err(FrameError::Truncated);
    }
    let kind = Kind::from_byte(head[0]).ok_or_else(|| {
        FrameError::Proto(
            ProtoError::new("bad-request", "unknown frame kind")
                .with("kind", vec![head[0]])
                .closing(),
        )
    })?;
    let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if len > cap {
        return Err(FrameError::Proto(
            ProtoError::new(
                "too-large",
                format!("declared body length {len} above the {cap}-byte limit for this frame"),
            )
            .with("limit", cap.to_string().into_bytes()),
        ));
    }
    let mut body = vec![0u8; len];
    let got = fill(r, &mut body).map_err(FrameError::Io)?;
    if got < len {
        return Err(FrameError::Truncated);
    }
    Ok(Some((kind, body)))
}

/// Reads a frame at a boundary where an idle peer is distinguishable from a
/// stalled one: a timeout before the first byte is `Idle`, after it `Truncated`.
pub fn read_frame_at_boundary<R: Read>(
    r: &mut R,
    cap: usize,
) -> Result<Option<(Kind, Vec<u8>)>, FrameError> {
    let mut first = [0u8; 1];
    match r.read(&mut first) {
        Ok(0) => return Ok(None),
        Ok(_) => {}
        Err(ref e) if is_timeout(e) => return Err(FrameError::Idle),
        Err(e) => return Err(FrameError::Io(e)),
    }
    let mut rest = PrefixedRead {
        prefix: &first,
        inner: r,
    };
    read_frame(&mut rest, cap)
}

struct PrefixedRead<'a, R: Read> {
    prefix: &'a [u8],
    inner: &'a mut R,
}

impl<R: Read> Read for PrefixedRead<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if !self.prefix.is_empty() {
            let n = self.prefix.len().min(buf.len());
            buf[..n].copy_from_slice(&self.prefix[..n]);
            self.prefix = &self.prefix[n..];
            return Ok(n);
        }
        self.inner.read(buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn field_names_follow_the_grammar() {
        assert!(valid_name(b"op"));
        assert!(valid_name(b"origin_host"));
        assert!(valid_name(b"host.identity0"));
        assert!(!valid_name(b""));
        assert!(!valid_name(b"Op"));
        assert!(!valid_name(b"0op"));
        assert!(!valid_name(b"op-name"));
        assert!(!valid_name(&[b'a'; MAX_NAME + 1]));
    }

    #[test]
    fn values_carry_arbitrary_bytes_including_nul() {
        let fields = Fields::new().with("text", b"hi\n\0".to_vec());
        let round = parse_body(&encode_body(&fields)).unwrap();
        assert_eq!(round.get("text"), Some(&b"hi\n\0"[..]));
    }

    #[test]
    fn empty_and_absent_are_distinct() {
        let fields = Fields::new().with("text", Vec::new());
        let round = parse_body(&encode_body(&fields)).unwrap();
        assert_eq!(round.get("text"), Some(&b""[..]));
        assert_eq!(round.get("regtype"), None);
    }

    #[test]
    fn duplicate_field_is_bad_field() {
        let mut body = encode_body(&Fields::new().with("op", b"host.identity".to_vec()));
        body.extend_from_slice(&encode_body(
            &Fields::new().with("op", b"host.identity".to_vec()),
        ));
        let err = parse_body(&body).unwrap_err();
        assert_eq!(err.code, "bad-field");
        assert_eq!(err.detail.get("field"), Some(&b"op"[..]));
        assert!(!err.closes);
    }

    #[test]
    fn a_value_past_the_body_end_is_bad_request() {
        // name "op", value_len 9, but only 4 value bytes follow.
        let body = b"\x02op\x00\x00\x00\x09clip".to_vec();
        let err = parse_body(&body).unwrap_err();
        assert_eq!(err.code, "bad-request");
        assert!(!err.closes);
    }

    #[test]
    fn an_uppercase_field_name_is_refused_rather_than_ignored() {
        let body = b"\x02Op\x00\x00\x00\x00".to_vec();
        assert_eq!(parse_body(&body).unwrap_err().code, "bad-request");
    }

    #[test]
    fn a_declared_length_above_the_cap_is_too_large_and_closes() {
        let mut stream = io::Cursor::new(encode_raw(Kind::Request, &[0u8; 64]));
        let err = read_frame(&mut stream, 16).unwrap_err();
        match err {
            FrameError::Proto(e) => {
                assert_eq!(e.code, "too-large");
                assert!(e.closes);
            }
            other => panic!("expected too-large, got {other}"),
        }
    }

    #[test]
    fn an_unknown_frame_kind_closes_the_connection() {
        let mut stream = io::Cursor::new(b"Z\x00\x00\x00\x00".to_vec());
        match read_frame(&mut stream, MAX_BODY).unwrap_err() {
            FrameError::Proto(e) => {
                assert_eq!(e.code, "bad-request");
                assert!(e.closes, "a desynchronized stream cannot be resumed");
            }
            other => panic!("expected bad-request, got {other}"),
        }
    }

    #[test]
    fn a_short_body_is_truncation_not_a_frame() {
        let mut stream = io::Cursor::new(b"Q\x00\x00\x00\x08abc".to_vec());
        assert!(matches!(
            read_frame(&mut stream, MAX_BODY).unwrap_err(),
            FrameError::Truncated
        ));
    }

    #[test]
    fn eof_at_a_frame_boundary_is_a_clean_close() {
        let mut stream = io::Cursor::new(Vec::new());
        assert!(read_frame(&mut stream, MAX_BODY).unwrap().is_none());
    }

    #[test]
    fn frames_round_trip_through_the_boundary_reader() {
        let fields = Fields::new()
            .with("op", b"host.identity".to_vec())
            .with("text", b"\0\0".to_vec());
        let mut stream = io::Cursor::new(encode(Kind::Request, &fields));
        let (kind, body) = read_frame_at_boundary(&mut stream, MAX_BODY)
            .unwrap()
            .unwrap();
        assert_eq!(kind, Kind::Request);
        assert_eq!(parse_body(&body).unwrap(), fields);
    }
}
