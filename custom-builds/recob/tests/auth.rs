//! §9.2's mutual authentication and §3.5's pre-authentication limits, as
//! controls rather than as fields — which is how §11.4 asks for them.
//!
//! The tests that need a real accept loop (the §3.5 caps) spawn the daemon; the
//! rest run its `session::serve` in process.

mod common;

use common::{ctx_mut, ctx_with_host, served, served_teed, testutil, text, Daemon, TEST_TOKEN};
use recobd::auth::Token;
use recobd::listen::Endpoint;
use recobd::wire::{self, Fields, Kind};

fn state_dir(dir: &std::path::Path, host: &str) -> String {
    std::fs::create_dir_all(dir.join("clipboard")).unwrap();
    std::fs::write(dir.join("clipboard/self-name"), format!("{host}\n")).unwrap();
    dir.to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// §5.1 / §9.2: what the banner may say, and what the handshake must establish
// ---------------------------------------------------------------------------

#[test]
fn the_pre_auth_banner_discloses_proto_host_and_nonce_and_nothing_else() {
    // §11.4 wants this as an assertion over the frame's field set, so a later
    // addition of `caps` to the banner fails a test rather than passing review.
    let dir = testutil::tempdir("banner-fields");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let client = served(ctx, Endpoint::Public);
    let names: Vec<&str> = client.banner.names().collect();
    assert_eq!(names, vec!["proto", "host", "nonce"]);
    assert_eq!(client.nonce().len(), 32);
    // An unauthenticated peer must not learn the build identity or the operation
    // inventory: that is a free reconnaissance map for the local attacker §9.2
    // exists to stop.
    assert_eq!(client.banner.get("impl"), None);
    assert_eq!(client.banner.get("caps"), None);
}

#[test]
fn the_trusted_socket_is_challenged_with_nothing() {
    // §9.2: the trusted Unix socket requires no credential — its uid boundary is
    // the credential — so there is no nonce to issue and no proof to give.
    let dir = testutil::tempdir("banner-trusted");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    assert_eq!(
        client.banner.names().collect::<Vec<_>>(),
        vec!["proto", "host"]
    );
    client.hello_default();
    assert_eq!(client.expect_caps().get("proof"), None);
}

#[test]
fn a_correct_response_authenticates_and_the_server_proves_itself() {
    let dir = testutil::tempdir("auth-happy");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Public);
    client.hello_authenticated(TEST_TOKEN);
    // expect_caps_proven recomputes the proof from *this* client's cnonce, so an
    // endpoint that echoed the client's own digest back would fail here.
    let caps = client.expect_caps_proven(TEST_TOKEN);
    assert_eq!(text(&caps, "endpoint"), "public");
    let (kind, fields) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");
}

// ---------------------------------------------------------------------------
// §11.4: "Authentication, as a control rather than a field"
// ---------------------------------------------------------------------------

/// Every refusal below must dispatch nothing, close the connection, and disclose
/// only that it failed.
fn assert_refused(client: &mut common::Client<impl std::io::Read + std::io::Write>) -> String {
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "unauthorized");
    assert!(
        client.next_raw().is_none(),
        "§9.2: the endpoint closes after refusing"
    );
    text(&fields, "reason")
}

#[test]
fn a_connection_with_no_credential_is_refused() {
    let dir = testutil::tempdir("auth-none");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Public);
    client.hello(
        &Fields::new()
            .with("proto", b"1".to_vec())
            .with("cnonce", vec![0u8; 32]),
    );
    assert_eq!(assert_refused(&mut client), "no-credential");
}

#[test]
fn a_credential_belonging_to_another_owner_is_refused() {
    let dir = testutil::tempdir("auth-other");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Public);
    let other = "f".repeat(64);
    let auth = Token::from_hex(&other)
        .unwrap()
        .client_digest(client.nonce());
    let cnonce = client.cnonce.clone();
    client.hello(
        &Fields::new()
            .with("proto", b"1".to_vec())
            .with("auth", auth.into_bytes())
            .with("cnonce", cnonce),
    );
    assert_eq!(assert_refused(&mut client), "bad-credential");
}

