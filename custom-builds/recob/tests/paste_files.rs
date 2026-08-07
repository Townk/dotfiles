//! `paste --files` end to end against a real daemon: the local engine, the
//! streamed remote engine (file and directory), and the refusals that must
//! happen before any transfer.
//!
//! The engine lives in `recob-wire` and is driven here through its library
//! API rather than through the spawned binary, so the assertions are about
//! what landed on disk rather than about parsed output — the binary's own
//! argument plumbing is covered by `wire/tests/clip_bin.rs`.

mod common;

use common::testutil;
use recob_wire::client::{Credential, Session, Timeouts};
use recob_wire::paste_files::{self, Context, Options, Output};
use recob_wire::wire::Fields;

/// A daemon with its store inside the test's own directory.
fn daemon(dir: &std::path::Path) -> (common::Daemon, std::path::PathBuf) {
    let state = dir.join("state");
    let data = dir.join("data");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&data).unwrap();
    let socket = dir.join("cb.sock");
    let daemon = common::Daemon::activated(
        dir,
        &["--socket", socket.to_str().unwrap()],
        &[
            ("XDG_STATE_HOME", state.to_str().unwrap()),
            ("XDG_DATA_HOME", data.to_str().unwrap()),
        ],
    );
    (daemon, data.join("pick-clipboard/history.db"))
}

fn trusted(daemon: &common::Daemon) -> Session<std::os::unix::net::UnixStream> {
    let stream = std::os::unix::net::UnixStream::connect(&daemon.socket).unwrap();
    Session::establish(stream, Credential::TrustedSocket, Timeouts::default()).unwrap()
}

/// The identity the daemon stamps on a local capture — read back from its own
/// answer so the test never guesses this machine's name.
fn host_of(session: &mut Session<std::os::unix::net::UnixStream>) -> String {
    let reply = session
        .exchange(&Fields::new().with("op", b"host.identity".to_vec()), false)
        .unwrap();
    String::from_utf8_lossy(reply.get("host").unwrap()).into_owned()
}

fn persist_files(session: &mut Session<std::os::unix::net::UnixStream>, host: &str, paths: &str) {
    session
        .exchange(
            &Fields::new()
                .with("op", b"store.persist.files".to_vec())
                .with("host", host.as_bytes().to_vec())
                .with("paths", paths.as_bytes().to_vec()),
            false,
        )
        .expect("manifest persisted");
}

fn options(dir: &std::path::Path) -> Options {
    Options {
        force: false,
        output: Output::Quiet,
        dir: dir.to_path_buf(),
    }
}

fn context(self_host: &str, over_ssh: bool) -> Context {
    Context {
        self_host: Some(self_host.to_string()),
        over_ssh,
        mount_helper: "/nonexistent/clipboard-mount".into(),
        cap: u64::MAX,
    }
}

#[test]
fn a_same_host_clip_materializes_through_the_local_engine() {
    let dir = testutil::tempdir("files-local");
    let (daemon, _db) = daemon(dir.path());
    let mut session = trusted(&daemon);
    let host = host_of(&mut session);

    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("one.txt"), b"first").unwrap();
    let tree = source.join("bundle");
    std::fs::create_dir(&tree).unwrap();
    std::fs::write(tree.join("nested.txt"), b"deep").unwrap();
    persist_files(
        &mut session,
        &host,
        &format!("{}\0{}", source.join("one.txt").display(), tree.display()),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    paste_files::run(&mut session, &options(&dest), &context(&host, false)).unwrap();

    assert_eq!(std::fs::read(dest.join("one.txt")).unwrap(), b"first");
    assert_eq!(
        std::fs::read(dest.join("bundle/nested.txt")).unwrap(),
        b"deep",
        "a directory item copies whole"
    );
    assert!(
        std::fs::read_dir(&dest)
            .unwrap()
            .flatten()
            .all(|entry| !entry.file_name().to_string_lossy().starts_with(".pbpaste-")),
        "no staging or recovery residue survives a clean run"
    );
}

