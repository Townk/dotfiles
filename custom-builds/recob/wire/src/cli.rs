//! The plumbing every RECOB CLI shares — endpoint resolution, credentials,
//! session establishment. Extracted from `system-clip` when `system-bridge`
//! arrived so the two binaries cannot drift on how they find, dial or trust
//! the bridge; the binaries keep only their own surface.

use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use crate::client::{dial, read_pushed_token, Credential, Dial, Session, Timeouts, SIDE_TUNNEL};

pub fn is_ssh() -> bool {
    ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]
        .iter()
        .any(|name| std::env::var_os(name).is_some_and(|v| !v.is_empty()))
}

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

pub fn state_home() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state"))
}

pub fn bridge_port() -> u16 {
    std::env::var("CLIPBOARD_BRIDGE_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2490)
}

/// The machine this one is VISITING (6c): the `LocalForward` counterpart of
/// 2490's reverse forward — 2489 is my own bridge, 2490 the machine visiting
/// me, 2491 the machine I am visiting. Pointer pushes at copy time dial it
/// best-effort; nothing listening simply means no session is up.
pub fn visited_port() -> u16 {
    std::env::var("CLIPBOARD_BRIDGE_VISITED_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2491)
}

pub fn trusted_socket_path() -> PathBuf {
    std::env::var_os("CLIPBOARD_BRIDGE_LOCAL_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state/cb.sock"))
}

/// The self-name-first identity every row a client writes is stamped with —
/// the same precedence as the zsh `self_host()` and the daemon's
/// `HostIdentity`.
pub fn self_host() -> Option<String> {
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

pub fn valid_host(name: &str) -> bool {
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
pub fn held_tokens() -> Vec<crate::auth::Token> {
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

pub enum PublicBridge {
    /// Nothing bound on the port: the one state that may fall back.
    Absent,
    Session(Session<std::net::TcpStream>),
}

/// Connect + establish against the reverse-tunneled public endpoint. Every
/// failure other than a refused connect is loud and final (§5.2). The
/// session's §7.1 side is the tunnel's, because that is what this port names.
pub fn public_session(program: &str) -> Result<PublicBridge, String> {
    public_session_at(program, bridge_port())
}

/// The same establishment against an explicit port — 6c's pointer pushes dial
/// `visited_port()` with it; the default-port wrapper above keeps every
/// existing caller unchanged.
pub fn public_session_at(program: &str, port: u16) -> Result<PublicBridge, String> {
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
                Ok(mut session) => {
                    session.set_side(SIDE_TUNNEL);
                    Ok(PublicBridge::Session(session))
                }
                Err(e) => Err(format!("{program}: 127.0.0.1:{port}: {e}")),
            }
        }
    }
}

/// The trusted local endpoint, with the Linux socket-activation self-heal the
/// shims carry (`ensure_trusted_bridge`).
pub fn trusted_session(program: &str) -> Result<Session<UnixStream>, String> {
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
