//! §11.1: `recobd --record`, a real listener that records.
//!
//! Every assertion here goes through the shipped binary's production accept
//! loop and decoder — that is the whole point of the seam. The fake `nc` it
//! replaces observed only the bytes a client wrote and invented the reply, so a
//! client that emitted a subtly wrong frame was faithfully recorded as wrong.

mod common;

use common::{testutil, text, Daemon};
use recobd::wire::{self, Fields, FrameError, Kind};

struct Recorder {
    daemon: Daemon,
    log: std::path::PathBuf,
    _dir: testutil::TempDir,
}

fn recorder(label: &str, script: Option<&str>) -> Recorder {
    let dir = testutil::tempdir(label);
    std::fs::create_dir_all(dir.path().join("clipboard")).unwrap();
    std::fs::write(dir.path().join("clipboard/self-name"), "boxA\n").unwrap();
    let log = dir.path().join("record.log");
    let script_path = dir.path().join("script");
    if let Some(text) = script {
        std::fs::write(&script_path, text).unwrap();
    }

    let mut env = vec![
        ("XDG_STATE_HOME", dir.path().to_string_lossy().into_owned()),
        ("RECOB_RECORD_LOG", log.to_string_lossy().into_owned()),
    ];
    if script.is_some() {
        env.push((
            "RECOB_RECORD_SCRIPT",
            script_path.to_string_lossy().into_owned(),
        ));
    }
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let daemon = Daemon::activated(dir.path(), &["--record"], &env);
    daemon.wait_for_log("recording mode");
    Recorder {
        daemon,
        log,
        _dir: dir,
    }
}

impl Recorder {
    fn lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    /// Waits for the recorder to have written `n` lines, so an assertion is not
    /// racing the daemon's append.
    fn wait_for_lines(&self, n: usize) -> Vec<String> {
        for _ in 0..200 {
            let lines = self.lines();
            if lines.len() >= n {
                return lines;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        panic!(
            "only {} log lines, wanted {n}:\n{:?}\n{}",
            self.lines().len(),
            self.lines(),
            self.daemon.stderr()
        );
    }
}

#[test]
fn the_log_line_is_the_format_the_spec_fixes() {
    let rec = recorder("record-format", None);
    let mut client = rec.daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();
    let (kind, fields) = client.request("host.identity");
    assert_eq!(
        kind,
        Kind::Response,
        "an absent script answers from the registry"
    );
    assert_eq!(text(&fields, "host"), "boxA");

    let lines = rec.wait_for_lines(2);
    // `<endpoint>\t<op>\t<field>=<hex>…`, values hex so NUL and binary payloads
    // are exact. "1" is 31, "spec-test" is 737065632d74657374.
    assert_eq!(
        lines[0],
        "trusted\thello\tproto=31\timpl=737065632d74657374"
    );
    assert_eq!(lines[1], "trusted\thost.identity");
}

#[test]
fn a_subtly_wrong_frame_fails_instead_of_being_recorded_as_wrong() {
    // The property the fake `nc` could not have: the recorder decodes with the
    // production decoder, so a bad frame is an error, not a log line.
    let rec = recorder("record-strict", None);
    let mut client = rec.daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();

    // A field this build has never heard of (P6).
    client.send_request(
        &Fields::new()
            .with("op", b"host.identity".to_vec())
            .with("verbose", b"1".to_vec()),
    );
    assert_eq!(text(&client.expect_error(), "code"), "unknown-field");

    // A duplicate field name (§4.3).
    let mut body = wire::encode_body(&Fields::new().with("op", b"host.identity".to_vec()));
    body.extend_from_slice(&wire::encode_body(
        &Fields::new().with("op", b"host.identity".to_vec()),
    ));
    client.send_raw(&wire::encode_raw(Kind::Request, &body));
    assert_eq!(text(&client.expect_error(), "code"), "bad-field");

    // An operation that does not exist here.
    client.send_request(&Fields::new().with("op", b"clip.st".to_vec()));
    assert_eq!(text(&client.expect_error(), "code"), "unknown-op");

    // One good exchange, to prove the recorder was recording all along.
    let (kind, _) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);

    let lines = rec.wait_for_lines(2);
    assert_eq!(
        lines,
        vec![
            "trusted\thello\tproto=31\timpl=737065632d74657374".to_string(),
            "trusted\thost.identity".to_string(),
        ],
        "only the exchange that decoded and validated is recorded"
    );
}

#[test]
fn scripted_replies_answer_in_order() {
    let rec = recorder(
        "record-script",
        Some("ok host=626f7842\nerr not-found nothing to answer with\n"),
    );
    let mut client = rec.daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();

    let (kind, fields) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(
        text(&fields, "host"),
        "boxB",
        "the script replies, not the registry"
    );

    let (kind, fields) = client.request("host.identity");
    assert_eq!(kind, Kind::Error);
    assert_eq!(text(&fields, "code"), "not-found");
    assert_eq!(text(&fields, "message"), "nothing to answer with");

    // Spent script: the daemon answers from its own registry again, which is
    // what makes the recorder usable as a real listener.
    let (kind, fields) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");

    rec.wait_for_lines(4);
}

#[test]
fn the_close_directive_disconnects_mid_frame() {
    // "close (disconnect mid-frame, to exercise truncation handling)": a header
    // that declares a body, and then nothing.
    let rec = recorder("record-close", Some("close\n"));
    let mut client = rec.daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();
    client.send_request(&Fields::new().with("op", b"host.identity".to_vec()));
    match client.next_result() {
        Err(FrameError::Truncated) => {}
        other => panic!("expected a truncated frame, got {other:?}"),
    }
}

#[test]
fn the_stream_directive_ends_with_an_explicit_empty_chunk() {
    let dir = testutil::tempdir("record-stream-payload");
    let blob = dir.path().join("blob");
    std::fs::write(&blob, b"one\0two\n").unwrap();
    let rec = recorder(
        "record-stream",
        Some(&format!("stream {}\n", blob.display())),
    );

    let mut client = rec.daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();
    client.send_request(&Fields::new().with("op", b"host.identity".to_vec()));

    let (kind, fields) = client.next().unwrap();
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "size"), "8");
    let (kind, body) = client.next_raw().unwrap();
    assert_eq!(kind, Kind::Data);
    assert_eq!(body, b"one\0two\n");
    let (kind, body) = client.next_raw().unwrap();
    assert_eq!(kind, Kind::Data);
    assert!(
        body.is_empty(),
        "§6.4: a zero-length D terminates the stream"
    );
}

