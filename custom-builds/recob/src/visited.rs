//! 6c: the sitting machine's pointer push. When this machine has an ssh
//! session open TO a peer, the `config.d` fragment gives it a
//! `LocalForward 127.0.0.1:2491 → peer:2489` — a route to the machine it is
//! VISITING. A fresh local capture pushes its POINTER there at copy time
//! (text as `clip.set{origin_host}`, files as `store.persist.files`), so the
//! visited daemon's mount enrichment can load its pasteboard and Cmd+V is
//! native over there. Bytes never cross here — they stream through the
//! visited machine's FUSE mount at paste time (the user's 6b/6c ruling:
//! bytes are pull-only; metadata and pointers may push).
//!
//! Transport: spawn `system-bridge call` with `CLIPBOARD_BRIDGE_PORT` set to
//! the visited port — the same shell-out pattern the daemon already uses for
//! `clipboard-mount`, reusing the client's token/auth logic verbatim instead
//! of coupling the daemon to the client crate. Loop safety comes for free:
//! `capture::decide` refuses remote-origin pasteboard contents, and the
//! visited daemon's own tracker suppresses the echo of its own write.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::capture::{Capture, TypeKind};
use crate::log;

/// Same env name the wire client uses (`cli::visited_port`), so one variable
/// steers both halves in tests and odd setups.
pub fn visited_port() -> u16 {
    std::env::var("CLIPBOARD_BRIDGE_VISITED_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2491)
}

fn system_bridge_bin() -> PathBuf {
    std::env::var_os("RECOB_SYSTEM_BRIDGE_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".local/libexec/system-bridge")
        })
}

/// The push a capture warrants, if any: `(argv-after-"call", stdin-field
/// bytes)`. Pure, so the mapping is table-testable. Text rides `clip.set`
/// (sets the visited pasteboard directly + records provenance in one op);
/// files ride `store.persist.files` (a pointer row; the visited daemon's
/// mount enrichment does the pasteboard). Every other kind stays local —
/// rich payloads are bytes, and bytes are pull-only.
pub fn pointer_push_for(capture: &Capture, host: &str) -> Option<(Vec<String>, Vec<u8>)> {
    match capture.kind {
        TypeKind::Text => {
            let plain = capture.plain.as_deref()?;
            if plain.is_empty() {
                return None;
            }
            Some((
                vec![
                    "--peer".into(),
                    "--stdin".into(),
                    "text".into(),
                    "clip.set".into(),
                    "regtype=v".into(),
                    format!("origin_host={host}"),
                ],
                plain.as_bytes().to_vec(),
            ))
        }
        TypeKind::Files | TypeKind::File | TypeKind::Directory => {
            let paths = capture.authority_paths.as_ref()?;
            if paths.is_empty() {
                return None;
            }
            Some((
                vec![
                    "--peer".into(),
                    "--stdin".into(),
                    "paths".into(),
                    "store.persist.files".into(),
                    format!("host={host}"),
                ],
                paths.join("\0").into_bytes(),
            ))
        }
        _ => None,
    }
}

/// The visitor's bridge — the reverse forward a machine ssh'd INTO us
/// carries (the wire client's default peer port). A capture pushed there
/// lands on the machine whose human is LOOKING at us over that session
/// (ssh, or the VNC companion tunnel): the GUI equivalent of tmux's OSC 52
/// copy-follows-the-viewer. Same env override as the wire client.
pub fn visitor_port() -> u16 {
    std::env::var("CLIPBOARD_BRIDGE_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2490)
}

/// Fire-and-forget push of a fresh local capture to EVERY connected peer
/// direction: the machine we are visiting (2491) and the machine visiting
/// us (2490) — each behind a cheap dial (nothing bound = no session, the
/// common state — no process spawned). Each push runs on its own thread
/// exactly like the mount enrichment: capture latency must never pay for a
/// slow peer. Loop-safe both ways: only self-origin captures reach here, a
/// text push lands as the far daemon's OWN tracker-marked write (never
/// re-captured), and a files push's enrichment carries the provenance
/// marker the far capture refuses.
pub fn push_capture(capture: &Capture, host: &str) {
    let Some((args, stdin_bytes)) = pointer_push_for(capture, host) else {
        return;
    };
    for port in [visited_port(), visitor_port()] {
        let host_label = host.to_string();
        let args = args.clone();
        let stdin_bytes = stdin_bytes.clone();
        std::thread::spawn(move || {
            use std::net::TcpStream;
            let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
            if TcpStream::connect_timeout(&addr, std::time::Duration::from_millis(250)).is_err() {
                return;
            }
            let mut command = Command::new(system_bridge_bin());
            command
                .arg("call")
                .args(&args)
                .env("CLIPBOARD_BRIDGE_PORT", port.to_string())
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            match command.spawn() {
                Ok(mut child) => {
                    if let Some(stdin) = child.stdin.as_mut() {
                        let _ = stdin.write_all(&stdin_bytes);
                    }
                    drop(child.stdin.take());
                    let _ = child.wait();
                }
                Err(e) => {
                    log!("peer push ({host_label}:{port}): cannot spawn system-bridge: {e}")
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn text_capture(plain: &str) -> Capture {
        Capture {
            kind: TypeKind::Text,
            type_hash: "h".into(),
            plain: Some(plain.into()),
            preview: plain.into(),
            len: plain.len() as i64,
            source_app: None,
            source_bundle_id: None,
            data: BTreeMap::new(),
            authority_paths: None,
        }
    }

    #[test]
    fn text_pushes_clip_set_with_origin() {
        let (args, stdin) = pointer_push_for(&text_capture("hello"), "laptop").expect("push");
        assert_eq!(
            args,
            vec![
                "--peer",
                "--stdin",
                "text",
                "clip.set",
                "regtype=v",
                "origin_host=laptop"
            ]
        );
        assert_eq!(stdin, b"hello");
    }

    #[test]
    fn files_push_store_persist_with_nul_joined_paths() {
        let mut capture = text_capture("");
        capture.kind = TypeKind::Files;
        capture.plain = None;
        capture.authority_paths = Some(vec!["/a/b".into(), "/c d".into()]);
        let (args, stdin) = pointer_push_for(&capture, "laptop").expect("push");
        assert_eq!(
            args,
            vec![
                "--peer",
                "--stdin",
                "paths",
                "store.persist.files",
                "host=laptop"
            ]
        );
        assert_eq!(stdin, b"/a/b\0/c d");
    }

    #[test]
    fn empty_text_and_pathless_files_and_rich_kinds_stay_local() {
        assert!(pointer_push_for(&text_capture(""), "laptop").is_none());
        let mut files = text_capture("x");
        files.kind = TypeKind::Files;
        files.plain = None;
        files.authority_paths = Some(vec![]);
        assert!(pointer_push_for(&files, "laptop").is_none());
        let mut rich = text_capture("x");
        rich.kind = TypeKind::Image;
        assert!(pointer_push_for(&rich, "laptop").is_none());
    }
}
