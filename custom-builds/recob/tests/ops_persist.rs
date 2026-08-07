//! `store.persist.text` / `store.persist.files` over served connections —
//! the P and M materialization behaviors, against per-test stores.

mod common;

use common::{testutil, text};
use recobd::listen::Endpoint;
use recobd::wire::{Fields, Kind};
use rusqlite::Connection;

fn persist_text_request(host: &str, textbytes: &[u8]) -> Fields {
    Fields::new()
        .with("op", b"store.persist.text".to_vec())
        .with("host", host.as_bytes().to_vec())
        .with("kind", b"text".to_vec())
        .with("app", b"nvim".to_vec())
        .with("regtype", b"b".to_vec())
        .with("text", textbytes.to_vec())
}

#[test]
fn persist_text_materializes_a_row_and_a_repeat_bumps_it() {
    let dir = testutil::tempdir("persist-text");
    let ctx = common::ctx_mut(dir.path(), "boxA");
    let db = ctx.db_path.clone();
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();

    client.send_request(&persist_text_request("boxB", b"  hello\n\n peer  \n"));
    let (kind, _) = client.next().expect("an answer");
    assert_eq!(kind, Kind::Response);
    client.send_request(&persist_text_request("boxB", b"  hello\n\n peer  \n"));
    client.next().expect("an answer");

    let conn = Connection::open(&db).unwrap();
    let (count, preview, plain, host, app, regtype): (i64, String, String, String, String, String) =
        conn.query_row(
            "SELECT COUNT(*), text_preview, text_plain, source_host, source_app, regtype \
             FROM clips;",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(count, 1, "the repeat deduped into one row");
    assert_eq!(preview, "hello peer", "the zsh preview flattening");
    assert_eq!(plain, "  hello\n\n peer  \n", "text stays byte-exact");
    assert_eq!(host, "boxB", "the declared origin, not this machine");
    assert_eq!(app, "nvim");
    assert_eq!(regtype, "b");
}

#[test]
fn persist_text_refuses_file_kinds_and_bad_shapes() {
    let dir = testutil::tempdir("persist-text-refuse");
    let ctx = common::ctx_mut(dir.path(), "boxA");
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();

    let request = |host: &str, kind: &str, regtype: &str| {
        Fields::new()
            .with("op", b"store.persist.text".to_vec())
            .with("host", host.as_bytes().to_vec())
            .with("kind", kind.as_bytes().to_vec())
            .with("app", b"nvim".to_vec())
            .with("regtype", regtype.as_bytes().to_vec())
            .with("text", b"x".to_vec())
    };
    client.send_request(&request("boxB", "files", "b"));
    assert_eq!(
        client.code(),
        "refused",
        "file kinds go through store.persist.files"
    );

    client.send_request(&request("boxB", "text", "q"));
    assert_eq!(client.code(), "bad-field", "P5: regtype is a closed enum");

    client.send_request(&request("-bad", "text", "b"));
    assert_eq!(client.code(), "bad-field");
}

#[test]
fn a_trusted_files_persist_mints_authority_for_this_machine_only() {
    let dir = testutil::tempdir("persist-files-trusted");
    let file_a = dir.path().join("a.txt");
    let file_b = dir.path().join("b.txt");
    std::fs::write(&file_a, b"a").unwrap();
    std::fs::write(&file_b, b"b").unwrap();
    let paths = format!("{}\0{}", file_a.display(), file_b.display());

    let ctx = common::ctx_mut(dir.path(), "boxA");
    let db = ctx.db_path.clone();
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();

    // The trusted leg must claim this machine — anything else is refused.
    client.send_request(
        &Fields::new()
            .with("op", b"store.persist.files".to_vec())
            .with("host", b"boxB".to_vec())
            .with("paths", paths.as_bytes().to_vec()),
    );
    assert_eq!(client.code(), "refused");

    client.send_request(
        &Fields::new()
            .with("op", b"store.persist.files".to_vec())
            .with("host", b"boxA".to_vec())
            .with("paths", paths.as_bytes().to_vec()),
    );
    let (kind, _) = client.next().expect("an answer");
    assert_eq!(kind, Kind::Response);

    let conn = Connection::open(&db).unwrap();
    let (kind_col, preview): (String, String) = conn
        .query_row(
            "SELECT type_kind, text_preview FROM clips ORDER BY id DESC LIMIT 1;",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(kind_col, "files");
    assert_eq!(
        preview,
        format!("{}\n{}", file_a.display(), file_b.display()),
        "the manifest preview is the newline-joined paths, unflattened"
    );
    let manifest: Vec<u8> = conn
        .query_row(
            "SELECT blob FROM clip_types WHERE uti='x-file-manifest';",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(manifest, paths.as_bytes());
    let authorities: i64 = conn
        .query_row("SELECT COUNT(*) FROM file_authorities;", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(authorities, 2, "the trusted leg minted the path snapshot");
}

#[test]
fn a_public_files_persist_is_a_pointer_row_and_cannot_claim_this_machine() {
    let dir = testutil::tempdir("persist-files-public");
    let ctx = common::ctx_mut(dir.path(), "boxA");
    let db = ctx.db_path.clone();
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Public);
    client.hello_authenticated(common::TEST_TOKEN);
    client.expect_caps_proven(common::TEST_TOKEN);

    client.send_request(
        &Fields::new()
            .with("op", b"store.persist.files".to_vec())
            .with("host", b"boxA".to_vec())
            .with("paths", b"/tmp/x".to_vec()),
    );
    assert_eq!(
        client.code(),
        "refused",
        "§9.7: a public persist cannot claim this machine"
    );

    client.send_request(
        &Fields::new()
            .with("op", b"store.persist.files".to_vec())
            .with("host", b"boxB".to_vec())
            .with("paths", b"/tmp/x\0/tmp/y".to_vec()),
    );
    let (kind, _) = client.next().expect("an answer");
    assert_eq!(kind, Kind::Response);

    let conn = Connection::open(&db).unwrap();
    let authorities: i64 = conn
        .query_row("SELECT COUNT(*) FROM file_authorities;", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        authorities, 0,
        "§9.3 mints_authority: a public row is a pointer, never authority"
    );
    let host: String = conn
        .query_row("SELECT source_host FROM clips;", [], |row| row.get(0))
        .unwrap();
    assert_eq!(host, "boxB");
}

#[test]
fn a_symlink_in_a_trusted_manifest_refuses_the_authority() {
    let dir = testutil::tempdir("persist-files-symlink");
    let real = dir.path().join("real.txt");
    std::fs::write(&real, b"x").unwrap();
    let link = dir.path().join("link.txt");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let ctx = common::ctx_mut(dir.path(), "boxA");
    let db = ctx.db_path.clone();
    let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client.send_request(
        &Fields::new()
            .with("op", b"store.persist.files".to_vec())
            .with("host", b"boxA".to_vec())
            .with(
                "paths",
                format!("{}\0{}", real.display(), link.display()).into_bytes(),
            ),
    );
    let fields = client.expect_error();
    assert_eq!(text(&fields, "code"), "refused");

    let conn = Connection::open(&db).unwrap();
    let authorities: i64 = conn
        .query_row("SELECT COUNT(*) FROM file_authorities;", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(authorities, 0, "no partial authority set survives");
}

/// The mount-aware half of `store.persist.files` (`clip::mount_enrich`,
/// carried across at cutover): when this Mac holds a healthy rclone mount of
/// the manifest's host, the pasteboard additionally gets mount-mapped file
/// URLs so Cmd+V in Finder is a native copy.
///
/// A remote-host persist — the only shape that enriches — can only arrive on
/// the authenticated PUBLIC endpoint: the trusted socket refuses any host
/// that is not this machine (§9.7, pinned above), and the enrichment bails on
/// a self-host manifest. So these tests drive the public leg for the remote
/// facets and the trusted leg for the self-host one.
///
/// The enrichment is detached (a named thread), so every positive facet polls
/// the test's private pasteboard under a deadline, and every negative facet
/// holds its assertion across a bounded settle window after the last
/// observable step.
#[cfg(target_os = "macos")]
mod mount_enrichment {
    use super::*;
    use recobd::platform::macos::{url_encode, Pasteboard};

    const POLL: std::time::Duration = std::time::Duration::from_millis(20);

    fn write_stub(dir: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    /// Poll for a detached-thread effect, ~2s cap in 20ms steps.
    fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            if done() {
                return;
            }
            std::thread::sleep(POLL);
        }
        panic!("timed out waiting for {what}");
    }

    /// A bounded negative window: the condition must HOLD at every step for
    /// the whole window — the only way to assert a non-event coming from a
    /// detached thread.
    fn hold_for(what: &str, mut holds: impl FnMut() -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(400);
        loop {
            assert!(holds(), "{what}");
            if std::time::Instant::now() >= deadline {
                return;
            }
            std::thread::sleep(POLL);
        }
    }

    /// The daemon's remote leg: an authenticated public connection.
    fn served_public(ctx: recobd::session::Ctx) -> common::Client<std::os::unix::net::UnixStream> {
        let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Public);
        client.hello_authenticated(common::TEST_TOKEN);
        client.expect_caps_proven(common::TEST_TOKEN);
        client
    }

    fn persist_ok(
        client: &mut common::Client<std::os::unix::net::UnixStream>,
        host: &str,
        paths: &[u8],
    ) {
        client.send_request(
            &Fields::new()
                .with("op", b"store.persist.files".to_vec())
                .with("host", host.as_bytes().to_vec())
                .with("paths", paths.to_vec()),
        );
        let (kind, _) = client.next().expect("persist answer");
        assert_eq!(kind, Kind::Response);
    }

    #[test]
    fn a_healthy_mount_enriches_the_pasteboard_with_mapped_file_urls() {
        let dir = testutil::tempdir("enrich-healthy");
        let mount = dir.path().join("mnt");
        let remote = "/remote/report.txt";
        let mapped = format!("{}{remote}", mount.display());
        std::fs::create_dir_all(std::path::Path::new(&mapped).parent().unwrap()).unwrap();
        std::fs::write(&mapped, b"payload").unwrap();

        let mut ctx = common::ctx_mut(dir.path(), "boxA");
        ctx.tools.clipboard_mount = write_stub(
            dir.path(),
            "mount",
            &format!(
                "case \"$1\" in check) printf '%s\\n' \"{}\";; esac",
                mount.display()
            ),
        );
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = served_public(ctx);
        persist_ok(&mut client, "boxB", remote.as_bytes());

        let pasteboard = Pasteboard::with_name(&name);
        wait_until("the enrichment write", || {
            pasteboard.snapshot(None).filenames.is_some()
        });
        let snapshot = pasteboard.snapshot(None);
        assert_eq!(
            snapshot.filenames.as_deref(),
            Some(&[mapped.clone()][..]),
            "NSFilenamesPboardType holds the MAPPED (mountpoint-prefixed) path"
        );
        assert_eq!(
            snapshot.data.get("public.file-url"),
            Some(&format!("file://{}", url_encode(&mapped)).into_bytes()),
            "the first mapped path as a file URL"
        );
        assert_eq!(
            snapshot.data.get("org.chezmoi.clipboard.UntrustedFileURLs"),
            Some(&b"1".to_vec()),
            "the provenance marker travels in the same pasteboard change"
        );
    }

    #[test]
    fn a_multi_path_manifest_maps_every_path() {
        let dir = testutil::tempdir("enrich-multi");
        let mount = dir.path().join("mnt");
        let mapped_a = format!("{}/remote/a.txt", mount.display());
        let mapped_b = format!("{}/remote/b.txt", mount.display());
        // Only the first mapped path has to exist for the write to happen.
        std::fs::create_dir_all(std::path::Path::new(&mapped_a).parent().unwrap()).unwrap();
        std::fs::write(&mapped_a, b"a").unwrap();

        let mut ctx = common::ctx_mut(dir.path(), "boxA");
        ctx.tools.clipboard_mount = write_stub(
            dir.path(),
            "mount",
            &format!(
                "case \"$1\" in check) printf '%s\\n' \"{}\";; esac",
                mount.display()
            ),
        );
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = served_public(ctx);
        persist_ok(&mut client, "boxB", b"/remote/a.txt\0/remote/b.txt");

        let pasteboard = Pasteboard::with_name(&name);
        wait_until("the enrichment write", || {
            pasteboard.snapshot(None).filenames.is_some()
        });
        let snapshot = pasteboard.snapshot(None);
        let plist = snapshot
            .data
            .get("NSFilenamesPboardType")
            .expect("the filenames plist");
        for mapped in [&mapped_a, &mapped_b] {
            assert!(
                String::from_utf8_lossy(plist).contains(mapped.as_str()),
                "{mapped} appears in the NSFilenamesPboardType plist bytes"
            );
        }
        assert_eq!(
            snapshot.filenames.as_deref(),
            Some(&[mapped_a, mapped_b][..]),
            "ALL manifest paths are mapped, in order"
        );
    }

    #[test]
    fn a_missing_mapped_path_means_no_pasteboard_write() {
        let dir = testutil::tempdir("enrich-missing");
        let mount = dir.path().join("mnt");
        std::fs::create_dir_all(&mount).unwrap();
        let log = dir.path().join("log");

        let mut ctx = common::ctx_mut(dir.path(), "boxA");
        ctx.tools.clipboard_mount = write_stub(
            dir.path(),
            "mount",
            &format!(
                "case \"$1\" in check) echo check >> \"{}\"; printf '%s\\n' \"{}\";; esac",
                log.display(),
                mount.display()
            ),
        );
        let name = ctx.pasteboard_name.clone().unwrap();
        let pasteboard = Pasteboard::with_name(&name);
        let cc = pasteboard.change_count();
        let mut client = served_public(ctx);
        // The manifest names a file that does not exist under the mountpoint.
        persist_ok(&mut client, "boxB", b"/remote/missing.txt");

        wait_until("the mount check", || {
            std::fs::read_to_string(&log).is_ok_and(|logged| logged.contains("check"))
        });
        hold_for("no pasteboard write for a missing mapped path", || {
            pasteboard.change_count() == cc
        });
        assert_eq!(
            std::fs::read_to_string(&log).unwrap(),
            "check\n",
            "a healthy check needs no self-heal"
        );
    }

    #[test]
    fn a_self_host_manifest_never_invokes_the_mount_helper() {
        let dir = testutil::tempdir("enrich-self");
        let file = dir.path().join("a.txt");
        std::fs::write(&file, b"a").unwrap();
        let log = dir.path().join("log");

        let mut ctx = common::ctx_mut(dir.path(), "boxA");
        // A helper that would prove it ran; the point is that it must not.
        ctx.tools.clipboard_mount = write_stub(
            dir.path(),
            "mount",
            &format!("echo \"$1\" >> \"{}\"", log.display()),
        );
        let name = ctx.pasteboard_name.clone().unwrap();
        let pasteboard = Pasteboard::with_name(&name);
        let cc = pasteboard.change_count();

        // The self-host shape arrives on the trusted leg (§9.7).
        let mut client = common::served(std::sync::Arc::new(ctx), Endpoint::Trusted);
        client.hello_default();
        client.expect_caps();
        persist_ok(&mut client, "boxA", file.display().to_string().as_bytes());

        hold_for(
            "the mount helper never runs for a self-host manifest",
            || !log.exists(),
        );
        assert_eq!(
            pasteboard.change_count(),
            cc,
            "and nothing was written to the pasteboard"
        );
    }

    #[test]
    fn an_unhealthy_mount_self_heals_through_ensure_then_enriches() {
        let dir = testutil::tempdir("enrich-heal");
        let mount = dir.path().join("mnt");
        let remote = "/remote/healed.txt";
        let mapped = format!("{}{remote}", mount.display());
        std::fs::create_dir_all(std::path::Path::new(&mapped).parent().unwrap()).unwrap();
        std::fs::write(&mapped, b"payload").unwrap();
        let log = dir.path().join("log");
        let flag = dir.path().join("flag");

        let mut ctx = common::ctx_mut(dir.path(), "boxA");
        ctx.tools.clipboard_mount = write_stub(
            dir.path(),
            "mount",
            &format!(
                "case \"$1\" in\n\
                 check)\n  echo check >> \"{log}\"\n  [ -e \"{flag}\" ] || exit 1\n  printf '%s\\n' \"{mount}\"\n  ;;\n\
                 ensure)\n  echo ensure >> \"{log}\"\n  touch \"{flag}\"\n  ;;\n\
                 esac",
                log = log.display(),
                flag = flag.display(),
                mount = mount.display()
            ),
        );
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = served_public(ctx);
        persist_ok(&mut client, "boxB", remote.as_bytes());

        let pasteboard = Pasteboard::with_name(&name);
        wait_until("the enrichment write after the self-heal", || {
            pasteboard.snapshot(None).filenames.is_some()
        });
        assert_eq!(
            pasteboard.snapshot(None).filenames.as_deref(),
            Some(&[mapped][..]),
            "the healed mount's mapped path landed"
        );
        assert!(flag.exists(), "ensure performed the remount");
        assert_eq!(
            std::fs::read_to_string(&log).unwrap(),
            "check\nensure\ncheck\n",
            "failed check, ensure, successful re-check — in that order"
        );
    }

    #[test]
    fn a_user_copy_during_the_self_heal_wins_over_the_enrichment() {
        let dir = testutil::tempdir("enrich-guard");
        let mount = dir.path().join("mnt");
        let remote = "/remote/guarded.txt";
        // The mapped path EXISTS: the changeCount guard must be the only
        // thing standing between the enrichment and the pasteboard.
        let mapped = format!("{}{remote}", mount.display());
        std::fs::create_dir_all(std::path::Path::new(&mapped).parent().unwrap()).unwrap();
        std::fs::write(&mapped, b"payload").unwrap();
        let log = dir.path().join("log");
        let flag = dir.path().join("flag");
        let started = dir.path().join("started");
        let sync = dir.path().join("sync");

        let mut ctx = common::ctx_mut(dir.path(), "boxA");
        // `ensure` announces itself and then BLOCKS until the test says go —
        // the ordering below is file-signalled, never timing-guessed.
        ctx.tools.clipboard_mount = write_stub(
            dir.path(),
            "mount",
            &format!(
                "case \"$1\" in\n\
                 check)\n  echo check >> \"{log}\"\n  [ -e \"{flag}\" ] || exit 1\n  printf '%s\\n' \"{mount}\"\n  ;;\n\
                 ensure)\n  touch \"{started}\"\n  n=0\n  while [ ! -e \"{sync}\" ]; do\n    [ \"$n\" -ge 500 ] && exit 1\n    n=$((n+1))\n    sleep 0.02\n  done\n  touch \"{flag}\"\n  ;;\n\
                 esac",
                log = log.display(),
                flag = flag.display(),
                mount = mount.display(),
                started = started.display(),
                sync = sync.display()
            ),
        );
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = served_public(ctx);
        persist_ok(&mut client, "boxB", remote.as_bytes());

        // `started` exists only after the enrichment captured its changeCount
        // token and failed the first check — so the copy below is strictly
        // inside the guard window.
        wait_until("ensure to start", || started.exists());
        let pasteboard = Pasteboard::with_name(&name);
        let mut data = std::collections::BTreeMap::new();
        data.insert(
            "public.utf8-plain-text".to_string(),
            b"the user's copy".to_vec(),
        );
        pasteboard.write_all(&data);
        std::fs::write(&sync, b"").unwrap();

        wait_until("the re-check after ensure", || {
            std::fs::read_to_string(&log).is_ok_and(|logged| logged.matches("check").count() == 2)
        });
        hold_for("the enrichment must not overwrite the user's copy", || {
            let snapshot = pasteboard.snapshot(None);
            snapshot.data.get("public.utf8-plain-text") == Some(&b"the user's copy".to_vec())
                && snapshot.filenames.is_none()
                && !snapshot
                    .data
                    .contains_key("org.chezmoi.clipboard.UntrustedFileURLs")
        });
    }
}
