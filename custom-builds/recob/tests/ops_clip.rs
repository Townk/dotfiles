//! The `clip.*` operations and §11.4's behavior coverage: one copy one row,
//! restore across every clip kind, restore-not-a-capture, and the `plain_only`
//! branches. Everything pasteboard-shaped runs against the per-test private
//! pasteboard `common::ctx_mut` names — never the live clipboard.

mod common;

use common::{testutil, text, Client};
use recobd::listen::Endpoint;
use recobd::wire::{Fields, Kind};
use rusqlite::Connection;

fn trusted(ctx: std::sync::Arc<recobd::session::Ctx>) -> Client<std::os::unix::net::UnixStream> {
    let mut client = common::served(ctx, Endpoint::Trusted);
    client.hello_default();
    client.expect_caps();
    client
}

fn set_text(
    client: &mut Client<std::os::unix::net::UnixStream>,
    text: &[u8],
    regtype: &str,
    origin: Option<&str>,
) {
    let mut request = Fields::new()
        .with("op", b"clip.set".to_vec())
        .with("text", text.to_vec())
        .with("regtype", regtype.as_bytes().to_vec());
    if let Some(origin) = origin {
        request.push("origin_host", origin.as_bytes());
    }
    client.send_request(&request);
    let (kind, _) = client.next().expect("clip.set answer");
    assert_eq!(kind, Kind::Response);
}

