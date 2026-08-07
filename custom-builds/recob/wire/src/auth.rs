//! Connection authentication (§9.2): the token, the nonces, and the two digests.
//!
//! The credential never crosses the wire. The server challenges with a fresh
//! nonce, the client answers `SHA256(token || ":c:" || nonce)`, and the server
//! answers the client's own challenge with `SHA256(token || ":s:" || cnonce)` —
//! so neither side has to trust an assertion made by the party it is trying to
//! authenticate. §9.2 works through why the obvious simplifications (send the
//! token; check the banner's `host` first; skip the round trip) are each a
//! credential-theft or payload-theft vector, and they are not re-litigated here.
//!
//! The two domain separators are what defeat reflection: a listener that echoes
//! the client's digest back cannot satisfy the server's step, because the hashed
//! string differs in a position it cannot influence.

use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::log;

/// §9.2: the credential is a 32-byte random value, hex-encoded.
pub const TOKEN_BYTES: usize = 32;
pub const TOKEN_HEX_LEN: usize = TOKEN_BYTES * 2;
/// §6.6: `nonce` and `cnonce` are exactly 32 bytes.
pub const NONCE_BYTES: usize = 32;
/// §9.2: the `auth` list is capped at 8 entries.
pub const MAX_AUTH_ENTRIES: usize = 8;

/// Domain separators. `":c:"` marks the client's direction, `":s:"` the
/// server's; see the module note on reflection.
const CLIENT_DOMAIN: &[u8] = b":c:";
const SERVER_DOMAIN: &[u8] = b":s:";

/// The verified contents of `accepted-token`. Held as the hex text, because that
/// is what the digest is computed over.
#[derive(Clone)]
pub struct Token(String);

/// Redacting, and deliberately hand-written: a derived `Debug` would put the
/// credential into any log line, panic message or test failure that formatted a
/// value containing one. §11.4 requires a test that the token appears nowhere in
/// a recorded exchange; this is the same rule applied to the daemon's own output.
impl std::fmt::Debug for Token {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Token(<redacted {} chars>)", self.0.len())
    }
}

impl Token {
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The digest the client is expected to send for this nonce.
    pub fn client_digest(&self, nonce: &[u8]) -> String {
        digest(self.0.as_bytes(), CLIENT_DOMAIN, nonce)
    }

    /// The digest the server answers the client's challenge with.
    pub fn server_proof(&self, cnonce: &[u8]) -> String {
        digest(self.0.as_bytes(), SERVER_DOMAIN, cnonce)
    }
}

fn digest(token: &[u8], domain: &[u8], nonce: &[u8]) -> String {
    // §9.2: plain SHA256 over the concatenation is sufficient and HMAC is not
    // required — length extension needs an attacker who controls the message and
    // profits from extending it, but here the message is a nonce the *verifier*
    // chose, and a digest over an extension of it matches no nonce the server
    // will ever issue.
    let mut hasher = Sha256::new();
    hasher.update(token);
    hasher.update(domain);
    hasher.update(nonce);
    hex(&hasher.finalize())
}

pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(DIGITS[(*b >> 4) as usize] as char);
        out.push(DIGITS[(*b & 0x0f) as usize] as char);
    }
    out
}

/// Why a token file was not usable. Every variant is treated as absent by the
/// caller (§9.2: "a file failing any check is treated as absent and reported as
/// such, never partially matched"), but they are distinguished so the log says
/// which one it was.
#[derive(Debug, PartialEq, Eq)]
pub enum TokenFault {
    Missing,
    Unreadable(String),
    /// §9.2 validation on read: the mode must not grant group or other any bits.
    Permissive(u32),
    NotHex,
    WrongLength(usize),
    TrailingContent,
}

impl std::fmt::Display for TokenFault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TokenFault::Missing => write!(f, "missing"),
            TokenFault::Unreadable(e) => write!(f, "unreadable: {e}"),
            TokenFault::Permissive(mode) => {
                write!(f, "mode {mode:04o} grants group or other access")
            }
            TokenFault::NotHex => write!(f, "not 64 lowercase hex characters"),
            TokenFault::WrongLength(n) => write!(f, "{n} characters, expected {TOKEN_HEX_LEN}"),
            TokenFault::TrailingContent => write!(f, "more than one line"),
        }
    }
}

