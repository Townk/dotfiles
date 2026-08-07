//! The client binary's §5.2/§8 behavior, driven as a spawned process — no
//! daemon required: these are the cases where the *absence* or *misbehavior*
//! of the bridge decides, and §11.4 calls the fail-open one the most
//! important test in the set.

#[path = "../../src/testutil.rs"]
mod testutil;

use std::process::Command;

fn clip() -> Command {
    Command::new(env!("CARGO_BIN_EXE_system-clip"))
}

/// A port with nothing bound: bind, learn the number, drop the listener.
fn refused_port() -> u16 {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    listener.local_addr().unwrap().port()
}

fn ssh_env(cmd: &mut Command, dir: &std::path::Path, port: u16, sink: &std::path::Path) {
    cmd.env("SSH_TTY", "/dev/ttys000")
        .env("CLIPBOARD_BRIDGE_PORT", port.to_string())
        .env("CLIPBOARD_BRIDGE_LOCAL_SOCKET", dir.join("no.sock"))
        .env("XDG_STATE_HOME", dir.join("state"))
        .env("PBCOPY_OSC52_SINK", sink)
        .env("RECOB_HELLO_TIMEOUT_MS", "300");
}

#[test]
fn an_absent_bridge_falls_back_to_osc52_silently() {
    let dir = testutil::tempdir("clip-osc52");
    let sink = dir.path().join("tty");
    std::fs::write(&sink, b"").unwrap();

    let mut cmd = clip();
    cmd.arg("copy");
    ssh_env(&mut cmd, dir.path(), refused_port(), &sink);
    let mut child = cmd
        .stdin(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"fallback text")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "ECONNREFUSED is the fallback license");

    let written = std::fs::read(&sink).unwrap();
    // base64("fallback text")
    assert_eq!(written, b"\x1b]52;c;ZmFsbGJhY2sgdGV4dA==\x1b\\".to_vec());
}

/// §11.4's fail-open regression test: a listener that answers nothing at all
/// completed the connect, so the copy must fail loudly and MUST NOT emit an
/// OSC 52 sequence. This is the difference between authentication being a
/// control and being a suggestion.
#[test]
fn a_reachable_but_silent_bridge_fails_loudly_with_no_osc52() {
    let dir = testutil::tempdir("clip-no-fallback");
    let sink = dir.path().join("tty");
    std::fs::write(&sink, b"").unwrap();

    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let hold = std::thread::spawn(move || {
        // Accept and say nothing until the client gives up.
        let (stream, _) = listener.accept().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1200));
        drop(stream);
    });

    let mut cmd = clip();
    cmd.arg("copy");
    ssh_env(&mut cmd, dir.path(), port, &sink);
    let mut child = cmd
        .stdin(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write;
    child.stdin.take().unwrap().write_all(b"secret").unwrap();
    let out = child.wait_with_output().unwrap();
    hold.join().unwrap();

    assert!(
        !out.status.success(),
        "a completed connect is never an absent bridge"
    );
    let sink_bytes = std::fs::read(&sink).unwrap();
    assert!(
        sink_bytes.is_empty(),
        "no OSC 52 byte may leave on a reachable-but-unsatisfied bridge"
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("pbcopy"),
        "the failure is reported, not papered over: {stderr}"
    );
}

#[test]
fn paste_never_falls_back_and_names_the_tunnel() {
    let dir = testutil::tempdir("clip-paste-down");
    let sink = dir.path().join("tty");
    let mut cmd = clip();
    cmd.arg("paste");
    ssh_env(&mut cmd, dir.path(), refused_port(), &sink);
    let out = cmd.output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("reverse SSH tunnel down"),
        "the diagnostic names the likely cause: {stderr}"
    );
    assert!(out.stdout.is_empty(), "nothing fabricated on stdout");
}

#[test]
fn a_missing_subcommand_prints_usage() {
    let out = clip().output().unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("usage"));
}

#[test]
fn restore_validates_its_clip_id_before_dialing() {
    let dir = testutil::tempdir("clip-restore-args");
    // A socket that does not exist: if the id were accepted, the failure would
    // be about the connection instead of the argument.
    let mut cmd = clip();
    cmd.arg("restore").arg("id:12").env(
        "CLIPBOARD_BRIDGE_LOCAL_SOCKET",
        dir.path().join("absent.sock"),
    );
    let out = cmd.output().unwrap();
    assert!(!out.status.success());
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("not a clip id"),
        "the bare rowid replaced the id: prefix (§6.1)"
    );

    let out = clip().arg("restore").output().unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("usage"));
}