fn row_count(db: &std::path::Path) -> i64 {
    Connection::open(db)
        .unwrap()
        .query_row("SELECT COUNT(*) FROM clips;", [], |row| row.get(0))
        .unwrap()
}

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use recobd::host::HostIdentity;
    use recobd::platform::macos::{capture_step, Pasteboard};
    use recobd::store::Store;

    /// §11.4 "One copy, one row": a `clip.set` produces exactly one store row
    /// carrying the declared origin, the daemon's own observation adds no
    /// second row for the same write, and a later *physical* copy of the same
    /// text is still captured.
    #[test]
    fn one_copy_one_row_and_the_inverse() {
        let dir = testutil::tempdir("clip-one-row");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = trusted(ctx.clone());

        set_text(&mut client, b"copied once", "v", Some("boxB"));
        assert_eq!(row_count(&db), 1, "exactly one row for the write");
        let conn = Connection::open(&db).unwrap();
        let (host, regtype, first_ts): (String, String, f64) = conn
            .query_row(
                "SELECT source_host, regtype, last_ts FROM clips;",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(host, "boxB", "the declared origin_host, not this machine");
        assert_eq!(regtype, "v");

        // The daemon's own observation of that write: no second row.
        let pasteboard = Pasteboard::with_name(&name);
        let mut store = Store::open(&db, "boxA").unwrap();
        let host_id = HostIdentity::with_paths(dir.path().join("self-name"), None);
        let seen = capture_step(
            &pasteboard,
            &mut store,
            &ctx.tracker,
            &host_id,
            0, // stale, so the step sees "a change" and must skip it as its own
            &|| {
                Some(recobd::capture::FrontmostApp {
                    name: "Ghostty".to_string(),
                    bundle_id: None,
                })
            },
        );
        assert_eq!(seen, pasteboard.change_count());
        assert_eq!(row_count(&db), 1, "§6.2: the echo added nothing");

        // The inverse: a physical copy of the same text afterwards is a real
        // capture — dedup bumps the row rather than skipping the change.
        let mut data = std::collections::BTreeMap::new();
        data.insert(
            "public.utf8-plain-text".to_string(),
            b"copied once".to_vec(),
        );
        pasteboard.write_all(&data);
        capture_step(
            &pasteboard,
            &mut store,
            &ctx.tracker,
            &host_id,
            seen,
            &|| {
                Some(recobd::capture::FrontmostApp {
                    name: "Ghostty".to_string(),
                    bundle_id: None,
                })
            },
        );
        assert_eq!(row_count(&db), 1, "same bytes dedup into the same row");
        let (host, bumped_ts): (String, f64) = Connection::open(&db)
            .unwrap()
            .query_row("SELECT source_host, last_ts FROM clips;", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        assert!(
            bumped_ts > first_ts,
            "the physical copy was captured, not suppressed"
        );
        assert_eq!(host, "boxA", "and it is a local capture now");
    }

    #[test]
    fn clip_get_answers_text_regtype_timestamp_and_host_in_one_exchange() {
        let dir = testutil::tempdir("clip-get");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let mut client = trusted(ctx);

        set_text(&mut client, b"block yank\n", "b", None);
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(fields.get("text"), Some(&b"block yank\n"[..]));
        assert_eq!(
            text(&fields, "regtype"),
            "b",
            "§14.6: answered from the tracker, no sidecar file"
        );
        assert_eq!(text(&fields, "host"), "boxA");
        let row_ts: f64 = Connection::open(&db)
            .unwrap()
            .query_row("SELECT last_ts FROM clips;", [], |row| row.get(0))
            .unwrap();
        assert_eq!(
            text(&fields, "timestamp"),
            format!("{row_ts}"),
            "the content-matched row's last_ts"
        );
    }

    /// §11.4 "Restore covers every clip kind" and "Restore does not become a
    /// capture", plus §14.6's round trip.
    #[test]
    fn restore_reinstates_the_full_set_and_the_regtype_without_capturing() {
        let dir = testutil::tempdir("clip-restore");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = trusted(ctx.clone());

        // A text row with a register type, then a rich row on top.
        set_text(&mut client, b"first clip\n", "b", None);
        client.send_request(
            &Fields::new()
                .with("op", b"clip.set.rich".to_vec())
                .with("uti", b"com.example.custom".to_vec())
                .with("blob", b"opaque \x00 bytes".to_vec()),
        );
        client.next().expect("rich answer");

        // Restore the text row (id 1): the stored set lands on the pasteboard
        // and the regtype survives the round trip through clip.get.
        client.send_request(
            &Fields::new()
                .with("op", b"clip.restore".to_vec())
                .with("clip_id", b"1".to_vec()),
        );
        let (kind, _) = client.next().expect("restore answer");
        assert_eq!(kind, Kind::Response);
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(fields.get("text"), Some(&b"first clip\n"[..]));
        assert_eq!(text(&fields, "regtype"), "b", "§14.6 round trip");

        // Restore is not a capture: the observation loop sees the change and
        // adds nothing; the row count is unchanged.
        let rows_before = row_count(&db);
        let pasteboard = Pasteboard::with_name(&name);
        let mut store = Store::open(&db, "boxA").unwrap();
        let host_id = HostIdentity::with_paths(dir.path().join("self-name"), None);
        capture_step(&pasteboard, &mut store, &ctx.tracker, &host_id, 0, &|| {
            Some(recobd::capture::FrontmostApp {
                name: "Ghostty".to_string(),
                bundle_id: None,
            })
        });
        assert_eq!(
            row_count(&db),
            rows_before,
            "restore did not become a capture"
        );

        // A restore that names no row.
        client.send_request(
            &Fields::new()
                .with("op", b"clip.restore".to_vec())
                .with("clip_id", b"999".to_vec()),
        );
        let fields = client.expect_error();
        assert_eq!(text(&fields, "code"), "not-found");
        assert_eq!(text(&fields, "reason"), "no-row");
    }

    /// §14.5's `plain_only` branches, one per branch, none reinstating the
    /// register type.
    #[test]
    fn plain_only_degrades_by_kind() {
        let dir = testutil::tempdir("clip-plain-only");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = trusted(ctx.clone());
        let pasteboard = Pasteboard::with_name(&name);
        let pasteboard_text = |pb: &Pasteboard| -> Vec<u8> {
            pb.snapshot(None)
                .data
                .get("public.utf8-plain-text")
                .cloned()
                .unwrap_or_default()
        };

        // url row (id 1): the markdown link, not the bare text.
        set_text(&mut client, b"https://example.com/x", "v", None);
        client.send_request(
            &Fields::new()
                .with("op", b"clip.restore".to_vec())
                .with("clip_id", b"1".to_vec())
                .with("plain_only", b"1".to_vec()),
        );
        client.next().expect("restore answer");
        assert_eq!(
            pasteboard_text(&pasteboard),
            b"[https://example.com/x](https://example.com/x)".to_vec()
        );
        assert_eq!(
            ctx.tracker.regtype_at(pasteboard.change_count()),
            None,
            "a degraded restore reinstates no register type (§14.5)"
        );

        // image row (id 2): a data-URI markdown image.
        client.send_request(
            &Fields::new()
                .with("op", b"clip.set.rich".to_vec())
                .with("uti", b"public.png".to_vec())
                .with("blob", b"fakepng".to_vec()),
        );
        client.next().expect("rich answer");
        client.send_request(
            &Fields::new()
                .with("op", b"clip.restore".to_vec())
                .with("clip_id", b"2".to_vec())
                .with("plain_only", b"1".to_vec()),
        );
        client.next().expect("restore answer");
        assert_eq!(
            pasteboard_text(&pasteboard),
            b"![](data:image/png;base64,ZmFrZXBuZw==)".to_vec()
        );

        // file row (id 3): a file:// link named by basename.
        let file = dir.path().join("granted file.txt");
        std::fs::write(&file, b"1234567").unwrap();
        client.send_request(
            &Fields::new()
                .with("op", b"clip.set.files".to_vec())
                .with("paths", file.display().to_string().into_bytes()),
        );
        client.next().expect("set.files answer");
        client.send_request(
            &Fields::new()
                .with("op", b"clip.restore".to_vec())
                .with("clip_id", b"3".to_vec())
                .with("plain_only", b"1".to_vec()),
        );
        client.next().expect("restore answer");
        let link = String::from_utf8(pasteboard_text(&pasteboard)).unwrap();
        assert!(
            link.starts_with("[granted file.txt](file:///") && link.contains("granted%20file.txt"),
            "a file row linkifies its resolved path: {link}"
        );

        // text row: plain text, verbatim.
        set_text(&mut client, b"ordinary text", "v", None);
        let text_id = row_count(&db).to_string();
        client.send_request(
            &Fields::new()
                .with("op", b"clip.restore".to_vec())
                .with("clip_id", text_id.clone().into_bytes())
                .with("plain_only", b"1".to_vec()),
        );
        client.next().expect("restore answer");
        assert_eq!(pasteboard_text(&pasteboard), b"ordinary text".to_vec());

        // A row holding only public.html: the derived plain form. Constructed
        // directly — the capture path refuses an html clip with no plain
        // sibling, so only pre-existing store data has this shape.
        {
            let conn = Connection::open(&db).unwrap();
            conn.execute(
                "INSERT INTO clips (text_preview, type_kind, first_ts, last_ts, type_hash, source_host) \
                 VALUES ('[html]', 'html', 1.0, 1.0, 'x', 'boxA');",
                [],
            )
            .unwrap();
            let id = conn.last_insert_rowid();
            conn.execute(
                "INSERT INTO clip_types (clip_id, uti, blob) VALUES (?1, 'public.html', ?2);",
                rusqlite::params![id, b"<b>hi</b> &amp; bye".to_vec()],
            )
            .unwrap();
            client.send_request(
                &Fields::new()
                    .with("op", b"clip.restore".to_vec())
                    .with("clip_id", id.to_string().into_bytes())
                    .with("plain_only", b"1".to_vec()),
            );
            client.next().expect("restore answer");
            assert_eq!(
                pasteboard_text(&pasteboard),
                b"hi & bye".to_vec(),
                "branch 3: WebKit-backed derivation, headless (probe Q9)"
            );
        }
    }

    /// §14.6's other half: a pasteboard change the daemon did *not* perform
    /// has no tracker record, so `clip.get` answers the register type from
    /// the trailing-newline heuristic — `l` for a clip ending in a newline,
    /// `v` otherwise.
    #[test]
    fn clip_get_regtype_falls_back_to_the_trailing_newline_heuristic() {
        let dir = testutil::tempdir("clip-get-heuristic");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = trusted(ctx.clone());

        // A direct write to the test's private pasteboard — the shape of a
        // copy some other program made. Nothing lands on the tracker.
        let pasteboard = Pasteboard::with_name(&name);
        let mut data = std::collections::BTreeMap::new();
        data.insert(
            "public.utf8-plain-text".to_string(),
            b"a whole line\n".to_vec(),
        );
        pasteboard.write_all(&data);
        assert_eq!(
            ctx.tracker.regtype_at(pasteboard.change_count()),
            None,
            "precondition: the daemon has no record of this change"
        );
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(fields.get("text"), Some(&b"a whole line\n"[..]));
        assert_eq!(
            text(&fields, "regtype"),
            "l",
            "§14.6: trailing newline means linewise"
        );

        let mut data = std::collections::BTreeMap::new();
        data.insert("public.utf8-plain-text".to_string(), b"a fragment".to_vec());
        pasteboard.write_all(&data);
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(fields.get("text"), Some(&b"a fragment"[..]));
        assert_eq!(
            text(&fields, "regtype"),
            "v",
            "§14.6: no trailing newline means characterwise"
        );
    }

    #[test]
    fn set_files_writes_the_manifest_and_mints_authority() {
        let dir = testutil::tempdir("clip-set-files");
        let file_a = dir.path().join("a.txt");
        let file_b = dir.path().join("b.txt");
        std::fs::write(&file_a, b"a").unwrap();
        std::fs::write(&file_b, b"b").unwrap();

        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let name = ctx.pasteboard_name.clone().unwrap();
        let mut client = trusted(ctx);

        client.send_request(&Fields::new().with("op", b"clip.set.files".to_vec()).with(
            "paths",
            format!("{}\0{}", file_a.display(), file_b.display()).into_bytes(),
        ));
        let (kind, _) = client.next().expect("set.files answer");
        assert_eq!(kind, Kind::Response);

        let pasteboard = Pasteboard::with_name(&name);
        let snapshot = pasteboard.snapshot(None);
        assert_eq!(
            snapshot.filenames.as_deref(),
            Some(&[file_a.display().to_string(), file_b.display().to_string()][..]),
            "NSFilenamesPboardType round-trips through the real plist parser"
        );

        let conn = Connection::open(&db).unwrap();
        let (kind_col, authorities): (String, i64) = conn
            .query_row(
                "SELECT type_kind, (SELECT COUNT(*) FROM file_authorities) FROM clips;",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(kind_col, "files");
        assert_eq!(authorities, 2, "a local files write mints its authority");

        // Exactly one of paths | clip_id.
        client.send_request(&Fields::new().with("op", b"clip.set.files".to_vec()));
        assert_eq!(client.code(), "bad-request");
    }

    #[test]
    fn rich_writes_respect_the_endpoint_allow_list_and_the_blob_cap() {
        let dir = testutil::tempdir("clip-rich-policy");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));

        let mut public = common::served(ctx.clone(), Endpoint::Public);
        public.hello_authenticated(common::TEST_TOKEN);
        public.expect_caps_proven(common::TEST_TOKEN);
        public.send_request(
            &Fields::new()
                .with("op", b"clip.set.rich".to_vec())
                .with("uti", b"com.example.custom".to_vec())
                .with("blob", b"x".to_vec()),
        );
        assert_eq!(
            public.code(),
            "refused",
            "§9.3 uti_allow: the public endpoint takes only the seven UTIs"
        );

        let mut client = trusted(ctx);
        client.send_request(
            &Fields::new()
                .with("op", b"clip.set.rich".to_vec())
                .with("uti", b"com.example.custom".to_vec())
                .with("blob", b"x".to_vec()),
        );
        let (kind, _) = client.next().expect("trusted rich answer");
        assert_eq!(kind, Kind::Response, "any UTI on the trusted socket");

        // §6.5: one byte past the 128 MiB cap is file-too-large.
        client.send_request(
            &Fields::new()
                .with("op", b"clip.set.rich".to_vec())
                .with("uti", b"public.png".to_vec())
                .with("blob", vec![0u8; 128 * 1024 * 1024 + 1]),
        );
        let fields = client.expect_error();
        assert_eq!(text(&fields, "code"), "file-too-large");
    }
}