impl Token {
    /// §9.2 "Validation on read", the value half: exactly 64 characters, all
    /// `[0-9a-f]`, a single line with no trailing content.
    ///
    /// Separate from the file half so both ends share it. A client reads its
    /// pushed `tunnel-tokens/<owner-host>` copy under exactly these rules, which
    /// is why this is not test-only scaffolding.
    pub fn from_hex(text: &str) -> Result<Token, TokenFault> {
        // A single trailing newline is the written form; anything beyond it is
        // trailing content.
        let body = text.strip_suffix('\n').unwrap_or(text);
        if body.contains('\n') || body.contains('\r') {
            return Err(TokenFault::TrailingContent);
        }
        if body.len() != TOKEN_HEX_LEN {
            return Err(TokenFault::WrongLength(body.len()));
        }
        if !body
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(TokenFault::NotHex);
        }
        Ok(Token(body.to_string()))
    }
}

/// §9.2 "Validation on read". This file sits on a shared box and can be stale,
/// truncated, hand-edited or garbage, so it gets the same defensive treatment
/// `self-name` already gets — plus the mode check, which a value alone cannot
/// carry.
pub fn read_token(path: &Path) -> Result<Token, TokenFault> {
    let meta = match fs::metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Err(TokenFault::Missing),
        Err(e) => return Err(TokenFault::Unreadable(e.to_string())),
    };
    let mode = meta.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(TokenFault::Permissive(mode));
    }
    let raw = fs::read_to_string(path).map_err(|e| TokenFault::Unreadable(e.to_string()))?;
    Token::from_hex(&raw)
}

/// 32 bytes from the operating system CSPRNG (§9.2).
///
/// `/dev/urandom` rather than a userspace generator, and read fresh per call
/// rather than from a seeded stream: §9.2 keeps the nonce-distinctness
/// requirement specifically because a generator seeded once at start reproduces
/// the forked-`$RANDOM` failure in any language, and it is invisible in every
/// other test because authentication still succeeds when the nonce repeats.
pub fn random_bytes(n: usize) -> io::Result<Vec<u8>> {
    let mut buf = vec![0u8; n];
    let mut f = fs::File::open("/dev/urandom")?;
    f.read_exact(&mut buf)?;
    Ok(buf)
}

pub fn nonce() -> io::Result<Vec<u8>> {
    random_bytes(NONCE_BYTES)
}

/// §9.2 Bootstrap: `accepted-token` is created by the listener at startup when
/// it is absent or fails validation. There is no separate provisioning step and
/// no state in which the listener runs without a credential to check against.
///
/// Regeneration happens *here*, at startup, and deliberately not when a
/// per-connection read fails validation: rewriting the token invalidates every
/// remote's pushed copy at once, so doing it while serving would turn one
/// corrupt file into a fleet-wide outage with no push to repair it.
pub fn load_or_create(path: &Path) -> io::Result<Token> {
    match read_token(path) {
        Ok(token) => Ok(token),
        Err(TokenFault::Missing) => create(path),
        Err(fault) => {
            log!(
                "{} is unusable ({fault}); regenerating — every remote will need a fresh push",
                path.display()
            );
            create(path)
        }
    }
}

fn create(path: &Path) -> io::Result<Token> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} has no parent directory", path.display()),
        )
    })?;
    crate::fsfile::ensure_private_dir(parent)?;
    let token = hex(&random_bytes(TOKEN_BYTES)?);
    // umask before the write and an explicit chmod after, so there is no window
    // in which the token exists at a permissive mode — the same belt-and-braces
    // §3.3 requires of the trusted socket, and §9.2 of the push.
    crate::fsfile::write_private(path, format!("{token}\n").as_bytes())?;
    log!("wrote a fresh credential to {}", path.display());
    Ok(Token(token))
}

/// The default location of the owning machine's credential (§9.2).
pub fn accepted_token_path() -> PathBuf {
    state_dir().join("accepted-token")
}

/// Where a client keeps the credentials it has been pushed, one file per owning
/// machine (§9.2). The daemon writes here only in `--record` mode, to give the
/// spec suite the credential fixture §11.1 requires.
pub fn tunnel_token_path(owner_host: &str) -> PathBuf {
    state_dir().join("tunnel-tokens").join(owner_host)
}

pub fn state_dir() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let mut home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
            home.push(".local/state");
            home
        });
    base.join("clipboard")
}

/// Result of checking a client's `auth` field.
#[derive(Debug, PartialEq, Eq)]
pub enum AuthOutcome {
    Accepted,
    /// The field was absent — `reason=no-credential` (§10).
    NoCredential,
    /// Present, and no entry matched — `reason=bad-credential`.
    BadCredential,
}

