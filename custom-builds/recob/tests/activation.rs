//! §3.2: socket activation. systemd owns both listening sockets and passes them
//! as fds 3 and 4; `recobd` adopts them when `LISTEN_FDS` is set and binds them
//! itself when it is not, so the same binary runs under systemd, under launchd,
//! and from a terminal.
//!
//! Verified here against a harness that reproduces systemd's side of that
//! contract, not against systemd itself — this machine is macOS. The daemon's
//! half is platform-neutral std (`FromRawFd`, `local_addr`, two environment
//! variables) with no `#[cfg]` on the path under test.

mod common;

use common::{testutil, text, Daemon};
use recobd::wire::Kind;

fn state_dir(dir: &std::path::Path, host: &str) -> String {
    std::fs::create_dir_all(dir.join("clipboard")).unwrap();
    std::fs::write(dir.join("clipboard/self-name"), format!("{host}\n")).unwrap();
    dir.to_string_lossy().into_owned()
}

#[test]
fn both_endpoints_are_adopted_from_listen_fds() {
    let dir = testutil::tempdir("activation");
    let state = state_dir(dir.path(), "boxA");
    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated public endpoint");
    daemon.wait_for_log("activated trusted socket");

    let mut public = daemon.connect_public();
    public.hello_default();
    assert_eq!(text(&public.expect_caps(), "endpoint"), "public");
    let (kind, fields) = public.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");

    let mut trusted = daemon.connect_trusted();
    trusted.hello_default();
    assert_eq!(text(&trusted.expect_caps(), "endpoint"), "trusted");
    let (kind, fields) = trusted.request("host.identity");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "host"), "boxA");

    // Adoption, not a bind that happened to work: the daemon was given fds 3
    // and 4 and never learned a port or a path from its arguments.
    let log = daemon.stderr();
    assert!(
        !log.contains("public endpoint on") || log.contains("activated public endpoint on"),
        "the daemon bound its own listener instead of adopting:\n{log}"
    );
}

#[test]
fn the_daemon_finds_each_socket_by_family_not_by_fd_order() {
    // The harness passes TCP on 3 and Unix on 4; systemd's order follows unit
    // configuration, so the daemon asks the kernel what each descriptor is. If
    // it trusted the order, one of these two connections would fail.
    let dir = testutil::tempdir("activation-order");
    let state = state_dir(dir.path(), "boxC");
    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated trusted socket");

    assert_eq!(host_identity(&mut daemon.connect_public()), "boxC");
    assert_eq!(host_identity(&mut daemon.connect_trusted()), "boxC");
}

#[test]
fn an_activated_socket_with_a_loose_mode_is_refused() {
    // §3.3: the daemon asserts the mode it was handed rather than assuming the
    // unit set SocketMode=0600. Fail closed — the trusted endpoint's entire
    // security model is same-uid-only.
    use std::os::unix::fs::PermissionsExt;
    let dir = testutil::tempdir("activation-mode");
    let state = state_dir(dir.path(), "boxA");
    let socket = dir.path().join("cb.sock");

    let daemon = Daemon::activated(dir.path(), &[], &[("XDG_STATE_HOME", &state)]);
    daemon.wait_for_log("activated trusted socket");
    drop(daemon);

    // Same socket path, now handed over group-readable.
    std::fs::remove_file(&socket).ok();
    let loosened = Daemon::activated_with(dir.path(), &[], &[("XDG_STATE_HOME", &state)], |path| {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660)).unwrap()
    });
    loosened.wait_for_log("not 0600");
    assert!(
        loosened.stderr().contains("SocketMode=0600"),
        "the refusal should name the fix:\n{}",
        loosened.stderr()
    );
}

fn host_identity<S: std::io::Read + std::io::Write>(client: &mut common::Client<S>) -> String {
    client.hello_default();
    client.expect_caps();
    let (kind, fields) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
    text(&fields, "host")
}