#[test]
fn a_malformed_credential_is_a_bad_field_before_any_digest_work() {
    let dir = testutil::tempdir("auth-malformed");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Public);
    let cnonce = client.cnonce.clone();
    client.hello(
        &Fields::new()
            .with("proto", b"1".to_vec())
            .with("auth", b"not-a-digest".to_vec())
            .with("cnonce", cnonce),
    );
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "bad-field");
    assert_eq!(text(&fields, "field"), "auth");
}

#[test]
fn a_token_file_at_mode_0640_is_rejected_as_if_absent() {
    use std::os::unix::fs::PermissionsExt;
    let dir = testutil::tempdir("auth-mode");
    let ctx = ctx_with_host(dir.path(), "boxA");
    std::fs::set_permissions(&ctx.token_path, std::fs::Permissions::from_mode(0o640)).unwrap();

    let mut client = served(ctx, Endpoint::Public);
    // The client offers a *correct* response; the endpoint still refuses, because
    // it will not read a credential any other uid could have.
    client.hello_authenticated(TEST_TOKEN);
    assert_refused(&mut client);
}

#[test]
fn a_response_is_bound_to_the_nonce_it_answered() {
    // §11.4: a response captured from one nonce is rejected against another.
    let dir = testutil::tempdir("auth-replay");
    let ctx = ctx_with_host(dir.path(), "boxA");

    let first = served(ctx.clone(), Endpoint::Public);
    let captured = Token::from_hex(TEST_TOKEN)
        .unwrap()
        .client_digest(first.nonce());
    drop(first);

    let mut second = served(ctx, Endpoint::Public);
    assert_ne!(
        second.nonce(),
        Token::from_hex(TEST_TOKEN).unwrap().as_str().as_bytes(),
        "sanity: the nonce is not the token"
    );
    let cnonce = second.cnonce.clone();
    second.hello(
        &Fields::new()
            .with("proto", b"1".to_vec())
            .with("auth", captured.into_bytes())
            .with("cnonce", cnonce),
    );
    assert_eq!(assert_refused(&mut second), "bad-credential");
}

#[test]
fn the_token_never_appears_on_the_wire() {
    // §11.4's headline authentication assertion, over every byte of a full
    // authenticated exchange in both directions.
    let dir = testutil::tempdir("auth-wire");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served_teed(ctx, Endpoint::Public);
    client.hello_authenticated(TEST_TOKEN);
    client.expect_caps_proven(TEST_TOKEN);
    let (kind, _) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);

    let wire = client.stream.wire();
    assert!(!wire.is_empty());
    let token = TEST_TOKEN.as_bytes();
    assert!(
        !wire.windows(token.len()).any(|w| w == token),
        "the credential itself crossed the connection"
    );
    // The digests did cross, and that is the point: they are what the token is
    // for. Their presence proves the search above was looking at real traffic.
    let expected = Token::from_hex(TEST_TOKEN)
        .unwrap()
        .client_digest(client.nonce())
        .into_bytes();
    assert!(
        wire.windows(expected.len()).any(|w| w == expected),
        "the client's response should be on the wire"
    );
}

#[test]
fn the_same_token_answers_differently_to_a_different_nonce() {
    let dir = testutil::tempdir("auth-varies");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let a = served(ctx.clone(), Endpoint::Public);
    let b = served(ctx, Endpoint::Public);
    let token = Token::from_hex(TEST_TOKEN).unwrap();
    assert_ne!(a.nonce(), b.nonce());
    assert_ne!(
        token.client_digest(a.nonce()),
        token.client_digest(b.nonce()),
        "§11.4: the same token produces a different auth value per nonce"
    );
}

