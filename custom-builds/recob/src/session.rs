//! The connection lifecycle (§5): preamble, banner, hello, capabilities, then
//! request/response exchanges until either side closes.
//!
//! One connection carries any number of exchanges (P2) and responses are
//! strictly ordered — the Nth `R`/`E` answers the Nth `Q` — so there are no
//! request identifiers and the handler is single-threaded per connection.
//!
//! Phase 1 has no authentication (§9.2 is Phase 2). Two consequences are
//! deliberate and visible here: the banner carries no `nonce`, and the
//! capabilities frame carries no `proof`. Both are absent rather than stubbed,
//! because a nonce nobody challenges with is worse than no nonce at all.

use std::io::{Read, Write};
use std::time::Duration;

use crate::host::HostIdentity;
use crate::listen::Endpoint;
use crate::log;
use crate::record::{Directive, Recorder, Script};
use crate::registry;
use crate::wire::{
    self, Fields, FrameError, Kind, ProtoError, MAX_BODY, PREAMBLE_LEN, PROTO, WIRE_VERSION,
};

/// §6.4: a `D` chunk is at most 64 KiB.
const CHUNK: usize = 64 * 1024;

pub struct Ctx {
    pub host: HostIdentity,
    /// §5.1 `impl`: build identity, diagnostics only, never compared
    /// programmatically. Phase 8's build hook passes the chezmoi source hash
    /// prefix in `RECOB_IMPL`; a hand-built binary says so.
    pub impl_id: String,
    pub exchange_timeout: Duration,
    pub recorder: Option<Recorder>,
}

impl Ctx {
    pub fn new(host: HostIdentity, impl_id: String, exchange_timeout: Duration) -> Self {
        Ctx {
            host,
            impl_id,
            exchange_timeout,
            recorder: None,
        }
    }
}

