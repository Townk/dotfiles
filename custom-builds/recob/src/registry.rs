//! The operation registry and its authorization policy (§6.1, §9.1, §9.3).
//!
//! **One table, not two.** §9.3 requires the policy to be declared once, in the
//! source the daemon dispatches from and the test reads, with the registry
//! *derived* from it rather than maintained beside it — a policy the test
//! re-declares in its own fixture would satisfy every assertion while protecting
//! nothing. So the policy fields live on the registry row, which makes §9.4's
//! first assertion structural: a row cannot exist without a tier, because the
//! type has no default for one.
//!
//! Phase 1 carried `host.identity` alone as proof that dispatch works, and this
//! phase adds its policy row. The other thirteen operations of §6.1 arrive in
//! Phase 4 **with their handlers**, not before: `caps` advertises what this build
//! can dispatch (§5.1), so a policy row without a handler would put a lie in it
//! and §7.1's skew diagnostic is built on `caps` being true.

use crate::auth::AuthOutcome;
use crate::listen::Endpoint;
use crate::session::Ctx;
use crate::wire::{Fields, ProtoError, PROTO};

/// §9.1. `local` implies `authed`. There is deliberately no "anyone who can open
/// the port" tier: the public endpoint requires a credential at the *connection*
/// level, before any operation is parsed, which cannot be defeated by forgetting
/// a table entry.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tier {
    Authed,
    Local,
}

impl Tier {
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Authed => "authed",
            Tier::Local => "local",
        }
    }
}

/// What a connection has established about itself. Derived from which listener
/// accepted it and, on the public endpoint, from the credential — never from
/// request data.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Granted(Tier);

impl Granted {
    /// The trusted Unix socket: its uid boundary *is* the credential (§9.2), and
    /// it is the only source of `local`.
    pub fn local() -> Self {
        Granted(Tier::Local)
    }

    /// A public connection whose credential validated.
    pub fn authed() -> Self {
        Granted(Tier::Authed)
    }

    pub fn tier(self) -> Tier {
        self.0
    }

    fn satisfies(self, required: Tier) -> bool {
        match required {
            Tier::Authed => true, // local implies authed
            Tier::Local => self.0 == Tier::Local,
        }
    }
}

/// §9.3's descriptive `effect` column. Carried because the brief asks for the
/// table as data; nothing branches on it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Effect {
    Read,
    Write,
    Store,
    FsRead,
    Gui,
}

/// §9.5's rate buckets. `None` on a row means the operation is not throttled.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Bucket {
    Osd,
    Window,
    Store,
}

pub struct Op {
    pub name: &'static str,
    /// §7.1: the `proto` an operation first appeared in, so a client can say
    /// "and clip.set.files needs proto 2" instead of inventing a version map.
    pub since: u32,
    pub tier: Tier,
    /// §9.1: whether a valid `files.grant` bearer token is required. No Phase 2
    /// operation sets it; `files.fetch` does, in Phase 4.
    pub grant: bool,
    pub rate: Option<Bucket>,
    pub effect: Effect,
    /// Field names the operation accepts, excluding `op` itself.
    pub request_fields: &'static [&'static str],
}

pub const OPS: &[Op] = &[Op {
    name: "host.identity",
    since: 1,
    tier: Tier::Authed,
    grant: false,
    rate: None,
    effect: Effect::Read,
    request_fields: &[],
}];

pub fn find(name: &str) -> Option<&'static Op> {
    OPS.iter().find(|op| op.name == name)
}

/// §5.1 `caps`: NUL-joined operation names this build can dispatch.
///
/// §9.6 is explicit that local exposure does **not** filter this. The advertised
/// set stays a pure build signal, because §7.1 makes `caps` authoritative for
/// "operation missing at equal versions" — folding local policy in would make a
/// deliberately withdrawn operation indistinguishable from an older build, and
/// the client would tell the operator to run `chezmoi apply` on a machine that is
/// perfectly up to date.
pub fn caps() -> Vec<u8> {
    OPS.iter()
        .map(|op| op.name)
        .collect::<Vec<_>>()
        .join("\0")
        .into_bytes()
}