/// The Linux halves are cfg-gated the other way: the store row is the clip.
#[cfg(not(target_os = "macos"))]
mod linux {
    use super::*;

    #[test]
    fn clip_set_and_get_round_trip_through_the_store() {
        let dir = testutil::tempdir("clip-linux");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let mut client = trusted(ctx);
        set_text(&mut client, b"headless clip\n", "l", None);
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(fields.get("text"), Some(&b"headless clip\n"[..]));
        assert_eq!(text(&fields, "regtype"), "l", "the row's regtype column");
        assert_eq!(text(&fields, "host"), "boxA");
    }

    #[test]
    fn restore_is_a_recency_fact() {
        let dir = testutil::tempdir("clip-linux-restore");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let mut client = trusted(ctx);
        set_text(&mut client, b"old", "v", None);
        set_text(&mut client, b"new", "v", None);
        client.send_request(
            &Fields::new()
                .with("op", b"clip.restore".to_vec())
                .with("clip_id", b"1".to_vec()),
        );
        let (kind, _) = client.next().expect("restore answer");
        assert_eq!(kind, Kind::Response);
        let newest: String = Connection::open(&db)
            .unwrap()
            .query_row(
                "SELECT text_plain FROM clips ORDER BY last_ts DESC LIMIT 1;",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(newest, "old", "the restored row is the newest again");
    }

    /// An empty store is a well-formed answer, not an error: empty text, the
    /// heuristic regtype for empty bytes, no timestamp — the shape a fresh
    /// machine's first `clip.get` sees.
    #[test]
    fn clip_get_on_an_empty_store_answers_empty_not_an_error() {
        let dir = testutil::tempdir("clip-linux-empty");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let mut client = trusted(ctx);
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response, "an empty store is not an error");
        assert_eq!(fields.get("text"), Some(&b""[..]));
        assert_eq!(
            text(&fields, "regtype"),
            "v",
            "empty text has no trailing newline: characterwise"
        );
        assert_eq!(text(&fields, "timestamp"), "", "no rows, no timestamp");
        assert_eq!(text(&fields, "host"), "boxA");
    }