pub fn serve<S: Read + Write>(stream: &mut S, accepted_on: Endpoint, peer: &str, ctx: &Ctx) {
    let endpoint = ctx
        .recorder
        .as_ref()
        .map_or(accepted_on, |r| r.label(accepted_on));
    let mut script = ctx
        .recorder
        .as_ref()
        .map(|r| r.open_script())
        .unwrap_or_default();

    // §4.1: the server writes its six preamble bytes and its banner immediately
    // on accept, never waiting for the client, so a peer learns straight away
    // that it is talking to RECOB.
    let banner_proto = script.hello_proto().unwrap_or(PROTO);
    let mut banner = Fields::new();
    banner.push("proto", banner_proto.to_string().into_bytes());
    if let Some(host) = ctx.host.current() {
        banner.push("host", host.into_bytes());
    }
    let mut opening = wire::preamble().to_vec();
    opening.extend_from_slice(&wire::encode(Kind::Hello, &banner));
    if !send(stream, &opening, endpoint, peer) {
        return;
    }

    // §4.1: the client writes the same six bytes.
    match read_preamble(stream) {
        Preamble::Version(WIRE_VERSION) => {}
        Preamble::Version(other) => {
            let err = ProtoError::new(
                "wire-version-mismatch",
                format!(
                    "this endpoint speaks wire version {WIRE_VERSION}, the caller speaks {other}"
                ),
            );
            log!("{} {peer}: {err}", endpoint.as_str());
            send(stream, &err.frame(), endpoint, peer);
            return;
        }
        // §7.3 specifies a diagnostic shim in the *old* framing for this case.
        // It is Phase 5/7 work and deliberately not implemented here: writing a
        // RECOB frame to a peer that by definition cannot parse one would be
        // worse than the log line.
        Preamble::NotRecob(head) => {
            log!(
                "{} {peer}: not a RECOB peer (first bytes {:?}); closing",
                endpoint.as_str(),
                String::from_utf8_lossy(&head)
            );
            return;
        }
        Preamble::Short(n) => {
            log!(
                "{} {peer}: closed after {n} preamble bytes",
                endpoint.as_str()
            );
            return;
        }
        Preamble::Timeout => {
            log!(
                "{} {peer}: no preamble within the read timeout",
                endpoint.as_str()
            );
            return;
        }
        Preamble::Io(e) => {
            log!("{} {peer}: preamble read failed: {e}", endpoint.as_str());
            return;
        }
    }

    // §4.2: the hello is the first frame and arrives exactly once per side.
    let hello = match wire::read_frame(stream, MAX_BODY) {
        Ok(Some((Kind::Hello, body))) => match wire::parse_body(&body) {
            Ok(fields) => fields,
            Err(err) => {
                log!("{} {peer}: bad hello: {err}", endpoint.as_str());
                send(stream, &err.frame(), endpoint, peer);
                return;
            }
        },
        Ok(Some((kind, _))) => {
            let err = ProtoError::new(
                "bad-request",
                format!("first frame was {kind}, expected the hello"),
            );
            log!("{} {peer}: {err}", endpoint.as_str());
            send(stream, &err.frame(), endpoint, peer);
            return;
        }
        Ok(None) => {
            log!("{} {peer}: closed before its hello", endpoint.as_str());
            return;
        }
        Err(e) => {
            log!("{} {peer}: no hello: {e}", endpoint.as_str());
            if let FrameError::Proto(err) = e {
                send(stream, &err.frame(), endpoint, peer);
            }
            return;
        }
    };
    if let Err(err) = check_hello(&hello) {
        log!("{} {peer}: bad hello: {err}", endpoint.as_str());
        send(stream, &err.frame(), endpoint, peer);
        return;
    }
    if let Some(recorder) = &ctx.recorder {
        recorder.record(endpoint, "hello", &hello);
    }
    // §7.2: a differing `proto` never refuses the connection. The operation is
    // the unit of compatibility, and `unknown-op` / `unknown-field` are what
    // carry the diagnostic.
    let peer_proto = hello
        .get("proto")
        .map(|v| String::from_utf8_lossy(v).into_owned())
        .unwrap_or_default();

    // §5.1: capabilities ride back in front of the first response rather than
    // being asked for, so the split costs no round trip.
    let mut caps = Fields::new();
    caps.push("impl", ctx.impl_id.as_bytes());
    caps.push("endpoint", endpoint.as_str());
    caps.push("caps", registry::caps());
    if !send(stream, &wire::encode(Kind::Caps, &caps), endpoint, peer) {
        return;
    }

    // Exchange loop. The cap is §4.2's default; §6.5 raises it for one operation
    // and §3.5 lowers it sharply pre-auth, both in later phases, which is why
    // the decoder takes it as an argument.
    loop {
        match wire::read_frame_at_boundary(stream, MAX_BODY) {
            Ok(Some((Kind::Request, body))) => {
                let action = handle_request(&body, endpoint, peer, ctx, &mut script);
                if !action.bytes.is_empty() && !send(stream, &action.bytes, endpoint, peer) {
                    return;
                }
                if action.close {
                    return;
                }
            }
            Ok(Some((kind, _))) => {
                let err = ProtoError::new(
                    "bad-request",
                    format!("a client may not send a {kind} frame"),
                );
                log!("{} {peer}: {err}", endpoint.as_str());
                send(stream, &err.frame(), endpoint, peer);
                return;
            }
            Ok(None) => return,
            Err(FrameError::Idle) => {
                log!(
                    "{} {peer}: idle for {:?} after proto {peer_proto}; closing",
                    endpoint.as_str(),
                    ctx.exchange_timeout
                );
                return;
            }
            Err(FrameError::Proto(err)) => {
                log!("{} {peer}: {err}", endpoint.as_str());
                send(stream, &err.frame(), endpoint, peer);
                return;
            }
            Err(e) => {
                log!("{} {peer}: {e}", endpoint.as_str());
                return;
            }
        }
    }
}

struct Action {
    bytes: Vec<u8>,
    close: bool,
}

impl Action {
    fn reply(bytes: Vec<u8>) -> Self {
        Action {
            bytes,
            close: false,
        }
    }

    fn from_error(err: ProtoError) -> Self {
        Action {
            bytes: err.frame(),
            close: err.closes,
        }
    }
}