#[test]
fn nonces_are_pairwise_distinct_across_concurrent_connections() {
    // §11.4 keeps this test for a hazard the daemon cannot have: a generator
    // seeded once at start reproduces the forked-$RANDOM failure in any language,
    // and it is invisible in every other test because authentication still
    // *succeeds* when the nonce repeats.
    let dir = testutil::tempdir("auth-nonces");
    let state = state_dir(dir.path(), "boxA");
    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated public endpoint");

    // Twenty-four connections, in batches of eight. Both bounds are §3.5's and
    // neither can be argued with here: eight unauthenticated connections may be in
    // flight at once, and thirty new connections are admitted per ten seconds, so
    // a live nonce test cannot exceed thirty without waiting out the window.
    // Volume distinctness is covered where it belongs, against the generator, in
    // `auth`'s own unit tests.
    let port = daemon.port;
    let mut nonces: Vec<Vec<u8>> = Vec::new();
    for _ in 0..3 {
        let mut handles = Vec::new();
        for _ in 0..8 {
            handles.push(std::thread::spawn(move || {
                let stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let client = common::Client::open(stream);
                client.nonce().to_vec()
            }));
        }
        nonces.extend(handles.into_iter().map(|h| h.join().unwrap()));
    }
    let unique: std::collections::HashSet<Vec<u8>> = nonces.iter().cloned().collect();
    assert_eq!(
        unique.len(),
        nonces.len(),
        "a nonce repeated across connections"
    );
    assert!(nonces.iter().all(|n| n.len() == 32));
}

#[test]
fn capabilities_always_precede_any_response() {
    // The server-side half of §9.2's "a response before `proof` is refused": the
    // client's rule is enforceable only if the server never gives it the chance,
    // so the frame carrying the proof must come first even when requests were
    // pipelined behind the hello.
    let dir = testutil::tempdir("auth-order");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Public);
    let token = Token::from_hex(TEST_TOKEN).unwrap();
    let auth = token.client_digest(client.nonce());
    let cnonce = client.cnonce.clone();
    let mut out = wire::preamble().to_vec();
    out.extend_from_slice(&wire::encode(
        Kind::Hello,
        &Fields::new()
            .with("proto", b"1".to_vec())
            .with("auth", auth.into_bytes())
            .with("cnonce", cnonce),
    ));
    out.extend_from_slice(&wire::encode(
        Kind::Request,
        &Fields::new().with("op", b"host.identity".to_vec()),
    ));
    client.send_raw(&out);

    let (kind, fields) = client.next().unwrap();
    assert_eq!(kind, Kind::Caps, "the proof-bearing frame comes first");
    assert!(fields.get("proof").is_some());
    let (kind, _) = client.next().unwrap();
    assert_eq!(kind, Kind::Response);
}

/// A recorder daemon with one connection-level directive in its script, started
/// through the production `--record` wiring rather than a test-only constructor.
fn recorder_with(label: &str, directive: &str) -> (testutil::TempDir, Daemon, String) {
    let dir = testutil::tempdir(label);
    let state = state_dir(dir.path(), "boxA");
    let script = dir.path().join("script");
    std::fs::write(&script, format!("{directive}\n")).unwrap();
    let daemon = Daemon::activated(
        dir.path(),
        &["--record"],
        &[
            ("XDG_STATE_HOME", &state),
            ("RECOB_RECORD_SCRIPT", &script.to_string_lossy()),
        ],
    );
    daemon.wait_for_log("recording mode");
    let token = common::wait_for_token(dir.path());
    (dir, daemon, token)
}

#[test]
fn the_recorder_can_withhold_the_proof() {
    // §11.1's `no-proof`, which exists so a client's untrusted-endpoint path can
    // be exercised deliberately in Phase 5.
    let (_dir, daemon, token) = recorder_with("auth-no-proof", "no-proof");
    let mut client = daemon.connect_public();
    client.hello_authenticated(&token);
    assert_eq!(client.expect_caps().get("proof"), None);
}

#[test]
fn the_recorder_can_falsify_the_proof() {
    // `bad-proof` is a separate directive because a client that merely tests for
    // the *presence* of `proof` would pass `no-proof`'s counterpart and must not.
    let (_dir, daemon, token) = recorder_with("auth-bad-proof", "bad-proof");
    let mut client = daemon.connect_public();
    client.hello_authenticated(&token);
    let caps = client.expect_caps();
    let offered = text(&caps, "proof");
    let honest = Token::from_hex(&token)
        .unwrap()
        .server_proof(&client.cnonce);
    assert_ne!(offered, honest, "bad-proof must not prove anything");
    assert_eq!(
        offered.len(),
        honest.len(),
        "but must still look like a proof"
    );
}