#[test]
fn a_remote_clip_streams_files_and_directories_over_the_wire() {
    let dir = testutil::tempdir("files-remote");
    let (daemon, _db) = daemon(dir.path());
    let mut session = trusted(&daemon);
    let host = host_of(&mut session);

    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    let payload = vec![7u8; 150 * 1024];
    std::fs::write(source.join("big.bin"), &payload).unwrap();
    let tree = source.join("bundle");
    std::fs::create_dir(&tree).unwrap();
    std::fs::write(tree.join("inside.txt"), b"archived").unwrap();
    persist_files(
        &mut session,
        &host,
        &format!("{}\0{}", source.join("big.bin").display(), tree.display()),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    // The manifest's host is this daemon's; telling the engine it is someone
    // else makes the clip remote, which is the streaming path.
    paste_files::run(
        &mut session,
        &options(&dest),
        &context("some-other-box", true),
    )
    .unwrap();

    assert_eq!(
        std::fs::read(dest.join("big.bin")).unwrap(),
        payload,
        "a streamed file arrives byte-exact"
    );
    assert_eq!(
        std::fs::read(dest.join("bundle/inside.txt")).unwrap(),
        b"archived",
        "a streamed directory extracts from its archive"
    );
}

#[test]
fn existing_names_are_refused_before_anything_is_transferred() {
    let dir = testutil::tempdir("files-conflict");
    let (daemon, _db) = daemon(dir.path());
    let mut session = trusted(&daemon);
    let host = host_of(&mut session);

    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("one.txt"), b"new").unwrap();
    persist_files(
        &mut session,
        &host,
        &source.join("one.txt").display().to_string(),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    std::fs::write(dest.join("one.txt"), b"old").unwrap();

    let err = paste_files::run(&mut session, &options(&dest), &context(&host, false)).unwrap_err();
    assert!(
        err.contains("refusing to overwrite existing items (use --force)"),
        "{err}"
    );
    assert_eq!(
        std::fs::read(dest.join("one.txt")).unwrap(),
        b"old",
        "the existing item is untouched by a refused run"
    );

    // --force replaces it, and leaves no recovery residue behind.
    let forced = Options {
        force: true,
        ..options(&dest)
    };
    paste_files::run(&mut session, &forced, &context(&host, false)).unwrap();
    assert_eq!(std::fs::read(dest.join("one.txt")).unwrap(), b"new");
    assert!(
        std::fs::read_dir(&dest)
            .unwrap()
            .flatten()
            .all(|entry| !entry.file_name().to_string_lossy().starts_with(".pbpaste-")),
        "the displaced original is dropped once its replacement lands"
    );
}

/// A `store.persist.files` over the public endpoint: `mints_authority` is
/// `local`, so the row it produces is a pointer one — no authority snapshot,
/// and `files.grant` answers `-`.
fn persist_pointer(daemon: &common::Daemon, state: &std::path::Path, host: &str, paths: &str) {
    let stream = std::net::TcpStream::connect(("127.0.0.1", daemon.port)).unwrap();
    let token = recob_wire::auth::Token::from_hex(&common::wait_for_token(state)).unwrap();
    let mut public =
        Session::establish(stream, Credential::single(token), Timeouts::default()).unwrap();
    public
        .exchange(
            &Fields::new()
                .with("op", b"store.persist.files".to_vec())
                .with("host", host.as_bytes().to_vec())
                .with("paths", paths.as_bytes().to_vec()),
            false,
        )
        .unwrap();
}

#[test]
fn a_pointer_row_cannot_be_streamed() {
    let dir = testutil::tempdir("files-pointer");
    let (daemon, _db) = daemon(dir.path());

    // A public persist from a peer produces a pointer row: no authority, so
    // `files.grant` answers `-` and there is nothing to stream.
    persist_pointer(
        &daemon,
        &dir.path().join("state"),
        "far-away-box",
        "/tmp/not-here.txt",
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    let mut session = trusted(&daemon);
    let err =
        paste_files::run(&mut session, &options(&dest), &context("this-box", true)).unwrap_err();
    assert!(
        err.contains("origin did not authorize this manifest"),
        "a pointer row fails closed: {err}"
    );
}

#[test]
fn a_local_self_host_pointer_row_fails_closed() {
    let dir = testutil::tempdir("files-local-pointer");
    let (daemon, _db) = daemon(dir.path());

    // A pointer row whose host is THIS machine — the shape a peer-mount-
    // enriched pasteboard produces. Its paths are readable by this uid, but
    // the row carries no authority, and the shim's PF_REQUIRE_CAP refused it
    // on the local route too, not only on the streaming one.
    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("untrusted.txt"), b"unauthorized bytes").unwrap();
    persist_pointer(
        &daemon,
        &dir.path().join("state"),
        "this-box",
        &source.join("untrusted.txt").display().to_string(),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    let mut session = trusted(&daemon);
    let err =
        paste_files::run(&mut session, &options(&dest), &context("this-box", false)).unwrap_err();
    assert!(
        err.contains("origin did not authorize this manifest"),
        "a local pointer row fails closed: {err}"
    );
    assert!(
        !dest.join("untrusted.txt").exists(),
        "nothing materializes from a refused pointer row"
    );
}

#[test]
fn the_size_cap_does_not_apply_to_a_same_host_local_copy() {
    let dir = testutil::tempdir("files-local-cap");
    let (daemon, _db) = daemon(dir.path());
    let mut session = trusted(&daemon);
    let host = host_of(&mut session);

    // §11's cap is scoped to transfers that cross a machine boundary: the
    // shim gated every local-engine cap_check on PF_MOUNT_REMOTE, so a local
    // `cp` of the user's own file was never capped — refusing a 4 GB local
    // paste at the 200 MB default is not what the cap is for.
    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("own-big.bin"), vec![0u8; 4096]).unwrap();
    persist_files(
        &mut session,
        &host,
        &source.join("own-big.bin").display().to_string(),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    let tiny_cap = Context {
        cap: 10,
        ..context(&host, false)
    };
    paste_files::run(&mut session, &options(&dest), &tiny_cap).unwrap();
    assert_eq!(
        std::fs::read(dest.join("own-big.bin")).unwrap().len(),
        4096,
        "a same-host local copy is never size-capped"
    );
}

#[test]
fn a_deferred_cap_refusal_places_nothing() {
    let dir = testutil::tempdir("files-mount-cap");
    let (daemon, _db) = daemon(dir.path());

    // A mount-mapped manifest's sizes are only knowable after staging, so the
    // cap check runs against the staged copies — and a refusal on ANY item
    // must leave the target untouched, or a refusal is not safe to retry with
    // a higher cap. The shim measured and checked every staged item before
    // placing the first one.
    let mount = dir.path().join("mount");
    std::fs::create_dir_all(mount.join("remote")).unwrap();
    std::fs::write(mount.join("remote/small.txt"), b"tiny").unwrap();
    std::fs::write(mount.join("remote/big.txt"), vec![b'x'; 64]).unwrap();

    let helper = dir.path().join("clipboard-mount");
    std::fs::write(
        &helper,
        format!(
            "#!/bin/sh\ncase \"$1\" in\n\
             check) printf '%s\\n' '{mount}' ;;\n\
             map) printf '%s%s\\n' '{mount}' \"$3\" ;;\n\
             esac\n",
            mount = mount.display()
        ),
    )
    .unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    persist_pointer(
        &daemon,
        &dir.path().join("state"),
        "peer-box",
        "/remote/small.txt\0/remote/big.txt",
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    let mut session = trusted(&daemon);
    let context = Context {
        self_host: Some("this-box".to_string()),
        over_ssh: false,
        mount_helper: helper,
        cap: 10,
    };
    let err = paste_files::run(&mut session, &options(&dest), &context).unwrap_err();
    assert!(err.contains("exceeds size cap"), "{err}");
    assert!(
        !dest.join("small.txt").exists() && !dest.join("big.txt").exists(),
        "a deferred-cap refusal leaves the target untouched"
    );
}

#[test]
fn a_pointer_row_on_its_source_host_still_pastes_over_ssh() {
    let dir = testutil::tempdir("files-ssh-pointer");
    let (daemon, _db) = daemon(dir.path());

    // The paste-back flow: over SSH the manifest comes from the ORIGIN's
    // daemon through the forwarded port, and the origin cannot mint authority
    // over this machine's own paths — every same-host row it answers with is
    // a pointer one. The files are this uid's own; refusing here would break
    // copy-on-this-box, paste-on-this-box whenever the shell arrived by SSH.
    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("own.txt"), b"my own bytes").unwrap();
    persist_pointer(
        &daemon,
        &dir.path().join("state"),
        "this-box",
        &source.join("own.txt").display().to_string(),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    let mut session = trusted(&daemon);
    paste_files::run(&mut session, &options(&dest), &context("this-box", true)).unwrap();
    assert_eq!(
        std::fs::read(dest.join("own.txt")).unwrap(),
        b"my own bytes",
        "a source-host pointer row still materializes over SSH"
    );
}

#[test]
fn a_remote_manifest_without_a_mount_says_so() {
    let dir = testutil::tempdir("files-no-mount");
    let (daemon, _db) = daemon(dir.path());
    let mut session = trusted(&daemon);
    let host = host_of(&mut session);

    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("one.txt"), b"x").unwrap();
    persist_files(
        &mut session,
        &host,
        &source.join("one.txt").display().to_string(),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    // Not over SSH and the clip belongs to another machine: the peer's
    // endpoint is not reachable from here, so the mount is the missing piece.
    let err = paste_files::run(
        &mut session,
        &options(&dest),
        &context("some-other-box", false),
    )
    .unwrap_err();
    assert!(
        err.contains("mount is unavailable") && err.contains("pick-clipboard Ctrl-Y"),
        "the diagnostic names the remedy: {err}"
    );
}

#[test]
fn the_size_cap_refuses_before_pulling_bytes() {
    let dir = testutil::tempdir("files-cap");
    let (daemon, _db) = daemon(dir.path());
    let mut session = trusted(&daemon);
    let host = host_of(&mut session);

    let source = dir.path().join("src");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("big.bin"), vec![0u8; 4096]).unwrap();
    persist_files(
        &mut session,
        &host,
        &source.join("big.bin").display().to_string(),
    );

    let dest = dir.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    let tiny_cap = Context {
        cap: 10,
        ..context("some-other-box", true)
    };
    let err = paste_files::run(&mut session, &options(&dest), &tiny_cap).unwrap_err();

    assert!(
        err.starts_with("pbpaste: ") && err.contains("-- refusing"),
        "the cap refusal keeps its parse contract: {err}"
    );
    assert!(
        !dest.join("big.bin").exists(),
        "nothing landed for a refused item"
    );
}
