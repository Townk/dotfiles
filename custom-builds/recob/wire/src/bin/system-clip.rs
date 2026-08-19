//! `system-clip` — the universal clipboard client, compiled (D2/D6): one
//! binary with `copy` and `paste` subcommands, built from the daemon's own
//! codec crate so the wire has one implementation. The `pbcopy`/`pbpaste`
//! names stay two-line exec trampolines in `home/`, so what the overwrite is
//! called is chezmoi's decision, never this binary's — RECOB is the bridge,
//! and this is just the clipboard client that rides it.
//!
//! **No AppKit.** This binary never touches a pasteboard — that is the
//! daemon's job — and §8 makes the missing framework a build assertion, not a
//! good intention.
//!
//! The behavior contract is the zsh shims', §8/§5.2 applied. The one
//! deliberate change from today's `pbcopy`: OSC 52 is a fallback for an
//! *absent* bridge only — a refused TCP connect — never for a refusing,
//! stalling or overloaded one (§5.2's "a timeout must never become a
//! downgrade"). Everything else that fails, fails loudly with the code the
//! server named.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use recob_wire::cli::{
    bridge_port, home, is_ssh, public_session, public_session_at, self_host, trusted_session,
    visited_port, PublicBridge,
};
use recob_wire::client::{ClientStream, Session};
use recob_wire::paste_files;
use recob_wire::wire::Fields;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("copy") => pbcopy(&args[2..]),
        Some("paste") => pbpaste(&args[2..]),
        Some("restore") => restore(&args[2..]),
        _ => {
            eprintln!("usage: system-clip copy|paste|restore [args]");
            ExitCode::FAILURE
        }
    }
}

// --- shared plumbing --------------------------------------------------------
//
// Endpoint resolution, credentials and session establishment live in
// `recob_wire::cli`, shared with `system-bridge` so the two binaries cannot
// drift on how they find, dial or trust the bridge.

fn exchange_ok<S: ClientStream>(
    session: &mut Session<S>,
    fields: &Fields,
    action: bool,
    program: &str,
) -> Result<Fields, String> {
    session
        .exchange(fields, action)
        .map_err(|e| format!("{program}: {e}"))
}

fn fail(message: String) -> ExitCode {
    eprintln!("{message}");
    ExitCode::FAILURE
}

/// `l` iff the text ends in a newline, else `v` — the shims' shared heuristic.
fn regtype_of(text: &[u8]) -> &'static str {
    if text.last() == Some(&b'\n') {
        "l"
    } else {
        "v"
    }
}

/// The zsh `abspath`: the parent resolved, the leaf kept as named — a symlink
/// leaf stays a symlink path, which the authority validation then judges.
fn absolute(path: &str) -> Result<String, String> {
    let p = Path::new(path);
    if !p.exists() && std::fs::symlink_metadata(p).is_err() {
        return Err(format!("no such file: {path}"));
    }
    let parent = p.parent().filter(|parent| !parent.as_os_str().is_empty());
    let file = p
        .file_name()
        .ok_or_else(|| format!("no such file: {path}"))?;
    let base = match parent {
        Some(parent) => parent
            .canonicalize()
            .map_err(|e| format!("cannot resolve {}: {e}", parent.display()))?,
        None => std::env::current_dir().map_err(|e| format!("cannot resolve cwd: {e}"))?,
    };
    Ok(base.join(file).to_string_lossy().into_owned())
}

fn exec_first(candidates: &[(&str, &[&str])]) -> Option<ExitCode> {
    use std::os::unix::process::CommandExt;
    for (bin, bin_args) in candidates {
        let path = Path::new(bin);
        let available = if path.is_absolute() {
            path.is_file()
        } else {
            which(bin)
        };
        if available {
            let err = std::process::Command::new(bin).args(*bin_args).exec();
            eprintln!("system-clip: cannot exec {bin}: {err}");
            return Some(ExitCode::FAILURE);
        }
    }
    None
}

fn which(bin: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|paths| std::env::split_paths(&paths).any(|dir| dir.join(bin).is_file()))
}

// --- pbcopy -----------------------------------------------------------------