    /// §14.6 on the headless half: a newest row with no regtype column value
    /// (the shape pre-daemon zsh rows have) answers from the trailing-newline
    /// heuristic instead of erroring or inventing a value.
    #[test]
    fn clip_get_regtype_falls_back_to_the_heuristic_when_the_row_has_none() {
        let dir = testutil::tempdir("clip-linux-null-regtype");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let mut client = trusted(ctx);
        // A first write through the daemon creates the schema; the rows under
        // test are seeded directly so their regtype is NULL.
        set_text(&mut client, b"schema seed", "v", None);
        let conn = Connection::open(&db).unwrap();
        conn.execute(
            "INSERT INTO clips (text_preview, text_plain, type_kind, first_ts, last_ts, \
             type_hash, source_host) \
             VALUES ('legacy', ?1, 'text', 9000000000.0, 9000000000.0, 'legacy-l', 'boxA');",
            rusqlite::params!["a legacy line\n"],
        )
        .unwrap();
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(fields.get("text"), Some(&b"a legacy line\n"[..]));
        assert_eq!(
            text(&fields, "regtype"),
            "l",
            "NULL regtype falls back to the trailing-newline heuristic"
        );

        conn.execute(
            "INSERT INTO clips (text_preview, text_plain, type_kind, first_ts, last_ts, \
             type_hash, source_host) \
             VALUES ('legacy', ?1, 'text', 9000000001.0, 9000000001.0, 'legacy-v', 'boxA');",
            rusqlite::params!["a legacy fragment"],
        )
        .unwrap();
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(fields.get("text"), Some(&b"a legacy fragment"[..]));
        assert_eq!(
            text(&fields, "regtype"),
            "v",
            "no trailing newline: characterwise"
        );
    }

