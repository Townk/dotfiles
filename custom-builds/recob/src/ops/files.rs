//! `files.list`, `files.grant` and `files.fetch` — the file half of the
//! bridge: a display-only manifest, an opaque short-lived capability over a
//! trusted local path snapshot, and the streaming fetch that spends it.
//!
//! §6.5's no-race contract replaces the 0.3 s sleep the zsh resolver carried:
//! the manifest reflects the pasteboard as of the moment the request arrived,
//! satisfied by comparing the live `changeCount` against the last one whose
//! row exists and capturing synchronously when they differ.

use rusqlite::{params, OptionalExtension};

use crate::registry::{Response, StreamSource};
use crate::session::Ctx;
use crate::store::{self, Store};
use crate::validate;
use crate::wire::{Fields, ProtoError};

/// Grants idle out after 30 minutes and die at 24 hours regardless.
const GRANT_IDLE_S: f64 = 30.0 * 60.0;
const GRANT_HARD_S: f64 = 24.0 * 3600.0;

fn internal(e: impl std::fmt::Display) -> ProtoError {
    ProtoError::new("internal", format!("store access failed: {e}"))
}

fn open_store(ctx: &Ctx) -> Result<Store, ProtoError> {
    let host = ctx.host.current().unwrap_or_default();
    Store::open(&ctx.db_path, &host).map_err(internal)
}

/// §6.5: capture synchronously when the pasteboard has moved past what the
/// store holds, so a paste issued immediately after a Finder copy resolves
/// without a sleep. Compiled out on Linux, where the newest row *is* the
/// current clipboard by construction.
#[cfg(target_os = "macos")]
fn ensure_current(ctx: &Ctx, store: &mut Store) {
    use crate::platform::macos::{frontmost_app, Pasteboard};

    // A daemon that was not asked to observe the pasteboard does not observe
    // it here either: this capture and the poll loop's are the same act, so
    // they share one switch (§14.2's opt-in). Without it, the newest row is
    // whatever the store holds, which is exactly what a non-capturing daemon
    // is entitled to answer from.
    if !ctx.capture {
        return;
    }
    let pasteboard = match &ctx.pasteboard_name {
        Some(name) => Pasteboard::with_name(name),
        None => Pasteboard::general(),
    };
    // The lock is held across the capture so two concurrent list/grant calls
    // do not both capture the same change.
    let mut last = ctx.last_cc.lock().unwrap();
    let change_count = pasteboard.change_count();
    if *last == Some(change_count) {
        return;
    }
    if !ctx.tracker.is_own(change_count) {
        let snapshot = pasteboard.snapshot(frontmost_app());
        if let Ok(capture) = crate::capture::decide(&snapshot) {
            let host = ctx.host.current().unwrap_or_default();
            if let Err(e) = store.write_capture(&capture, &host, true, store::now_ts()) {
                crate::log!("files: synchronous capture failed: {e}");
            }
        }
    }
    *last = Some(change_count);
}

#[cfg(not(target_os = "macos"))]
fn ensure_current(_ctx: &Ctx, _store: &mut Store) {}

struct Manifest {
    clip_id: i64,
    kind: String,
    host: String,
    timestamp: f64,
    /// NUL-joined display paths.
    paths: Vec<u8>,
}