fn pbcopy(args: &[String]) -> ExitCode {
    match args.first().map(String::as_str) {
        Some("-h" | "--help") => {
            print!("{}", PBCOPY_HELP);
            return ExitCode::SUCCESS;
        }
        Some("--content") => return pbcopy_content(&args[1..]),
        _ => {}
    }
    let mut rest: &[String] = args;
    if rest.first().map(String::as_str) == Some("--") {
        rest = &rest[1..];
    }
    if !rest.is_empty() {
        return pbcopy_files(rest);
    }
    pbcopy_text()
}

const PBCOPY_HELP: &str = "\
Universal clipboard copy — the same pbcopy everywhere, whether you're at the Mac
or SSH'd into a remote host. Reads stdin and puts it on the Mac's system
clipboard.

pbcopy <path>...        puts a real file clip on the pasteboard.
pbcopy --content <file> puts the file's raw bytes on the pasteboard under a
                        detected UTI (rich-type copy).

Usage: printf '%s' \"$text\" | pbcopy
";

fn read_stdin() -> Result<Vec<u8>, String> {
    let mut text = Vec::new();
    std::io::stdin()
        .read_to_end(&mut text)
        .map_err(|e| format!("pbcopy: cannot read stdin: {e}"))?;
    Ok(text)
}

fn pbcopy_text() -> ExitCode {
    if !is_ssh() {
        let darwin =
            std::env::var("PBCOPY_DARWIN_BIN").unwrap_or_else(|_| "/usr/bin/pbcopy".to_string());
        if let Some(code) = exec_first(&[
            (darwin.as_str(), &[]),
            ("wl-copy", &[]),
            ("xclip", &["-selection", "clipboard"]),
        ]) {
            return code;
        }
        // Headless Linux: the store is the clipboard; the trusted socket is
        // the local endpoint and needs no credential.
        let text = match read_stdin() {
            Ok(text) => text,
            Err(e) => return fail(e),
        };
        let mut session = match trusted_session("pbcopy") {
            Ok(session) => session,
            Err(e) => return fail(e),
        };
        let request = Fields::new()
            .with("op", b"clip.set".to_vec())
            .with("text", text.clone())
            .with("regtype", regtype_of(&text).as_bytes().to_vec());
        return match exchange_ok(&mut session, &request, false, "pbcopy") {
            Ok(_) => ExitCode::SUCCESS,
            Err(e) => fail(e),
        };
    }

    // Over SSH: one connection carries the copy, with its own provenance —
    // §6.2's collapse of O+T into clip.set.
    let text = match read_stdin() {
        Ok(text) => text,
        Err(e) => return fail(e),
    };
    let regtype = regtype_of(&text);
    let host = self_host();

    let delivered = match public_session("pbcopy") {
        Err(e) => return fail(e),
        Ok(PublicBridge::Absent) => {
            // §5.2: nothing is bound — the one state where the less trusted
            // path is permitted, silently, as today.
            if !osc52_copy(&text) {
                return fail(format!(
                    "pbcopy: cannot deliver the copy -- no bridge on 127.0.0.1:{} and {} cannot be opened for OSC 52",
                    bridge_port(),
                    osc52_sink().display()
                ));
            }
            true
        }
        Ok(PublicBridge::Session(mut session)) => {
            let mut request = Fields::new()
                .with("op", b"clip.set".to_vec())
                .with("text", text.clone())
                .with("regtype", regtype.as_bytes().to_vec());
            if let Some(host) = &host {
                request.push("origin_host", host.as_bytes());
            }
            if let Err(e) = exchange_ok(&mut session, &request, false, "pbcopy") {
                // A reachable bridge that refuses is a failed control, never a
                // downgrade license.
                return fail(e);
            }
            true
        }
    };

    // The origin's own history row, exactly as the shim recorded it — in
    // process now, so it needs no backgrounding, and best-effort as before.
    if delivered {
        if let Some(host) = &host {
            if let Ok(mut local) = trusted_session("pbcopy") {
                let request = Fields::new()
                    .with("op", b"store.persist.text".to_vec())
                    .with("host", host.as_bytes().to_vec())
                    .with("kind", b"text".to_vec())
                    .with("app", b"".to_vec())
                    .with("regtype", regtype.as_bytes().to_vec())
                    .with("text", text);
                let _ = local.exchange(&request, false);
            }
        }
    }
    ExitCode::SUCCESS
}

