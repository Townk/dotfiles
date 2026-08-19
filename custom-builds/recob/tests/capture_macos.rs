//! §14.1/§14.2 against the real pasteboard machinery — on a uniquely-named
//! PRIVATE pasteboard throughout, the way `probes/pasteboard.rs` works, so the
//! human's live clipboard is never touched and the live store is never
//! written: every store here lives in a throwaway directory.
//!
//! §14.7: none of this exists off macOS; the platform-neutral halves of these
//! behaviors are covered for every build by the unit tests in `capture.rs` and
//! `store.rs`.

#![cfg(target_os = "macos")]

mod common;

use std::collections::BTreeMap;

use common::testutil;
use recobd::capture::FrontmostApp;
use recobd::host::HostIdentity;
use recobd::platform::macos::{capture_step, Pasteboard};
use recobd::platform::RegtypeTracker;
use recobd::store::Store;

fn ghostty() -> Option<FrontmostApp> {
    Some(FrontmostApp {
        name: "Ghostty".to_string(),
        bundle_id: Some("com.mitchellh.ghostty".to_string()),
    })
}

fn test_host(dir: &std::path::Path) -> HostIdentity {
    let path = dir.join("self-name");
    std::fs::write(&path, "boxA\n").unwrap();
    HostIdentity::with_paths(path, Some("fallback".to_string()))
}

fn scratch_store(dir: &std::path::Path) -> Store {
    Store::open(&dir.join("history.db"), "boxA").expect("open scratch store")
}