/// P6: an unrecognized field is an error, not something to ignore — and it is
/// the precise skew diagnostic, naming the field and the build that lacks it.
pub fn validate_request(op: &Op, fields: &Fields) -> Result<(), ProtoError> {
    for name in fields.names() {
        if name == "op" || op.request_fields.contains(&name) {
            continue;
        }
        return Err(ProtoError::new(
            "unknown-field",
            format!("{} does not take a field named {name}", op.name),
        )
        .with("field", name)
        .with("proto", PROTO.to_string().into_bytes()));
    }
    Ok(())
}

/// **The single authorization call site** (P7).
///
/// Three checks in a fixed order, and the order is load-bearing:
///
/// 1. the §9.3 tier, which is the table's grant;
/// 2. §9.6's local exposure, evaluated *after* the table so withdrawing can only
///    ever remove a capability the table already granted, never restore one it
///    denied;
/// 3. §9.5's rate bucket, last, so a caller who is not allowed the operation
///    learns nothing about the bucket's state.
///
/// Grants (§9.1) are checked by the operations that require one, in Phase 4; no
/// row here sets `grant`, and the assertion in `tests` fails if one appears
/// without this call site learning to check it.
pub fn authorize(
    op: &Op,
    endpoint: Endpoint,
    granted: Granted,
    ctx: &Ctx,
) -> Result<(), ProtoError> {
    if !granted.satisfies(op.tier) {
        return Err(unauthorized(
            "tier",
            format!(
                "{} requires the {} tier; this connection holds {}",
                op.name,
                op.tier.as_str(),
                granted.tier().as_str()
            ),
        ));
    }
    if ctx.exposure.withdrawn(op.name, endpoint) {
        return Err(unauthorized(
            "not-exposed",
            format!(
                "this machine does not answer {} on the {} endpoint",
                op.name,
                endpoint.as_str()
            ),
        ));
    }
    if let Some(bucket) = op.rate {
        if let Some(retry_after) = ctx.limits.rate_check(endpoint, bucket) {
            return Err(
                ProtoError::new("rate-limited", format!("{} is rate limited", op.name))
                    .with("retry_after", retry_after.to_string().into_bytes()),
            );
        }
    }
    Ok(())
}

/// §10: `unauthorized` carries `reason`. The tier/grant/exposure reasons leave
/// the connection open; a credential failure closes it, which is why that one is
/// raised at the handshake rather than here.
fn unauthorized(reason: &str, message: String) -> ProtoError {
    ProtoError::new("unauthorized", message).with("reason", reason)
}

/// The handshake's own refusal (§9.2): answered with `E{code=unauthorized}` and
/// the connection closed, having dispatched nothing and disclosed nothing beyond
/// the banner.
pub fn credential_refusal(outcome: &AuthOutcome) -> ProtoError {
    let reason = match outcome {
        AuthOutcome::NoCredential => "no-credential",
        AuthOutcome::BadCredential => "bad-credential",
        AuthOutcome::Accepted => unreachable!("accepted is not a refusal"),
    };
    // §9.2: failure discloses nothing either way — one `unauthorized`, regardless
    // of how many entries were offered or how close any came.
    ProtoError::new("unauthorized", "credential missing or not accepted")
        .with("reason", reason)
        .closing()
}

/// What a handler answers with: one `R` frame, or — for `files.fetch` alone
/// (§6.4) — an `R` head followed by a `D` stream the session writes chunk by
/// chunk, so a directory archive is never buffered whole.
pub enum Response {
    Fields(Fields),
    Stream {
        head: Fields,
        source: Box<dyn StreamSource>,
    },
}

impl From<Fields> for Response {
    fn from(fields: Fields) -> Self {
        Response::Fields(fields)
    }
}

/// §6.4's producer half. `Ok(Some(chunk))` is the next `D` payload (the session
/// enforces the 64 KiB split), `Ok(None)` is the clean end the empty `D` frame
/// announces, and `Err` becomes the mid-stream `E` that terminates the exchange
/// while leaving the connection reusable.
pub trait StreamSource: Send {
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, ProtoError>;
}

