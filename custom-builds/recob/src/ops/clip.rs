//! The `clip.*` operations — the pasteboard half of the bridge, and §6.2's
//! largest collapse: the daemon writes the pasteboard *and* the store row in
//! one operation, so provenance is a field instead of a message left in a
//! file for a stranger, and the origin-file apparatus has nothing left to do.
//!
//! On macOS every write records itself on the regtype tracker (§14.6) and on
//! the shared last-`changeCount`, which is how the observation loop knows an
//! echo from a copy (§6.2) and how `clip.get` answers the register type with
//! no sidecar file. §14.7: on Linux there is no pasteboard — the store row is
//! the clip, exactly as the headless zsh backend behaved.

use std::collections::BTreeMap;

use rusqlite::{params, OptionalExtension};

use crate::capture::{self, FrontmostApp};
use crate::registry::Response;
use crate::session::{Ctx, RICH_BLOB_CAP};
use crate::store::{self, Store};
use crate::validate;
use crate::wire::{Fields, ProtoError};

fn internal(e: impl std::fmt::Display) -> ProtoError {
    ProtoError::new("internal", format!("store access failed: {e}"))
}

fn open_store(ctx: &Ctx) -> Result<Store, ProtoError> {
    let host = ctx.host.current().unwrap_or_default();
    Store::open(&ctx.db_path, &host).map_err(internal)
}

fn no_row() -> ProtoError {
    ProtoError::new("not-found", "no such clip").with("reason", "no-row")
}

/// The row host and locality for a write carrying its own provenance: the
/// declared `origin_host` when present, this machine otherwise. Local means
/// "may mint file authority" (§14.2) — a remote-origin row never does.
fn provenance(ctx: &Ctx, origin_host: Option<&str>) -> (String, bool) {
    let self_host = ctx.host.current().unwrap_or_default();
    match origin_host {
        Some(host) if host != self_host => (host.to_string(), false),
        _ => (self_host, true),
    }
}

/// `clip.get` — everything about the current clip in one exchange (§6.2):
/// text, register type, the store's `last_ts` for it, and this machine's
/// identity.
pub fn get(ctx: &Ctx) -> Result<Response, ProtoError> {
    let store = open_store(ctx)?;
    let (text, regtype) = current_text_and_regtype(ctx, &store)?;
    let timestamp = current_timestamp(&store, &text)?;
    Ok(Fields::new()
        .with("text", text)
        .with("regtype", regtype.into_bytes())
        .with("timestamp", timestamp.into_bytes())
        .with("host", ctx.host.current().unwrap_or_default().into_bytes())
        .into())
}

#[cfg(target_os = "macos")]
fn current_text_and_regtype(ctx: &Ctx, _store: &Store) -> Result<(Vec<u8>, String), ProtoError> {
    let pasteboard = pasteboard(ctx);
    let change_count = pasteboard.change_count();
    let snapshot = pasteboard.snapshot(None);
    let text = [
        "public.utf8-plain-text",
        "public.text",
        "NSStringPboardType",
    ]
    .iter()
    .find_map(|uti| snapshot.data.get(*uti).cloned())
    .unwrap_or_default();
    // §14.6: the daemon's own record while the counts still match, else the
    // trailing-newline heuristic — same two cases the sidecar file served,
    // with the hash comparison replaced by the change the daemon observes
    // directly.
    let regtype = match ctx.tracker.regtype_at(change_count) {
        Some(regtype) => regtype,
        None => heuristic_regtype(&text),
    };
    Ok((text, regtype))
}

