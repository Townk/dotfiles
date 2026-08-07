//! §14.3's delegated GUI operations, driven over real served connections with
//! stub helpers — no test raises a live toast or moves a live window.

mod common;

use common::{testutil, text};
use recobd::listen::Endpoint;
use recobd::wire::{Fields, Kind};

fn write_stub(dir: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    path
}

#[test]
fn fullscreen_toggle_names_the_terminal_and_flips_the_mirror() {
    let dir = testutil::tempdir("gui-toggle");
    let log = dir.path().join("log");
    let mut ctx = common::ctx_mut(dir.path(), "boxA");
    ctx.tools.fullscreen_toggle = write_stub(
        dir.path(),
        "toggle",
        &format!(
            "printf 'toggle terminal=%s ssh=%s\\n' \"$MUX_TERMINAL\" \"$SSH_CONNECTION\" >> {}",
            log.display()
        ),
    );
    ctx.tools.fullscreen_probe = write_stub(
        dir.path(),
        "probe",
        &format!("printf 'probe %s\\n' \"$1\" >> {}", log.display()),
    );

    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"window.fullscreen.toggle".to_vec())
            .with("terminal", b"ghostty".to_vec()),
    );
    let (kind, _) = client.next().expect("an answer");
    assert_eq!(kind, Kind::Response);

    let logged = std::fs::read_to_string(&log).unwrap();
    assert_eq!(
        logged, "toggle terminal=ghostty ssh=\nprobe --flip\n",
        "the toggle sees MUX_TERMINAL and cleared SSH state, then the mirror flips"
    );
}

#[test]
fn fullscreen_toggle_refuses_an_unknown_terminal_before_spawning() {
    let dir = testutil::tempdir("gui-toggle-bad");
    let mut ctx = common::ctx_mut(dir.path(), "boxA");
    // A helper that would prove it ran; the point is that it must not.
    let log = dir.path().join("log");
    ctx.tools.fullscreen_toggle =
        write_stub(dir.path(), "toggle", &format!("touch {}", log.display()));

    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"window.fullscreen.toggle".to_vec())
            .with("terminal", b"kitty".to_vec()),
    );
    assert_eq!(client.code(), "bad-field", "P5: the terminal set is closed");
    assert!(!log.exists(), "no helper ran for a refused terminal");
}

#[test]
fn a_missing_toggle_is_unavailable_and_a_failing_one_is_internal() {
    let dir = testutil::tempdir("gui-toggle-missing");
    let ctx = common::ctx_mut(dir.path(), "boxA");
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"window.fullscreen.toggle".to_vec())
            .with("terminal", b"wezterm".to_vec()),
    );
    assert_eq!(client.code(), "unavailable");

    let dir = testutil::tempdir("gui-toggle-fails");
    let mut ctx = common::ctx_mut(dir.path(), "boxA");
    ctx.tools.fullscreen_toggle =
        write_stub(dir.path(), "toggle", "echo 'no window found' >&2; exit 1");
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"window.fullscreen.toggle".to_vec())
            .with("terminal", b"wezterm".to_vec()),
    );
    let fields = client.expect_error();
    assert_eq!(fields.get("code"), Some(&b"internal"[..]));
    assert_eq!(
        fields.get("message"),
        Some(&b"no window found"[..]),
        "the helper's own diagnostic reaches the caller"
    );
}

#[test]
fn fullscreen_state_answers_the_probes_output() {
    let dir = testutil::tempdir("gui-state");
    let mut ctx = common::ctx_mut(dir.path(), "boxA");
    ctx.tools.fullscreen_probe = write_stub(dir.path(), "probe", "echo true");
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    let (kind, fields) = {
        client.send_request(&Fields::new().with("op", b"window.fullscreen.state".to_vec()));
        client.next().expect("an answer")
    };
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "state"), "true");
}