pub fn dispatch(
    op: &Op,
    _request: &Fields,
    _endpoint: Endpoint,
    ctx: &Ctx,
) -> Result<Response, ProtoError> {
    match op.name {
        // §6.1: no request fields, one response field. Re-read per request rather
        // than cached, per §3.4.
        "host.identity" => match ctx.host.current() {
            Some(host) => Ok(Fields::new().with("host", host.into_bytes()).into()),
            None => Err(ProtoError::new(
                "internal",
                "cannot resolve this machine's wire identity",
            )),
        },
        other => unreachable!("dispatch reached for unregistered op {other}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::exposure::Exposure;
    use crate::limits::Limits;
    use crate::testutil;

    fn ctx() -> Ctx {
        let mut ctx = Ctx::new(
            crate::host::HostIdentity::with_paths("/nonexistent".into(), Some("boxA".into())),
            "test-impl".to_string(),
            std::time::Duration::from_secs(2),
        );
        // Dispatch reachability drives real handlers; none may ever open the
        // live store from a test.
        ctx.db_path = std::env::temp_dir().join(format!(
            "recobd-registry-test-{}/history.db",
            std::process::id()
        ));
        ctx
    }

    // §9.4 assertion 1. With one table this is structural — a row cannot be
    // written without a tier — so the test's job is to fail if someone later
    // splits the table in two and reintroduces the drift it guards against.
    #[test]
    fn every_dispatchable_operation_has_a_policy_entry() {
        for op in OPS {
            assert!(
                matches!(op.tier, Tier::Authed | Tier::Local),
                "{} has no tier",
                op.name
            );
            assert!(
                find(op.name).is_some(),
                "{} is not reachable by name",
                op.name
            );
        }
        // caps is built from the same table, so the advertised set and the gated
        // set cannot diverge.
        let advertised = String::from_utf8(caps()).unwrap();
        for op in OPS {
            assert!(advertised.split('\0').any(|n| n == op.name));
        }
    }

    // §9.4 assertion 2: every policy entry names a real operation. Catches an
    // entry left behind by a rename.
    #[test]
    fn every_policy_entry_names_a_dispatchable_operation() {
        for op in OPS {
            // A row whose handler is missing would reach dispatch's unreachable!
            // arm. Reaching it — not a successful answer — is what this asserts:
            // an op with request fields answers missing-field here, which still
            // proves the row has a handler.
            let _ = dispatch(op, &Fields::new(), Endpoint::Trusted, &ctx());
        }
    }

    // §9.4 assertion 4.
    #[test]
    fn every_entry_declares_a_since_no_greater_than_proto() {
        for op in OPS {
            assert!(
                op.since <= PROTO,
                "{} claims since {} but this build speaks proto {PROTO}",
                op.name,
                op.since
            );
        }
    }

    // No row sets `grant` yet, and the call site cannot check one. This fails the
    // moment a row does, which is the reminder that Phase 4 owes the check.
    #[test]
    fn no_row_requires_a_grant_the_call_site_cannot_check() {
        for op in OPS {
            assert!(
                !op.grant,
                "{} requires a grant, but authorize() has no grant check yet",
                op.name
            );
        }
    }

    #[test]
    fn local_implies_authed_but_not_the_reverse() {
        assert!(Granted::local().satisfies(Tier::Authed));
        assert!(Granted::local().satisfies(Tier::Local));
        assert!(Granted::authed().satisfies(Tier::Authed));
        assert!(!Granted::authed().satisfies(Tier::Local));
    }

    // §9.4 assertion 3, the table-driven half: every `local` operation must be
    // refused on a connection that holds only `authed`. Phase 2's table has no
    // `local` row, so this loop is empty today and covers each one the moment it
    // has an entry.
    #[test]
    fn every_local_operation_is_refused_to_an_authed_connection() {
        let ctx = ctx();
        for op in OPS.iter().filter(|op| op.tier == Tier::Local) {
            let err = authorize(op, Endpoint::Public, Granted::authed(), &ctx).unwrap_err();
            assert_eq!(err.code, "unauthorized");
            assert_eq!(err.detail.get("reason"), Some(&b"tier"[..]));
        }
    }

    // The enforcement logic itself, proven now rather than when Phase 4 supplies
    // the first `local` row. The input is a constructed Op, not a re-declared
    // table: the real table stays the only source of truth for real operations.
    #[test]
    fn the_tier_check_refuses_a_local_operation_over_the_public_endpoint() {
        let local_op = Op {
            name: "test.local.only",
            since: 1,
            tier: Tier::Local,
            grant: false,
            rate: None,
            effect: Effect::Write,
            request_fields: &[],
        };
        let ctx = ctx();
        let err = authorize(&local_op, Endpoint::Public, Granted::authed(), &ctx).unwrap_err();
        assert_eq!(err.code, "unauthorized");
        assert_eq!(err.detail.get("reason"), Some(&b"tier"[..]));
        assert!(
            !err.closes,
            "§10: a tier refusal leaves the connection open"
        );
        // The same operation over the trusted socket is allowed.
        authorize(&local_op, Endpoint::Trusted, Granted::local(), &ctx).unwrap();
    }

    #[test]
    fn exposure_can_only_subtract() {
        let dir = testutil::tempdir("authorize-exposure");
        let path = dir.path().join("exposure");
        std::fs::write(&path, "public host.identity\n").unwrap();
        let mut ctx = ctx();
        ctx.exposure = Exposure::at(path);

        let op = find("host.identity").unwrap();
        // Withdrawn where the table granted it.
        let err = authorize(op, Endpoint::Public, Granted::authed(), &ctx).unwrap_err();
        assert_eq!(err.detail.get("reason"), Some(&b"not-exposed"[..]));
        // Still available on the endpoint it was not withdrawn from.
        authorize(op, Endpoint::Trusted, Granted::local(), &ctx).unwrap();

        // And it cannot *enable* what the table denies: a `local` row withdrawn
        // nowhere is still refused to an authed connection.
        let local_op = Op {
            name: "test.local.only",
            since: 1,
            tier: Tier::Local,
            grant: false,
            rate: None,
            effect: Effect::Write,
            request_fields: &[],
        };
        let err = authorize(&local_op, Endpoint::Public, Granted::authed(), &ctx).unwrap_err();
        assert_eq!(err.detail.get("reason"), Some(&b"tier"[..]));
    }

    #[test]
    fn a_rate_bucket_is_consulted_last() {
        // A withdrawn, rate-limited operation reports not-exposed rather than
        // rate-limited: the caller must not learn the bucket's state for an
        // operation it cannot use.
        let dir = testutil::tempdir("authorize-order");
        let path = dir.path().join("exposure");
        std::fs::write(&path, "public test.rated\n").unwrap();
        let mut ctx = ctx();
        ctx.exposure = Exposure::at(path);
        ctx.limits = std::sync::Arc::new(Limits::with_caps(crate::limits::Caps::default()));

        let rated = Op {
            name: "test.rated",
            since: 1,
            tier: Tier::Authed,
            grant: false,
            rate: Some(Bucket::Window),
            effect: Effect::Gui,
            request_fields: &[],
        };
        let err = authorize(&rated, Endpoint::Public, Granted::authed(), &ctx).unwrap_err();
        assert_eq!(err.detail.get("reason"), Some(&b"not-exposed"[..]));
    }

    #[test]
    fn an_unknown_field_names_itself() {
        let op = find("host.identity").unwrap();
        let err = validate_request(op, &Fields::new().with("text", b"x".to_vec())).unwrap_err();
        assert_eq!(err.code, "unknown-field");
        assert_eq!(err.detail.get("field"), Some(&b"text"[..]));
        assert!(!err.closes);
    }

    #[test]
    fn the_op_field_itself_is_not_an_unknown_field() {
        let op = find("host.identity").unwrap();
        validate_request(op, &Fields::new().with("op", b"host.identity".to_vec())).unwrap();
    }

    #[test]
    fn a_credential_refusal_closes_and_discloses_only_the_reason() {
        let err = credential_refusal(&AuthOutcome::BadCredential);
        assert_eq!(err.code, "unauthorized");
        assert_eq!(err.detail.get("reason"), Some(&b"bad-credential"[..]));
        assert!(err.closes);
        assert_eq!(
            err.detail.len(),
            1,
            "nothing about how close the offer came"
        );

        let err = credential_refusal(&AuthOutcome::NoCredential);
        assert_eq!(err.detail.get("reason"), Some(&b"no-credential"[..]));
    }
}
