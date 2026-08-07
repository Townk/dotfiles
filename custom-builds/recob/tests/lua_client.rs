//! The Lua client's codec against the Rust one.
//!
//! §11's reasoning is that the Lua provider is a *second* implementation of
//! the wire and that a rule only one implementation obeys has not been
//! tested. The daemon's own suite cannot drive nvim's provider end to end,
//! but it can hold the two encoders to the same bytes — which is where a
//! hand-rolled big-endian length or an off-by-one field header would show up,
//! and those are the mistakes this file exists to catch before the client
//! reaches a machine.

mod common;

use common::testutil;
use recob_wire::wire::{self, Fields, Kind};

/// The nvim provider, in the chezmoi source tree where it now lives. Tested
/// from its installed location rather than from a staging copy: two copies of
/// a client is exactly the drift this project keeps warning about.
fn staged_client() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../home/dot_config/nvim/lua/clipboard/universal.lua")
}

fn nvim_available() -> bool {
    std::env::var_os("PATH")
        .is_some_and(|paths| std::env::split_paths(&paths).any(|dir| dir.join("nvim").is_file()))
}

/// Runs a snippet with the staged client loaded as `client`, returning what it
/// printed.
fn in_nvim(snippet: &str) -> String {
    let dir = testutil::tempdir("lua-client");
    let script = dir.path().join("snippet.lua");
    std::fs::write(
        &script,
        format!(
            "local client = dofile('{}')\n{snippet}\n",
            staged_client().display()
        ),
    )
    .unwrap();
    let out = std::process::Command::new("nvim")
        .args(["--headless", "--clean", "-l"])
        .arg(&script)
        .output()
        .expect("nvim runs");
    assert!(
        out.status.success(),
        "nvim failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // `-l` prints to stdout; older builds route `print` to stderr.
    let mut text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if text.is_empty() {
        text = String::from_utf8_lossy(&out.stderr).trim().to_string();
    }
    text
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn the_lua_encoder_agrees_with_the_rust_one_byte_for_byte() {
    if !nvim_available() {
        eprintln!("nvim is not on PATH; skipping the cross-implementation check");
        return;
    }
    // A request that exercises what the framing can get wrong: a multi-byte
    // length, an embedded NUL, a trailing newline and a name at the short end.
    let text = "hi\n\0there";
    let expected = wire::encode(
        Kind::Request,
        &Fields::new()
            .with("op", b"clip.set".to_vec())
            .with("text", text.as_bytes().to_vec())
            .with("regtype", b"b".to_vec()),
    );

    let printed = in_nvim(
        "local frame = client._encode_frame('Q', {\n\
         { 'op', 'clip.set' },\n\
         { 'text', 'hi\\n' .. string.char(0) .. 'there' },\n\
         { 'regtype', 'b' },\n\
         })\n\
         local out = {}\n\
         for i = 1, #frame do out[i] = string.format('%02x', frame:byte(i)) end\n\
         io.write(table.concat(out))",
    );
    assert_eq!(printed, hex(&expected), "the two encoders disagree");
}

#[test]
fn the_lua_decoder_reads_what_the_daemon_writes() {
    if !nvim_available() {
        eprintln!("nvim is not on PATH; skipping the cross-implementation check");
        return;
    }
    // A response body as the daemon encodes it, including a value with a NUL
    // and one that is empty.
    let body = wire::encode_body(
        &Fields::new()
            .with("text", b"a\0b".to_vec())
            .with("regtype", b"l".to_vec())
            .with("host", b"".to_vec()),
    );
    let escaped: String = body
        .iter()
        .map(|b| format!("\\{:03}", b))
        .collect::<Vec<_>>()
        .join("");

    let printed = in_nvim(&format!(
        "local body = '{escaped}'\n\
         local fields = client._decode_fields(body)\n\
         io.write(string.format('%d|%s|%s|%d', #fields.text, fields.regtype, fields.host, #fields.host))"
    ));
    assert_eq!(
        printed, "3|l||0",
        "the Lua decoder mis-read a body the daemon produced"
    );
}

#[test]
fn the_lua_length_prefix_matches_at_a_size_a_shell_would_get_wrong() {
    if !nvim_available() {
        eprintln!("nvim is not on PATH; skipping the cross-implementation check");
        return;
    }
    // 0x0102 bytes: a length whose high byte is non-zero, which is where a
    // hand-rolled big-endian pack goes wrong first.
    let printed = in_nvim(
        "local packed = client._pack_be32(258)\n\
         local out = {}\n\
         for i = 1, #packed do out[i] = string.format('%02x', packed:byte(i)) end\n\
         io.write(table.concat(out))",
    );
    assert_eq!(printed, hex(&258u32.to_be_bytes()));
}

/// §14.4's sole-writer requirement, as a regression guard rather than a live
/// check: `hs.sqlite3` exists only inside Hammerspoon, so the module
/// cannot be exercised here — but the property that matters is textual. If a
/// write, a schema statement or the watcher ever reappears in it, two writers
/// exist again and the store quietly doubles, which is precisely the failure
/// §14.4 says is most likely to be skipped because everything appears to work.
#[test]
fn the_history_module_can_no_longer_write() {
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../home/dot_config/hammerspoon/modules/apps/clipboard-history.lua"),
    )
    .expect("the read-path module");

    // Only the doc comment may mention these; code must not.
    let code: String = source
        .lines()
        .filter(|line| !line.trim_start().starts_with("--"))
        .collect::<Vec<_>>()
        .join("\n");

    for forbidden in [
        "INSERT",
        "UPDATE",
        "DELETE",
        "CREATE TABLE",
        "ALTER TABLE",
        "pasteboard.watcher",
        "capture_now",
    ] {
        assert!(
            !code.contains(forbidden),
            "the read-path module reintroduced {forbidden}: two writers again (§14.4)"
        );
    }
    assert!(
        code.contains("OPEN_READONLY"),
        "the store must be opened read-only, so a reintroduced write fails loudly"
    );
    // The picker's call sites are unchanged, which is what keeps this a
    // one-file change rather than a picker rewrite.
    for kept in [
        "restore_by_id",
        "restore_plain_by_id",
        "_preview_of",
        "_my_host",
    ] {
        assert!(code.contains(kept), "the read surface lost {kept}");
    }
}
