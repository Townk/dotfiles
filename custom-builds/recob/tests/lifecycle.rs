//! The connection lifecycle (§5) and dispatch (§6.1's one Phase 1 row), driven
//! through the daemon's own `session::serve`.

mod common;

use common::{ctx_with_host, served, testutil, text};
use recobd::listen::Endpoint;
use recobd::wire::{self, Fields, Kind, PROTO};

#[test]
fn the_banner_arrives_before_the_client_says_anything() {
    let dir = testutil::tempdir("banner");
    let ctx = ctx_with_host(dir.path(), "boxA");
    // Client::open reads only; nothing has been written by the client yet.
    let client = served(ctx, Endpoint::Trusted);
    assert_eq!(client.wire_version, wire::WIRE_VERSION);
    assert_eq!(text(&client.banner, "proto"), PROTO.to_string());
    assert_eq!(text(&client.banner, "host"), "boxA");
    // §5.1: the pre-auth banner is thin. `impl` and `caps` wait for the
    // capabilities frame, and `nonce` arrives with authentication in Phase 2.
    assert_eq!(client.banner.get("impl"), None);
    assert_eq!(client.banner.get("caps"), None);
    assert_eq!(client.banner.len(), 2);
}

#[test]
fn capabilities_ride_in_front_of_the_first_response() {
    let dir = testutil::tempdir("caps");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    let caps = client.expect_caps();
    assert_eq!(text(&caps, "impl"), "test-impl");
    assert_eq!(text(&caps, "endpoint"), "trusted");
    assert_eq!(
        text(&caps, "caps").as_bytes(),
        recobd::registry::caps().as_slice(),
        "caps advertises exactly what this build dispatches (§5.1)"
    );
    // Phase 2's mutual proof is absent rather than stubbed.
    assert_eq!(caps.get("proof"), None);
}

#[test]
fn the_endpoint_is_a_property_of_the_listener_that_accepted() {
    let dir = testutil::tempdir("endpoint-label");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Public);
    client.hello_authenticated(common::TEST_TOKEN);
    let caps = client.expect_caps_proven(common::TEST_TOKEN);
    assert_eq!(text(&caps, "endpoint"), "public");
}

#[test]
fn host_identity_dispatches() {
    let dir = testutil::tempdir("dispatch");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    let (kind, fields) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");
    assert_eq!(fields.len(), 1);
}

#[test]
fn one_connection_carries_many_exchanges_in_order() {
    // P2: the connection is the unit of cost. Three requests pipelined behind
    // one hello, three responses in order.
    let dir = testutil::tempdir("pipeline");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    let mut pipelined = Vec::new();
    for op in ["host.identity", "nope.missing", "host.identity"] {
        pipelined.extend_from_slice(&wire::encode(
            Kind::Request,
            &Fields::new().with("op", op.as_bytes()),
        ));
    }
    client.send_raw(&pipelined);
    client.expect_caps();

    let (kind, fields) = client.next().unwrap();
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");

    let (kind, fields) = client.next().unwrap();
    assert_eq!(kind, Kind::Error, "the Nth R/E answers the Nth Q");
    assert_eq!(text(&fields, "code"), "unknown-op");

    let (kind, fields) = client.next().unwrap();
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");
}

#[test]
fn an_unknown_op_names_itself_and_leaves_the_connection_open() {
    let dir = testutil::tempdir("unknown-op");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();

    let (kind, fields) = client.request("clip.set");
    assert_eq!(kind, Kind::Error);
    assert_eq!(text(&fields, "code"), "unknown-op");
    // §10: `unknown-op` carries op, proto and impl, so two builds sharing a
    // proto are still distinguishable (§7.1).
    assert_eq!(text(&fields, "op"), "clip.set");
    assert_eq!(text(&fields, "proto"), PROTO.to_string());
    assert_eq!(text(&fields, "impl"), "test-impl");

    let (kind, _) = client.request("host.identity");
    assert_eq!(
        kind,
        Kind::Response,
        "§10: unknown-op leaves the connection open"
    );
}

#[test]
fn an_unknown_field_is_refused_rather_than_ignored() {
    // P6, and §4.3's skew diagnostic: a newer client sending a field this build
    // has never heard of is told exactly which field.
    let dir = testutil::tempdir("unknown-field");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"host.identity".to_vec())
            .with("verbose", b"1".to_vec()),
    );
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "unknown-field");
    assert_eq!(text(&fields, "field"), "verbose");

    let (kind, _) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
}