/// The shared resolution `files.list` and `files.grant` use: the newest row,
/// its kind checked, its paths from `x-file-manifest`, the watcher's
/// `NSFilenamesPboardType` plist, or `x-resolved-path` — in that order, for
/// the reasons the zsh comments carry (a multi-file capture's resolved path
/// holds only the first of N).
fn resolve_manifest(store: &Store) -> Result<Manifest, ProtoError> {
    let conn = store.conn();
    let newest: Option<(i64, String, Option<String>, f64)> = conn
        .query_row(
            "SELECT id, type_kind, source_host, last_ts FROM clips \
             ORDER BY last_ts DESC LIMIT 1;",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(internal)?;
    let Some((clip_id, kind, host, timestamp)) = newest else {
        return Err(
            ProtoError::new("not-found", "the store holds no rows").with("reason", "empty-store")
        );
    };
    if !matches!(kind.as_str(), "files" | "file" | "directory") {
        return Err(
            ProtoError::new("not-found", "the current clip is not a files clip")
                .with("reason", "not-files"),
        );
    }

    let blob = |uti: &str| -> Result<Option<Vec<u8>>, ProtoError> {
        conn.query_row(
            "SELECT blob FROM clip_types WHERE clip_id=?1 AND uti=?2;",
            params![clip_id, uti],
            |row| row.get(0),
        )
        .optional()
        .map_err(internal)
    };

    let paths: Option<Vec<u8>> = if let Some(manifest) = blob("x-file-manifest")? {
        Some(manifest)
    } else if let Some(ns_blob) = blob("NSFilenamesPboardType")? {
        parse_ns_filenames(&ns_blob).map(|paths| paths.join("\0").into_bytes())
    } else {
        blob("x-resolved-path")?
    };
    let Some(paths) = paths.filter(|paths| !paths.is_empty()) else {
        return Err(
            ProtoError::new("not-found", "the current clip carries no paths")
                .with("reason", "not-files"),
        );
    };

    Ok(Manifest {
        clip_id,
        kind,
        host: host.unwrap_or_default(),
        timestamp,
        paths,
    })
}

#[cfg(target_os = "macos")]
fn parse_ns_filenames(blob: &[u8]) -> Option<Vec<String>> {
    crate::platform::macos::parse_filenames_bytes(blob)
}

/// Unreachable on Linux by construction: `NSFilenamesPboardType` blobs are
/// only ever written by macOS capture; Linux files rows always carry
/// `x-file-manifest`, which resolves first.
#[cfg(not(target_os = "macos"))]
fn parse_ns_filenames(_blob: &[u8]) -> Option<Vec<String>> {
    None
}

fn manifest_reply(manifest: &Manifest) -> Fields {
    Fields::new()
        .with("kind", manifest.kind.as_bytes())
        .with("host", manifest.host.as_bytes())
        .with("timestamp", format_ts(manifest.timestamp).into_bytes())
        .with("paths", manifest.paths.clone())
}

/// `last_ts` the way the zsh wrote it back: the REAL column's own decimal.
fn format_ts(ts: f64) -> String {
    // SQLite REALs round-trip; trim a trailing ".0" the way sqlite3's CLI
    // prints integers stored as REAL.
    let text = format!("{ts}");
    text.trim_end_matches(".0").to_string()
}

/// `files.list` — the display-only manifest. It deliberately contains no
/// authority.
pub fn list(ctx: &Ctx) -> Result<Response, ProtoError> {
    let mut store = open_store(ctx)?;
    ensure_current(ctx, &mut store);
    let manifest = resolve_manifest(&store)?;
    Ok(manifest_reply(&manifest).into())
}

/// `files.grant` — the manifest plus an opaque bearer token when this row
/// holds a trusted authority snapshot. A pointer row answers `-`, so a client
/// on the source host can still use the paths locally while cross-machine
/// streaming fails closed.
pub fn grant(ctx: &Ctx) -> Result<Response, ProtoError> {
    let mut store = open_store(ctx)?;
    ensure_current(ctx, &mut store);
    let manifest = resolve_manifest(&store)?;

    let mut token = "-".to_string();
    let mut paths = manifest.paths.clone();
    if let Some(authority) = load_authority(&store, manifest.clip_id)? {
        paths = authority.join("\0").into_bytes();
        token = create_grant(&store, manifest.clip_id)?;
    }
    let mut reply = manifest_reply(&manifest);
    reply.push("token", token.into_bytes());
    // The authority snapshot, when present, replaces the display paths — the
    // grant's paths are what the token actually covers.
    let reply = replace_field(reply, "paths", paths);
    Ok(reply.into())
}

/// Fields has no in-place replace; rebuild preserving order.
fn replace_field(fields: Fields, name: &str, value: Vec<u8>) -> Fields {
    let mut out = Fields::new();
    for field in fields.names().collect::<Vec<_>>() {
        if field == name {
            out.push(field, value.clone());
        } else if let Some(existing) = fields.get(field) {
            out.push(field, existing.to_vec());
        }
    }
    out
}

/// The immutable authority snapshot, re-validated at load exactly as the zsh
/// does: contiguous indexes from 1, and every path still a real, non-symlink
/// file or directory. Any violation means "no authority" — pointer semantics,
/// not an error.
fn load_authority(store: &Store, clip_id: i64) -> Result<Option<Vec<String>>, ProtoError> {
    let conn = store.conn();
    let mut stmt = conn
        .prepare(
            "SELECT item_index, path FROM file_authorities WHERE clip_id=?1 ORDER BY item_index;",
        )
        .map_err(internal)?;
    let rows: Vec<(i64, Vec<u8>)> = stmt
        .query_map(params![clip_id], |row| Ok((row.get(0)?, row.get(1)?)))
        .map_err(internal)?
        .collect::<Result<_, _>>()
        .map_err(internal)?;
    if rows.is_empty() {
        return Ok(None);
    }
    let mut paths = Vec::with_capacity(rows.len());
    for (expected, (index, raw)) in rows.into_iter().enumerate() {
        if index != expected as i64 + 1 {
            return Ok(None);
        }
        let Ok(path) = String::from_utf8(raw) else {
            return Ok(None);
        };
        match std::fs::symlink_metadata(&path) {
            Ok(meta) if !meta.file_type().is_symlink() && (meta.is_file() || meta.is_dir()) => {}
            _ => return Ok(None),
        }
        paths.push(path);
    }
    Ok(Some(paths))
}

/// Issue a grant: the authority BLOBs are *copied*, so clipboard churn and row
/// retention cannot change what an already-issued token means.
fn create_grant(store: &Store, clip_id: i64) -> Result<String, ProtoError> {
    let conn = store.conn();
    prune_grants(conn)?;
    for _attempt in 0..3 {
        let token = crate::auth::random_bytes(32)
            .map(|bytes| crate::auth::hex(&bytes))
            .map_err(|e| ProtoError::new("internal", format!("no randomness: {e}")))?;
        let now = store::now_ts();
        let inserted = conn
            .execute(
                "INSERT INTO file_grants \
                 (token,item_index,path,created_ts,last_used_ts,hard_expires_ts) \
                 SELECT ?1,item_index,path,?2,?2,?3 FROM file_authorities \
                 WHERE clip_id=?4 \
                 AND NOT EXISTS (SELECT 1 FROM file_grants WHERE token=?1);",
                params![token, now, now + GRANT_HARD_S, clip_id],
            )
            .map_err(internal)?;
        if inserted > 0 {
            return Ok(token);
        }
        conn.execute("DELETE FROM file_grants WHERE token=?1;", params![token])
            .map_err(internal)?;
    }
    Err(ProtoError::new("internal", "grant creation failed"))
}

fn prune_grants(conn: &rusqlite::Connection) -> Result<(), ProtoError> {
    let now = store::now_ts();
    conn.execute(
        "DELETE FROM file_authorities WHERE clip_id NOT IN (SELECT id FROM clips);",
        [],
    )
    .map_err(internal)?;
    conn.execute(
        &format!(
            "DELETE FROM file_grants WHERE hard_expires_ts <= {now} \
             OR last_used_ts < {};",
            now - GRANT_IDLE_S
        ),
        [],
    )
    .map_err(internal)?;
    Ok(())
}

/// `files.fetch{token, index}` — spend a grant: `R{kind, size}` then the §6.4
/// `D` stream. `kind` is what retires today's `is-directory` magic-string
/// retry — the server already knows which it is and declares it.
pub fn fetch(fields: &Fields, ctx: &Ctx) -> Result<Response, ProtoError> {
    let token = validate::token_hex("token", validate::required_text(fields, "token")?)?;
    let index = validate::decimal("index", validate::required_text(fields, "index")?)?;

    let store = open_store(ctx)?;
    let conn = store.conn();
    prune_grants(conn)?;
    let now = store::now_ts();

    // A live grant's path count first, so an out-of-range index on a valid
    // token is `bad-field` (§6.6) rather than indistinguishable from expiry.
    let count: i64 = conn
        .query_row(
            &format!(
                "SELECT COUNT(*) FROM file_grants WHERE token=?1 \
                 AND hard_expires_ts > {now} AND last_used_ts >= {};",
                now - GRANT_IDLE_S
            ),
            params![token],
            |row| row.get(0),
        )
        .map_err(internal)?;
    if count == 0 {
        return Err(
            ProtoError::new("unauthorized", "no grant matches that capability")
                .with("reason", "no-grant"),
        );
    }
    if index < 1 || index > count {
        return Err(validate::bad("index", "outside the grant's path count"));
    }
    let raw_path: Vec<u8> = conn
        .query_row(
            "SELECT path FROM file_grants WHERE token=?1 AND item_index=?2;",
            params![token, index],
            |row| row.get(0),
        )
        .map_err(internal)?;
    // Opening any item refreshes the whole manifest token's idle clock; the
    // hard expiry stands regardless.
    conn.execute(
        &format!(
            "UPDATE file_grants SET last_used_ts={now} WHERE token=?1 AND hard_expires_ts > {now};"
        ),
        params![token],
    )
    .map_err(internal)?;
    let Ok(path) = String::from_utf8(raw_path) else {
        return Err(ProtoError::new("internal", "grant path is not valid UTF-8"));
    };

    stream_path(&path)
}

/// O_NOFOLLOW: open and inspect the same descriptor — separate lstat/open
/// calls leave a symlink-swap gap, which is the zsh comment carried across.
#[cfg(target_os = "macos")]
const O_NOFOLLOW: i32 = 0x0100;
#[cfg(not(target_os = "macos"))]
const O_NOFOLLOW: i32 = 0o400000;

fn stream_path(path: &str) -> Result<Response, ProtoError> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(_) => {
            // A symlink is a refusal, not an absence — the authority snapshot
            // never held one, so one appearing since is a swap.
            return if std::fs::symlink_metadata(path)
                .map(|meta| meta.file_type().is_symlink())
                .unwrap_or(false)
            {
                Err(ProtoError::new("refused", "unsupported file type"))
            } else {
                Err(ProtoError::new("internal", "cannot read the granted path"))
            };
        }
    };
    let meta = file
        .metadata()
        .map_err(|_| ProtoError::new("internal", "cannot stat the granted path"))?;
    if meta.is_dir() {
        return stream_directory(path);
    }
    if !meta.is_file() {
        return Err(ProtoError::new("refused", "unsupported file type"));
    }
    let size = meta.len();
    Ok(Response::Stream {
        head: Fields::new()
            .with("kind", b"file".to_vec())
            .with("size", size.to_string().into_bytes()),
        source: Box::new(FileSource {
            file,
            remaining: size,
        }),
    })
}