fn osc52_sink() -> PathBuf {
    std::env::var_os("PBCOPY_OSC52_SINK")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/dev/tty"))
}

/// The write is the openability test, exactly as the shim reasons: the device
/// node can exist without a controlling terminal to open.
fn osc52_copy(text: &[u8]) -> bool {
    let Ok(mut sink) = std::fs::OpenOptions::new().write(true).open(osc52_sink()) else {
        return false;
    };
    let mut sequence = Vec::with_capacity(text.len() * 4 / 3 + 16);
    sequence.extend_from_slice(b"\x1b]52;c;");
    sequence.extend_from_slice(base64(text).as_bytes());
    sequence.extend_from_slice(b"\x1b\\");
    sink.write_all(&sequence).is_ok()
}

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

fn pbcopy_files(paths: &[String]) -> ExitCode {
    let mut resolved = Vec::with_capacity(paths.len());
    for path in paths {
        match absolute(path) {
            Ok(path) => resolved.push(path),
            Err(e) => return fail(format!("pbcopy: {e}")),
        }
    }
    let joined = resolved.join("\0");

    if !is_ssh() {
        // A local file clip: the pasteboard write and the row in one local
        // operation. No local-tool fallback exists, so the reply decides.
        let mut session = match trusted_session("pbcopy") {
            Ok(session) => session,
            Err(e) => return fail(e),
        };
        let request = Fields::new()
            .with("op", b"clip.set.files".to_vec())
            .with("paths", joined.clone().into_bytes());
        if let Err(e) = exchange_ok(&mut session, &request, false, "pbcopy") {
            return fail(e);
        }
        // 6c: the sitting machine's pointer push. If a session to a visited
        // peer is up (the 2491 LocalForward), mirror the manifest there —
        // pointer only, bytes stay pull-only — so the visited machine's
        // daemon can enrich its pasteboard with mount file-URLs and Cmd+V is
        // native over there. Silently best-effort: no forward listening is
        // simply "no session", and the local copy already succeeded.
        push_pointer_files_to_visited(&joined);
        return ExitCode::SUCCESS;
    }

    // Over SSH: the local manifest record is the primary action and fails
    // loudly; the peer push is a best-effort courtesy that only ever warns.
    let Some(host) = self_host() else {
        return fail("pbcopy: cannot resolve this machine's identity".to_string());
    };
    let mut local = match trusted_session("pbcopy") {
        Ok(session) => session,
        Err(e) => return fail(e),
    };
    let request = Fields::new()
        .with("op", b"store.persist.files".to_vec())
        .with("host", host.as_bytes().to_vec())
        .with("paths", joined.clone().into_bytes());
    if let Err(e) = exchange_ok(&mut local, &request, false, "pbcopy") {
        return fail(e);
    }

    match public_session("pbcopy") {
        Ok(PublicBridge::Session(mut peer)) => {
            let request = Fields::new()
                .with("op", b"store.persist.files".to_vec())
                .with("host", host.as_bytes().to_vec())
                .with("paths", joined.into_bytes());
            if let Err(e) = peer.exchange(&request, false) {
                eprintln!(
                    "pbcopy: file copied to this machine's clipboard; peer not notified -- {e}"
                );
            }
        }
        Ok(PublicBridge::Absent) => {
            eprintln!(
                "pbcopy: file copied to this machine's clipboard; peer not notified -- reverse bridge down"
            );
        }
        Err(e) => {
            eprintln!("pbcopy: file copied to this machine's clipboard; peer not notified -- {e}");
        }
    }
    ExitCode::SUCCESS
}

/// 6c: best-effort pointer push of a NUL-joined manifest to the machine this
/// one is VISITING (`visited_port()`, the 2491 LocalForward). Everything is
/// quiet except a genuinely failing established session: no listener is the
/// normal no-session state, and this must never affect the local copy's
/// outcome (it already succeeded).
fn push_pointer_files_to_visited(joined: &str) {
    let Some(host) = self_host() else { return };
    match public_session_at("pbcopy", visited_port()) {
        Ok(PublicBridge::Session(mut peer)) => {
            let request = Fields::new()
                .with("op", b"store.persist.files".to_vec())
                .with("host", host.as_bytes().to_vec())
                .with("paths", joined.as_bytes().to_vec());
            if let Err(e) = peer.exchange(&request, false) {
                eprintln!("pbcopy: visited machine not notified -- {e}");
            }
        }
        Ok(PublicBridge::Absent) => {}
        Err(_) => {}
    }
}