#[test]
fn a_duplicate_field_is_bad_field_and_the_connection_survives() {
    let dir = testutil::tempdir("duplicate-field");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();

    let mut body = wire::encode_body(&Fields::new().with("op", b"host.identity".to_vec()));
    body.extend_from_slice(&wire::encode_body(
        &Fields::new().with("op", b"host.identity".to_vec()),
    ));
    client.send_raw(&wire::encode_raw(Kind::Request, &body));
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "bad-field");
    assert_eq!(text(&fields, "field"), "op");

    let (kind, _) = client.request("host.identity");
    assert_eq!(
        kind,
        Kind::Response,
        "framing is length-delimited, so the reader is still in sync"
    );
}

#[test]
fn a_request_without_an_op_is_missing_field() {
    let dir = testutil::tempdir("no-op");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(&Fields::new());
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "missing-field");
    assert_eq!(text(&fields, "field"), "op");
}

#[test]
fn a_declared_length_above_the_cap_is_too_large_and_closes() {
    // §4.2: an unauthenticated peer must not be able to make the listener
    // allocate a large buffer by asserting a large length. Nothing but a header
    // is sent here.
    let dir = testutil::tempdir("too-large");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_raw(&[Kind::Request.byte(), 0x0f, 0xff, 0xff, 0xff]);
    assert_eq!(client.code(), "too-large");
    assert!(client.next_raw().is_none(), "§10: too-large closes");
}

#[test]
fn a_wire_version_mismatch_is_unrecoverable() {
    let dir = testutil::tempdir("wire-version");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.preamble_only(b"RECOB\x02");
    assert_eq!(client.code(), "wire-version-mismatch");
    assert!(client.next_raw().is_none());
}

#[test]
fn a_stranger_gets_the_banner_and_a_close_rather_than_a_recob_frame() {
    // §7.3 specifies a diagnostic in the *old* framing for a pre-RECOB client.
    // That shim is later-phase work, so this build closes and logs instead of
    // writing a frame the caller could not parse.
    let dir = testutil::tempdir("stranger");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.preamble_only(b"H\x00\x00\x00\x00\x00");
    assert!(client.next_raw().is_none());
}

#[test]
fn a_client_may_not_send_a_response_frame() {
    let dir = testutil::tempdir("wrong-kind");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_raw(&wire::encode(Kind::Response, &Fields::new()));
    assert_eq!(client.code(), "bad-request");
}

#[test]
fn the_first_frame_must_be_the_hello() {
    let dir = testutil::tempdir("hello-first");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.preamble_only(&wire::preamble());
    client.send_request(&Fields::new().with("op", b"host.identity".to_vec()));
    assert_eq!(client.code(), "bad-request");
}

#[test]
fn a_credential_offered_to_the_trusted_socket_is_refused_not_ignored() {
    // In Phase 1 this was `unknown-field`, because the build had never heard of
    // `auth`. Now it knows the field and refuses it as inapplicable: the trusted
    // socket's uid boundary *is* its credential (§9.2), and silently accepting a
    // credential field on an endpoint that checks none is the shape P6 forbids.
    let dir = testutil::tempdir("hello-auth");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello(
        &Fields::new()
            .with("proto", b"1".to_vec())
            .with("auth", b"00".repeat(32)),
    );
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "bad-request");
    assert_eq!(text(&fields, "field"), "auth");
}

#[test]
fn a_differing_proto_does_not_refuse_the_connection() {
    // §7.2: skew is normal. The operation is the unit of compatibility.
    let dir = testutil::tempdir("skew");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello(&Fields::new().with("proto", b"9".to_vec()));
    client.expect_caps();
    let (kind, fields) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");
}

#[test]
fn the_self_name_file_is_re_read_not_cached() {
    // §3.4: `ssh-prepare-connection` rewrites this file at connect time while
    // the daemon is running, so a value read once at startup would be wrong for
    // the rest of the daemon's life.
    let dir = testutil::tempdir("self-name");
    let ctx = ctx_with_host(dir.path(), "boxA");

    let mut first = served(ctx.clone(), Endpoint::Trusted);
    first.hello_default();
    first.expect_caps();
    assert_eq!(text(&first.request("host.identity").1, "host"), "boxA");

    std::fs::write(dir.path().join("self-name"), "boxB\n").unwrap();

    // The same request on the same connection, and then a fresh connection.
    assert_eq!(text(&first.request("host.identity").1, "host"), "boxB");
    let mut second = served(ctx, Endpoint::Trusted);
    assert_eq!(text(&second.banner, "host"), "boxB");
    second.hello_default();
    second.expect_caps();
    assert_eq!(text(&second.request("host.identity").1, "host"), "boxB");
}

#[test]
fn either_side_may_close_after_a_complete_exchange() {
    let dir = testutil::tempdir("close");
    let ctx = ctx_with_host(dir.path(), "boxA");
    let mut client = served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    let (kind, _) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
    drop(client);
    // Nothing to assert but the absence of a panic: the handler thread sees EOF
    // at a frame boundary and returns, which §5.5 permits without a goodbye.
}
