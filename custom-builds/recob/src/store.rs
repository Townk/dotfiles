//! The clipboard history store — §14.2's writer half.
//!
//! **The schema is off-limits** (§16, plan ground rules): every statement here
//! is a port of what `clipboard-history.lua` executes today, against the same
//! file, so the pickers' read paths keep working unchanged. What this module
//! adds is only *who* runs the statements — the daemon becomes the writer
//! §14.2 says it must be, with the same dedup, the same retention sweeps, the
//! same `file_authorities` rules and the same `file_grants` expiry.
//!
//! During the Phase 3–7 window the Lua watcher still writes too; §14.4 expects
//! two rows per copy or one row and a dedup update, depending on which writer
//! wins, and that duplication is deliberately not "fixed" here. WAL plus a
//! busy timeout is what lets the two writers coexist without either erroring.

use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

use crate::capture::Capture;

/// Retention: at most 1000 rows (`clipboard-history.lua:66`).
const MAX_ROWS: i64 = 1000;
/// Retention: at most 200 MB of blobs across the store.
const MAX_STORE_BYTES: i64 = 200 * 1024 * 1024;
/// `file_grants` expire after 30 minutes idle.
const GRANT_IDLE_S: f64 = 30.0 * 60.0;

/// The store the pickers read: `$XDG_DATA_HOME/pick-clipboard/history.db`.
pub fn default_db_path() -> PathBuf {
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let mut home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
            home.push(".local/share");
            home
        });
    data.join("pick-clipboard/history.db")
}

pub struct Store {
    conn: Connection,
}