    /// Byte-exactness through the store: an embedded NUL survives the round
    /// trip. Invalid UTF-8 does NOT — `store.persist.text` runs the bytes
    /// through `from_utf8_lossy`, so they come back with U+FFFD replacements.
    /// The old zsh store was byte-exact here; this test pins what IS, and the
    /// divergence is reported with this phase rather than silently absorbed.
    #[test]
    fn clip_text_keeps_embedded_nuls_but_lossy_replaces_invalid_utf8() {
        let dir = testutil::tempdir("clip-linux-nul");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let mut client = trusted(ctx);

        set_text(&mut client, b"nul\0inside", "v", None);
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(
            fields.get("text"),
            Some(&b"nul\0inside"[..]),
            "the embedded NUL round-trips byte-exact"
        );
        let stored: Vec<u8> = Connection::open(&db)
            .unwrap()
            .query_row(
                "SELECT CAST(text_plain AS BLOB) FROM clips ORDER BY last_ts DESC LIMIT 1;",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            stored,
            b"nul\0inside".to_vec(),
            "the row itself holds the NUL byte-exact"
        );

        set_text(&mut client, b"bad \xff byte", "v", None);
        let (kind, fields) = client.request("clip.get");
        assert_eq!(kind, Kind::Response);
        assert_eq!(
            fields.get("text"),
            Some(&b"bad \xef\xbf\xbd byte"[..]),
            "pinned divergence: from_utf8_lossy replaced the invalid byte \
             (the zsh store kept it byte-exact)"
        );
    }

