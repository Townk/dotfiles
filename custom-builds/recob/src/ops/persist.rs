//! `store.persist.text` and `store.persist.files` — the P and M opcodes'
//! materialization paths, ported statement for statement from
//! `clipboard-store-core.zsh`. These are the two operations that write the
//! store *without* touching a pasteboard: a used peer clip is materialized
//! into this machine's store so it survives the origin going offline (§11 of
//! the clipboard project), and a files manifest is recorded where no watcher
//! could have captured it.

use rusqlite::params;

use crate::registry::Response;
use crate::session::Ctx;
use crate::store::{self, Store};
use crate::validate;
use crate::wire::{Fields, ProtoError};

/// The persist sweep's row cap — the zsh dispatcher's `MAX_ROWS`.
const MAX_ROWS: i64 = 1000;
/// The zsh `clip::preview_of` budget. 200, not the Lua watcher's 100: the two
/// writers genuinely differ here today and this op ports the zsh one.
const PREVIEW_MAX: usize = 200;

fn internal(e: impl std::fmt::Display) -> ProtoError {
    ProtoError::new("internal", format!("store write failed: {e}"))
}

fn open_store(ctx: &Ctx) -> Result<Store, ProtoError> {
    let host = ctx.host.current().unwrap_or_default();
    Store::open(&ctx.db_path, &host).map_err(internal)
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let mut hex = String::with_capacity(64);
    for byte in hasher.finalize() {
        use std::fmt::Write;
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

/// The zsh `clip::preview_of`: blank lines dropped, every other line trimmed
/// and joined with a single space, collection stopping once the 200-byte
/// budget is covered — whole lines, no mid-line truncation and no ellipsis
/// (both pickers truncate to their own column width at render time).
fn preview_of(text: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    let mut len = 0;
    for line in text.split('\n') {
        let trimmed =
            line.trim_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r'));
        if trimmed.is_empty() {
            continue;
        }
        parts.push(trimmed);
        len += trimmed.len() + 1;
        if len > PREVIEW_MAX {
            break;
        }
    }
    parts.join(" ")
}

/// `store.persist.text{host, kind, app, regtype, text}` — replaces `P`.
pub fn persist_text(fields: &Fields, ctx: &Ctx) -> Result<Response, ProtoError> {
    let host = validate::host_shaped("host", validate::required_text(fields, "host")?)?;
    let kind = validate::one_of(
        "kind",
        validate::required_text(fields, "kind")?,
        &["text", "files", "file", "directory"],
    )?;
    let app = validate::required_text(fields, "app")?;
    validate::app_shaped("app", app)?;
    // §6.6 is strict here where the zsh silently stored NULL for anything
    // outside v|l|b; the closed enum is the spec's posture and Phase 5's
    // clients always know the register type they are persisting.
    let regtype = validate::one_of(
        "regtype",
        validate::required_text(fields, "regtype")?,
        &["v", "l", "b"],
    )?;
    let text = validate::required(fields, "text")?;

    // The zsh handler's own policy line, kept as a refusal rather than widened:
    // file kinds are persisted through `store.persist.files`, which knows what
    // a manifest row needs.
    if kind != "text" {
        return Err(ProtoError::new(
            "refused",
            "store.persist.text cannot persist file kinds",
        ));
    }

    let store = open_store(ctx)?;
    let conn = store.conn();
    let hash = sha256_hex(text);
    let now = store::now_ts();
    let text_str = String::from_utf8_lossy(text);

    // Dedup scoped by (source_host, hash, kind) — a files manifest of the same
    // text hashes identically to plain text, hence the kind scope.
    let existing: Option<i64> = conn
        .query_row(
            "SELECT id FROM clips WHERE source_host=?1 AND type_hash=?2 AND type_kind=?3 LIMIT 1;",
            params![host, hash, kind],
            |row| row.get(0),
        )
        .optional_err()?;
    match existing {
        Some(id) => {
            conn.execute("UPDATE clips SET last_ts=?1 WHERE id=?2;", params![now, id])
                .map_err(internal)?;
        }
        None => {
            conn.execute(
                "INSERT INTO clips (text_preview, text_plain, len, first_ts, last_ts, \
                 source_app, type_kind, regtype, pinned, type_hash, source_host) \
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,0,?9,?10);",
                params![
                    preview_of(&text_str),
                    text_str,
                    text.len() as i64,
                    now,
                    now,
                    app,
                    kind,
                    regtype,
                    hash,
                    host
                ],
            )
            .map_err(internal)?;
            sweep(conn)?;
        }
    }
    Ok(Fields::new().into())
}

/// The persist ops' bounded sweep — the zsh shape, which orders by
/// `pinned DESC, last_ts DESC` rather than the watcher's oldest-unpinned scan.
fn sweep(conn: &rusqlite::Connection) -> Result<(), ProtoError> {
    conn.execute(
        &format!(
            "DELETE FROM clips WHERE pinned=0 AND id NOT IN \
             (SELECT id FROM clips ORDER BY pinned DESC, last_ts DESC LIMIT {MAX_ROWS});"
        ),
        [],
    )
    .map_err(internal)?;
    conn.execute(
        "DELETE FROM clip_types WHERE clip_id NOT IN (SELECT id FROM clips);",
        [],
    )
    .map_err(internal)?;
    Ok(())
}

/// `store.persist.files{host, paths}` — replaces `M`, record-only: no
/// pasteboard write and no origin declaration. §9.3's `mints_authority:
/// local` is evaluated against the *endpoint*, never the caller-supplied
/// host: a trusted call may authorize self-host paths, a public one produces
/// a pointer row that cannot mint file authority.
pub fn persist_files(fields: &Fields, trusted: bool, ctx: &Ctx) -> Result<Response, ProtoError> {
    let host = validate::host_shaped("host", validate::required_text(fields, "host")?)?;
    let paths = validate::nul_paths("paths", validate::required(fields, "paths")?)?;

    let self_host = ctx.host.current().unwrap_or_default();
    if trusted {
        if host != self_host {
            return Err(ProtoError::new(
                "refused",
                "source host does not match this machine",
            ));
        }
    } else if !self_host.is_empty() && host == self_host {
        return Err(ProtoError::new(
            "refused",
            "a public persist cannot claim this machine",
        ));
    }

    let store = open_store(ctx)?;
    persist_files_row(&store, host, &paths, trusted)?;

    // Mount enrichment, after the row stands (macOS): when this Mac holds a
    // healthy rclone mount of `host`, the pasteboard additionally gets
    // mount-relative file URLs so Cmd+V in Finder is a native copy. The spec
    // does not mention this M behavior either way; dropping it silently at
    // cutover would regress a validated feature, so it is carried across and
    // the gap is reported with this phase. Detached: a wedged FUSE stat can
    // never hang the handler, and every failure just leaves the lazy row.
    #[cfg(target_os = "macos")]
    enrich::spawn(ctx, host.to_string(), self_host, paths);

    Ok(Fields::new().into())
}

/// The manifest-row core, shared with `clip.set.files`' Linux half — where
/// there is no pasteboard, the row *is* the clip. Returns the row id.
pub(crate) fn persist_files_row(
    store: &Store,
    host: &str,
    paths: &[String],
    trusted: bool,
) -> Result<i64, ProtoError> {
    let joined = paths.join("\n");
    let manifest = paths.join("\0");
    let hash = sha256_hex(joined.as_bytes());
    let now = store::now_ts();

    let row_id = {
        let conn = store.conn();
        // Dedup additionally scoped by whether the row holds authority, so a
        // trusted self row and a public pointer row for the same manifest never
        // collapse into each other.
        let predicate = if trusted {
            "EXISTS (SELECT 1 FROM file_authorities fa WHERE fa.clip_id=clips.id)"
        } else {
            "NOT EXISTS (SELECT 1 FROM file_authorities fa WHERE fa.clip_id=clips.id)"
        };
        let existing: Option<i64> = conn
            .query_row(
                &format!(
                    "SELECT id FROM clips WHERE source_host=?1 AND type_hash=?2 \
                     AND type_kind='files' AND {predicate} LIMIT 1;"
                ),
                params![host, hash],
                |row| row.get(0),
            )
            .optional_err()?;
        match existing {
            Some(id) => {
                conn.execute("UPDATE clips SET last_ts=?1 WHERE id=?2;", params![now, id])
                    .map_err(internal)?;
                id
            }
            None => {
                conn.execute(
                    "INSERT INTO clips (text_preview, len, first_ts, last_ts, type_kind, \
                     pinned, type_hash, source_host) VALUES (?1,?2,?3,?4,'files',0,?5,?6);",
                    params![joined, joined.len() as i64, now, now, hash, host],
                )
                .map_err(internal)?;
                conn.last_insert_rowid()
            }
        }
    };
    store
        .conn()
        .execute(
            "INSERT OR REPLACE INTO clip_types (clip_id, uti, blob) VALUES (?1,'x-file-manifest',?2);",
            params![row_id, manifest.as_bytes()],
        )
        .map_err(internal)?;

    if trusted {
        replace_file_authority_strict(store.conn(), row_id, paths)?;
    }
    sweep(store.conn())?;
    store
        .conn()
        .execute(
            &format!(
                "DELETE FROM file_grants WHERE hard_expires_ts <= {now} \
                 OR last_used_ts < {};",
                now - 1800.0
            ),
            [],
        )
        .map_err(internal)?;
    store
        .conn()
        .execute(
            "DELETE FROM file_authorities WHERE clip_id NOT IN (SELECT id FROM clips);",
            [],
        )
        .map_err(internal)?;
    Ok(row_id)
}

/// The strict authority validation the persist path applies — beyond §6.6's
/// path shape, each element must be a real, non-symlink file or directory
/// (`clip::replace_file_authority`). A refusal fails the operation; the row
/// stands without authority, exactly as the zsh behaves.
fn replace_file_authority_strict(
    conn: &rusqlite::Connection,
    clip_id: i64,
    paths: &[String],
) -> Result<(), ProtoError> {
    for path in paths {
        let meta = std::fs::symlink_metadata(path)
            .map_err(|_| ProtoError::new("refused", "unsupported authority path type"))?;
        if meta.file_type().is_symlink() || !(meta.is_file() || meta.is_dir()) {
            return Err(ProtoError::new(
                "refused",
                "unsupported authority path type",
            ));
        }
    }
    conn.execute(
        "DELETE FROM file_authorities WHERE clip_id=?1;",
        params![clip_id],
    )
    .map_err(internal)?;
    for (index, path) in paths.iter().enumerate() {
        conn.execute(
            "INSERT INTO file_authorities (clip_id,item_index,path) VALUES (?1,?2,?3);",
            params![clip_id, index as i64 + 1, path.as_bytes()],
        )
        .map_err(internal)?;
    }
    Ok(())
}

/// A small adapter so `query_row(...).optional()` failures all map to
/// `internal` without repeating the plumbing.
trait OptionalErr<T> {
    fn optional_err(self) -> Result<Option<T>, ProtoError>;
}

impl<T> OptionalErr<T> for Result<T, rusqlite::Error> {
    fn optional_err(self) -> Result<Option<T>, ProtoError> {
        use rusqlite::OptionalExtension;
        self.optional().map_err(internal)
    }
}

#[cfg(target_os = "macos")]
mod enrich {
    //! The mount-aware half of the M path (`clip::mount_enrich`), natively:
    //! no `hs` spawn — the changeCount guard and the marker-bearing write are
    //! the daemon's own pasteboard calls, which closes the multi-second guard
    //! gap the two-process version had.

    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::Duration;

    use crate::ops::run_with_deadline;
    use crate::platform::macos::{filenames_plist, url_encode, Pasteboard};
    use crate::session::Ctx;

    pub fn spawn(ctx: &Ctx, host: String, self_host: String, paths: Vec<String>) {
        let mount_bin = ctx.tools.clipboard_mount.clone();
        // The pasteboard seam rides into the thread: an enrichment running
        // under a test daemon must write the test's private pasteboard, never
        // the general one — the same rule every other pasteboard path obeys.
        let pasteboard_name = ctx.pasteboard_name.clone();
        let _ = std::thread::Builder::new()
            .name("enrich".to_string())
            .spawn(move || run(&mount_bin, &pasteboard_name, &host, &self_host, &paths));
    }

    fn run(
        mount_bin: &PathBuf,
        pasteboard_name: &Option<String>,
        host: &str,
        self_host: &str,
        paths: &[String],
    ) {
        crate::log!("enrich: {host}: {} path(s)", paths.len());
        let open = || match pasteboard_name {
            Some(name) => Pasteboard::with_name(name),
            None => Pasteboard::general(),
        };
        if !mount_bin.is_file() {
            return;
        }
        // Enriching a manifest whose source is this machine would mount
        // ourselves over SFTP; the trusted leg always matches here and bails.
        if host == self_host {
            return;
        }
        // The guard token: a change between here and the write means a newer
        // user copy, which must not be overwritten.
        let cc = open().change_count();

        let mount_point = match check(mount_bin, host) {
            Some(mp) => Some(mp),
            None => {
                // Self-heal: a remount takes seconds and sessions ride a
                // long-lived ControlMaster, so a mid-session teardown would
                // otherwise leave every copy lazy until a fresh connection.
                let mut ensure = Command::new(mount_bin);
                ensure.arg("ensure").arg(host);
                let _ = run_with_deadline(ensure, Duration::from_secs(30));
                check(mount_bin, host)
            }
        };
        let Some(mount_point) = mount_point else {
            crate::log!("enrich: {host}: no healthy mount; staying lazy");
            return;
        };
        let mapped: Vec<String> = paths
            .iter()
            .map(|path| format!("{mount_point}{path}"))
            .collect();
        if !std::path::Path::new(&mapped[0]).exists() {
            crate::log!("enrich: {host}: mapped path missing: {}", mapped[0]);
            return;
        }

        let pasteboard = open();
        let cc_now = pasteboard.change_count();
        if cc_now != cc {
            crate::log!("enrich: {host}: pasteboard moved ({cc} -> {cc_now}); yielding");
            return;
        }
        let mut data = BTreeMap::new();
        data.insert(
            "NSFilenamesPboardType".to_string(),
            filenames_plist(&mapped),
        );
        data.insert(
            "public.file-url".to_string(),
            format!("file://{}", url_encode(&mapped[0])).into_bytes(),
        );
        // Change-bound provenance: the marker travels in the exact pasteboard
        // change the capture path observes, so a public pointer row can never
        // become local file authority (§14.2's sensitive-UTI refusal).
        data.insert(
            "org.chezmoi.clipboard.UntrustedFileURLs".to_string(),
            b"1".to_vec(),
        );
        pasteboard.write_all(&data);
    }

    fn check(mount_bin: &PathBuf, host: &str) -> Option<String> {
        let mut command = Command::new(mount_bin);
        command.arg("check").arg(host);
        let run = run_with_deadline(command, Duration::from_secs(10)).ok()?;
        if !run.ok {
            return None;
        }
        let out = String::from_utf8_lossy(&run.stdout).trim().to_string();
        if out.is_empty() {
            None
        } else {
            Some(out)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_persist_preview_keeps_whole_lines_inside_the_zsh_budget() {
        assert_eq!(preview_of("  a  \n\n b\n"), "a b");
        let long = format!("{}\nsecond", "x".repeat(250));
        // The first line alone exceeds the budget; collection stops after it,
        // whole, with no ellipsis.
        assert_eq!(preview_of(&long), "x".repeat(250));
    }

    #[test]
    fn sha256_hex_matches_the_shell_formula() {
        // printf 'abc' | shasum -a 256
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
