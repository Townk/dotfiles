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
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use recob_wire::client::{
    dial, read_pushed_token, ClientStream, Credential, Dial, Session, Timeouts,
};
use recob_wire::wire::Fields;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("copy") => pbcopy(&args[2..]),
        Some("paste") => pbpaste(&args[2..]),
        _ => {
            eprintln!("usage: system-clip copy|paste [args]");
            ExitCode::FAILURE
        }
    }
}

// --- shared plumbing --------------------------------------------------------

fn is_ssh() -> bool {
    ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]
        .iter()
        .any(|name| std::env::var_os(name).is_some_and(|v| !v.is_empty()))
}

fn state_home() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state"))
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

fn bridge_port() -> u16 {
    std::env::var("CLIPBOARD_BRIDGE_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2490)
}

fn trusted_socket_path() -> PathBuf {
    std::env::var_os("CLIPBOARD_BRIDGE_LOCAL_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state/cb.sock"))
}

/// The self-name-first identity every row this shim writes is stamped with —
/// the same precedence as the zsh `self_host()` and the daemon's `HostIdentity`.
fn self_host() -> Option<String> {
    let path = state_home().join("clipboard/self-name");
    if let Ok(raw) = std::fs::read_to_string(&path) {
        let mut lines = raw.lines();
        if let (Some(name), None) = (lines.next(), lines.next()) {
            if valid_host(name) {
                return Some(name.to_string());
            }
        }
        // A multi-line or malformed file is rejected whole, not first-lined.
    }
    for (cmd, cmd_args) in [
        ("scutil", &["--get", "LocalHostName"][..]),
        ("hostname", &["-s"][..]),
    ] {
        if let Ok(out) = std::process::Command::new(cmd).args(cmd_args).output() {
            if out.status.success() {
                let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if valid_host(&name) {
                    return Some(name);
                }
            }
        }
    }
    None
}

fn valid_host(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 253
        && name
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphanumeric())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
}

/// Every validated token this machine holds (§9.2's pushed
/// `tunnel-tokens/<owner-host>` files), offered together per §6.6's list.
fn held_tokens() -> Vec<recob_wire::auth::Token> {
    let dir = state_home().join("clipboard/tunnel-tokens");
    let mut tokens = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        let mut paths: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
        paths.sort();
        for path in paths {
            if let Some(token) = read_pushed_token(&path) {
                tokens.push(token);
            }
        }
    }
    tokens
}

enum PublicBridge {
    /// Nothing bound on the port: the one state that may fall back.
    Absent,
    Session(Session<std::net::TcpStream>),
}

/// Connect + establish against the reverse-tunneled public endpoint. Every
/// failure other than a refused connect is loud and final (§5.2).
fn public_session(program: &str) -> Result<PublicBridge, String> {
    let port = bridge_port();
    match dial("127.0.0.1", port, std::time::Duration::from_secs(2)) {
        Dial::Refused => Ok(PublicBridge::Absent),
        Dial::Failed(e) => Err(format!(
            "{program}: cannot reach the clipboard bridge on 127.0.0.1:{port}: {e}"
        )),
        Dial::Connected(stream) => {
            match Session::establish(
                stream,
                Credential::Tokens(held_tokens()),
                Timeouts::default(),
            ) {
                Ok(session) => Ok(PublicBridge::Session(session)),
                Err(e) => Err(format!("{program}: 127.0.0.1:{port}: {e}")),
            }
        }
    }
}

/// The trusted local endpoint, with the Linux socket-activation self-heal the
/// shims carry (`ensure_trusted_bridge`).
fn trusted_session(program: &str) -> Result<Session<UnixStream>, String> {
    let path = trusted_socket_path();
    let stream = match UnixStream::connect(&path) {
        Ok(stream) => stream,
        Err(first) => {
            if cfg!(target_os = "macos") {
                return Err(format!(
                    "{program}: this machine's trusted clipboard bridge is not reachable at {}: {first}",
                    path.display()
                ));
            }
            let _ = std::process::Command::new("systemctl")
                .args(["--user", "start", "clipboard-bridge-trusted.socket"])
                .status();
            UnixStream::connect(&path).map_err(|_| {
                format!(
                    "{program}: this machine's trusted clipboard bridge is not reachable at {}: {first}",
                    path.display()
                )
            })?
        }
    };
    Session::establish(stream, Credential::TrustedSocket, Timeouts::default())
        .map_err(|e| format!("{program}: {}: {e}", path.display()))
}

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
            .with("paths", joined.into_bytes());
        return match exchange_ok(&mut session, &request, false, "pbcopy") {
            Ok(_) => ExitCode::SUCCESS,
            Err(e) => fail(e),
        };
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

// --- pbpaste ----------------------------------------------------------------

fn pbpaste(args: &[String]) -> ExitCode {
    match args.first().map(String::as_str) {
        Some("-h" | "--help") => {
            print!("{}", PBPASTE_HELP);
            ExitCode::SUCCESS
        }
        Some("--manifest") => pbpaste_manifest(),
        Some("--files") => {
            // Stages 2–3 of the port; the staged binary does not ship until
            // Phase 8, and this must be implemented before it can.
            fail("pbpaste: --files is not implemented in this build yet".to_string())
        }
        _ => pbpaste_text(),
    }
}

const PBPASTE_HELP: &str = "\
Universal clipboard paste — the read side of the pbcopy/pbpaste pair. Prints the
Mac's clipboard to stdout, whether you're at the Mac or SSH'd in.

--manifest: print the current clipboard entry's file manifest (kind/host/ts/
path lines) instead of its text.

Usage: text=$(pbpaste)
       pbpaste --manifest
";

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
        Ok(PublicBridge::Absent) => fail(format!(
            "pbpaste: clipboard bridge not reachable on 127.0.0.1:{} (reverse SSH tunnel down?)",
            bridge_port()
        )),
        Ok(PublicBridge::Session(mut session)) => print_clip_text(&mut session),
    }
}

fn print_clip_text<S: ClientStream>(session: &mut Session<S>) -> ExitCode {
    match exchange_ok(
        session,
        &Fields::new().with("op", b"clip.get".to_vec()),
        false,
        "pbpaste",
    ) {
        Ok(reply) => {
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