fn pbcopy_content(args: &[String]) -> ExitCode {
    let [file] = args else {
        return fail("pbcopy: --content takes exactly one file".to_string());
    };
    if !Path::new(file).exists() {
        return fail(format!("pbcopy: no such file: {file}"));
    }
    let Some(uti) = detect_uti(file) else {
        return fail(format!("pbcopy: cannot infer UTI for {file}"));
    };
    let blob = match std::fs::read(file) {
        Ok(blob) => blob,
        Err(e) => return fail(format!("pbcopy: cannot read {file}: {e}")),
    };
    let request = Fields::new()
        .with("op", b"clip.set.rich".to_vec())
        .with("uti", uti.as_bytes().to_vec())
        .with("blob", blob);

    if !is_ssh() {
        let mut session = match trusted_session("pbcopy") {
            Ok(session) => session,
            Err(e) => return fail(e),
        };
        return match exchange_ok(&mut session, &request, false, "pbcopy") {
            Ok(_) => ExitCode::SUCCESS,
            Err(e) => fail(e),
        };
    }
    match public_session("pbcopy") {
        Err(e) => fail(e),
        Ok(PublicBridge::Absent) => fail(
            "pbcopy: --content needs the reverse bridge (OSC 52 cannot carry rich types)"
                .to_string(),
        ),
        Ok(PublicBridge::Session(mut session)) => {
            match exchange_ok(&mut session, &request, false, "pbcopy") {
                Ok(_) => ExitCode::SUCCESS,
                Err(e) => fail(e),
            }
        }
    }
}

/// The shim's extension map, then `file --mime-type -b` — the one non-wire
/// spawn this mode keeps, exactly as before.
fn detect_uti(path: &str) -> Option<String> {
    let ext = Path::new(path)
        .extension()
        .map(|ext| ext.to_string_lossy().to_lowercase());
    let by_ext = match ext.as_deref() {
        Some("png") => Some("public.png"),
        Some("jpg" | "jpeg") => Some("public.jpeg"),
        Some("tif" | "tiff") => Some("public.tiff"),
        Some("pdf") => Some("com.adobe.pdf"),
        Some("txt") => Some("public.utf8-plain-text"),
        Some("gif") => Some("com.compuserve.gif"),
        Some("webp") => Some("org.webmproject.webp"),
        _ => None,
    };
    if let Some(uti) = by_ext {
        return Some(uti.to_string());
    }
    let out = std::process::Command::new("file")
        .args(["--mime-type", "-b", "--", path])
        .output()
        .ok()?;
    let mime = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let uti = match mime.as_str() {
        "image/png" => "public.png",
        "image/jpeg" => "public.jpeg",
        "image/tiff" => "public.tiff",
        "application/pdf" => "com.adobe.pdf",
        "text/plain" => "public.utf8-plain-text",
        "image/gif" => "com.compuserve.gif",
        "image/webp" => "org.webmproject.webp",
        _ => return None,
    };
    Some(uti.to_string())
}

// --- restore ----------------------------------------------------------------

/// `system-clip restore <clip_id> [--plain]` — §14.5's operation, for the GUI
/// picker.
///
/// The picker used to restore in process, which made Hammerspoon a second
/// writer of the pasteboard; sole-writer means sole-writer, so it now asks the
/// daemon. It asks through this binary rather than speaking the wire from Lua:
/// a third hand-written implementation of the framing is exactly what §8
/// exists to prevent, and a picker action can afford one exec of a static
/// binary.
fn restore(args: &[String]) -> ExitCode {
    let mut clip_id = None;
    let mut plain_only = false;
    for arg in args {
        match arg.as_str() {
            "--plain" => plain_only = true,
            other if other.starts_with('-') => {
                return fail(format!("system-clip restore: unknown option: {other}"))
            }
            other => {
                if clip_id.replace(other.to_string()).is_some() {
                    return fail("system-clip restore: one clip id".to_string());
                }
            }
        }
    }
    let Some(clip_id) = clip_id else {
        return fail("usage: system-clip restore <clip_id> [--plain]".to_string());
    };
    if clip_id.is_empty() || !clip_id.bytes().all(|b| b.is_ascii_digit()) {
        return fail(format!("system-clip restore: not a clip id: {clip_id}"));
    }

    // `clip.restore` is tier `local`: restoring an arbitrary stored clip onto
    // this machine's pasteboard is not something a peer has any business
    // doing, so it goes over the trusted socket and nowhere else.
    let mut session = match trusted_session("system-clip") {
        Ok(session) => session,
        Err(e) => return fail(e),
    };
    let mut request = Fields::new()
        .with("op", b"clip.restore".to_vec())
        .with("clip_id", clip_id.into_bytes());
    if plain_only {
        request.push("plain_only", b"1".to_vec());
    }
    match exchange_ok(&mut session, &request, false, "system-clip") {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => fail(e),
    }
}

