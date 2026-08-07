//! `files.list` / `files.grant` / `files.fetch` over served connections:
//! manifest resolution without the 0.3 s sleep, capability issuance, and the
//! §6.4 stream with its empty-`D` terminator.

mod common;

use common::{testutil, text, Client};
use recobd::listen::Endpoint;
use recobd::wire::{Fields, Kind};

fn persist_manifest(client: &mut Client<std::os::unix::net::UnixStream>, host: &str, paths: &str) {
    client.send_request(
        &Fields::new()
            .with("op", b"store.persist.files".to_vec())
            .with("host", host.as_bytes().to_vec())
            .with("paths", paths.as_bytes().to_vec()),
    );
    let (kind, _) = client.next().expect("persist answer");
    assert_eq!(kind, Kind::Response, "manifest persisted");
}

/// Reads a §6.4 stream to its terminator: `D` payloads concatenated, and the
/// explicit empty `D` that makes truncation detectable.
fn read_stream(client: &mut Client<std::os::unix::net::UnixStream>) -> Vec<u8> {
    let mut body = Vec::new();
    loop {
        let (kind, chunk) = client.next_raw().expect("stream frame");
        assert_eq!(kind, Kind::Data, "a D frame mid-stream");
        if chunk.is_empty() {
            return body;
        }
        body.extend_from_slice(&chunk);
    }
}

#[test]
fn list_answers_not_found_for_an_empty_store_and_a_text_row() {
    let dir = testutil::tempdir("files-list-empty");
    let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
    let mut client = common::served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();

    let (kind, fields) = client.request("files.list");
    assert_eq!(kind, Kind::Error);
    assert_eq!(text(&fields, "code"), "not-found");
    assert_eq!(text(&fields, "reason"), "empty-store");

    // A text clip on top: the answer is not-files, immediately — §6.5 forbids
    // the old 0.3 s sleep, so ten of these must be effectively instant.
    client.send_request(
        &Fields::new()
            .with("op", b"store.persist.text".to_vec())
            .with("host", b"boxB".to_vec())
            .with("kind", b"text".to_vec())
            .with("app", b"".to_vec())
            .with("regtype", b"v".to_vec())
            .with("text", b"plain".to_vec()),
    );
    client.next().expect("persist answer");
    let started = std::time::Instant::now();
    for _ in 0..10 {
        let (kind, fields) = client.request("files.list");
        assert_eq!(kind, Kind::Error);
        assert_eq!(text(&fields, "reason"), "not-files");
    }
    assert!(
        started.elapsed() < std::time::Duration::from_millis(1500),
        "no retry sleep survives in the resolution path"
    );
}

#[test]
fn a_trusted_manifest_grants_a_capability_that_fetches_bytes() {
    let dir = testutil::tempdir("files-fetch-file");
    let payload = vec![0xA5u8; 200 * 1024];
    let big = dir.path().join("big.bin");
    std::fs::write(&big, &payload).unwrap();
    let small = dir.path().join("small.txt");
    std::fs::write(&small, b"tiny").unwrap();
    let paths = format!("{}\0{}", big.display(), small.display());

    let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
    let mut client = common::served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    persist_manifest(&mut client, "boxA", &paths);

    let (kind, fields) = client.request("files.list");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&fields, "kind"), "files");
    assert_eq!(text(&fields, "host"), "boxA");
    assert_eq!(fields.get("paths"), Some(paths.as_bytes()));

    let (kind, fields) = client.request("files.grant");
    assert_eq!(kind, Kind::Response);
    let token = text(&fields, "token");
    assert_eq!(token.len(), 64, "a real capability, not the pointer dash");
    assert_eq!(fields.get("paths"), Some(paths.as_bytes()));

    // Spend it: item 1 streams the exact bytes, 64 KiB chunks, empty-D end.
    client.send_request(
        &Fields::new()
            .with("op", b"files.fetch".to_vec())
            .with("token", token.as_bytes().to_vec())
            .with("index", b"1".to_vec()),
    );
    let (kind, head) = client.next().expect("stream head");
    assert_eq!(kind, Kind::Response);
    assert_eq!(
        text(&head, "kind"),
        "file",
        "kind retires the is-directory retry"
    );
    assert_eq!(text(&head, "size"), payload.len().to_string());
    assert_eq!(read_stream(&mut client), payload, "byte-exact");

    // The connection remains reusable after a completed stream.
    client.send_request(
        &Fields::new()
            .with("op", b"files.fetch".to_vec())
            .with("token", token.as_bytes().to_vec())
            .with("index", b"2".to_vec()),
    );
    let (kind, head) = client.next().expect("second head");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&head, "size"), "4");
    assert_eq!(read_stream(&mut client), b"tiny");

    // An index outside the grant is bad-field (§6.6); a wrong token is
    // unauthorized with no grant detail beyond the reason.
    client.send_request(
        &Fields::new()
            .with("op", b"files.fetch".to_vec())
            .with("token", token.as_bytes().to_vec())
            .with("index", b"3".to_vec()),
    );
    assert_eq!(client.code(), "bad-field");
    client.send_request(
        &Fields::new()
            .with("op", b"files.fetch".to_vec())
            .with("token", "b".repeat(64).into_bytes())
            .with("index", b"1".to_vec()),
    );
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "unauthorized");
    assert_eq!(text(&fields, "reason"), "no-grant");
}