struct FileSource {
    file: std::fs::File,
    remaining: u64,
}

impl StreamSource for FileSource {
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, ProtoError> {
        use std::io::Read;
        if self.remaining == 0 {
            return Ok(None);
        }
        let want = self.remaining.min(64 * 1024) as usize;
        let mut buf = vec![0u8; want];
        let got = self
            .file
            .read(&mut buf)
            .map_err(|e| ProtoError::new("internal", format!("read failed mid-stream: {e}")))?;
        if got == 0 {
            // Shorter than its own stat said: an error in place of the next
            // chunk, so the truncation is loud (§6.4).
            return Err(ProtoError::new("internal", "file shrank mid-stream"));
        }
        buf.truncate(got);
        self.remaining -= got as u64;
        Ok(Some(buf))
    }
}

fn stream_directory(path: &str) -> Result<Response, ProtoError> {
    // Pre-flight readability walk: an entry tar cannot open would otherwise
    // fail after the head is out. §10 narrows the report to a count — the
    // paths go nowhere, a peer must not get a filesystem probe one refusal at
    // a time.
    let unreadable = walk_unreadable(std::path::Path::new(path));
    if unreadable > 0 {
        return Err(ProtoError::new(
            "unreadable-entries",
            "entries inside the directory are unreadable",
        )
        .with("count", unreadable.to_string().into_bytes()));
    }

    // `du -sk` × 1024: the filesystem's own block accounting, an estimate for
    // progress display only, with no directional guarantee.
    let size = du_estimate(path);

    let path_buf = std::path::PathBuf::from(path);
    let parent = path_buf
        .parent()
        .unwrap_or_else(|| std::path::Path::new("/"));
    let base = path_buf
        .file_name()
        .ok_or_else(|| ProtoError::new("internal", "granted directory has no name"))?;
    let child = std::process::Command::new("tar")
        .arg("--no-xattrs")
        .arg("-cf")
        .arg("-")
        .arg("-C")
        .arg(parent)
        .arg("--")
        .arg(base)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| ProtoError::new("internal", format!("cannot start tar: {e}")))?;

    Ok(Response::Stream {
        head: Fields::new()
            .with("kind", b"directory".to_vec())
            .with("size", size.to_string().into_bytes()),
        source: Box::new(TarSource { child }),
    })
}

