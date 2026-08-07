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