// --- pbpaste ----------------------------------------------------------------

fn pbpaste(args: &[String]) -> ExitCode {
    match args.first().map(String::as_str) {
        Some("-h" | "--help") => {
            print!("{}", PBPASTE_HELP);
            ExitCode::SUCCESS
        }
        Some("--manifest") => pbpaste_manifest(),
        Some("--files") => pbpaste_files(&args[1..]),
        _ => pbpaste_text(),
    }
}

const PBPASTE_HELP: &str = "\
Universal clipboard paste — the read side of the pbcopy/pbpaste pair. Prints the
Mac's clipboard to stdout, whether you're at the Mac or SSH'd in.

--manifest: print the current clipboard entry's file manifest (kind/host/ts/
path lines) instead of its text.

--files [--from-peer] [--force] [--quiet|--progress|--porcelain] [dir]:
materialize the current file clip into dir (default: cwd). Refuses existing
names unless --force. Same-host files copy locally;
SSH clients stream authorized files;
a local Mac reads remote manifests through its healthy peer mount.
--from-peer forces the peer endpoint when the environment can't answer (the
picker's live-row restore) — tunnel down is then a hard error.

Usage: text=$(pbpaste)
       pbpaste --manifest
       pbpaste --files [--from-peer] [--force] [--quiet|--progress|--porcelain] [dir]
";

enum PasteSource {
    Peer,
    Own,
}

/// 6b newer-wins: which side's clip a remote paste prints. Pure so the rule
/// is table-testable; clock skew between the two machines is the documented
/// accepted hazard (phase 6 spec §11) — no compensation here.
fn choose_paste_source(peer_ts: Option<f64>, own_ts: Option<f64>) -> PasteSource {
    match (peer_ts, own_ts) {
        (Some(peer), Some(own)) if peer > own => PasteSource::Peer,
        (Some(_), Some(_)) => PasteSource::Own,
        (Some(_), None) => PasteSource::Peer,
        (None, Some(_)) => PasteSource::Own,
        (None, None) => PasteSource::Peer,
    }
}

fn ts_of(reply: &Fields) -> Option<f64> {
    std::str::from_utf8(reply.get("timestamp").unwrap_or_default())
        .ok()
        .and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|ts| *ts > 0.0)
}

fn pbpaste_text() -> ExitCode {
    if !is_ssh() {
        let darwin =
            std::env::var("PBPASTE_DARWIN_BIN").unwrap_or_else(|_| "/usr/bin/pbpaste".to_string());
        if let Some(code) = exec_first(&[
            (darwin.as_str(), &[]),
            ("wl-paste", &[]),
            ("xclip", &["-selection", "clipboard", "-o"]),
        ]) {
            return code;
        }
        let mut session = match trusted_session("pbpaste") {
            Ok(session) => session,
            Err(e) => return fail(e),
        };
        return print_clip_text(&mut session);
    }

    match public_session("pbpaste") {
        Err(e) => fail(e),
        Ok(PublicBridge::Absent) => {
            // §5.2: ECONNREFUSED is the one licensed downgrade — the tunnel
            // is definitively down, so this machine's own clipboard is the
            // honest answer (6b). Anything slower still fails loudly above.
            eprintln!(
                "pbpaste: bridge not reachable on 127.0.0.1:{} — using this machine's own clipboard",
                bridge_port()
            );
            match trusted_session("pbpaste") {
                Ok(mut session) => print_clip_text(&mut session),
                Err(e) => fail(e),
            }
        }
        Ok(PublicBridge::Session(mut session)) => {
            let peer = match exchange_ok(
                &mut session,
                &Fields::new().with("op", b"clip.get".to_vec()),
                false,
                "pbpaste",
            ) {
                Ok(reply) => reply,
                Err(e) => return fail(e),
            };
            // Own comparand: this machine's daemon over the trusted socket.
            // Its being down must not break a paste the healthy tunnel can
            // answer — degrade to peer with a warning (spec §4.4).
            let own = trusted_session("pbpaste").ok().and_then(|mut local| {
                local
                    .exchange(&Fields::new().with("op", b"clip.get".to_vec()), false)
                    .ok()
            });
            if own.is_none() {
                eprintln!("pbpaste: this machine's own clipboard store is unreachable — using the peer clip");
            }
            match choose_paste_source(ts_of(&peer), own.as_ref().and_then(ts_of)) {
                PasteSource::Own => write_clip_text(&own.expect("own is Some when it wins")),
                PasteSource::Peer => {
                    let code = write_clip_text(&peer);
                    // The peer clip is now "what I pasted here" — record it
                    // locally (best-effort, the nvim persist_local precedent)
                    // so the next comparison sees this paste.
                    persist_peer_text(&peer);
                    code
                }
            }
        }
    }
}