#[test]
fn an_observed_change_writes_a_store_row() {
    let dir = testutil::tempdir("capture-observed");
    let mut store = scratch_store(dir.path());
    let host = test_host(dir.path());
    let tracker = RegtypeTracker::default();
    let pasteboard = Pasteboard::unique();

    let last = pasteboard.change_count();
    let mut data = BTreeMap::new();
    data.insert(
        "public.utf8-plain-text".to_string(),
        b"observed copy".to_vec(),
    );
    pasteboard.write_all(&data);

    let after = capture_step(&pasteboard, &mut store, &tracker, &host, last, &ghostty);
    assert_ne!(after, last, "the write bumped changeCount");

    let (plain, kind, app, bundle, host_col): (String, String, String, String, String) = store
        .conn()
        .query_row(
            "SELECT text_plain, type_kind, source_app, source_bundle_id, source_host \
             FROM clips ORDER BY id DESC LIMIT 1;",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .expect("a captured row");
    assert_eq!(plain, "observed copy");
    assert_eq!(kind, "text");
    assert_eq!(app, "Ghostty", "source_app stamped from the frontmost app");
    assert_eq!(bundle, "com.mitchellh.ghostty");
    assert_eq!(
        host_col, "boxA",
        "a local capture carries this machine's host"
    );

    pasteboard.release();
}

#[test]
fn the_daemons_own_write_is_not_captured() {
    let dir = testutil::tempdir("capture-own-write");
    let mut store = scratch_store(dir.path());
    let host = test_host(dir.path());
    let tracker = RegtypeTracker::default();
    let pasteboard = Pasteboard::unique();

    let last = pasteboard.change_count();
    let mut data = BTreeMap::new();
    data.insert("public.utf8-plain-text".to_string(), b"own write".to_vec());
    let written_at = pasteboard.write_all(&data);
    // What Phase 4's clip operations will do: record the write, so observation
    // recognizes the echo (§6.2) and §14.6 can answer regtype from memory.
    tracker.record(written_at, Some("b".to_string()));

    let after = capture_step(&pasteboard, &mut store, &tracker, &host, last, &ghostty);
    assert_eq!(after, written_at, "the step consumed the change");
    let rows: i64 = store
        .conn()
        .query_row("SELECT COUNT(*) FROM clips;", [], |row| row.get(0))
        .unwrap();
    assert_eq!(rows, 0, "§6.2: an own write is an echo, not a capture");
    assert_eq!(
        tracker.regtype_at(written_at).as_deref(),
        Some("b"),
        "§14.6: the regtype rides the changeCount, no sidecar file"
    );

    pasteboard.release();
}

#[test]
fn a_password_manager_frontmost_refuses_capture_from_the_real_pasteboard() {
    let dir = testutil::tempdir("capture-denied");
    let mut store = scratch_store(dir.path());
    let host = test_host(dir.path());
    let tracker = RegtypeTracker::default();
    let pasteboard = Pasteboard::unique();

    let last = pasteboard.change_count();
    let mut data = BTreeMap::new();
    data.insert("public.utf8-plain-text".to_string(), b"hunter2".to_vec());
    pasteboard.write_all(&data);

    let front = || {
        Some(FrontmostApp {
            name: "1Password".to_string(),
            bundle_id: Some("com.1password.1password".to_string()),
        })
    };
    capture_step(&pasteboard, &mut store, &tracker, &host, last, &front);
    let rows: i64 = store
        .conn()
        .query_row("SELECT COUNT(*) FROM clips;", [], |row| row.get(0))
        .unwrap();
    assert_eq!(rows, 0, "§14.2: the deny-list is a security control");

    pasteboard.release();
}

#[test]
fn a_multi_uti_write_is_one_change_and_round_trips_byte_exact() {
    // §14.1's atomicity result, load-bearing twice over: dedup and
    // single-observation both assume one write is one changeCount step.
    let pasteboard = Pasteboard::unique();
    let before = pasteboard.change_count();

    let mut data = BTreeMap::new();
    data.insert(
        "public.utf8-plain-text".to_string(),
        b"hi\n\0world".to_vec(),
    );
    data.insert("com.adobe.pdf".to_string(), b"%PDF-1.4".to_vec());
    data.insert("org.chezmoi.recob.test-marker".to_string(), b"1".to_vec());
    let after = pasteboard.write_all(&data);
    assert_eq!(after - before, 1, "three UTIs in ONE changeCount step");

    let snapshot = pasteboard.snapshot(ghostty());
    assert_eq!(
        snapshot
            .data
            .get("public.utf8-plain-text")
            .map(Vec::as_slice),
        Some(b"hi\n\0world".as_slice()),
        "byte-exact round trip including an embedded NUL"
    );
    assert_eq!(
        snapshot
            .data
            .get("org.chezmoi.recob.test-marker")
            .map(Vec::as_slice),
        Some(b"1".as_slice()),
        "a private marker UTI survives the write"
    );

    pasteboard.release();
}

#[test]
fn a_sensitive_marker_on_the_pasteboard_refuses_capture() {
    let dir = testutil::tempdir("capture-sensitive");
    let mut store = scratch_store(dir.path());
    let host = test_host(dir.path());
    let tracker = RegtypeTracker::default();
    let pasteboard = Pasteboard::unique();

    let last = pasteboard.change_count();
    let mut data = BTreeMap::new();
    data.insert(
        "public.utf8-plain-text".to_string(),
        b"peer-derived paths".to_vec(),
    );
    data.insert(
        "org.chezmoi.clipboard.UntrustedFileURLs".to_string(),
        b"1".to_vec(),
    );
    pasteboard.write_all(&data);

    capture_step(&pasteboard, &mut store, &tracker, &host, last, &ghostty);
    let rows: i64 = store
        .conn()
        .query_row("SELECT COUNT(*) FROM clips;", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        rows, 0,
        "§14.2: the private untrusted-file-URL marker refuses"
    );

    pasteboard.release();
}

#[test]
fn a_dedup_re_copy_updates_the_row_through_the_real_pasteboard() {
    let dir = testutil::tempdir("capture-dedup");
    let mut store = scratch_store(dir.path());
    let host = test_host(dir.path());
    let tracker = RegtypeTracker::default();
    let pasteboard = Pasteboard::unique();

    let mut data = BTreeMap::new();
    data.insert("public.utf8-plain-text".to_string(), b"same clip".to_vec());

    let mut last = pasteboard.change_count();
    pasteboard.write_all(&data);
    last = capture_step(&pasteboard, &mut store, &tracker, &host, last, &ghostty);
    pasteboard.write_all(&data);
    capture_step(&pasteboard, &mut store, &tracker, &host, last, &ghostty);

    let rows: i64 = store
        .conn()
        .query_row("SELECT COUNT(*) FROM clips;", [], |row| row.get(0))
        .unwrap();
    assert_eq!(rows, 1, "an identical re-copy dedups into one row");

    pasteboard.release();
}

/// The spawned binary, end to end: `--capture` starts the loop, the env seam
/// points it at a private pasteboard and a scratch store, and a change made by
/// another handle to that pasteboard lands as a row.
#[test]
fn the_daemon_binary_captures_from_a_named_pasteboard() {
    let dir = testutil::tempdir("capture-daemon");
    let writer = Pasteboard::unique();
    let name = writer.name();
    let socket = dir.path().join("cb.sock");

    let daemon = common::Daemon::spawned(
        dir.path(),
        &[
            "--capture",
            "--no-public",
            "--socket",
            socket.to_str().unwrap(),
        ],
        &[
            ("XDG_DATA_HOME", dir.path().to_str().unwrap()),
            ("RECOB_CAPTURE_PASTEBOARD", name.as_str()),
            ("RECOB_CAPTURE_POLL_MS", "25"),
        ],
    );
    daemon.wait_for_log("capture: observing");

    let mut data = BTreeMap::new();
    data.insert(
        "public.utf8-plain-text".to_string(),
        b"copied while the daemon watches".to_vec(),
    );
    writer.write_all(&data);

    let db = dir.path().join("pick-clipboard/history.db");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let plain = loop {
        if let Ok(conn) = rusqlite::Connection::open(&db) {
            if let Ok(plain) = conn.query_row(
                "SELECT text_plain FROM clips ORDER BY id DESC LIMIT 1;",
                [],
                |row| row.get::<_, String>(0),
            ) {
                break plain;
            }
        }
        assert!(
            std::time::Instant::now() < deadline,
            "no row appeared; daemon log:\n{}",
            daemon.stderr()
        );
        std::thread::sleep(std::time::Duration::from_millis(25));
    };
    assert_eq!(plain, "copied while the daemon watches");

    drop(daemon);
    writer.release();
}

/// §14.2's done-when names the *general* pasteboard, so this one test observes
/// it — run explicitly with `cargo test --test capture_macos -- --ignored`. It
/// saves the live clipboard's full representation set first and restores it
/// afterwards; the store it writes is scratch. Ignored by default so a routine
/// suite run never touches the human's clipboard.
#[test]
#[ignore = "observes the live general pasteboard (saves and restores it)"]
fn live_general_pasteboard_changes_are_observed() {
    let dir = testutil::tempdir("capture-live");
    let mut store = scratch_store(dir.path());
    let host = test_host(dir.path());
    let tracker = RegtypeTracker::default();
    let general = Pasteboard::general();

    let saved = general.snapshot(None);

    let last = general.change_count();
    let mut data = BTreeMap::new();
    data.insert(
        "public.utf8-plain-text".to_string(),
        b"recob phase 3 live check".to_vec(),
    );
    general.write_all(&data);
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        capture_step(&general, &mut store, &tracker, &host, last, &ghostty);
        store
            .conn()
            .query_row(
                "SELECT text_plain FROM clips ORDER BY id DESC LIMIT 1;",
                [],
                |row| row.get::<_, String>(0),
            )
            .expect("a captured row")
    }));

    // Restore the human's clipboard before judging the outcome.
    general.write_all(&saved.data);

    let plain = outcome.expect("capture from the general pasteboard");
    assert_eq!(plain, "recob phase 3 live check");
}