struct TarSource {
    child: std::process::Child,
}

impl StreamSource for TarSource {
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, ProtoError> {
        use std::io::Read;
        let Some(stdout) = self.child.stdout.as_mut() else {
            return Ok(None);
        };
        let mut buf = vec![0u8; 64 * 1024];
        let got = stdout
            .read(&mut buf)
            .map_err(|e| ProtoError::new("internal", format!("tar read failed: {e}")))?;
        if got > 0 {
            buf.truncate(got);
            return Ok(Some(buf));
        }
        // EOF: the archive is complete only if tar itself succeeded — this is
        // the mid-stream error channel today's raw-tar design lacked.
        let status = self
            .child
            .wait()
            .map_err(|e| ProtoError::new("internal", format!("tar did not exit: {e}")))?;
        if status.success() {
            Ok(None)
        } else {
            Err(ProtoError::new("internal", "tar failed mid-archive"))
        }
    }
}

impl Drop for TarSource {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Effective-access walk, the `[[ -r ]]`/`[[ -x ]]` shape: symlinks are
/// exempt (tar archives the link, never the target), a directory needs
/// read+search, a file needs read. Returns how many entries fail.
fn walk_unreadable(dir: &std::path::Path) -> usize {
    let mut unreadable = 0;
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return 1,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            unreadable += 1;
            continue;
        };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            unreadable += walk_unreadable(&path);
        } else if std::fs::File::open(&path).is_err() {
            unreadable += 1;
        }
    }
    unreadable
}

fn du_estimate(path: &str) -> u64 {
    let output = std::process::Command::new("du")
        .arg("-sk")
        .arg(path)
        .stderr(std::process::Stdio::null())
        .output();
    let Ok(output) = output else { return 0 };
    let text = String::from_utf8_lossy(&output.stdout);
    text.split_whitespace()
        .next()
        .and_then(|kb| kb.parse::<u64>().ok())
        .map_or(0, |kb| kb * 1024)
}
