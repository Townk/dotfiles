//! The delegated GUI operations (§14.3): `window.fullscreen.toggle`,
//! `window.fullscreen.state` and `osd.notify`. Delegation is the mechanism the
//! product is built on (P9) — a peer causes a deliberately chosen thing to
//! happen on the machine the human sits at, without being able to say *how*.

use std::process::Command;
use std::time::Duration;

use crate::registry::Response;
use crate::session::Ctx;
use crate::validate;
use crate::wire::{Fields, ProtoError};

use super::{run_with_deadline, Scratch};

/// The dispatcher gave every `hs` and helper spawn ten seconds.
const HELPER_DEADLINE: Duration = Duration::from_secs(10);

/// `window.fullscreen.toggle{terminal}` — toggle that terminal's fullscreen on
/// this machine for a session at the far end of the tunnel. The terminal is a
/// closed set (P5), named by the caller because the daemon has no terminal
/// environment of its own to detect from.
pub fn fullscreen_toggle(fields: &Fields, ctx: &Ctx) -> Result<Response, ProtoError> {
    let terminal = validate::one_of(
        "terminal",
        validate::required_text(fields, "terminal")?,
        &["ghostty", "wezterm"],
    )?;

    let toggle = &ctx.tools.fullscreen_toggle;
    if !toggle.is_file() {
        return Err(ProtoError::new(
            "unavailable",
            "no fullscreen toggle on this machine",
        ));
    }
    // MUX_TERMINAL short-circuits detect_terminal, which would otherwise see no
    // TERM_PROGRAM here and give up. SSH_* are cleared for the same reason: the
    // daemon may itself have been started from an ssh login, and the toggle
    // reads them as "you are not the local machine".
    let mut command = Command::new(toggle);
    command
        .env("SSH_CONNECTION", "")
        .env("SSH_CLIENT", "")
        .env("MUX_TERMINAL", terminal);
    let run = run_with_deadline(command, HELPER_DEADLINE)
        .map_err(|e| ProtoError::new("internal", format!("cannot run the toggle: {e}")))?;
    if !run.ok {
        let mut message = String::from_utf8_lossy(&run.stderr).trim().to_string();
        if message.is_empty() {
            message = String::from_utf8_lossy(&run.stdout).trim().to_string();
        }
        if message.is_empty() {
            message = "fullscreen toggle failed".to_string();
        }
        return Err(ProtoError::new("internal", message));
    }
    // Record it here too: the window that just moved is this machine's, so this
    // machine's own mirror is now wrong. `--flip` rather than a fresh probe —
    // the state was just inverted deliberately, and the local client-resized
    // hook re-asks authoritatively a moment later.
    let probe = &ctx.tools.fullscreen_probe;
    if probe.is_file() {
        let mut flip = Command::new(probe);
        flip.arg("--flip");
        let _ = run_with_deadline(flip, HELPER_DEADLINE);
    }
    Ok(Fields::new().into())
}

/// `window.fullscreen.state` — answer `true`, `false` or empty (unknown).
pub fn fullscreen_state(ctx: &Ctx) -> Result<Response, ProtoError> {
    let probe = &ctx.tools.fullscreen_probe;
    if !probe.is_file() {
        return Err(ProtoError::new(
            "unavailable",
            "no fullscreen probe on this machine",
        ));
    }
    let mut command = Command::new(probe);
    command.arg("--print");
    let run = run_with_deadline(command, HELPER_DEADLINE)
        .map_err(|e| ProtoError::new("internal", format!("cannot run the probe: {e}")))?;
    // The dispatcher captured through `$(...)`, which strips trailing newlines.
    let mut state = run.stdout;
    while state.last() == Some(&b'\n') {
        state.pop();
    }
    Ok(Fields::new().with("state", state).into())
}

/// `osd.notify{origin_host, style, icon, sound, text}` — raise a toast on this
/// Mac for a caller with no GUI of its own. D7, measured: spawn `hs <file>`
/// per notification (~12 ms, off every caller's critical path). `hs -c` is
/// recorded as both slower and unreliable; the temp-file form is deliberate.
pub fn notify(fields: &Fields, ctx: &Ctx) -> Result<Response, ProtoError> {
    let origin_host = validate::host_shaped(
        "origin_host",
        validate::required_text(fields, "origin_host")?,
    )?;
    let style = validate::one_of(
        "style",
        validate::required_text(fields, "style")?,
        &["plain", "ansi"],
    )?;
    // Icon, sound and text are content, not identifiers — bytes with caps, no
    // shape (§6.6): a toast's text legitimately carries newlines and ANSI.
    let icon = validate::required(fields, "icon")?;
    validate::max_len("icon", icon, 256)?;
    let sound = validate::required(fields, "sound")?;
    validate::max_len("sound", sound, 64)?;
    let text = validate::required(fields, "text")?;
    validate::max_len("text", text, 1024)?;

    if cfg!(not(target_os = "macos")) {
        // Refused on purpose: a host with no OSD answering `ok` would be a
        // silent sink for notifications aimed at the machine the human is at.
        return Err(ProtoError::new("unavailable", "no OSD on this host"));
    }

    // Provenance, not decoration: a toast raised across the bridge must never
    // be mistakable for one this machine raised itself.
    let mut labelled = Vec::new();
    if ctx.host.current().as_deref() != Some(origin_host) {
        labelled.extend_from_slice(origin_host.as_bytes());
        labelled.extend_from_slice(b": ");
    }
    labelled.extend_from_slice(text);

    // P5 made concrete: the wire carries an enum; the Lua global it maps to
    // never crosses the wire and is chosen from this table alone.
    let lua_fn = match style {
        "ansi" => "notifyAnsi",
        _ => "notify",
    };

    // Values reach Lua through side files, never string interpolation — the
    // injection boundary, since the text arrives from the network.
    let scratch = Scratch::new("notify")
        .map_err(|e| ProtoError::new("internal", format!("cannot stage the toast: {e}")))?;
    let dir = scratch.path();
    let write = |name: &str, bytes: &[u8]| std::fs::write(dir.join(name), bytes);
    write("text", &labelled)
        .and_then(|()| write("icon", icon))
        .and_then(|()| write("sound", sound))
        .and_then(|()| {
            let script = format!(
                "local function rd(p) local f=io.open(p,'rb'); if not f then return nil end; \
                 local c=f:read('*a'); f:close(); if c=='' then return nil end; return c end\n\
                 {lua_fn}(rd([[{dir}/icon]]), rd([[{dir}/text]]), rd([[{dir}/sound]]))\n",
                dir = dir.display()
            );
            write("notify.lua", script.as_bytes())
        })
        .map_err(|e| ProtoError::new("internal", format!("cannot stage the toast: {e}")))?;

    let mut command = Command::new(&ctx.tools.hs);
    command.arg(dir.join("notify.lua"));
    let run = run_with_deadline(command, HELPER_DEADLINE)
        .map_err(|_| ProtoError::new("internal", "hs run failed"))?;
    if !run.ok {
        return Err(ProtoError::new("internal", "hs run failed"));
    }
    Ok(Fields::new().into())
}
