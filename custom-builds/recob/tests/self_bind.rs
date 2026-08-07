//! The launch shape when nothing hands the daemon a socket (§3.1, §3.3, §3.4):
//! `recobd` binds both endpoints itself, establishes the trusted socket's
//! permissions, and serves each connection on its own task.

mod common;

use common::{testutil, text, Daemon};
use recobd::listen::mode_of;
use recobd::wire::Kind;

fn state(dir: &std::path::Path, host: &str) -> String {
    std::fs::create_dir_all(dir.join("clipboard")).unwrap();
    std::fs::write(dir.join("clipboard/self-name"), format!("{host}\n")).unwrap();
    dir.to_string_lossy().into_owned()
}

fn trusted_daemon(dir: &std::path::Path, host: &str) -> Daemon {
    let socket = dir.join("cb.sock");
    let state = state(dir, host);
    let daemon = Daemon::spawned(
        dir,
        &["--no-public", "--socket", &socket.to_string_lossy()],
        &[("XDG_STATE_HOME", &state)],
    );
    daemon.wait_for_log("trusted endpoint on");
    daemon
}

#[test]
fn the_daemon_establishes_the_trusted_socket_permissions_itself() {
    let dir = testutil::tempdir("self-bind-mode");
    let daemon = trusted_daemon(dir.path(), "boxA");

    // §3.3, all three: 0600 socket, 0700 parent, and both halves visible in the
    // log — 0700 at bind is the umask, 0600 after is the chmod.
    assert_eq!(mode_of(&daemon.socket).unwrap() & 0o777, 0o600);
    assert_eq!(mode_of(dir.path()).unwrap() & 0o777, 0o700);
    assert!(
        daemon
            .stderr()
            .contains("mode 0700 at bind, 0600 after chmod, parent 0700"),
        "{}",
        daemon.stderr()
    );
    // A parent that is already 0700 is left alone. The socket's directory is a
    // state directory shared with everything else on the machine, so the daemon
    // reporting that it tightened one is a real event, not routine noise.
    assert!(
        !daemon.stderr().contains("tightened"),
        "the daemon changed a directory that was already correct:\n{}",
        daemon.stderr()
    );

    let mut client = daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();
    assert_eq!(text(&client.request("host.identity").1, "host"), "boxA");
}

#[test]
fn a_second_daemon_will_not_take_a_live_socket() {
    let dir = testutil::tempdir("self-bind-live");
    let _first = trusted_daemon(dir.path(), "boxA");

    let socket = dir.path().join("cb.sock");
    let state = dir.path().to_string_lossy().into_owned();
    let mut second = Daemon::spawned(
        dir.path(),
        &["--no-public", "--socket", &socket.to_string_lossy()],
        &[("XDG_STATE_HOME", &state)],
    );
    assert!(!second.exited().success());
    assert!(
        second.stderr().contains("already serving"),
        "{}",
        second.stderr()
    );
}

#[test]
fn a_stale_socket_from_a_dead_daemon_is_reclaimed() {
    let dir = testutil::tempdir("self-bind-stale");
    drop(trusted_daemon(dir.path(), "boxA"));
    // The socket file outlives the process that bound it.
    assert!(std::fs::symlink_metadata(dir.path().join("cb.sock")).is_ok());

    let daemon = trusted_daemon(dir.path(), "boxB");
    let mut client = daemon.connect_trusted();
    client.hello_default();
    client.expect_caps();
    assert_eq!(text(&client.request("host.identity").1, "host"), "boxB");
}

#[test]
fn connections_are_served_concurrently_and_independently() {
    // §3.4: a task per connection. Two connections interleave, and a protocol
    // error that closes one leaves the other and the accept loop untouched.
    let dir = testutil::tempdir("self-bind-concurrent");
    let daemon = trusted_daemon(dir.path(), "boxA");

    let mut first = daemon.connect_trusted();
    let mut second = daemon.connect_trusted();
    first.hello_default();
    second.hello_default();
    first.expect_caps();
    second.expect_caps();

    assert_eq!(text(&first.request("host.identity").1, "host"), "boxA");
    assert_eq!(text(&second.request("host.identity").1, "host"), "boxA");

    // Kill the first connection with a frame the stream cannot recover from.
    first.send_raw(&[b'Z', 0, 0, 0, 0]);
    assert_eq!(text(&first.expect_error(), "code"), "bad-request");
    assert!(first.next_raw().is_none());

    // The second connection is unaffected, and a third still gets accepted.
    assert_eq!(text(&second.request("host.identity").1, "host"), "boxA");
    let mut third = daemon.connect_trusted();
    third.hello_default();
    third.expect_caps();
    let (kind, _) = third.request("host.identity");
    assert_eq!(kind, Kind::Response);
}

#[test]
fn the_public_endpoint_binds_loopback_only() {
    let dir = testutil::tempdir("self-bind-public");
    let state = state(dir.path(), "boxA");
    let daemon = Daemon::spawned(
        dir.path(),
        &["--no-trusted", "--port", "0"],
        &[("XDG_STATE_HOME", &state)],
    );
    daemon.wait_for_log("public endpoint on 127.0.0.1:");
    let log = daemon.stderr();
    let bound = log
        .lines()
        .find_map(|line| line.split("public endpoint on ").nth(1))
        .unwrap()
        .trim()
        .to_string();
    assert!(bound.starts_with("127.0.0.1:"), "{bound}");

    let port: u16 = bound.rsplit(':').next().unwrap().parse().unwrap();
    let stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
        .unwrap();
    let token = common::wait_for_token(dir.path());
    let mut client = common::Client::open(stream);
    client.hello_authenticated(&token);
    assert_eq!(
        text(&client.expect_caps_proven(&token), "endpoint"),
        "public"
    );
}