#[cfg(target_os = "macos")]
#[test]
fn notify_stages_side_files_and_prefixes_a_remote_origin() {
    let dir = testutil::tempdir("gui-notify");
    let out = dir.path().join("out");
    let mut ctx = common::ctx_mut(dir.path(), "boxA");
    // The stub stands in for `hs`: it receives the generated script path and
    // copies the staged side files where the test can read them.
    ctx.tools.hs = write_stub(
        dir.path(),
        "hs",
        &format!(
            "d=$(dirname \"$1\"); mkdir -p {out}; cp \"$d\"/text \"$d\"/icon \"$d\"/sound {out}/; cp \"$1\" {out}/script.lua",
            out = out.display()
        ),
    );

    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"osd.notify".to_vec())
            .with("origin_host", b"boxB".to_vec())
            .with("style", b"ansi".to_vec())
            .with("icon", b"copy".to_vec())
            .with("sound", b"".to_vec())
            .with("text", b"copied \x1b[1m3 files\x1b[0m\nto boxA".to_vec()),
    );
    let (kind, _) = client.next().expect("an answer");
    assert_eq!(kind, Kind::Response);

    assert_eq!(
        std::fs::read(out.join("text")).unwrap(),
        b"boxB: copied \x1b[1m3 files\x1b[0m\nto boxA".to_vec(),
        "a remote origin is prefixed onto the text — provenance, not decoration"
    );
    assert_eq!(std::fs::read(out.join("icon")).unwrap(), b"copy");
    assert_eq!(std::fs::read(out.join("sound")).unwrap(), b"");
    let script = std::fs::read_to_string(out.join("script.lua")).unwrap();
    assert!(
        script.contains("notifyAnsi(") && !script.contains("\x1b"),
        "the enum maps to the Lua symbol inside the handler; content stays in side files"
    );
}

#[cfg(target_os = "macos")]
#[test]
fn notify_from_this_machine_is_not_prefixed_and_caps_bind() {
    let dir = testutil::tempdir("gui-notify-local");
    let out = dir.path().join("out");
    let mut ctx = common::ctx_mut(dir.path(), "boxA");
    ctx.tools.hs = write_stub(
        dir.path(),
        "hs",
        &format!(
            "d=$(dirname \"$1\"); mkdir -p {out}; cp \"$d\"/text {out}/",
            out = out.display()
        ),
    );

    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"osd.notify".to_vec())
            .with("origin_host", b"boxA".to_vec())
            .with("style", b"plain".to_vec())
            .with("icon", b"".to_vec())
            .with("sound", b"".to_vec())
            .with("text", b"local toast".to_vec()),
    );
    let (kind, _) = client.next().expect("an answer");
    assert_eq!(kind, Kind::Response);
    assert_eq!(std::fs::read(out.join("text")).unwrap(), b"local toast");

    // §6.6's caps are today's, written down: text beyond 1024 bytes is refused
    // before anything is staged.
    client.send_request(
        &Fields::new()
            .with("op", b"osd.notify".to_vec())
            .with("origin_host", b"boxA".to_vec())
            .with("style", b"plain".to_vec())
            .with("icon", b"".to_vec())
            .with("sound", b"".to_vec())
            .with("text", vec![b'x'; 1025]),
    );
    assert_eq!(client.code(), "bad-field");
}

#[cfg(not(target_os = "macos"))]
#[test]
fn notify_is_unavailable_off_macos() {
    // The Linux build refuses rather than becoming a silent sink for
    // notifications aimed at the machine the human is sitting at.
    let dir = testutil::tempdir("gui-notify-linux");
    let ctx = common::ctx_mut(dir.path(), "boxA");
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"osd.notify".to_vec())
            .with("origin_host", b"boxB".to_vec())
            .with("style", b"plain".to_vec())
            .with("icon", b"".to_vec())
            .with("sound", b"".to_vec())
            .with("text", b"toast".to_vec()),
    );
    assert_eq!(client.code(), "unavailable");
}