    /// The Linux `clip.set.rich` halves: the plain-text UTI populates
    /// text_plain byte-exact plus the flattened preview, and an image UTI
    /// classifies the row as an image.
    #[test]
    fn linux_persist_rich() {
        let dir = testutil::tempdir("clip-linux-rich");
        let ctx = std::sync::Arc::new(common::ctx_mut(dir.path(), "boxA"));
        let db = ctx.db_path.clone();
        let mut client = trusted(ctx);

        client.send_request(
            &Fields::new()
                .with("op", b"clip.set.rich".to_vec())
                .with("uti", b"public.utf8-plain-text".to_vec())
                .with("blob", b"  rich\n\n text  \n".to_vec()),
        );
        let (kind, _) = client.next().expect("rich answer");
        assert_eq!(kind, Kind::Response);
        let conn = Connection::open(&db).unwrap();
        let (kind_col, preview, plain): (String, String, String) = conn
            .query_row(
                "SELECT type_kind, text_preview, text_plain FROM clips \
                 ORDER BY id DESC LIMIT 1;",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(kind_col, "text");
        assert_eq!(
            plain, "  rich\n\n text  \n",
            "the plain-text UTI populates text_plain byte-exact"
        );
        assert_eq!(
            preview, "rich text",
            "and the flattened single-line preview"
        );

        client.send_request(
            &Fields::new()
                .with("op", b"clip.set.rich".to_vec())
                .with("uti", b"public.png".to_vec())
                .with("blob", b"fakepng".to_vec()),
        );
        let (kind, _) = client.next().expect("rich answer");
        assert_eq!(kind, Kind::Response);
        let (kind_col, plain): (String, Option<String>) = conn
            .query_row(
                "SELECT type_kind, text_plain FROM clips ORDER BY id DESC LIMIT 1;",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(kind_col, "image", "public.png classifies as an image row");
        assert_eq!(plain, None, "an image row has no plain text");
    }
}
