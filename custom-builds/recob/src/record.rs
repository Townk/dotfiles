//! The observation seam (§11.1): `recobd --record`.
//!
//! A mode of the production binary rather than a harness built from the same
//! parts, because "built from the same codec" is a claim that decays the first
//! time someone edits one and not the other. The mode is bounded to teeing
//! decoded exchanges to a log and consulting a reply script: the frame is
//! decoded and validated by exactly the code the daemon serves with, so a client
//! that emits a subtly wrong frame *fails* instead of being faithfully recorded
//! as wrong — which is what the fake `nc` it replaces cannot do.
//!
//! | Variable | Purpose |
//! | --- | --- |
//! | `RECOB_RECORD_LOG` | append one line per decoded exchange |
//! | `RECOB_RECORD_SCRIPT` | scripted replies, one directive per exchange |
//! | `RECOB_RECORD_ENDPOINT` | `public` or `trusted`, so endpoint-dependent policy is testable |

use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::listen::Endpoint;
use crate::log;
use crate::wire::Fields;

pub struct Recorder {
    log: Option<PathBuf>,
    script: Option<PathBuf>,
    endpoint: Option<Endpoint>,
}

impl Recorder {
    pub fn from_env() -> Self {
        let endpoint = std::env::var("RECOB_RECORD_ENDPOINT").ok().and_then(|v| {
            let parsed = Endpoint::parse(v.trim());
            if parsed.is_none() {
                log!("RECOB_RECORD_ENDPOINT={v:?} is neither public nor trusted; ignoring");
            }
            parsed
        });
        Recorder {
            log: std::env::var_os("RECOB_RECORD_LOG").map(PathBuf::from),
            script: std::env::var_os("RECOB_RECORD_SCRIPT").map(PathBuf::from),
            endpoint,
        }
    }

    /// The endpoint a connection is recorded and answered as. `RECOB_RECORD_ENDPOINT`
    /// overrides which listener actually accepted so that endpoint-dependent
    /// policy is reachable from a spec that only has one address to point at.
    pub fn label(&self, accepted_on: Endpoint) -> Endpoint {
        self.endpoint.unwrap_or(accepted_on)
    }

    /// Read fresh per connection, so each connection starts at the first
    /// directive — the behavior a spec that truncates its log per example needs.
    pub fn open_script(&self) -> Script {
        match &self.script {
            Some(path) => Script::load(path),
            None => Script::default(),
        }
    }

    /// §11.1's log line: `<endpoint>\t<op>\t<field>=<hex>…`. Values are hex so
    /// NUL and binary payloads are exact and assertions are unambiguous. The
    /// `op` field is column 2 and is not repeated in the field list.
    pub fn record(&self, endpoint: Endpoint, op: &str, fields: &Fields) {
        let Some(path) = &self.log else { return };
        let mut line = String::new();
        line.push_str(endpoint.as_str());
        line.push('\t');
        line.push_str(op);
        for (name, value) in fields.iter() {
            if name == "op" {
                continue;
            }
            line.push('\t');
            line.push_str(name);
            line.push('=');
            line.push_str(&hex_encode(value));
        }
        line.push('\n');
        // One O_APPEND write per line keeps concurrent connections from
        // interleaving mid-line.
        match OpenOptions::new().create(true).append(true).open(path) {
            Ok(mut f) => {
                if let Err(e) = f.write_all(line.as_bytes()) {
                    log!("cannot write {}: {e}", path.display());
                }
            }
            Err(e) => log!("cannot open {}: {e}", path.display()),
        }
    }
}

/// One directive per exchange (§11.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Directive {
    Ok(Fields),
    Err {
        code: String,
        message: String,
    },
    Stream(PathBuf),
    Close,
    /// A directive this build cannot parse. Reported loudly rather than skipped:
    /// a typo in a reply script must not look like a passing test.
    Malformed(String),
}

#[derive(Default)]
pub struct Script {
    hello_proto: Option<u32>,
    /// Connection-level directives (§11.1). Unlike a reply directive these are
    /// not consumed one per exchange: they change how the connection itself is
    /// answered, which is the only way to exercise a client's
    /// untrusted-endpoint and `unauthorized` paths deliberately.
    deny_auth: bool,
    no_proof: bool,
    bad_proof: bool,
    directives: VecDeque<String>,
}

impl Script {
    fn load(path: &Path) -> Self {
        let mut script = Script::default();
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(e) => {
                log!("cannot read RECOB_RECORD_SCRIPT {}: {e}", path.display());
                return script;
            }
        };
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            // `hello proto=<n>` answers the banner with a chosen version, which
            // is how §7's skew diagnostics get tested without two machines. It
            // applies to the connection, not to one exchange, so it is taken out
            // of the per-exchange queue.
            if let Some(rest) = line.strip_prefix("hello ") {
                match rest.trim().strip_prefix("proto=").map(str::parse::<u32>) {
                    Some(Ok(proto)) => script.hello_proto = Some(proto),
                    _ => log!("unparseable hello directive: {line:?}"),
                }
                continue;
            }
            // The three authentication directives are connection-level for the
            // same reason: they alter the handshake, which happens once.
            match line {
                "deny-auth" => {
                    script.deny_auth = true;
                    continue;
                }
                "no-proof" => {
                    script.no_proof = true;
                    continue;
                }
                "bad-proof" => {
                    script.bad_proof = true;
                    continue;
                }
                _ => {}
            }
            script.directives.push_back(line.to_string());
        }
        script
    }

    pub fn hello_proto(&self) -> Option<u32> {
        self.hello_proto
    }

    /// §11.1: exercise the client's `unauthorized` path without a wrong token.
    pub fn deny_auth(&self) -> bool {
        self.deny_auth
    }

    /// §11.1: withhold the proof, so a client's untrusted-endpoint path runs.
    pub fn no_proof(&self) -> bool {
        self.no_proof
    }

    /// §11.1: answer the client's challenge wrongly, which is the case a client
    /// that merely checks for *presence* of `proof` would pass and must not.
    pub fn bad_proof(&self) -> bool {
        self.bad_proof
    }

    /// The next directive, or `None` when the script is absent or spent — in
    /// which case the daemon answers from its own registry, which is what makes
    /// the recorder usable as a real listener.
    pub fn next_directive(&mut self) -> Option<Directive> {
        let line = self.directives.pop_front()?;
        Some(parse_directive(&line))
    }
}

