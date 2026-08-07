//! `system-bridge`'s own surface — argument shape, the hex/raw reply
//! contract, and the §8 rule 7 pre-flight — driven as a spawned process
//! against an in-test trusted-socket server. The server here is deliberately
//! tiny: enough §5.1 to establish, then scripted replies; the real daemon's
//! behavior behind each operation is the spec suite's business.

#[path = "../../src/testutil.rs"]
mod testutil;

use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::process::{Command, Stdio};

use recob_wire::wire::{self, Fields, Kind, MAX_BODY, PREAMBLE_LEN};

fn bridge() -> Command {
    Command::new(env!("CARGO_BIN_EXE_system-bridge"))
}

/// One accepted connection: preamble + hello + caps out, then every request
/// answered from `replies` in order. Returns the requests it heard.
fn serve(
    listener: UnixListener,
    proto: &str,
    caps: &[&str],
    replies: Vec<Result<Fields, (String, String)>>,
) -> std::thread::JoinHandle<Vec<Fields>> {
    let proto = proto.to_string();
    let caps = caps.join("\0");
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut head = [0u8; PREAMBLE_LEN];
        stream.read_exact(&mut head).unwrap();
        assert_eq!(&head[..5], wire::MAGIC, "client preamble");

        stream.write_all(&wire::preamble()).unwrap();
        let hello = Fields::new()
            .with("proto", proto.into_bytes())
            .with("impl", b"bridge-bin-test".to_vec());
        stream
            .write_all(&wire::encode(Kind::Hello, &hello))
            .unwrap();

        let (kind, _) = wire::read_frame(&mut stream, MAX_BODY).unwrap().unwrap();
        assert_eq!(kind, Kind::Hello, "client hello");

        let caps_frame = Fields::new()
            .with("caps", caps.into_bytes())
            .with("endpoint", b"trusted".to_vec());
        stream
            .write_all(&wire::encode(Kind::Caps, &caps_frame))
            .unwrap();

        let mut heard = Vec::new();
        let mut replies = replies.into_iter();
        while let Ok(Some((kind, body))) = wire::read_frame(&mut stream, MAX_BODY) {
            assert_eq!(kind, Kind::Request);
            heard.push(wire::parse_body(&body).unwrap());
            match replies.next().expect("a scripted reply per request") {
                Ok(fields) => stream
                    .write_all(&wire::encode(Kind::Response, &fields))
                    .unwrap(),
                Err((code, message)) => {
                    let error = Fields::new()
                        .with("code", code.into_bytes())
                        .with("message", message.into_bytes());
                    stream
                        .write_all(&wire::encode(Kind::Error, &error))
                        .unwrap();
                }
            }
        }
        heard
    })
}

struct Run {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: String,
}

