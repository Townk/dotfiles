//! §6.6: every field is validated against a declared shape before a handler
//! sees it, and fields that select behavior are closed enums (P5).
//!
//! Each check answers with the §10 code the taxonomy assigns — `missing-field`
//! or `bad-field`, always carrying `field` — so two clients can agree on what
//! is sendable without discovering it as a runtime rejection.

use crate::host::valid_host;
use crate::wire::{Fields, ProtoError};

pub fn missing(field: &str) -> ProtoError {
    ProtoError::new("missing-field", format!("{field} is required")).with("field", field)
}

pub fn bad(field: &str, why: &str) -> ProtoError {
    ProtoError::new("bad-field", format!("{field}: {why}")).with("field", field)
}

/// A required field's raw bytes.
pub fn required<'a>(fields: &'a Fields, field: &str) -> Result<&'a [u8], ProtoError> {
    fields.get(field).ok_or_else(|| missing(field))
}

/// A required field that must be UTF-8 text.
pub fn required_text<'a>(fields: &'a Fields, field: &str) -> Result<&'a str, ProtoError> {
    std::str::from_utf8(required(fields, field)?).map_err(|_| bad(field, "not valid UTF-8"))
}

/// An optional field that, when present, must be UTF-8 text.
pub fn optional_text<'a>(fields: &'a Fields, field: &str) -> Result<Option<&'a str>, ProtoError> {
    match fields.get(field) {
        None => Ok(None),
        Some(raw) => std::str::from_utf8(raw)
            .map(Some)
            .map_err(|_| bad(field, "not valid UTF-8")),
    }
}

/// P5: a field that selects behavior is a closed enum — exactly one of
/// `allowed`, nothing else.
pub fn one_of<'a>(field: &str, value: &'a str, allowed: &[&str]) -> Result<&'a str, ProtoError> {
    if allowed.contains(&value) {
        Ok(value)
    } else {
        Err(bad(
            field,
            &format!("must be one of {}", allowed.join(", ")),
        ))
    }
}

/// `[A-Za-z0-9][A-Za-z0-9.-]*`, ≤ 253 bytes — the wire identity shape (§6.6).
pub fn host_shaped<'a>(field: &str, value: &'a str) -> Result<&'a str, ProtoError> {
    if valid_host(value) {
        Ok(value)
    } else {
        Err(bad(field, "not a valid host name"))
    }
}

/// A decimal integer — `clip_id`, `index`.
pub fn decimal(field: &str, value: &str) -> Result<i64, ProtoError> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(bad(field, "not a decimal integer"));
    }
    value.parse::<i64>().map_err(|_| bad(field, "out of range"))
}

/// 64 lowercase hex characters — grant tokens (§6.6).
pub fn token_hex<'a>(field: &str, value: &'a str) -> Result<&'a str, ProtoError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        Ok(value)
    } else {
        Err(bad(field, "not 64 lowercase hex characters"))
    }
}

/// `paths`: NUL-joined, each element absolute, no `..` component (§6.6).
pub fn nul_paths(field: &str, raw: &[u8]) -> Result<Vec<String>, ProtoError> {
    let text = std::str::from_utf8(raw).map_err(|_| bad(field, "not valid UTF-8"))?;
    let paths: Vec<String> = text.split('\0').map(str::to_string).collect();
    if paths.is_empty() || paths.iter().any(String::is_empty) {
        return Err(bad(field, "empty path list or empty element"));
    }
    for path in &paths {
        if !path.starts_with('/') {
            return Err(bad(field, "a path is not absolute"));
        }
        if path.split('/').any(|component| component == "..") {
            return Err(bad(field, "a path carries a .. component"));
        }
    }
    Ok(paths)
}

/// A byte-length cap on a field that is otherwise free-form.
pub fn max_len(field: &str, value: &[u8], cap: usize) -> Result<(), ProtoError> {
    if value.len() > cap {
        Err(bad(field, &format!("longer than {cap} bytes")))
    } else {
        Ok(())
    }
}

/// `app`: ≤ 256 bytes, no NUL or newline (§6.6).
pub fn app_shaped(field: &str, value: &str) -> Result<(), ProtoError> {
    if value.len() > 256 {
        return Err(bad(field, "longer than 256 bytes"));
    }
    if value.bytes().any(|b| b == 0 || b == b'\n') {
        return Err(bad(field, "carries NUL or newline"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes_hold() {
        assert_eq!(decimal("clip_id", "42").unwrap(), 42);
        assert!(decimal("clip_id", "id:42").is_err());
        assert!(decimal("clip_id", "-1").is_err());
        assert!(decimal("clip_id", "").is_err());

        assert!(token_hex("token", &"a1".repeat(32)).is_ok());
        assert!(token_hex("token", &"A1".repeat(32)).is_err(), "uppercase");
        assert!(token_hex("token", "a1b2").is_err(), "short");

        assert!(one_of("regtype", "b", &["v", "l", "b"]).is_ok());
        assert!(one_of("regtype", "x", &["v", "l", "b"]).is_err());

        assert!(host_shaped("host", "boxA.local-1").is_ok());
        assert!(host_shaped("host", "-bad").is_err());

        let paths = nul_paths("paths", b"/a/b\0/c d/e").unwrap();
        assert_eq!(paths, vec!["/a/b".to_string(), "/c d/e".to_string()]);
        assert!(nul_paths("paths", b"relative").is_err());
        assert!(nul_paths("paths", b"/a/../b").is_err());
        assert!(nul_paths("paths", b"/a\0").is_err(), "empty element");

        assert!(app_shaped("app", "Ghostty").is_ok());
        assert!(app_shaped("app", "two\nlines").is_err());
        assert!(app_shaped("app", &"x".repeat(257)).is_err());
    }

    #[test]
    fn errors_carry_their_field_and_code() {
        let err = missing("text");
        assert_eq!(err.code, "missing-field");
        assert_eq!(err.detail.get("field"), Some(&b"text"[..]));
        let err = bad("regtype", "nope");
        assert_eq!(err.code, "bad-field");
        assert_eq!(err.detail.get("field"), Some(&b"regtype"[..]));
    }
}