impl Store {
    /// Opens (creating directories and schema as needed) the store at `path`.
    /// `host` backfills `source_host` on pre-migration rows, exactly as the Lua
    /// writer's `ensure_schema` does.
    pub fn open(path: &Path, host: &str) -> rusqlite::Result<Store> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                    Some(format!("create {}: {e}", parent.display())),
                )
            })?;
        }
        let conn = Connection::open(path)?;
        // The Lua writer relies on WAL's default busy handling; two concurrent
        // writers exist by design during the transition window, so the daemon
        // waits rather than surfacing SQLITE_BUSY.
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let store = Store { conn };
        store.ensure_schema(host)?;
        Ok(store)
    }

    /// The schema and migrations, statement for statement from the Lua writer.
    fn ensure_schema(&self, host: &str) -> rusqlite::Result<()> {
        // journal_mode returns a row; execute() would error on it.
        let _: String = self
            .conn
            .pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
        self.conn.pragma_update(None, "synchronous", "NORMAL")?;
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS clips (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    text_preview TEXT,
    text_plain TEXT,
    len INTEGER,
    first_ts REAL,
    last_ts REAL,
    source_app TEXT,
    source_bundle_id TEXT,
    type_kind TEXT,
    regtype TEXT,
    pinned INTEGER DEFAULT 0,
    type_hash TEXT,
    source_host TEXT
  );
CREATE TABLE IF NOT EXISTS clip_types (
    clip_id INTEGER,
    uti TEXT,
    blob BLOB,
    PRIMARY KEY (clip_id, uti)
  );
CREATE TABLE IF NOT EXISTS file_authorities (
    clip_id INTEGER NOT NULL,
    item_index INTEGER NOT NULL,
    path BLOB NOT NULL,
    PRIMARY KEY (clip_id, item_index)
  );
CREATE TABLE IF NOT EXISTS file_grants (
    token TEXT NOT NULL,
    item_index INTEGER NOT NULL,
    path BLOB NOT NULL,
    created_ts REAL NOT NULL,
    last_used_ts REAL NOT NULL,
    hard_expires_ts REAL NOT NULL,
    PRIMARY KEY (token, item_index)
  );
CREATE INDEX IF NOT EXISTS idx_clips_type_hash ON clips(type_hash);
CREATE INDEX IF NOT EXISTS idx_clips_last_ts ON clips(last_ts DESC);
CREATE INDEX IF NOT EXISTS idx_clips_pinned_ts ON clips(pinned DESC, last_ts DESC);
CREATE INDEX IF NOT EXISTS idx_file_grants_expiry ON file_grants(hard_expires_ts, last_used_ts);",
        )?;

        if !self.column_exists("clips", "source_bundle_id")? {
            self.conn
                .execute("ALTER TABLE clips ADD COLUMN source_bundle_id TEXT;", [])?;
        }
        if !self.column_exists("clips", "source_host")? {
            self.conn
                .execute("ALTER TABLE clips ADD COLUMN source_host TEXT;", [])?;
        }
        // Migration to the self-contained model: drop the old text-only mirror
        // pointer rows, backfill source_host (every pre-existing row was a
        // local capture), then drop the dead columns.
        if self.column_exists("clips", "origin")? {
            self.conn.execute(
                "DELETE FROM clips WHERE origin IN ('remote-ref','laptop-ref');",
                [],
            )?;
        }
        self.conn.execute(
            "UPDATE clips SET source_host=?1 WHERE source_host IS NULL OR source_host='';",
            params![host],
        )?;
        if self.column_exists("clips", "origin")? {
            self.conn
                .execute("ALTER TABLE clips DROP COLUMN origin;", [])?;
        }
        if self.column_exists("clips", "ref_id")? {
            self.conn
                .execute("ALTER TABLE clips DROP COLUMN ref_id;", [])?;
        }
        Ok(())
    }

    fn column_exists(&self, table: &str, column: &str) -> rusqlite::Result<bool> {
        let mut stmt = self.conn.prepare(&format!("PRAGMA table_info({table});"))?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let name: String = row.get(1)?;
            if name == column {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Writes one capture: dedup by `type_hash` (an existing unpinned row is
    /// updated, not duplicated), else a new row plus its `clip_types` payloads;
    /// `file_authorities` only when the capture is local (§14.2); then the
    /// retention sweeps. Returns the row id.
    ///
    /// `local` is provenance: Phase 3's observed captures are always local, but
    /// the rule it gates — never write file authority for a remote-origin row —
    /// is §14.2's, so the writer enforces it rather than trusting each caller.
    pub fn write_capture(
        &mut self,
        capture: &Capture,
        host: &str,
        local: bool,
        now: f64,
    ) -> rusqlite::Result<i64> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;

        let existing: Option<i64> = tx
            .query_row(
                "SELECT id FROM clips WHERE type_hash=?1 AND pinned=0 ORDER BY id DESC LIMIT 1;",
                params![capture.type_hash],
                |row| row.get(0),
            )
            .optional()?;

        let id = match existing {
            Some(id) => {
                tx.execute(
                    "UPDATE clips SET last_ts=?1, source_app=?2, source_bundle_id=?3, \
                     text_preview=?4, text_plain=?5, len=?6, type_kind=?7, regtype=?8, \
                     source_host=?9 WHERE id=?10;",
                    params![
                        now,
                        capture.source_app,
                        capture.source_bundle_id,
                        capture.preview,
                        capture.plain,
                        capture.len,
                        capture.kind.as_str(),
                        Option::<String>::None,
                        host,
                        id
                    ],
                )?;
                id
            }
            None => {
                tx.execute(
                    "INSERT INTO clips (text_preview, text_plain, len, first_ts, last_ts, \
                     source_app, source_bundle_id, type_kind, regtype, pinned, type_hash, \
                     source_host) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,0,?10,?11);",
                    params![
                        capture.preview,
                        capture.plain,
                        capture.len,
                        now,
                        now,
                        capture.source_app,
                        capture.source_bundle_id,
                        capture.kind.as_str(),
                        Option::<String>::None,
                        capture.type_hash,
                        host
                    ],
                )?;
                let id = tx.last_insert_rowid();
                for (uti, blob) in &capture.data {
                    tx.execute(
                        "INSERT OR REPLACE INTO clip_types (clip_id, uti, blob) VALUES (?1,?2,?3);",
                        params![id, uti, blob],
                    )?;
                }
                id
            }
        };

        if local {
            if let Some(paths) = &capture.authority_paths {
                if !replace_file_authority(&tx, id, paths)? {
                    crate::log!("capture: failed to authorize local file capture {id}");
                }
            }
        }

        enforce_retention(&tx, now)?;
        tx.commit()?;
        Ok(id)
    }

    /// Test/diagnostic access to the underlying connection.
    pub fn conn(&self) -> &Connection {
        &self.conn
    }
}

/// Replace one locally trusted file clip's immutable authority snapshot. Paths
/// are bound as BLOBs, never interpolated, so arbitrary filename bytes remain
/// exact; a relative path or one with a `..` traversal refuses the whole set,
/// as the Lua's validation does. `Ok(false)` is the refusal — the clip row
/// itself stands, only the authority snapshot is withheld.
fn replace_file_authority(
    tx: &rusqlite::Transaction<'_>,
    clip_id: i64,
    paths: &[String],
) -> rusqlite::Result<bool> {
    if paths.is_empty() {
        return Ok(false);
    }
    for path in paths {
        if !path.starts_with('/') || path.contains("/../") || path.ends_with("/..") {
            return Ok(false);
        }
    }
    tx.execute(
        "DELETE FROM file_authorities WHERE clip_id=?1;",
        params![clip_id],
    )?;
    for (index, path) in paths.iter().enumerate() {
        tx.execute(
            "INSERT INTO file_authorities (clip_id,item_index,path) VALUES (?1,?2,?3);",
            params![clip_id, index as i64 + 1, path.as_bytes()],
        )?;
    }
    Ok(true)
}

/// The retention sweeps (§14.2): drop the oldest unpinned rows past the row
/// cap, then past the byte cap, clean orphaned `clip_types` and
/// `file_authorities` by hand (no cross-process PRAGMA foreign_keys), and
/// expire `file_grants` at 30 minutes idle or past `hard_expires_ts`.
fn enforce_retention(tx: &rusqlite::Transaction<'_>, now: f64) -> rusqlite::Result<()> {
    tx.execute(
        &format!(
            "DELETE FROM clips WHERE id IN ( \
             SELECT id FROM clips WHERE pinned=0 ORDER BY last_ts ASC \
             LIMIT (SELECT MAX(0, COUNT(*) - {MAX_ROWS}) FROM clips));"
        ),
        [],
    )?;
    let (rows, bytes): (i64, i64) = tx.query_row(
        "SELECT (SELECT COUNT(*) FROM clips), \
         (SELECT COALESCE(SUM(length(blob)),0) FROM clip_types);",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    if bytes > MAX_STORE_BYTES {
        let limit = std::cmp::max(1, rows - MAX_ROWS / 2);
        tx.execute(
            &format!(
                "DELETE FROM clips WHERE pinned=0 AND id IN ( \
                 SELECT clip_id FROM clip_types GROUP BY clip_id \
                 ORDER BY (SELECT last_ts FROM clips c WHERE c.id=clip_id) ASC \
                 LIMIT {limit});"
            ),
            [],
        )?;
    }
    tx.execute(
        "DELETE FROM clip_types WHERE clip_id NOT IN (SELECT id FROM clips);",
        [],
    )?;
    tx.execute(
        "DELETE FROM file_authorities WHERE clip_id NOT IN (SELECT id FROM clips);",
        [],
    )?;
    tx.execute(
        &format!(
            "DELETE FROM file_grants WHERE hard_expires_ts <= {now} OR last_used_ts < {}",
            now - GRANT_IDLE_S
        ),
        [],
    )?;
    Ok(())
}

/// Seconds since the epoch as a float — the REAL the schema's timestamp
/// columns hold (`hs.timer.secondsSinceEpoch` in the Lua).
pub fn now_ts() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture::{decide, FrontmostApp, Snapshot};
    use std::collections::BTreeMap;

    fn open_test_store(dir: &Path) -> Store {
        Store::open(&dir.join("history.db"), "boxA").expect("open store")
    }

    fn text_capture(text: &str) -> Capture {
        let mut data = BTreeMap::new();
        data.insert(
            "public.utf8-plain-text".to_string(),
            text.as_bytes().to_vec(),
        );
        decide(&Snapshot {
            item_utis: vec!["public.utf8-plain-text".to_string()],
            data,
            frontmost: Some(FrontmostApp {
                name: "Ghostty".to_string(),
                bundle_id: Some("com.mitchellh.ghostty".to_string()),
            }),
            filenames: None,
            resolved_url_path: None,
        })
        .expect("captured")
    }

    #[test]
    fn a_capture_writes_a_row_and_its_payloads() {
        let dir = crate::testutil::tempdir("store-write");
        let mut store = open_test_store(dir.path());
        let id = store
            .write_capture(&text_capture("hello"), "boxA", true, 100.0)
            .unwrap();
        let (plain, kind, app, host): (String, String, String, String) = store
            .conn()
            .query_row(
                "SELECT text_plain, type_kind, source_app, source_host FROM clips WHERE id=?1;",
                params![id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(plain, "hello");
        assert_eq!(kind, "text");
        assert_eq!(app, "Ghostty");
        assert_eq!(host, "boxA");
        let blob: Vec<u8> = store
            .conn()
            .query_row(
                "SELECT blob FROM clip_types WHERE clip_id=?1 AND uti='public.utf8-plain-text';",
                params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(blob, b"hello");
    }

    #[test]
    fn dedup_updates_the_existing_unpinned_row_and_a_pinned_one_is_left_alone() {
        let dir = crate::testutil::tempdir("store-dedup");
        let mut store = open_test_store(dir.path());
        let capture = text_capture("same bytes");
        let first = store.write_capture(&capture, "boxA", true, 100.0).unwrap();
        let second = store.write_capture(&capture, "boxA", true, 200.0).unwrap();
        assert_eq!(
            first, second,
            "an identical re-copy updates, not duplicates"
        );
        let (count, last_ts): (i64, f64) = store
            .conn()
            .query_row("SELECT COUNT(*), MAX(last_ts) FROM clips;", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        assert_eq!(count, 1);
        assert!((last_ts - 200.0).abs() < f64::EPSILON, "last_ts bumped");

        store
            .conn()
            .execute("UPDATE clips SET pinned=1 WHERE id=?1;", params![first])
            .unwrap();
        let third = store.write_capture(&capture, "boxA", true, 300.0).unwrap();
        assert_ne!(third, first, "a pinned row is never the dedup target");
    }

    #[test]
    fn retention_drops_the_oldest_unpinned_rows_past_the_cap() {
        let dir = crate::testutil::tempdir("store-retention");
        let mut store = open_test_store(dir.path());
        for i in 0..(MAX_ROWS + 5) {
            store
                .write_capture(&text_capture(&format!("clip {i}")), "boxA", true, i as f64)
                .unwrap();
        }
        let count: i64 = store
            .conn()
            .query_row("SELECT COUNT(*) FROM clips;", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, MAX_ROWS);
        let oldest: String = store
            .conn()
            .query_row(
                "SELECT text_plain FROM clips ORDER BY last_ts ASC LIMIT 1;",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(oldest, "clip 5", "the oldest unpinned rows were dropped");
        let orphans: i64 = store
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM clip_types WHERE clip_id NOT IN (SELECT id FROM clips);",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(orphans, 0, "orphaned clip_types are swept");
    }

    #[test]
    fn file_authorities_are_written_for_local_captures_only() {
        let dir = crate::testutil::tempdir("store-authority");
        let mut store = open_test_store(dir.path());
        let mut capture = text_capture("with files");
        capture.authority_paths = Some(vec!["/tmp/a.txt".to_string(), "/tmp/b.txt".to_string()]);

        let remote = store.write_capture(&capture, "boxB", false, 100.0).unwrap();
        let count: i64 = store
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM file_authorities WHERE clip_id=?1;",
                params![remote],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "§14.2: never for a remote-origin row");

        let mut capture = text_capture("with files, local");
        capture.authority_paths = Some(vec!["/tmp/a.txt".to_string(), "/tmp/b.txt".to_string()]);
        let local = store.write_capture(&capture, "boxA", true, 200.0).unwrap();
        let paths: Vec<Vec<u8>> = store
            .conn()
            .prepare("SELECT path FROM file_authorities WHERE clip_id=?1 ORDER BY item_index;")
            .unwrap()
            .query_map(params![local], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(paths, vec![b"/tmp/a.txt".to_vec(), b"/tmp/b.txt".to_vec()]);
    }

    #[test]
    fn a_traversal_or_relative_path_refuses_the_whole_authority_set() {
        let dir = crate::testutil::tempdir("store-authority-bad");
        let mut store = open_test_store(dir.path());
        for bad in ["relative/path", "/tmp/../etc/passwd", "/tmp/.."] {
            let mut capture = text_capture(bad);
            capture.authority_paths = Some(vec!["/tmp/fine.txt".to_string(), bad.to_string()]);
            let id = store.write_capture(&capture, "boxA", true, 100.0).unwrap();
            let count: i64 = store
                .conn()
                .query_row(
                    "SELECT COUNT(*) FROM file_authorities WHERE clip_id=?1;",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 0, "path {bad:?} must refuse the set");
        }
    }

    #[test]
    fn file_grants_expire_at_idle_and_at_the_hard_deadline() {
        let dir = crate::testutil::tempdir("store-grants");
        let mut store = open_test_store(dir.path());
        let now = 10_000.0;
        for (token, last_used, hard_expires) in [
            ("fresh", now - 10.0, now + 3600.0),
            ("idle", now - GRANT_IDLE_S - 1.0, now + 3600.0),
            ("hard-expired", now - 10.0, now - 1.0),
        ] {
            store
                .conn()
                .execute(
                    "INSERT INTO file_grants (token,item_index,path,created_ts,last_used_ts,hard_expires_ts) \
                     VALUES (?1,1,?2,?3,?4,?5);",
                    params![token, b"/tmp/x".as_slice(), now - 100.0, last_used, hard_expires],
                )
                .unwrap();
        }
        store
            .write_capture(&text_capture("sweep trigger"), "boxA", true, now)
            .unwrap();
        let alive: Vec<String> = store
            .conn()
            .prepare("SELECT token FROM file_grants;")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(alive, vec!["fresh".to_string()]);
    }

    #[test]
    fn the_schema_migrations_backfill_source_host() {
        let dir = crate::testutil::tempdir("store-migrate");
        let path = dir.path().join("history.db");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE clips (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   text_preview TEXT, text_plain TEXT, len INTEGER,
                   first_ts REAL, last_ts REAL, source_app TEXT,
                   type_kind TEXT, regtype TEXT, pinned INTEGER DEFAULT 0,
                   type_hash TEXT, origin TEXT, ref_id INTEGER);
                 INSERT INTO clips (text_plain, origin) VALUES ('kept', 'local');
                 INSERT INTO clips (text_plain, origin) VALUES ('dropped', 'remote-ref');",
            )
            .unwrap();
        }
        let store = Store::open(&path, "boxA").unwrap();
        let rows: Vec<(String, String)> = store
            .conn()
            .prepare("SELECT text_plain, source_host FROM clips;")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(rows, vec![("kept".to_string(), "boxA".to_string())]);
        assert!(!store.column_exists("clips", "origin").unwrap());
        assert!(!store.column_exists("clips", "ref_id").unwrap());
    }
}