fn print_clip_text<S: ClientStream>(session: &mut Session<S>) -> ExitCode {
    match exchange_ok(
        session,
        &Fields::new().with("op", b"clip.get".to_vec()),
        false,
        "pbpaste",
    ) {
        Ok(reply) => write_clip_text(&reply),
        Err(e) => fail(e),
    }
}

fn write_clip_text(reply: &Fields) -> ExitCode {
    let text = reply.get("text").unwrap_or_default();
    let mut stdout = std::io::stdout();
    if stdout
        .write_all(text)
        .and_then(|()| stdout.flush())
        .is_err()
    {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// Best-effort local echo of a peer clip a remote paste chose: the nvim
/// `persist_local` precedent (pbcopy's own history row) applied to the read
/// side. `text`/`host` are both required on the wire (§6.2), so their
/// absence here means a malformed or stubbed reply, not a real clip — skip
/// rather than write garbage into the local history.
fn persist_peer_text(peer: &Fields) {
    let text = peer.get("text").unwrap_or_default();
    if text.is_empty() {
        return;
    }
    let host = peer.get("host").unwrap_or_default();
    if host.is_empty() {
        return;
    }
    let regtype = peer.get("regtype").unwrap_or(b"v");
    if let Ok(mut local) = trusted_session("pbpaste") {
        let request = Fields::new()
            .with("op", b"store.persist.text".to_vec())
            .with("host", host.to_vec())
            .with("kind", b"text".to_vec())
            .with("app", b"".to_vec())
            .with("regtype", regtype.to_vec())
            .with("text", text.to_vec());
        let _ = local.exchange(&request, false);
    }
}

/// `--files`: the manifest and any remote bytes come from one endpoint — the
/// peer's over SSH, this machine's own otherwise — and the engine decides
/// from the manifest's host whether the bytes are local, mounted or streamed.
///
/// `--from-peer` (6b) forces the peer endpoint + streaming semantics when the
/// ENVIRONMENT cannot answer: the picker's live-row restore runs outside any
/// ssh session (a GUI job under pueue, a VNC-local TUI), where `is_ssh()` is
/// false but the caller has already proven the reverse tunnel is up (the
/// probe). The caller says so explicitly rather than this binary guessing.
/// A refused tunnel is a hard error under the flag — never the trusted
/// fallback, because the trusted store's current clip is a DIFFERENT clip
/// and falling back would materialize the wrong bytes.
fn pbpaste_files(args: &[String]) -> ExitCode {
    let mut rest: Vec<String> = Vec::with_capacity(args.len());
    let mut from_peer = false;
    for arg in args {
        if arg == "--from-peer" {
            from_peer = true;
        } else {
            rest.push(arg.clone());
        }
    }
    let options = match paste_files::Options::parse(&rest) {
        Ok(options) => options,
        Err(e) => return fail(e),
    };
    let peer_mode = from_peer || is_ssh();
    let context = paste_files::Context {
        self_host: self_host(),
        over_ssh: peer_mode,
        mount_helper: std::env::var_os("CLIPBOARD_MOUNT_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join(".local/libexec/clipboard-mount")),
        cap: paste_files::size_cap_from_env(),
        // The edge decides: a human ran this binary, so an over-cap item may
        // be put to them. The engine no longer sniffs the terminal itself —
        // doing so let `cargo test` (which leaves fd 1 a tty) open a real
        // confirm dialog from inside a test.
        interactive: true,
    };

    let outcome = if peer_mode {
        match public_session("pbpaste") {
            Err(e) => return fail(e),
            Ok(PublicBridge::Absent) => {
                return fail(format!(
                    "pbpaste: clipboard bridge not reachable on 127.0.0.1:{} (reverse SSH tunnel down?)",
                    bridge_port()
                ))
            }
            Ok(PublicBridge::Session(mut session)) => {
                paste_files::run(&mut session, &options, &context)
            }
        }
    } else {
        match trusted_session("pbpaste") {
            Err(e) => return fail(e),
            Ok(mut session) => paste_files::run(&mut session, &options, &context),
        }
    };
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => fail(e),
    }
}

fn pbpaste_manifest() -> ExitCode {
    let reply = if is_ssh() {
        match public_session("pbpaste") {
            Err(e) => return fail(e),
            Ok(PublicBridge::Absent) => {
                return fail(format!(
                    "pbpaste: clipboard bridge not reachable on 127.0.0.1:{} (reverse SSH tunnel down?)",
                    bridge_port()
                ))
            }
            Ok(PublicBridge::Session(mut session)) => exchange_ok(
                &mut session,
                &Fields::new().with("op", b"files.list".to_vec()),
                false,
                "pbpaste",
            ),
        }
    } else {
        match trusted_session("pbpaste") {
            Ok(mut session) => exchange_ok(
                &mut session,
                &Fields::new().with("op", b"files.list".to_vec()),
                false,
                "pbpaste",
            ),
            Err(e) => return fail(e),
        }
    };
    let reply = match reply {
        Ok(reply) => reply,
        Err(e) => {
            // §8 rule 3: branch on the code. The old shim grepped message
            // text for `not-files`; the code now carries the fact.
            if let Some(rest) = e.strip_prefix("pbpaste: not-found") {
                if rest.contains("not a files clip") {
                    return fail(
                        "pbpaste: current clipboard entry is not a files clip -- use plain pbpaste to read it as text"
                            .to_string(),
                    );
                }
            }
            return fail(e);
        }
    };

    let field_text =
        |name: &str| String::from_utf8_lossy(reply.get(name).unwrap_or_default()).into_owned();
    // The four-line contract Alt+p and the yazi smart-paste plugin parse.
    println!("kind\t{}", field_text("kind"));
    println!("host\t{}", field_text("host"));
    println!("ts\t{}", field_text("timestamp"));
    for path in reply
        .get("paths")
        .unwrap_or_default()
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
    {
        println!("path\t{}", String::from_utf8_lossy(path));
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod paste_source_tests {
    use super::{choose_paste_source, PasteSource};

    #[test]
    fn peer_strictly_newer_wins() {
        assert!(matches!(
            choose_paste_source(Some(200.0), Some(100.0)),
            PasteSource::Peer
        ));
    }
    #[test]
    fn own_newer_wins() {
        assert!(matches!(
            choose_paste_source(Some(100.0), Some(200.0)),
            PasteSource::Own
        ));
    }
    #[test]
    fn tie_favors_own() {
        // Equal stamps usually mean both sides hold the same clip; Own is the
        // no-behavior-change default.
        assert!(matches!(
            choose_paste_source(Some(100.0), Some(100.0)),
            PasteSource::Own
        ));
    }
    #[test]
    fn missing_own_stamp_yields_peer() {
        assert!(matches!(
            choose_paste_source(Some(100.0), None),
            PasteSource::Peer
        ));
    }
    #[test]
    fn missing_peer_stamp_yields_own() {
        assert!(matches!(
            choose_paste_source(None, Some(100.0)),
            PasteSource::Own
        ));
    }
    #[test]
    fn both_missing_yields_peer() {
        // Today's behavior: the peer session is up, so its (possibly empty)
        // text is still the answer of record.
        assert!(matches!(choose_paste_source(None, None), PasteSource::Peer));
    }
}