/// §9.2: the server authenticates the connection iff **any** entry equals its
/// own recomputed digest.
///
/// Every entry is compared and every comparison is constant-time, with no
/// short-circuit on the first match — so the reply time does not vary with the
/// position of the matching token, which would correlate with which machine the
/// client thinks it is talking to.
pub fn verify_auth(token: &Token, nonce: &[u8], offered: Option<&[u8]>) -> AuthOutcome {
    let Some(offered) = offered else {
        return AuthOutcome::NoCredential;
    };
    let expected = token.client_digest(nonce);
    let mut matched = subtle::Choice::from(0u8);
    let mut entries = 0usize;
    // NUL-joined, newest first, capped at 8 (§9.2). Entries past the cap are not
    // examined: the cap is what keeps a peer from making the daemon hash a long
    // list, and honouring it here is what makes the cap real.
    for entry in offered.split(|b| *b == 0).take(MAX_AUTH_ENTRIES) {
        entries += 1;
        matched |= entry.ct_eq(expected.as_bytes());
    }
    if entries == 0 {
        return AuthOutcome::NoCredential;
    }
    if bool::from(matched) {
        AuthOutcome::Accepted
    } else {
        AuthOutcome::BadCredential
    }
}

/// §6.6: `auth` is NUL-joined, 1–8 entries, each 64 lowercase hex characters.
/// Shape is checked before any digest work, so a malformed field is a
/// `bad-field` rather than a silent authentication failure.
pub fn valid_auth_field(value: &[u8]) -> bool {
    if value.is_empty() {
        return false;
    }
    let entries: Vec<&[u8]> = value.split(|b| *b == 0).collect();
    if entries.is_empty() || entries.len() > MAX_AUTH_ENTRIES {
        return false;
    }
    entries.iter().all(|e| {
        e.len() == TOKEN_HEX_LEN
            && e.iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil;

    fn token_of(hexstr: &str) -> Token {
        Token(hexstr.to_string())
    }

    #[test]
    fn the_two_digests_differ_for_the_same_nonce() {
        // The reflection defence: a peer that echoes the client's digest back
        // cannot satisfy the server's step.
        let t = token_of(&"a".repeat(TOKEN_HEX_LEN));
        let n = [7u8; NONCE_BYTES];
        assert_ne!(t.client_digest(&n), t.server_proof(&n));
    }

    #[test]
    fn a_digest_is_bound_to_its_nonce() {
        let t = token_of(&"b".repeat(TOKEN_HEX_LEN));
        assert_ne!(
            t.client_digest(&[1u8; NONCE_BYTES]),
            t.client_digest(&[2u8; NONCE_BYTES])
        );
    }

    #[test]
    fn the_digest_matches_an_independent_computation() {
        // Guards against a silent change of construction: this is
        // SHA256("<token>:c:<nonce>") and nothing else.
        let t = token_of("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
        let nonce = b"0123456789abcdef0123456789abcdef";
        let mut h = Sha256::new();
        h.update(t.as_str().as_bytes());
        h.update(b":c:");
        h.update(nonce);
        assert_eq!(t.client_digest(nonce), hex(&h.finalize()));
    }

    #[test]
    fn any_entry_may_match_and_all_are_compared() {
        let t = token_of(&"c".repeat(TOKEN_HEX_LEN));
        let nonce = [3u8; NONCE_BYTES];
        let good = t.client_digest(&nonce);
        let bad = "f".repeat(TOKEN_HEX_LEN);

        assert_eq!(
            verify_auth(&t, &nonce, Some(good.as_bytes())),
            AuthOutcome::Accepted
        );
        // Newest first, so a match in a later position must still be accepted.
        let list = format!("{bad}\0{bad}\0{good}");
        assert_eq!(
            verify_auth(&t, &nonce, Some(list.as_bytes())),
            AuthOutcome::Accepted
        );
        assert_eq!(
            verify_auth(&t, &nonce, Some(bad.as_bytes())),
            AuthOutcome::BadCredential
        );
        assert_eq!(verify_auth(&t, &nonce, None), AuthOutcome::NoCredential);
    }

    #[test]
    fn an_entry_past_the_cap_is_not_examined() {
        let t = token_of(&"d".repeat(TOKEN_HEX_LEN));
        let nonce = [4u8; NONCE_BYTES];
        let good = t.client_digest(&nonce);
        let bad = "0".repeat(TOKEN_HEX_LEN);
        let mut list: Vec<String> = (0..MAX_AUTH_ENTRIES).map(|_| bad.clone()).collect();
        list.push(good);
        assert_eq!(
            verify_auth(&t, &nonce, Some(list.join("\0").as_bytes())),
            AuthOutcome::BadCredential,
            "the 9th entry must not be reachable"
        );
    }

    #[test]
    fn a_response_is_rejected_against_a_different_nonce() {
        let t = token_of(&"e".repeat(TOKEN_HEX_LEN));
        let captured = t.client_digest(&[5u8; NONCE_BYTES]);
        assert_eq!(
            verify_auth(&t, &[6u8; NONCE_BYTES], Some(captured.as_bytes())),
            AuthOutcome::BadCredential,
            "§11.4: a response captured from one nonce is rejected against another"
        );
    }

    #[test]
    fn the_auth_field_shape_is_checked_before_any_digest_work() {
        let good = "a".repeat(TOKEN_HEX_LEN);
        assert!(valid_auth_field(good.as_bytes()));
        assert!(valid_auth_field(
            [good.as_bytes(), good.as_bytes()].join(&0u8).as_slice()
        ));
        assert!(!valid_auth_field(b""));
        assert!(!valid_auth_field(b"short"));
        assert!(
            !valid_auth_field("A".repeat(TOKEN_HEX_LEN).as_bytes()),
            "uppercase"
        );
        assert!(
            !valid_auth_field("g".repeat(TOKEN_HEX_LEN).as_bytes()),
            "not hex"
        );
        let nine = (0..9).map(|_| good.clone()).collect::<Vec<_>>().join("\0");
        assert!(
            !valid_auth_field(nine.as_bytes()),
            "9 entries is over the cap"
        );
    }

    #[test]
    fn nonces_are_distinct_and_the_right_length() {
        // §11.4 requires this as a live property too; here it is the generator
        // itself, which is where a seeded-once implementation would show up.
        let mut seen = std::collections::HashSet::new();
        for _ in 0..256 {
            let n = nonce().unwrap();
            assert_eq!(n.len(), NONCE_BYTES);
            assert!(seen.insert(n), "a nonce repeated");
        }
    }

    #[test]
    fn token_validation_refuses_every_bad_shape() {
        let dir = testutil::tempdir("token-validate");
        let path = dir.path().join("accepted-token");
        let good = "a1b2".repeat(16);
        assert_eq!(good.len(), TOKEN_HEX_LEN);

        assert_eq!(read_token(&path).unwrap_err(), TokenFault::Missing);

        crate::fsfile::write_private(&path, format!("{good}\n").as_bytes()).unwrap();
        assert_eq!(read_token(&path).unwrap().as_str(), good);

        // §9.2: a file at mode 0640 is rejected as if absent.
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        assert_eq!(
            read_token(&path).unwrap_err(),
            TokenFault::Permissive(0o640)
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

        for (contents, want) in [
            (format!("{good}\nextra\n"), TokenFault::TrailingContent),
            (format!("{good}ff\n"), TokenFault::WrongLength(66)),
            (
                format!("{}\n", "z".repeat(TOKEN_HEX_LEN)),
                TokenFault::NotHex,
            ),
            (
                format!("{}\n", "A".repeat(TOKEN_HEX_LEN)),
                TokenFault::NotHex,
            ),
            (String::from("\n"), TokenFault::WrongLength(0)),
        ] {
            fs::write(&path, &contents).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            assert_eq!(read_token(&path).unwrap_err(), want, "for {contents:?}");
        }
    }

    #[test]
    fn bootstrap_creates_a_private_token_and_reuses_it() {
        let dir = testutil::tempdir("token-bootstrap");
        let path = dir.path().join("clipboard/accepted-token");
        let first = load_or_create(&path).unwrap();
        assert_eq!(first.as_str().len(), TOKEN_HEX_LEN);
        assert_eq!(crate::fsfile::mode_of(&path).unwrap() & 0o777, 0o600);
        assert_eq!(
            crate::fsfile::mode_of(path.parent().unwrap()).unwrap() & 0o777,
            0o700
        );
        // A valid file is reused, not rotated: rotating on every start would
        // invalidate every pushed copy on every restart.
        let second = load_or_create(&path).unwrap();
        assert_eq!(first.as_str(), second.as_str());
    }

    #[test]
    fn bootstrap_replaces_an_invalid_token() {
        let dir = testutil::tempdir("token-replace");
        let path = dir.path().join("accepted-token");
        crate::fsfile::write_private(&path, b"garbage\n").unwrap();
        let token = load_or_create(&path).unwrap();
        assert_eq!(token.as_str().len(), TOKEN_HEX_LEN);
        assert_eq!(read_token(&path).unwrap().as_str(), token.as_str());
    }
}