fn handle_request(
    body: &[u8],
    endpoint: Endpoint,
    peer: &str,
    ctx: &Ctx,
    script: &mut Script,
) -> Action {
    let fields = match wire::parse_body(body) {
        Ok(fields) => fields,
        Err(err) => {
            log!("{} {peer}: {err}", endpoint.as_str());
            return Action::from_error(err);
        }
    };
    let Some(raw_op) = fields.get("op") else {
        let err = ProtoError::new("missing-field", "a request must name its operation")
            .with("field", "op");
        log!("{} {peer}: {err}", endpoint.as_str());
        return Action::from_error(err);
    };
    let name = String::from_utf8_lossy(raw_op).into_owned();
    let Some(op) = registry::find(&name) else {
        // §10: `unknown-op` carries `op`, `proto` and `impl`, so two builds
        // sharing a proto are still distinguishable (§7.1).
        let err = ProtoError::new("unknown-op", format!("this build cannot dispatch {name}"))
            .with("op", raw_op.to_vec())
            .with("proto", PROTO.to_string().into_bytes())
            .with("impl", ctx.impl_id.as_bytes());
        log!(
            "{} {peer}: unknown op {}",
            endpoint.as_str(),
            printable(raw_op)
        );
        return Action::from_error(err);
    };
    if let Err(err) = registry::validate_request(op, &fields) {
        log!("{} {peer} {}: {err}", endpoint.as_str(), op.name);
        return Action::from_error(err);
    }

    // The recorder tees only what decoded and validated. That ordering is the
    // whole strength of the seam (§11.1): a subtly wrong frame fails here
    // instead of being faithfully recorded as wrong.
    if let Some(recorder) = &ctx.recorder {
        recorder.record(endpoint, op.name, &fields);
    }

    match script.next_directive() {
        Some(directive) => scripted(directive, endpoint, peer, op.name),
        None => match registry::dispatch(op, &fields, ctx) {
            Ok(response) => Action::reply(wire::encode(Kind::Response, &response)),
            Err(err) => {
                log!("{} {peer} {}: {err}", endpoint.as_str(), op.name);
                Action::from_error(err)
            }
        },
    }
}

/// A scripted reply (§11.1). Dispatch and authorization are unchanged by
/// `--record`; only the answer comes from the script instead of the handler.
fn scripted(directive: Directive, endpoint: Endpoint, peer: &str, op: &str) -> Action {
    match directive {
        Directive::Ok(fields) => Action::reply(wire::encode(Kind::Response, &fields)),
        Directive::Err { code, message } => Action::from_error(ProtoError::new(&code, message)),
        Directive::Stream(path) => match std::fs::read(&path) {
            Ok(bytes) => {
                let mut out = wire::encode(
                    Kind::Response,
                    &Fields::new().with("size", bytes.len().to_string().into_bytes()),
                );
                for chunk in bytes.chunks(CHUNK) {
                    out.extend_from_slice(&wire::encode_raw(Kind::Data, chunk));
                }
                // §6.4: an explicit zero-length chunk ends the stream, so
                // truncation is detectable.
                out.extend_from_slice(&wire::encode_raw(Kind::Data, &[]));
                Action::reply(out)
            }
            Err(e) => {
                log!(
                    "{} {peer} {op}: stream {} failed: {e}",
                    endpoint.as_str(),
                    path.display()
                );
                Action::from_error(ProtoError::new(
                    "internal",
                    format!("cannot read {}: {e}", path.display()),
                ))
            }
        },
        // "disconnect mid-frame, to exercise truncation handling": a header that
        // declares a body, and then nothing.
        Directive::Close => Action {
            bytes: vec![Kind::Response.byte(), 0, 0, 0, 32],
            close: true,
        },
        Directive::Malformed(why) => {
            log!(
                "{} {peer} {op}: malformed reply directive: {why}",
                endpoint.as_str()
            );
            Action::from_error(ProtoError::new(
                "internal",
                format!("malformed recorder directive: {why}"),
            ))
        }
    }
}

/// §5.1's client hello. Phase 2 adds `auth` and `cnonce`; until then a client
/// that sends them gets `unknown-field` naming the field, which is P6 working as
/// intended rather than a gap — the alternative is a credential silently ignored.
fn check_hello(fields: &Fields) -> Result<(), ProtoError> {
    for name in fields.names() {
        if !matches!(name, "proto" | "impl") {
            return Err(ProtoError::new(
                "unknown-field",
                format!("this build does not know the hello field {name}"),
            )
            .with("field", name)
            .with("proto", PROTO.to_string().into_bytes()));
        }
    }
    let Some(proto) = fields.get("proto") else {
        return Err(ProtoError::new("missing-field", "hello without proto").with("field", "proto"));
    };
    // §6.6: decimal integer, 1–4 digits.
    if proto.is_empty() || proto.len() > 4 || !proto.iter().all(u8::is_ascii_digit) {
        return Err(
            ProtoError::new("bad-field", "proto is not a 1-4 digit decimal").with("field", "proto"),
        );
    }
    if let Some(build) = fields.get("impl") {
        // §6.6: ≤ 64 bytes, [A-Za-z0-9._-].
        if build.is_empty()
            || build.len() > 64
            || !build
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return Err(
                ProtoError::new("bad-field", "impl outside [A-Za-z0-9._-]{1,64}")
                    .with("field", "impl"),
            );
        }
    }
    Ok(())
}

