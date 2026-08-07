//! The §8 client contract, driven end to end: the shared `client::Session`
//! against a spawned daemon — including §11.4's client-side authentication
//! cases, via the recorder's `deny-auth`/`no-proof`/`bad-proof` directives.

mod common;

use common::testutil;
use recobd::client::{dial, ClientError, Credential, Dial, Session, Timeouts};
use recobd::wire::Fields;

fn spawn_public(dir: &std::path::Path, extra_env: &[(&str, &str)]) -> (common::Daemon, String) {
    let state = dir.join("state");
    std::fs::create_dir_all(&state).unwrap();
    let mut env: Vec<(&str, &str)> = vec![("XDG_STATE_HOME", state.to_str().unwrap())];
    env.extend_from_slice(extra_env);
    let socket = dir.join("cb.sock");
    let socket_arg = socket.to_str().unwrap().to_string();
    let daemon = common::Daemon::activated(
        dir,
        &["--socket", &socket_arg],
        &env.iter().map(|(k, v)| (*k, *v)).collect::<Vec<_>>(),
    );
    let token = common::wait_for_token(&state);
    (daemon, token)
}

#[test]
fn a_trusted_session_establishes_and_exchanges() {
    let dir = testutil::tempdir("client-trusted");
    let (daemon, _token) = spawn_public(dir.path(), &[]);
    let stream = std::os::unix::net::UnixStream::connect(&daemon.socket).unwrap();
    let mut session =
        Session::establish(stream, Credential::TrustedSocket, Timeouts::default()).unwrap();
    assert_eq!(session.endpoint, "trusted");
    assert!(session.supports("host.identity"), "caps arrived");
    assert!(!session.supports("host.telemetry"));
    let reply = session
        .exchange(&Fields::new().with("op", b"host.identity".to_vec()), false)
        .unwrap();
    assert!(reply.get("host").is_some());
}

#[test]
fn a_public_session_authenticates_and_verifies_the_proof() {
    let dir = testutil::tempdir("client-public");
    let (daemon, token) = spawn_public(dir.path(), &[]);
    let stream = match dial("127.0.0.1", daemon.port, std::time::Duration::from_secs(2)) {
        Dial::Connected(stream) => stream,
        _ => panic!("the daemon is listening"),
    };
    let token = recobd::auth::Token::from_hex(&token).unwrap();
    let mut session =
        Session::establish(stream, Credential::Token(token), Timeouts::default()).unwrap();
    assert_eq!(session.endpoint, "public");
    let reply = session
        .exchange(&Fields::new().with("op", b"host.identity".to_vec()), false)
        .unwrap();
    assert!(reply.get("host").is_some());
}

#[test]
fn a_wrong_credential_reports_unauthorized_not_a_fallback() {
    let dir = testutil::tempdir("client-denied");
    let (daemon, _token) = spawn_public(dir.path(), &[]);
    let stream = match dial("127.0.0.1", daemon.port, std::time::Duration::from_secs(2)) {
        Dial::Connected(stream) => stream,
        _ => panic!("the daemon is listening"),
    };
    let wrong = recobd::auth::Token::from_hex(&"9".repeat(64)).unwrap();
    let err = Session::establish(stream, Credential::Token(wrong), Timeouts::default())
        .err()
        .expect("refused");
    match err {
        ClientError::Server { code, .. } => assert_eq!(code, "unauthorized"),
        other => panic!("expected the server's refusal, got {other}"),
    }
}

/// §11.4: "The client refuses an unproven server" — a listener that
/// authenticates the client but returns a wrong or absent proof gets nothing
/// further, and the failure names an untrusted endpoint rather than a timeout.
#[test]
fn an_unproven_server_is_refused_before_any_request() {
    for directive in ["no-proof", "bad-proof"] {
        let dir = testutil::tempdir(&format!("client-{directive}"));
        let script = dir.path().join("script");
        std::fs::write(&script, format!("{directive}\n")).unwrap();
        let log = dir.path().join("record.log");
        let (daemon, token) = spawn_public(
            dir.path(),
            &[
                ("RECOB_RECORD_SCRIPT", script.to_str().unwrap()),
                ("RECOB_RECORD_LOG", log.to_str().unwrap()),
            ],
        );
        // Re-spawn shape: the daemon needs --record for the script to bite.
        drop(daemon);
        let socket_arg = dir.path().join("cb.sock");
        std::fs::remove_file(&socket_arg).ok();
        let daemon = common::Daemon::activated(
            dir.path(),
            &["--record", "--socket", socket_arg.to_str().unwrap()],
            &[
                (
                    "XDG_STATE_HOME",
                    &dir.path().join("state").to_string_lossy(),
                ),
                ("RECOB_RECORD_SCRIPT", &script.to_string_lossy()),
                ("RECOB_RECORD_LOG", &log.to_string_lossy()),
            ],
        );

        let stream = match dial("127.0.0.1", daemon.port, std::time::Duration::from_secs(2)) {
            Dial::Connected(stream) => stream,
            _ => panic!("the recorder is listening"),
        };
        let token = recobd::auth::Token::from_hex(&token).unwrap();
        let err = Session::establish(stream, Credential::Token(token), Timeouts::default())
            .err()
            .expect("an unproven endpoint must be refused");
        match err {
            ClientError::Untrusted(_) => {}
            other => panic!("{directive}: expected Untrusted, got {other}"),
        }
    }
}

/// §5.2: the connect result is the only fallback signal. A refused connect is
/// [`Dial::Refused`]; everything else must fail loudly, which the caller can
/// only get right if the library never conflates the two.
#[test]
fn only_a_refused_connect_reads_as_an_absent_bridge() {
    // A port with nothing bound: bind, learn the number, drop the listener.
    let port = {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        listener.local_addr().unwrap().port()
    };
    match dial("127.0.0.1", port, std::time::Duration::from_secs(2)) {
        Dial::Refused => {}
        _ => panic!("an unbound port must read as Refused"),
    }

    // A bound listener that accepts and says nothing: the connect COMPLETES,
    // so this is never Refused — establish then fails loudly on the preamble.
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let hold = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1500));
        drop(stream);
    });
    let stream = match dial("127.0.0.1", port, std::time::Duration::from_secs(2)) {
        Dial::Connected(stream) => stream,
        _ => panic!("a bound listener completes the connect"),
    };
    let err = Session::establish(stream, Credential::TrustedSocket, Timeouts::default())
        .err()
        .expect("a silent listener is not an absent bridge");
    match err {
        ClientError::NotRecob(_) => {}
        other => panic!("expected the §7.3 diagnostic, got {other}"),
    }
    hold.join().unwrap();
}