#[test]
fn the_hello_directive_chooses_the_banner_version() {
    // How §7's skew diagnostics get tested without two machines.
    let rec = recorder("record-hello", Some("hello proto=7\n"));
    let client = rec.daemon.connect_trusted();
    assert_eq!(text(&client.banner, "proto"), "7");
    assert_eq!(text(&client.banner, "host"), "boxA");
}

#[test]
fn the_endpoint_override_makes_public_policy_reachable_over_a_socket() {
    let dir = testutil::tempdir("record-endpoint");
    std::fs::create_dir_all(dir.path().join("clipboard")).unwrap();
    std::fs::write(dir.path().join("clipboard/self-name"), "boxA\n").unwrap();
    let log = dir.path().join("record.log");
    let daemon = Daemon::activated(
        dir.path(),
        &["--record"],
        &[
            ("XDG_STATE_HOME", &dir.path().to_string_lossy()),
            ("RECOB_RECORD_LOG", &log.to_string_lossy()),
            ("RECOB_RECORD_ENDPOINT", "public"),
        ],
    );
    daemon.wait_for_log("recording mode");

    let mut client = daemon.connect_trusted();
    client.hello_default();
    assert_eq!(
        text(&client.expect_caps(), "endpoint"),
        "public",
        "a spec with only a socket to point at can still exercise public policy"
    );
    client.request("host.identity");

    for _ in 0..200 {
        if std::fs::read_to_string(&log)
            .unwrap_or_default()
            .contains("public\thost.identity")
        {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    panic!(
        "log never labelled the exchange public:\n{}",
        std::fs::read_to_string(&log).unwrap_or_default()
    );
}

#[test]
fn a_malformed_directive_is_reported_rather_than_skipped() {
    // A typo in a reply script must not look like a passing test.
    let rec = recorder("record-malformed", Some("ok host=nothex\n"));
    let mut client = rec.daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();
    client.send_request(&Fields::new().with("op", b"host.identity".to_vec()));
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "internal");
    assert!(
        text(&fields, "message").contains("not hex"),
        "{}",
        text(&fields, "message")
    );
}