enum Preamble {
    Version(u8),
    NotRecob(Vec<u8>),
    Short(usize),
    Timeout,
    Io(std::io::Error),
}

fn read_preamble<R: Read>(r: &mut R) -> Preamble {
    let mut buf = [0u8; PREAMBLE_LEN];
    match wire::fill(r, &mut buf) {
        Ok(n) if n == PREAMBLE_LEN => {
            if &buf[..wire::MAGIC.len()] == wire::MAGIC {
                Preamble::Version(buf[wire::MAGIC.len()])
            } else {
                Preamble::NotRecob(buf.to_vec())
            }
        }
        Ok(0) => Preamble::Timeout,
        Ok(n) => {
            if buf[..n] != wire::MAGIC[..n.min(wire::MAGIC.len())] {
                Preamble::NotRecob(buf[..n].to_vec())
            } else {
                Preamble::Short(n)
            }
        }
        Err(e) => Preamble::Io(e),
    }
}

fn send<S: Write>(stream: &mut S, bytes: &[u8], endpoint: Endpoint, peer: &str) -> bool {
    match stream.write_all(bytes).and_then(|_| stream.flush()) {
        Ok(()) => true,
        Err(e) => {
            log!("{} {peer}: write failed: {e}", endpoint.as_str());
            false
        }
    }
}

/// For log lines only: an operation name arrives as arbitrary bytes, and a log
/// file is not the place to render them raw.
fn printable(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| {
            if b.is_ascii_graphic() || *b == b' ' {
                (*b as char).to_string()
            } else {
                format!("\\x{b:02x}")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hello_needs_a_well_formed_proto() {
        check_hello(&Fields::new().with("proto", b"1".to_vec())).unwrap();
        check_hello(
            &Fields::new()
                .with("proto", b"12".to_vec())
                .with("impl", b"a1b2c3d4".to_vec()),
        )
        .unwrap();

        let err = check_hello(&Fields::new()).unwrap_err();
        assert_eq!(err.code, "missing-field");

        let err = check_hello(&Fields::new().with("proto", b"one".to_vec())).unwrap_err();
        assert_eq!(err.code, "bad-field");

        let err = check_hello(&Fields::new().with("proto", b"12345".to_vec())).unwrap_err();
        assert_eq!(err.code, "bad-field");

        let err = check_hello(
            &Fields::new()
                .with("proto", b"1".to_vec())
                .with("impl", b"build id".to_vec()),
        )
        .unwrap_err();
        assert_eq!(err.detail.get("field"), Some(&b"impl"[..]));
    }

    #[test]
    fn a_phase_two_credential_is_refused_by_name_not_ignored() {
        let err = check_hello(
            &Fields::new()
                .with("proto", b"1".to_vec())
                .with("auth", b"deadbeef".to_vec()),
        )
        .unwrap_err();
        assert_eq!(err.code, "unknown-field");
        assert_eq!(err.detail.get("field"), Some(&b"auth"[..]));
    }

    #[test]
    fn the_preamble_sniff_separates_a_short_read_from_a_stranger() {
        let mut cursor = std::io::Cursor::new(b"RECOB\x01".to_vec());
        assert!(matches!(read_preamble(&mut cursor), Preamble::Version(1)));

        let mut cursor = std::io::Cursor::new(b"RECOB\x09".to_vec());
        assert!(matches!(read_preamble(&mut cursor), Preamble::Version(9)));

        let mut cursor = std::io::Cursor::new(b"REC".to_vec());
        assert!(matches!(read_preamble(&mut cursor), Preamble::Short(3)));

        let mut cursor = std::io::Cursor::new(b"H\x00\x00\x00\x00\x00".to_vec());
        assert!(matches!(read_preamble(&mut cursor), Preamble::NotRecob(_)));

        let mut cursor = std::io::Cursor::new(Vec::new());
        assert!(matches!(read_preamble(&mut cursor), Preamble::Timeout));
    }

    #[test]
    fn printable_escapes_what_a_log_line_should_not_carry() {
        assert_eq!(printable(b"host.identity"), "host.identity");
        assert_eq!(printable(b"a\nb\0"), "a\\x0ab\\x00");
    }
}