#[test]
fn a_directory_fetch_declares_kind_and_streams_a_complete_archive() {
    let dir = testutil::tempdir("files-fetch-dir");
    let tree = dir.path().join("bundle");
    std::fs::create_dir(&tree).unwrap();
    std::fs::write(tree.join("one.txt"), b"first").unwrap();
    std::fs::create_dir(tree.join("nested")).unwrap();
    std::fs::write(tree.join("nested/two.txt"), b"second").unwrap();

    let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
    let mut client = common::served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    persist_manifest(&mut client, "boxA", &tree.display().to_string());

    let (kind, fields) = client.request("files.grant");
    assert_eq!(kind, Kind::Response);
    let token = text(&fields, "token");

    client.send_request(
        &Fields::new()
            .with("op", b"files.fetch".to_vec())
            .with("token", token.as_bytes().to_vec())
            .with("index", b"1".to_vec()),
    );
    let (kind, head) = client.next().expect("stream head");
    assert_eq!(kind, Kind::Response);
    assert_eq!(text(&head, "kind"), "directory");
    let archive = read_stream(&mut client);
    assert!(!archive.is_empty(), "a tar stream arrived");
    // Enough of a tar assertion without shelling out: both entry names appear.
    let haystack = String::from_utf8_lossy(&archive);
    assert!(haystack.contains("bundle/one.txt"));
    assert!(haystack.contains("bundle/nested/two.txt"));

    // The exchange after a completed archive still works.
    let (kind, _) = client.request("host.identity");
    assert_eq!(kind, Kind::Response);
}

