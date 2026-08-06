//! The operation registry (§6.1).
//!
//! Phase 1 carries one row — `host.identity` — as proof that named dispatch
//! works. The remaining thirteen operations are Phase 4, and the policy tier
//! each entry will carry is Phase 2 (§9.3): there is deliberately no `tier`
//! field here yet, because a default one is exactly what §9.4's "an operation
//! exists with no policy entry" assertion is built to catch.

use crate::session::Ctx;
use crate::wire::{Fields, ProtoError, PROTO};

pub struct Op {
    pub name: &'static str,
    /// §7.1: the `proto` this operation first appeared in, so a client can say
    /// "and clip.set.files needs proto 2" instead of inventing a version map.
    pub since: u32,
    /// Field names the operation accepts, excluding `op` itself.
    pub request_fields: &'static [&'static str],
}

pub const OPS: &[Op] = &[Op {
    name: "host.identity",
    since: 1,
    request_fields: &[],
}];

pub fn find(name: &str) -> Option<&'static Op> {
    OPS.iter().find(|op| op.name == name)
}

/// §5.1 `caps`: NUL-joined operation names this build can dispatch.
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

pub fn dispatch(op: &Op, _request: &Fields, ctx: &Ctx) -> Result<Fields, ProtoError> {
    match op.name {
        // §6.1: no request fields, one response field. The value is re-read per
        // request rather than cached, per §3.4 — `ssh-prepare-connection`
        // rewrites the self-name file while the daemon is running.
        "host.identity" => match ctx.host.current() {
            Some(host) => Ok(Fields::new().with("host", host.into_bytes())),
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

    #[test]
    fn caps_is_nul_joined() {
        assert_eq!(caps(), b"host.identity".to_vec());
    }

    #[test]
    fn every_registered_op_has_a_since_no_later_than_proto() {
        for op in OPS {
            assert!(
                op.since <= PROTO,
                "{} claims since {} but this build speaks proto {PROTO}",
                op.name,
                op.since
            );
        }
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
}