// 6c/Finder wedge regression: file flavors written through write_all MUST be
// item-backed and instantly readable. The legacy declare+setData path stored
// NOTHING for public.file-url, leaving a declared-but-empty flavor every
// reader then blocked on this living daemon to furnish — Finder froze on its
// Edit menu (found live 2026-08-18). The write is real, the read-back is
// real, and the custom marker must ride the first item.
#[test]
fn file_flavor_writes_are_item_backed_and_readable() {
    let pasteboard = Pasteboard::unique();
    let mut data = BTreeMap::new();
    data.insert(
        "NSFilenamesPboardType".to_string(),
        recobd::platform::macos::filenames_plist(&[
            "/tmp/recob test a.txt".to_string(),
            "/tmp/recob-b.txt".to_string(),
        ]),
    );
    data.insert(
        "public.file-url".to_string(),
        b"file:///tmp/recob%20test%20a.txt".to_vec(),
    );
    data.insert(
        "org.chezmoi.clipboard.UntrustedFileURLs".to_string(),
        b"1".to_vec(),
    );
    pasteboard.write_all(&data);

    let snapshot = pasteboard.snapshot(None);
    // The url items are really there (per-path), and the marker rides along.
    assert!(
        snapshot
            .item_utis
            .iter()
            .any(|uti| uti == "public.file-url"),
        "no file-url item: {:?}",
        snapshot.item_utis
    );
    assert!(
        snapshot
            .item_utis
            .iter()
            .any(|uti| uti == "org.chezmoi.clipboard.UntrustedFileURLs"),
        "marker missing: {:?}",
        snapshot.item_utis
    );
    let url_blob = snapshot
        .data
        .get("public.file-url")
        .expect("file-url flavor must hold DATA, not a dangling declaration");
    assert!(
        String::from_utf8_lossy(url_blob).starts_with("file://"),
        "unexpected url payload"
    );
    pasteboard.release();
}