#[test]
fn an_unreadable_entry_refuses_before_the_stream_with_a_count_and_no_path() {
    let dir = testutil::tempdir("files-fetch-unreadable");
    let tree = dir.path().join("bundle");
    std::fs::create_dir(&tree).unwrap();
    std::fs::write(tree.join("fine.txt"), b"ok").unwrap();
    let hidden = tree.join("hidden.txt");
    std::fs::write(&hidden, b"secret").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&hidden, std::fs::Permissions::from_mode(0o000)).unwrap();

    let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
    let mut client = common::served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    persist_manifest(&mut client, "boxA", &tree.display().to_string());
    let (_, fields) = client.request("files.grant");
    let token = text(&fields, "token");

    client.send_request(
        &Fields::new()
            .with("op", b"files.fetch".to_vec())
            .with("token", token.as_bytes().to_vec())
            .with("index", b"1".to_vec()),
    );
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "unreadable-entries");
    assert_eq!(text(&fields, "count"), "1");
    assert!(
        !text(&fields, "message").contains("hidden"),
        "§10: the message never hands a peer a path it did not supply"
    );

    // Restore the mode so the tempdir can be removed.
    std::fs::set_permissions(&hidden, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// §11.4 "files.list does not race the capture", the positive half: a
/// physical files copy — made straight onto the pasteboard, not through the
/// daemon — followed immediately by `files.list` resolves, with no sleep, via
/// §6.5's synchronous capture.
#[cfg(target_os = "macos")]
#[test]
fn a_files_copy_resolves_immediately_after_the_pasteboard_change() {
    use recobd::platform::macos::{filenames_plist, url_encode, Pasteboard};

    let dir = testutil::tempdir("files-no-race");
    let copied = dir.path().join("just copied.txt");
    std::fs::write(&copied, b"fresh").unwrap();

    let mut ctx = common::ctx_mut(dir.path(), "boxA");
    // §6.5's synchronous capture is the same act of observation the poll loop
    // performs, so it obeys the same opt-in: this is a capturing daemon.
    ctx.capture = true;
    let ctx = std::sync::Arc::new(ctx);
    let name = ctx.pasteboard_name.clone().unwrap();
    let mut client = common::served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();

    // The Finder-copy stand-in: a files clip appears on the pasteboard with
    // no daemon involvement and no store row yet.
    let pasteboard = Pasteboard::with_name(&name);
    let mut data = std::collections::BTreeMap::new();
    let path = copied.display().to_string();
    data.insert(
        "NSFilenamesPboardType".to_string(),
        filenames_plist(std::slice::from_ref(&path)),
    );
    data.insert(
        "public.file-url".to_string(),
        format!("file://{}", url_encode(&path)).into_bytes(),
    );
    pasteboard.write_all(&data);

    let started = std::time::Instant::now();
    let (kind, fields) = client.request("files.list");
    assert_eq!(kind, Kind::Response, "resolved on the first ask");
    assert_eq!(text(&fields, "kind"), "file");
    assert_eq!(fields.get("paths"), Some(path.as_bytes()));
    assert!(
        started.elapsed() < std::time::Duration::from_millis(250),
        "§6.5: capture-on-demand, not a sleep"
    );
}

/// §11.4 "Rate limits bite per endpoint": exhausting a bucket over the public
/// endpoint answers rate-limited there while the same operation on the
/// trusted socket still dispatches — the half that stops a peer's flood from
/// throttling the human's own copies.
#[test]
fn rate_limits_bite_per_endpoint() {
    let dir = testutil::tempdir("rate-per-endpoint");
    let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));

    let notify = |host: &str| {
        Fields::new()
            .with("op", b"osd.notify".to_vec())
            .with("origin_host", host.as_bytes().to_vec())
            .with("style", b"plain".to_vec())
            .with("icon", b"".to_vec())
            .with("sound", b"".to_vec())
            .with("text", b"toast".to_vec())
    };

    let mut public = common::served(ctx.clone(), Endpoint::Public);
    public.hello_authenticated(common::TEST_TOKEN);
    public.expect_caps_proven(common::TEST_TOKEN);
    // The osd bucket holds 20 per 10 s; authorization counts the attempt
    // whether or not the handler then succeeds — the stub tools make it fail
    // (`internal` on macOS, `unavailable` on Linux), which is irrelevant to
    // the bucket.
    let handler_failure = if cfg!(target_os = "macos") {
        "internal"
    } else {
        "unavailable"
    };
    for _ in 0..20 {
        public.send_request(&notify("boxB"));
        let fields = public.expect_error();
        assert_eq!(text(&fields, "code"), handler_failure);
    }
    public.send_request(&notify("boxB"));
    let fields = public.expect_error();
    assert_eq!(text(&fields, "code"), "rate-limited");
    assert!(fields.get("retry_after").is_some());

    let mut trusted = common::served(ctx, Endpoint::Trusted);
    trusted.hello_default();
    trusted.expect_caps();
    trusted.send_request(&notify("boxB"));
    let fields = trusted.expect_error();
    assert_eq!(
        text(&fields, "code"),
        handler_failure,
        "the trusted socket's bucket is untouched by the public flood"
    );
}

#[test]
fn a_pointer_row_grants_no_capability() {
    let dir = testutil::tempdir("files-grant-pointer");
    let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));

    // A public persist from a peer: pointer row, no authority.
    let mut public = common::served(ctx.clone(), Endpoint::Public);
    public.hello_authenticated(common::TEST_TOKEN);
    public.expect_caps_proven(common::TEST_TOKEN);
    public.send_request(
        &Fields::new()
            .with("op", b"store.persist.files".to_vec())
            .with("host", b"boxB".to_vec())
            .with("paths", b"/tmp/on-boxB.txt".to_vec()),
    );
    let (kind, _) = public.next().expect("persist answer");
    assert_eq!(kind, Kind::Response);

    let mut trusted = common::served(ctx, Endpoint::Trusted);
    trusted.hello_default();
    trusted.expect_caps();
    let (kind, fields) = trusted.request("files.grant");
    assert_eq!(kind, Kind::Response);
    assert_eq!(
        text(&fields, "token"),
        "-",
        "a pointer row cannot mint file authority; streaming fails closed"
    );
    assert_eq!(fields.get("paths"), Some(&b"/tmp/on-boxB.txt"[..]));
}
