#!/usr/bin/env zsh
# clipboard-bridge-client.zsh — the shell's doorway to the RECOB bridge
# (docs/recob-protocol-spec.md). Every function here is a thin, op-shaped
# wrapper over `system-bridge`, the generic invoker installed at
# ~/.local/libexec/system-bridge: one connection, one §4.3 request, one
# reply. The binary is the client (§8 — it speaks the wire, spawns nothing);
# these functions only shape arguments for their callers, so no opcode, frame
# byte or payload layout survives in shell.
#
# Callers: pick-clipboard (clip.get / clip.set / clip.set.rich /
# clip.set.files / store.persist.text), common.zsh's notify (osd.notify),
# mux-fullscreen-probe (window.fullscreen.state), terminal-toggle-fullscreen
# (window.fullscreen.toggle).
#
# CLIPBRIDGE_TIMEOUT_S keeps its meaning — it maps onto the client's §5.2
# exchange deadline (RECOB_TIMEOUT_S). Ops that make the origin DO something
# (a window animation, a first-use macOS Automation consent dialog) go out
# with --action, which selects the longer §5.2 action deadline instead.

# clipbridge::bin -> the generic invoker. SYSTEM_BRIDGE_BIN is the seam the
# spec suite points at its own build (the CLIPBOARD_MOUNT_BIN precedent).
clipbridge::bin() {
  print -rn -- "${SYSTEM_BRIDGE_BIN:-$HOME/.local/libexec/system-bridge}"
}

# clipbridge::probe <host> <port>
#   0 iff something is accepting on host:port (a live forward). §6.1:
#   reachability is not an operation — this is §5.2's connect result
#   (ECONNREFUSED down, anything else up), computed by the client library,
#   never an authenticated round trip. Strictly more accurate than the old
#   `nc -z`, which reported down for a bound but saturated listener.
clipbridge::probe() {
  "$(clipbridge::bin)" probe "$1" "$2" 2>/dev/null
}

# clipbridge::call [--peer|--action|--raw <field>|--stdin <name>]... <op> [name=value]...
#   The generic escape hatch: everything passes straight through to
#   `system-bridge call`. CLIPBRIDGE_TIMEOUT_S maps onto the §5.2 exchange
#   deadline unless the caller already set RECOB_TIMEOUT_S explicitly.
clipbridge::call() {
  if [[ -n "${CLIPBRIDGE_TIMEOUT_S:-}" && -z "${RECOB_TIMEOUT_S:-}" ]]; then
    RECOB_TIMEOUT_S="$CLIPBRIDGE_TIMEOUT_S" "$(clipbridge::bin)" call "$@"
  else
    "$(clipbridge::bin)" call "$@"
  fi
}

# --- the peer's clipboard (public endpoint over the reverse tunnel) ---------

# clipbridge::clip_get_raw <field>
#   One clip.get against the peer, exactly one reply field's bytes on stdout:
#   text, regtype, timestamp or host. Byte-exact — never routed through a
#   $(...) capture here, so redirect to a file for text that may carry NULs.
clipbridge::clip_get_raw() {
  clipbridge::call --peer --raw "$1" clip.get
}

# clipbridge::set_text <regtype>   (text bytes on stdin)
#   clip.set on the peer: regtype v|l|b rides as a field, the text bytes ride
#   stdin so any byte survives.
clipbridge::set_text() {
  clipbridge::call --peer --stdin text clip.set "regtype=$1"
}

# clipbridge::set_text_local <regtype>   (text bytes on stdin)
#   The same clip.set against THIS machine's own bridge over the trusted
#   socket — a local Ctrl-Y that must record the regtype alongside the write.
clipbridge::set_text_local() {
  clipbridge::call --stdin text clip.set "regtype=$1"
}

# clipbridge::ship_rich <uti>   (blob bytes on stdin)
#   clip.set.rich on the peer: one typed pasteboard payload (an image, a PDF).
#   The public endpoint's §9.3 UTI allow-list is the daemon's to enforce.
clipbridge::ship_rich() {
  clipbridge::call --peer --stdin blob clip.set.rich "uti=$1"
}

# --- this machine's store and pasteboard (trusted socket) -------------------

# clipbridge::persist_text <host> <kind> <app> <regtype>   (text on stdin)
#   store.persist.text on THIS machine's bridge — the history row a
#   materialized live-peer entry deserves.
clipbridge::persist_text() {
  clipbridge::call --stdin text store.persist.text \
    "host=$1" "kind=$2" "app=$3" "regtype=$4"
}

# clipbridge::set_files_paths   (NUL-joined absolute paths on stdin)
#   clip.set.files{paths}: put a file manifest on this machine's pasteboard.
clipbridge::set_files_paths() {
  clipbridge::call --stdin paths clip.set.files
}

# clipbridge::set_files_id <rowid>
#   clip.set.files{clip_id}: restore a store row's manifest by id. The old
#   `id:<rowid>` prefix is gone — named fields carry the discriminator
#   (§6.1), and clip_id is the bare decimal rowid.
clipbridge::set_files_id() {
  clipbridge::call clip.set.files "clip_id=$1"
}

# --- the origin's screen (public endpoint over the reverse tunnel) ----------

# clipbridge::notify <style> <icon> <sound> <origin_host>   (text on stdin)
#   osd.notify: style is the closed enum plain|ansi — the Lua global name the
#   old wire carried never crosses anymore (P5); the handler maps the enum to
#   its callable internally.
clipbridge::notify() {
  clipbridge::call --peer --stdin text osd.notify \
    "style=$1" "icon=$2" "sound=$3" "origin_host=$4"
}

# clipbridge::fullscreen_state -> `true` or `false` on stdout.
clipbridge::fullscreen_state() {
  clipbridge::call --peer --raw state window.fullscreen.state
}

# clipbridge::fullscreen_toggle <terminal>
#   window.fullscreen.toggle for ghostty|wezterm. --action: the origin DOES
#   something — a window animation, possibly gated on a first-use macOS
#   Automation consent dialog a human must click — and timing out there
#   reports "refused" for an action that actually happened.
clipbridge::fullscreen_toggle() {
  clipbridge::call --peer --action window.fullscreen.toggle "terminal=$1"
}