fn run(
    dir: &std::path::Path,
    socket: &std::path::Path,
    args: &[&str],
    stdin: Option<&[u8]>,
) -> Run {
    let mut cmd = bridge();
    cmd.args(args)
        .env("CLIPBOARD_BRIDGE_LOCAL_SOCKET", socket)
        .env("HOME", dir)
        .env("XDG_STATE_HOME", dir.join("state"))
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().unwrap();
    let mut pipe = child.stdin.take().unwrap();
    if let Some(bytes) = stdin {
        pipe.write_all(bytes).unwrap();
    }
    drop(pipe);
    let out = child.wait_with_output().unwrap();
    Run {
        status: out.status,
        stdout: out.stdout,
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

#[test]
fn a_reply_renders_as_hex_field_lines() {
    let dir = testutil::tempdir("bridge-hex");
    let socket = dir.path().join("cb.sock");
    let server = serve(
        UnixListener::bind(&socket).unwrap(),
        "1",
        &["clip.get"],
        vec![Ok(Fields::new()
            .with("text", b"hi\n\x00\xff".to_vec())
            .with("regtype", b"l".to_vec()))],
    );

    let run = run(dir.path(), &socket, &["call", "clip.get"], None);
    assert!(run.status.success(), "{}", run.stderr);
    assert_eq!(
        String::from_utf8_lossy(&run.stdout),
        "text=68690a00ff\nregtype=6c\n",
        "every reply field, hex-framed, in reply order"
    );
    server.join().unwrap();
}

#[test]
fn raw_prints_exactly_one_fields_bytes() {
    let dir = testutil::tempdir("bridge-raw");
    let socket = dir.path().join("cb.sock");
    let server = serve(
        UnixListener::bind(&socket).unwrap(),
        "1",
        &["window.fullscreen.state"],
        vec![Ok(Fields::new().with("state", b"true".to_vec()))],
    );

    let run = run(
        dir.path(),
        &socket,
        &["call", "window.fullscreen.state", "--raw", "state"],
        None,
    );
    assert!(run.status.success(), "{}", run.stderr);
    assert_eq!(run.stdout, b"true", "raw bytes, no framing, no newline");
    server.join().unwrap();
}

#[test]
fn raw_fails_when_the_reply_lacks_the_field() {
    let dir = testutil::tempdir("bridge-raw-missing");
    let socket = dir.path().join("cb.sock");
    let server = serve(
        UnixListener::bind(&socket).unwrap(),
        "1",
        &["window.fullscreen.state"],
        vec![Ok(Fields::new().with("state", b"true".to_vec()))],
    );

    let run = run(
        dir.path(),
        &socket,
        &["call", "window.fullscreen.state", "--raw", "absent"],
        None,
    );
    assert!(!run.status.success());
    assert!(
        run.stderr.contains("the reply carried no absent field"),
        "{}",
        run.stderr
    );
    server.join().unwrap();
}

#[test]
fn scalar_and_stdin_fields_reach_the_wire() {
    let dir = testutil::tempdir("bridge-fields");
    let socket = dir.path().join("cb.sock");
    let server = serve(
        UnixListener::bind(&socket).unwrap(),
        "1",
        &["osd.notify"],
        vec![Ok(Fields::new())],
    );

    let text = b"line one\n\x1b[31mred\x1b[0m";
    let run = run(
        dir.path(),
        &socket,
        &[
            "call",
            "osd.notify",
            "style=ansi",
            "icon=",
            "--stdin",
            "text",
        ],
        Some(text),
    );
    assert!(run.status.success(), "{}", run.stderr);
    assert_eq!(run.stdout, b"", "a status-only reply prints nothing");

    let heard = server.join().unwrap();
    assert_eq!(heard.len(), 1);
    assert_eq!(heard[0].get("op").unwrap(), b"osd.notify");
    assert_eq!(heard[0].get("style").unwrap(), b"ansi");
    assert_eq!(
        heard[0].get("icon").unwrap(),
        b"",
        "an empty scalar is sent"
    );
    assert_eq!(heard[0].get("text").unwrap(), text.as_slice());
}

#[test]
fn a_server_error_reports_message_and_code() {
    let dir = testutil::tempdir("bridge-err");
    let socket = dir.path().join("cb.sock");
    let server = serve(
        UnixListener::bind(&socket).unwrap(),
        "1",
        &["clip.set.files"],
        vec![Err((
            "not-found".to_string(),
            "no row with that clip_id".to_string(),
        ))],
    );

    let run = run(
        dir.path(),
        &socket,
        &["call", "clip.set.files", "clip_id=999"],
        None,
    );
    assert!(!run.status.success());
    assert_eq!(
        run.stderr.trim(),
        "system-bridge: no row with that clip_id (not-found)",
        "rule 3: the code rides in a fixed, greppable position"
    );
    server.join().unwrap();
}

#[test]
fn an_operation_absent_from_caps_is_refused_client_side() {
    let dir = testutil::tempdir("bridge-caps");
    let socket = dir.path().join("cb.sock");
    // Proto matches, caps lack the op: §7.1's caps-authoritative shape, and
    // the server must hear no request at all (§8 rule 7).
    let server = serve(
        UnixListener::bind(&socket).unwrap(),
        "1",
        &["clip.get"],
        vec![],
    );

    let run = run(dir.path(), &socket, &["call", "osd.notify"], None);
    assert!(!run.status.success());
    assert!(
        run.stderr
            .contains("this machine's clipboard bridge does not support osd.notify"),
        "{}",
        run.stderr
    );
    assert_eq!(
        server.join().unwrap().len(),
        0,
        "the refused operation never reached the wire"
    );
}

#[test]
fn a_behind_server_gets_the_skew_diagnostic() {
    let dir = testutil::tempdir("bridge-skew");
    let socket = dir.path().join("cb.sock");
    let server = serve(
        UnixListener::bind(&socket).unwrap(),
        "0",
        &["clip.get"],
        vec![],
    );

    let run = run(dir.path(), &socket, &["call", "clip.set.files"], None);
    assert!(!run.status.success());
    assert!(
        run.stderr
            .contains("this machine's clipboard bridge is behind — it speaks RECOB proto 0")
            && run.stderr.contains("clip.set.files needs proto 1")
            && run.stderr.contains("Run chezmoi apply here."),
        "{}",
        run.stderr
    );
    server.join().unwrap();
}

#[test]
fn probe_is_the_connect_result() {
    // §5.2 via §6.1: ECONNREFUSED is the one "down"; a bound listener is up
    // even though nothing speaks RECOB behind it yet.
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let up = bridge()
        .args(["probe", "127.0.0.1", &port.to_string()])
        .output()
        .unwrap();
    assert!(up.status.success(), "a bound port probes up");

    drop(listener);
    let down = bridge()
        .args(["probe", "127.0.0.1", &port.to_string()])
        .output()
        .unwrap();
    assert!(!down.status.success(), "a refused connect probes down");
    assert_eq!(down.stderr, b"", "the probe is silent either way");
}

#[test]
fn malformed_invocations_fail_before_dialing() {
    let dir = testutil::tempdir("bridge-args");
    let socket = dir.path().join("no.sock"); // nothing bound — a dial would fail loudly

    for (args, needle) in [
        (&["call"][..], "call needs an operation name"),
        (&["call", "clip.get", "bare-word"][..], "name=value"),
        (
            &["call", "osd.notify", "style=a", "style=b"][..],
            "field style given twice",
        ),
        (
            &["call", "osd.notify", "text=x", "--stdin", "text"][..],
            "field text given twice",
        ),
        (
            &["call", "clip.get", "op=clip.set"][..],
            "op is the operation argument",
        ),
        (&["nope"][..], "usage:"),
    ] {
        let run = run(dir.path(), &socket, args, None);
        assert!(!run.status.success(), "{args:?}");
        assert!(run.stderr.contains(needle), "{args:?} said: {}", run.stderr);
    }
}