fn parse_directive(line: &str) -> Directive {
    let (verb, rest) = match line.split_once(char::is_whitespace) {
        Some((verb, rest)) => (verb, rest.trim()),
        None => (line, ""),
    };
    match verb {
        "ok" => {
            let mut fields = Fields::new();
            for token in rest.split_whitespace() {
                let Some((name, hex)) = token.split_once('=') else {
                    return Directive::Malformed(format!("ok field {token:?} is not name=hex"));
                };
                if !crate::wire::valid_name(name.as_bytes()) {
                    return Directive::Malformed(format!(
                        "ok field name {name:?} is not a field name"
                    ));
                }
                if fields.get(name).is_some() {
                    return Directive::Malformed(format!("ok field {name:?} appears twice"));
                }
                match hex_decode(hex) {
                    Some(value) => {
                        fields.push(name, value);
                    }
                    None => {
                        return Directive::Malformed(format!("ok field {name:?} value is not hex"))
                    }
                }
            }
            Directive::Ok(fields)
        }
        "err" => match rest.split_once(char::is_whitespace) {
            Some((code, message)) => Directive::Err {
                code: code.to_string(),
                message: message.trim().to_string(),
            },
            None if !rest.is_empty() => Directive::Err {
                code: rest.to_string(),
                message: String::new(),
            },
            None => Directive::Malformed("err needs a code".to_string()),
        },
        "stream" if !rest.is_empty() => Directive::Stream(PathBuf::from(rest)),
        "close" => Directive::Close,
        _ => Directive::Malformed(format!("unknown directive {line:?}")),
    }
}

pub fn hex_encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(DIGITS[(*b >> 4) as usize] as char);
        out.push(DIGITS[(*b & 0x0f) as usize] as char);
    }
    out
}

pub fn hex_decode(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push((hi * 16 + lo) as u8);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil;

    #[test]
    fn hex_round_trips_binary_including_nul() {
        let raw = b"hi\n\0\xff".to_vec();
        assert_eq!(hex_encode(&raw), "68690a00ff");
        assert_eq!(hex_decode("68690a00ff"), Some(raw));
        assert_eq!(hex_decode("abc"), None);
        assert_eq!(hex_decode("zz"), None);
    }

    #[test]
    fn directives_parse() {
        assert_eq!(
            parse_directive("ok text=68690a00 regtype=6c"),
            Directive::Ok(
                Fields::new()
                    .with("text", b"hi\n\0".to_vec())
                    .with("regtype", b"l".to_vec())
            )
        );
        assert_eq!(
            parse_directive("err not-found nothing to answer with"),
            Directive::Err {
                code: "not-found".into(),
                message: "nothing to answer with".into()
            }
        );
        assert_eq!(
            parse_directive("stream /tmp/blob"),
            Directive::Stream(PathBuf::from("/tmp/blob"))
        );
        assert_eq!(parse_directive("close"), Directive::Close);
    }

    #[test]
    fn a_malformed_directive_is_reported_not_skipped() {
        assert!(matches!(
            parse_directive("ok text=nothex"),
            Directive::Malformed(_)
        ));
        assert!(matches!(
            parse_directive("ok bare"),
            Directive::Malformed(_)
        ));
        assert!(matches!(
            parse_directive("wat now"),
            Directive::Malformed(_)
        ));
    }

    #[test]
    fn the_hello_directive_leaves_the_exchange_queue_alone() {
        let dir = testutil::tempdir("script");
        let path = dir.path().join("script");
        std::fs::write(&path, "# comment\nhello proto=7\nok host=626f7841\nclose\n").unwrap();
        let mut script = Script::load(&path);
        assert_eq!(script.hello_proto(), Some(7));
        assert!(matches!(script.next_directive(), Some(Directive::Ok(_))));
        assert_eq!(script.next_directive(), Some(Directive::Close));
        assert_eq!(script.next_directive(), None);
    }

    #[test]
    fn the_log_line_is_endpoint_op_then_hex_fields() {
        let dir = testutil::tempdir("record-log");
        let path = dir.path().join("log");
        let recorder = Recorder {
            log: Some(path.clone()),
            script: None,
            endpoint: None,
        };
        let fields = Fields::new()
            .with("op", b"clip.set".to_vec())
            .with("text", b"hi\n\0".to_vec())
            .with("regtype", b"l".to_vec());
        recorder.record(Endpoint::Trusted, "clip.set", &fields);
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "trusted\tclip.set\ttext=68690a00\tregtype=6c\n"
        );
    }
}