#[test]
fn deny_auth_refuses_a_correct_credential() {
    let (_dir, daemon, token) = recorder_with("auth-deny", "deny-auth");
    let mut client = daemon.connect_public();
    client.hello_authenticated(&token);
    assert_eq!(assert_refused(&mut client), "bad-credential");
}

// ---------------------------------------------------------------------------
// §9.6: a withdrawn operation subtracts and nothing else
// ---------------------------------------------------------------------------

#[test]
fn a_withdrawn_operation_subtracts_and_nothing_else() {
    let dir = testutil::tempdir("exposure-e2e");
    let exposure = dir.path().join("exposure");
    std::fs::write(&exposure, "public host.identity\n").unwrap();
    let mut ctx = ctx_mut(dir.path(), "boxA");
    ctx.exposure = recobd::exposure::Exposure::at(exposure);
    let ctx = std::sync::Arc::new(ctx);

    // Refused on the endpoint it was withdrawn from, with a reason an operator can
    // tell apart from a wrong token.
    let mut public = served(ctx.clone(), Endpoint::Public);
    public.hello_authenticated(TEST_TOKEN);
    let caps_public = text(&public.expect_caps_proven(TEST_TOKEN), "caps");
    let (kind, fields) = public.request("host.identity");
    assert_eq!(kind, Kind::Error);
    assert_eq!(text(&fields, "code"), "unauthorized");
    assert_eq!(text(&fields, "reason"), "not-exposed");
    // The handler never ran: no `host` came back, and the connection survives.
    assert_eq!(fields.get("host"), None);
    let (kind, _) = public.request("host.identity");
    assert_eq!(kind, Kind::Error, "still withdrawn on the next exchange");

    // Still answered on the endpoint it was not withdrawn from.
    let mut trusted = served(ctx, Endpoint::Trusted);
    trusted.hello_default();
    let caps_trusted = text(&trusted.expect_caps(), "caps");
    let (kind, fields) = trusted.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");

    // §9.6: `caps` is byte-identical either way — the registry's own set, so
    // §7.1's "operation missing at equal versions" diagnostic cannot be
    // triggered by local policy.
    assert_eq!(
        caps_public.as_bytes(),
        recobd::registry::caps().as_slice(),
        "caps stays the build's full set, withdrawal notwithstanding"
    );
    assert_eq!(caps_public, caps_trusted);
}

#[test]
fn caps_is_unchanged_by_the_presence_of_an_exposure_file() {
    let dir = testutil::tempdir("exposure-caps");
    let without = {
        let ctx = ctx_with_host(dir.path(), "boxA");
        let mut client = served(ctx, Endpoint::Trusted);
        client.hello_default();
        text(&client.expect_caps(), "caps")
    };
    let with = {
        let exposure = dir.path().join("exposure");
        std::fs::write(&exposure, "trusted host.identity\n").unwrap();
        let mut ctx = ctx_mut(dir.path(), "boxA");
        ctx.exposure = recobd::exposure::Exposure::at(exposure);
        let mut client = served(std::sync::Arc::new(ctx), Endpoint::Trusted);
        client.hello_default();
        text(&client.expect_caps(), "caps")
    };
    assert_eq!(without, with);
}

// ---------------------------------------------------------------------------
// §3.5: pre-authentication limits, against a real accept loop
// ---------------------------------------------------------------------------

/// Connects and says nothing, holding an unauthenticated in-flight slot.
fn stalled(port: u16) -> std::net::TcpStream {
    let stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
        .unwrap();
    stream
}