#[cfg(not(target_os = "macos"))]
fn current_text_and_regtype(_ctx: &Ctx, store: &Store) -> Result<(Vec<u8>, String), ProtoError> {
    // The store is the pasteboard: the newest row's text, its regtype when it
    // is a real one, the heuristic otherwise.
    let row: Option<(Vec<u8>, Option<String>)> = store
        .conn()
        .query_row(
            "SELECT CAST(COALESCE(text_plain, text_preview, '') AS BLOB), regtype \
             FROM clips ORDER BY last_ts DESC LIMIT 1;",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(internal)?;
    let (text, regtype) = row.unwrap_or_default();
    let regtype = match regtype.as_deref() {
        Some(rt @ ("v" | "l" | "b")) => rt.to_string(),
        _ => heuristic_regtype(&text),
    };
    Ok((text, regtype))
}

fn heuristic_regtype(text: &[u8]) -> String {
    if text.last() == Some(&b'\n') {
        "l".to_string()
    } else {
        "v".to_string()
    }
}

/// `clip.get`'s `timestamp` (§6.1): content-matched against the store on
/// macOS, the newest row on Linux — the platform divergence is carried
/// through unchanged and documented as the weaker meaning.
fn current_timestamp(store: &Store, text: &[u8]) -> Result<String, ProtoError> {
    let conn = store.conn();
    let matched: Option<f64> = if cfg!(target_os = "macos") {
        conn.query_row(
            "SELECT last_ts FROM clips WHERE rtrim(text_plain, char(10)) = \
             rtrim(CAST(?1 AS TEXT), char(10)) ORDER BY last_ts DESC LIMIT 1;",
            params![text],
            |row| row.get(0),
        )
        .optional()
        .map_err(internal)?
    } else {
        None
    };
    let ts: Option<f64> = match matched {
        Some(ts) => Some(ts),
        None => conn
            .query_row("SELECT MAX(last_ts) FROM clips;", [], |row| row.get(0))
            .optional()
            .map_err(internal)?
            .flatten(),
    };
    Ok(ts.map(|ts| format!("{ts}")).unwrap_or_default())
}

/// `clip.set{text, regtype, origin_host?, app?}` — replaces `T` + `O`: the
/// pasteboard write and the store row happen in the same operation, and the
/// observation loop skips the echo by `changeCount` (§6.2).
pub fn set(fields: &Fields, ctx: &Ctx) -> Result<Response, ProtoError> {
    let text = validate::required(fields, "text")?.to_vec();
    let regtype = validate::one_of(
        "regtype",
        validate::required_text(fields, "regtype")?,
        &["v", "l", "b"],
    )?
    .to_string();
    let origin_host = match validate::optional_text(fields, "origin_host")? {
        Some(host) => Some(validate::host_shaped("origin_host", host)?),
        None => None,
    };
    let app = validate::optional_text(fields, "app")?.unwrap_or("");
    validate::app_shaped("app", app)?;
    let (row_host, local) = provenance(ctx, origin_host);

    let mut data = BTreeMap::new();
    data.insert("public.utf8-plain-text".to_string(), text);

    #[cfg(target_os = "macos")]
    {
        let pb = write_and_record(ctx, &data, Some(regtype.clone()));
        write_row_direct(ctx, &pb, app, &row_host, local, Some(&regtype))?;
    }
    #[cfg(not(target_os = "macos"))]
    {
        // No pasteboard: the row is the clip, in the zsh Linux backend's own
        // format — sha256(text), kind-scoped dedup (`clip::op_set` via
        // `persist_text_row`) — so dedup continuity with existing rows holds.
        linux_persist_text(
            ctx,
            &row_host,
            app,
            &regtype,
            data.get("public.utf8-plain-text").unwrap(),
        )?;
    }
    Ok(Fields::new().into())
}

/// `clip.set.rich{uti, blob, origin_host?}` — replaces `C`. The §9.3
/// `uti_allow` split: any UTI on the trusted socket, the seven-UTI set on the
/// public endpoint, and a refusal is `refused`, not a shape error.
pub fn set_rich(fields: &Fields, public: bool, ctx: &Ctx) -> Result<Response, ProtoError> {
    const PUBLIC_UTIS: &[&str] = &[
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.utf8-plain-text",
        "com.adobe.pdf",
        "com.compuserve.gif",
        "org.webmproject.webp",
    ];
    let uti = validate::required_text(fields, "uti")?.to_string();
    if uti.is_empty() {
        return Err(validate::bad("uti", "empty"));
    }
    let blob = validate::required(fields, "blob")?;
    if blob.len() > RICH_BLOB_CAP {
        return Err(
            ProtoError::new("file-too-large", "the blob exceeds clip.set.rich's cap")
                .with("size", blob.len().to_string().into_bytes()),
        );
    }
    if public && !PUBLIC_UTIS.contains(&uti.as_str()) {
        return Err(ProtoError::new(
            "refused",
            "rich type not allowed on the public endpoint",
        ));
    }
    let origin_host = match validate::optional_text(fields, "origin_host")? {
        Some(host) => Some(validate::host_shaped("origin_host", host)?),
        None => None,
    };
    let (row_host, local) = provenance(ctx, origin_host);

    let mut data = BTreeMap::new();
    data.insert(uti.clone(), blob.to_vec());

    #[cfg(target_os = "macos")]
    {
        let pb = write_and_record(ctx, &data, None);
        write_row_direct(ctx, &pb, "", &row_host, local, None)?;
    }
    #[cfg(not(target_os = "macos"))]
    linux_persist_rich(ctx, &row_host, &uti, blob)?;
    Ok(Fields::new().into())
}

/// `clip.set.files{paths | clip_id}` — replaces `U`, tier `local`. Exactly
/// one of the two fields; `clip_id` is the bare decimal rowid (the `id:`
/// prefix existed only to disambiguate a positional payload).
pub fn set_files(fields: &Fields, ctx: &Ctx) -> Result<Response, ProtoError> {
    match (fields.get("paths"), fields.get("clip_id")) {
        (Some(_), Some(_)) | (None, None) => Err(ProtoError::new(
            "bad-request",
            "exactly one of paths or clip_id",
        )),
        (Some(raw), None) => {
            let paths = validate::nul_paths("paths", raw)?;
            set_files_paths(ctx, &paths)
        }
        (None, Some(_)) => {
            let clip_id =
                validate::decimal("clip_id", validate::required_text(fields, "clip_id")?)?;
            // Form B is a full-fidelity restore of a stored clip by rowid —
            // the same behavior as clip.restore's default path (§14.5).
            restore_by_id(ctx, clip_id, false)
        }
    }
}

#[cfg(target_os = "macos")]
fn set_files_paths(ctx: &Ctx, paths: &[String]) -> Result<Response, ProtoError> {
    use crate::platform::macos::{filenames_plist, url_encode};
    let mut data = BTreeMap::new();
    data.insert("NSFilenamesPboardType".to_string(), filenames_plist(paths));
    data.insert(
        "public.file-url".to_string(),
        format!("file://{}", url_encode(&paths[0])).into_bytes(),
    );
    let pb = write_and_record(ctx, &data, None);
    // The row through the post-write snapshot, like every direct write — the
    // real plist parse and the single-path file/directory refinement included,
    // and the authority snapshot a local files capture mints.
    let (row_host, local) = provenance(ctx, None);
    write_row_direct(ctx, &pb, "", &row_host, local, None)?;
    Ok(Fields::new().into())
}

#[cfg(not(target_os = "macos"))]
fn set_files_paths(ctx: &Ctx, paths: &[String]) -> Result<Response, ProtoError> {
    // No pasteboard to write: the manifest row is the clip, with authority —
    // the zsh Linux backend's own `U` form A.
    let store = open_store(ctx)?;
    let (row_host, _) = provenance(ctx, None);
    crate::ops::persist::persist_files_row(&store, &row_host, paths, true)?;
    Ok(Fields::new().into())
}

/// `clip.restore{clip_id, plain_only?}` — §14.5: the picker's restore, as an
/// operation, across every clip kind.
pub fn restore(fields: &Fields, ctx: &Ctx) -> Result<Response, ProtoError> {
    let clip_id = validate::decimal("clip_id", validate::required_text(fields, "clip_id")?)?;
    let plain_only = fields.get("plain_only").is_some();
    restore_by_id(ctx, clip_id, plain_only)
}

#[cfg(target_os = "macos")]
fn restore_by_id(ctx: &Ctx, clip_id: i64, plain_only: bool) -> Result<Response, ProtoError> {
    let store = open_store(ctx)?;
    let conn = store.conn();
    let row: Option<(String, Option<String>, Option<String>)> = conn
        .query_row(
            "SELECT type_kind, regtype, text_plain FROM clips WHERE id=?1;",
            params![clip_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(internal)?;
    let Some((kind, regtype, text_plain)) = row else {
        return Err(no_row());
    };
    let mut types: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut stmt = conn
        .prepare("SELECT uti, blob FROM clip_types WHERE clip_id=?1;")
        .map_err(internal)?;
    let rows = stmt
        .query_map(params![clip_id], |row| Ok((row.get(0)?, row.get(1)?)))
        .map_err(internal)?;
    for entry in rows {
        let (uti, blob): (String, Vec<u8>) = entry.map_err(internal)?;
        types.insert(uti, blob);
    }

    if plain_only {
        return restore_plain(ctx, &store, clip_id, &kind, text_plain.as_deref(), &types);
    }

    // The default path: the full stored representation set, atomically, with
    // the row's register type reinstated through the tracker (§14.6) — the
    // write is attributed with no marker and no capture, because the daemon
    // performed it (§14.5).
    if types.is_empty() {
        let Some(plain) = text_plain else {
            return Err(no_row());
        };
        let mut data = BTreeMap::new();
        data.insert("public.utf8-plain-text".to_string(), plain.into_bytes());
        let reinstate = regtype.filter(|rt| matches!(rt.as_str(), "v" | "l" | "b"));
        write_and_record(ctx, &data, reinstate);
    } else {
        let reinstate = regtype.filter(|rt| matches!(rt.as_str(), "v" | "l" | "b"));
        write_and_record(ctx, &types, reinstate);
    }
    bump_last_ts(&store, clip_id)?;
    Ok(Fields::new().into())
}

/// §14.5's `plain_only`: a degrade-to-something-pasteable path with three
/// branches, none of which reinstates the register type — a degraded restore
/// is not the register the original clip had.
#[cfg(target_os = "macos")]
fn restore_plain(
    ctx: &Ctx,
    store: &Store,
    clip_id: i64,
    kind: &str,
    text_plain: Option<&str>,
    types: &BTreeMap<String, Vec<u8>>,
) -> Result<Response, ProtoError> {
    use crate::platform::macos::{attributed_to_text, RichDoc};

    // Branch 1: a markdown link for the kinds with no useful plain form. If
    // there is nothing to link to it FALLS THROUGH — a documented soft path,
    // not a hard error.
    if matches!(kind, "file" | "directory" | "url" | "image") {
        if let Some(link) = markdown_link(kind, text_plain, types) {
            write_text(ctx, link.into_bytes());
            bump_last_ts(store, clip_id)?;
            return Ok(Fields::new().into());
        }
    }
    // Branch 2: the plain representation.
    if let Some(plain) = text_plain.filter(|plain| !plain.is_empty()) {
        write_text(ctx, plain.as_bytes().to_vec());
        bump_last_ts(store, clip_id)?;
        return Ok(Fields::new().into());
    }
    // Branch 3: derive text from the rich payloads, HTML → RTF → RTFD — the
    // WebKit-backed importer the attrstr probe verified works headless.
    let derived = types
        .get("public.html")
        .and_then(|blob| attributed_to_text(blob, RichDoc::Html))
        .or_else(|| {
            types
                .get("public.rtf")
                .and_then(|blob| attributed_to_text(blob, RichDoc::Rtf))
        })
        .or_else(|| {
            types
                .get("NeXT RTFD pasteboard type")
                .or_else(|| types.get("Apple RTFD pasteboard type"))
                .and_then(|blob| attributed_to_text(blob, RichDoc::Rtfd))
        })
        .filter(|text| !text.is_empty());
    match derived {
        Some(text) => {
            write_text(ctx, text.into_bytes());
            bump_last_ts(store, clip_id)?;
            Ok(Fields::new().into())
        }
        // Every branch exhausted: a property of the data, not a fault (§14.5).
        None => Err(no_row()),
    }
}

/// The Alt+Enter linkification (`markdown_link_for`): a data-URI image, the
/// URL itself, or the resolved path as a `file://` link.
#[cfg(target_os = "macos")]
fn markdown_link(
    kind: &str,
    text_plain: Option<&str>,
    types: &BTreeMap<String, Vec<u8>>,
) -> Option<String> {
    use crate::platform::macos::url_encode;
    match kind {
        "url" => {
            let url = text_plain.filter(|url| !url.is_empty())?;
            Some(format!("[{url}]({url})"))
        }
        "image" => {
            const IMAGE_UTIS: &[(&str, &str)] = &[
                ("public.png", "image/png"),
                ("public.jpeg", "image/jpeg"),
                ("public.tiff", "image/tiff"),
                ("com.compuserve.gif", "image/gif"),
            ];
            for (uti, mime) in IMAGE_UTIS {
                if let Some(blob) = types.get(*uti) {
                    return Some(format!("![](data:{mime};base64,{})", base64(blob)));
                }
            }
            None
        }
        _ => {
            let path = types.get("x-resolved-path")?;
            let path = std::str::from_utf8(path).ok()?;
            let basename = path.trim_end_matches('/').rsplit('/').next()?;
            // Each segment encoded on its own, so the separators survive.
            let encoded: Vec<String> = path
                .split('/')
                .filter(|segment| !segment.is_empty())
                .map(|segment| {
                    url_encode(segment).replace('/', "%2F") // defensive; segments hold none
                })
                .collect();
            Some(format!("[{basename}](file:///{})", encoded.join("/")))
        }
    }
}

/// Plain base64, RFC 4648 — a dozen lines against pulling a dependency for
/// one call site.
#[cfg(target_os = "macos")]
fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(not(target_os = "macos"))]
fn restore_by_id(ctx: &Ctx, clip_id: i64, _plain_only: bool) -> Result<Response, ProtoError> {
    // No pasteboard: a restore is purely a recency fact, exactly as the zsh
    // Linux backend treated `U` form B.
    let store = open_store(ctx)?;
    let found: Option<i64> = store
        .conn()
        .query_row(
            "SELECT id FROM clips WHERE id=?1;",
            params![clip_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(internal)?;
    if found.is_none() {
        return Err(no_row());
    }
    bump_last_ts(&store, clip_id)?;
    Ok(Fields::new().into())
}

fn bump_last_ts(store: &Store, clip_id: i64) -> Result<(), ProtoError> {
    store
        .conn()
        .execute(
            "UPDATE clips SET last_ts=?1 WHERE id=?2;",
            params![store::now_ts(), clip_id],
        )
        .map_err(internal)?;
    Ok(())
}

/// The macOS write path shared by every clip.set variant: the atomic
/// pasteboard write, the §14.6 record, and the shared changeCount so neither
/// the observation loop nor a §6.5 sync capture re-captures the daemon's own
/// write. Hands the pasteboard back for the post-write row snapshot.
#[cfg(target_os = "macos")]
fn write_and_record(
    ctx: &Ctx,
    data: &BTreeMap<String, Vec<u8>>,
    regtype: Option<String>,
) -> crate::platform::macos::Pasteboard {
    let pb = pasteboard(ctx);
    let change_count = pb.write_all(data);
    ctx.tracker.record(change_count, regtype);
    *ctx.last_cc.lock().unwrap() = Some(change_count);
    pb
}

#[cfg(target_os = "macos")]
fn write_text(ctx: &Ctx, text: Vec<u8>) {
    let mut data = BTreeMap::new();
    data.insert("public.utf8-plain-text".to_string(), text);
    write_and_record(ctx, &data, None);
}

#[cfg(target_os = "macos")]
fn pasteboard(ctx: &Ctx) -> crate::platform::macos::Pasteboard {
    use crate::platform::macos::Pasteboard;
    match &ctx.pasteboard_name {
        Some(name) => Pasteboard::with_name(name),
        None => Pasteboard::general(),
    }
}

/// The row for a direct write, built from a snapshot of the pasteboard the
/// write just produced rather than from the request fields. That distinction
/// is load-bearing for dedup: the pasteboard advertises synonym types beyond
/// what was written (`NSStringPboardType` beside `public.utf8-plain-text`),
/// and a later *observation* of an identical physical copy hashes the full
/// advertised set — so the written row must too, or the same bytes stop
/// deduping. The content refusals hold (a refusal leaves the pasteboard
/// written and no row, exactly as the watcher refused the same content), the
/// GUI guards do not, and `source_app` is the caller's declaration.
#[cfg(target_os = "macos")]
fn write_row_direct(
    ctx: &Ctx,
    pb: &crate::platform::macos::Pasteboard,
    app: &str,
    row_host: &str,
    local: bool,
    regtype: Option<&str>,
) -> Result<(), ProtoError> {
    let snapshot = pb.snapshot(Some(FrontmostApp {
        name: app.to_string(),
        bundle_id: None,
    }));
    if let Ok(capture) = capture::decide_direct(&snapshot) {
        let mut store = open_store(ctx)?;
        let id = store
            .write_capture(&capture, row_host, local, store::now_ts())
            .map_err(internal)?;
        if let Some(regtype) = regtype {
            store
                .conn()
                .execute(
                    "UPDATE clips SET regtype=?1 WHERE id=?2;",
                    params![regtype, id],
                )
                .map_err(internal)?;
        }
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn linux_persist_text(
    ctx: &Ctx,
    host: &str,
    app: &str,
    regtype: &str,
    text: &[u8],
) -> Result<(), ProtoError> {
    // The zsh Linux `clip::op_set` shape via the shared persist core: kind
    // text, sha256(text), regtype in the row.
    let request = Fields::new()
        .with("host", host.as_bytes())
        .with("kind", b"text".to_vec())
        .with("app", app.as_bytes())
        .with("regtype", regtype.as_bytes())
        .with("text", text.to_vec());
    crate::ops::persist::persist_text(&request, ctx).map(|_| ())
}

#[cfg(not(target_os = "macos"))]
fn linux_persist_rich(ctx: &Ctx, host: &str, uti: &str, blob: &[u8]) -> Result<(), ProtoError> {
    use sha2::{Digest, Sha256};
    // The zsh Linux `clip::op_copy`: kind from the UTI, sha256(blob), the
    // plain-text UTI additionally populating text_plain/preview so clip.get
    // keeps working on rich text clips.
    let kind = match uti {
        "public.utf8-plain-text" => "text",
        "public.png" | "public.tiff" => "image",
        _ => "mixed",
    };
    let mut hasher = Sha256::new();
    hasher.update(blob);
    let hash: String = hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let store = open_store(ctx)?;
    let conn = store.conn();
    let now = store::now_ts();
    let existing: Option<i64> = conn
        .query_row(
            "SELECT id FROM clips WHERE source_host=?1 AND type_hash=?2 AND type_kind=?3 LIMIT 1;",
            params![host, hash, kind],
            |row| row.get(0),
        )
        .optional()
        .map_err(internal)?;
    let row_id = match existing {
        Some(id) => {
            conn.execute("UPDATE clips SET last_ts=?1 WHERE id=?2;", params![now, id])
                .map_err(internal)?;
            id
        }
        None => {
            let (preview, plain): (Option<String>, Option<String>) = if kind == "text" {
                let text = String::from_utf8_lossy(blob).into_owned();
                (Some(linux_preview(&text)), Some(text))
            } else {
                (None, None)
            };
            conn.execute(
                "INSERT INTO clips (text_preview, text_plain, len, first_ts, last_ts, \
                 type_kind, pinned, type_hash, source_host) VALUES (?1,?2,?3,?4,?5,?6,0,?7,?8);",
                params![
                    preview,
                    plain,
                    blob.len() as i64,
                    now,
                    now,
                    kind,
                    hash,
                    host
                ],
            )
            .map_err(internal)?;
            conn.last_insert_rowid()
        }
    };
    conn.execute(
        "INSERT OR REPLACE INTO clip_types (clip_id, uti, blob) VALUES (?1,?2,?3);",
        params![row_id, uti, blob],
    )
    .map_err(internal)?;
    conn.execute(
        &format!(
            "DELETE FROM clips WHERE pinned=0 AND id NOT IN \
             (SELECT id FROM clips ORDER BY pinned DESC, last_ts DESC LIMIT 1000);"
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

/// The store-wide single-line preview invariant, for the Linux rich path.
#[cfg(not(target_os = "macos"))]
fn linux_preview(text: &str) -> String {
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
        if len > 200 {
            break;
        }
    }
    parts.join(" ")
}

#[cfg(test)]
mod tests {
    #[cfg(target_os = "macos")]
    #[test]
    fn base64_matches_the_reference_vectors() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foo"), "Zm9v");
        assert_eq!(super::base64(b"foobar"), "Zm9vYmFy");
    }
}