#[test]
fn a_refused_connection_still_writes_recob_and_busy() {
    // The regression test for the bypass the first revision introduced, where the
    // pre-auth limits and the no-fallback rule combined into an authentication
    // bypass: a silent close would tell a client "no bridge here", which is the
    // one condition that unlocks unauthenticated OSC 52.
    let dir = testutil::tempdir("limits-busy");
    let state = state_dir(dir.path(), "boxA");
    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated public endpoint");

    // §3.5: eight unauthenticated connections in flight is the default cap, and a
    // peer that connects and says nothing occupies a slot until it authenticates
    // or closes. Hold them open for the duration.
    let _held: Vec<std::net::TcpStream> = (0..8).map(|_| stalled(daemon.port)).collect();

    let refused = stalled(daemon.port);
    let mut client_view = refused;
    let mut buf = Vec::new();
    use std::io::Read;
    client_view.read_to_end(&mut buf).unwrap();

    assert!(
        buf.starts_with(b"RECOB"),
        "a refusal must still identify itself as RECOB, got {buf:?}"
    );
    assert_eq!(buf[5], 1, "wire version");
    let (kind, body) = wire::read_frame(&mut std::io::Cursor::new(&buf[6..]), wire::MAX_BODY)
        .unwrap()
        .unwrap();
    assert_eq!(kind, Kind::Error, "§3.5: the preamble and that error only");
    let fields = wire::parse_body(&body).unwrap();
    assert_eq!(text(&fields, "code"), "busy");
    assert!(
        fields.get("retry_after").is_some(),
        "busy carries retry_after"
    );
    // Never the banner: there is no nonce to issue for a connection that will not
    // be authenticated.
    assert_eq!(fields.get("nonce"), None);
    assert!(
        daemon.stderr().contains("refused at accept"),
        "{}",
        daemon.stderr()
    );
}

#[test]
fn a_peer_that_stalls_mid_hello_is_dropped_at_the_deadline() {
    let dir = testutil::tempdir("limits-stall");
    let state = state_dir(dir.path(), "boxA");
    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated public endpoint");

    let mut client = daemon.connect_public();
    // The preamble and then nothing: the hello never arrives.
    client.preamble_only(&wire::preamble());
    let started = std::time::Instant::now();
    let code = client.code();
    assert_eq!(code, "bad-request");
    assert!(client.next_raw().is_none(), "the connection is dropped");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(3),
        "§3.5's 1 s handshake deadline should fire well before this"
    );
    assert!(
        daemon.stderr().contains("stalled during the handshake"),
        "{}",
        daemon.stderr()
    );
}

#[test]
fn a_pre_auth_frame_declaring_more_than_four_kib_is_refused() {
    let dir = testutil::tempdir("limits-frame");
    let state = state_dir(dir.path(), "boxA");
    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated public endpoint");

    let mut client = daemon.connect_public();
    client.preamble_only(&wire::preamble());
    // A hello header asserting 8 KiB of body, and no body: §3.5's cap exists so an
    // unauthenticated peer cannot make the listener allocate on an assertion.
    client.send_raw(&[Kind::Hello.byte(), 0x00, 0x00, 0x20, 0x00]);
    assert_eq!(client.code(), "too-large");
    assert!(client.next_raw().is_none());
}

#[test]
fn the_trusted_socket_keeps_its_own_admission_budget() {
    // §9.5's argument applied to §3.5: a flood on the public endpoint must not be
    // able to lock the human out of the trusted socket.
    let dir = testutil::tempdir("limits-per-endpoint");
    let state = state_dir(dir.path(), "boxA");
    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated trusted socket");

    let _flood: Vec<std::net::TcpStream> = (0..8).map(|_| stalled(daemon.port)).collect();
    // The public endpoint is now at its unauthenticated cap.
    let mut refused = stalled(daemon.port);
    let mut buf = Vec::new();
    use std::io::Read;
    refused.read_to_end(&mut buf).unwrap();
    let (_, body) = wire::read_frame(&mut std::io::Cursor::new(&buf[6..]), wire::MAX_BODY)
        .unwrap()
        .unwrap();
    assert_eq!(text(&wire::parse_body(&body).unwrap(), "code"), "busy");

    // The trusted socket is untouched.
    let mut trusted = daemon.connect_trusted();
    trusted.hello_default();
    trusted.expect_caps();
    let (kind, fields) = trusted.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");
}
