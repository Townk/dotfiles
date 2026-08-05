# Notify over the clipboard bridge — plan

> **Status**: implemented. See "As built" at the end for the three places the
> implementation departs from the design below; the rest landed as written.
> Public repo; no employer/work identifiers. The personal Mac mini is
> `mac-mini` where a concrete host name is needed.

---

## Problem

`notify` paints a Hammerspoon OSD on **the machine where `hs` runs**, not where
the human sits. Over SSH into `mac-mini` or the Linux dev-shell, `notify()`
(`common.zsh:619-678`) still resolves local `hs` via `notify::available`
(`:591-597`) and succeeds against the wrong Hammerspoon — or returns 1 when no
`hs` exists (dev-shell, `:659`).

This is **destination-unaware routing**, not an SSH gate. `tmux-alert-notify:46-49`
and `copy-pwd:122-131` already suppress OSDs when `mux::session_is_remote` —
fixing the wrong-screen symptom but leaving remote sessions silent.

The bridge already carries non-clipboard GUI effects on the `public` endpoint:
`W` → `clip::op_window_action` at `clipboard-bridge-dispatch:236`, ungated like
`T`/`C`. Notify belongs on the same wire.

---

## Design

### Routing: one place

**`notify()` in `common.zsh`.** `executable_notify:25-60` sources `common.zsh`
and calls the shell function (shadows the external command — no recursion).
Callers either source and invoke the function (`tmux-alert-notify:58-59`,
`copy-pwd:135`) or exec `~/.local/bin/notify` (`pick-clipboard:464-468`,
`wezterm.lua:348`). The binary stays a thin CLI wrapper (help, rc-2 handling);
zero routing logic there.

### “Am I remote?” — reuse, do not invent

| Probe | Location | Use for notify? |
|---|---|---|
| Inlined SSH triple | `environment.sh:111-115` | No — early POSIX bootstrap only (`:105-110`) |
| `mux::is_remote` | `mux-bootstrap.zsh:119-121` | **Yes** — primary gate |
| `mux::session_is_remote` | `mux-bootstrap.zsh:139-155` | **At call sites only** — tmux server birth env lacks `SSH_*` (`:108-113`) |
| `sec::op_use_service` | `system-secrets-common.zsh:429-431` | No — 1Password auth, same triple but wrong semantic |

**Bridge route when:** `(mux::is_remote || NOTIFY_VIA_BRIDGE)` **and**
`clipbridge::probe 127.0.0.1 "${CLIPBOARD_BRIDGE_PORT:-2490}"` (same bridge-up
test as `pick-clipboard:103-105`; port convention `executable_pbpaste:196-207`).

**`NOTIFY_VIA_BRIDGE=1`:** set by tmux-server callers (`tmux-alert-notify`,
`copy-pwd`) when `mux::session_is_remote "$sess"` — not a fourth remote test,
just the session helper’s verdict passed in.

### Opcode `n` and payload

Add lowercase **`n`** to `clipboard-bridge-dispatch:195-238`, ungated on
`public` (like `W`). Repurposes the letter of the retired mirror `N`; lowercase
matches specialized ops (`f`, `a`).

**Encoding** — US (`\x1f`) multi-field, same convention as `O`/`M`
(`clip::op_declare_origin:1048-1050`, `clip::parse_manifest_payload:1070-1072`),
**not** the binary rich shape (`clip::parse_rich_payload:484-492`):

```
origin_host \x1f fn \x1f icon \x1f sound \x1f text
```

- `origin_host`: caller’s `clip::self_host` (identity chain of opcode `H`,
  `clip::op_get_host:630-631`); validated via `clip::valid_host` (`:211-215`).
- `fn`: `notify` or `notifyAnsi` (`common.zsh:643-645`).
- `icon`/`sound`: may be empty; empty sound → silent.
- Caps: host ≤253, icon ≤256, sound ≤64, text ≤1024 bytes → else `send_err`.

**Dispatch (`clip::op_notify`, macOS):** prefix display text with
`<origin_host>: ` when origin ≠ local `clip::self_host`; call global
`notify`/`notifyAnsi` via `clip::hs_run` (`hammerspoon/init.lua:31-36`,
`osd/init.lua:594-606`). Clear `SSH_*` in the handler if needed (mirror `W` at
`clipboard-store-core.zsh:664-667`). **Linux headless:** `send_err` — never a
sink; dev-shell clients terminate on the laptop’s macOS dispatcher one hop away.

**Client:** lazy-source `clipboard-bridge-client.zsh`; payload in temp file;
`clipbridge::send 127.0.0.1 "${CLIPBOARD_BRIDGE_PORT:-2490}" n "$payloadf"`;
timeout default 2s (`clipboard-bridge-client.zsh:22-28`).

### Routing tree

```
parse flags → empty? → rc 2
(mux::is_remote || NOTIFY_VIA_BRIDGE) && probe :2490?
  yes → send n; O → rc 0; fail → rc 1, NO local hs
  no  → existing hs path (:659-677)
```

**Double-notify:** branches exclusive — successful bridge send returns without
calling `notify::available`. **Fallback:** bridge failure when remote → rc 1
silently (`:615-617`); never fall back to local `hs` when remote (recreates
wrong-screen). **Local at mini** with `:2490` up from another SSH session:
`mux::is_remote` false → local `hs` wins.

**Nested SSH** (laptop → `mac-mini` → dev-shell): dev-shell’s `:2490` forwards
to mini `:2489`, not the laptop — OSD on mini, not laptop. Per-hop reverse
forward limit; document, do not chase v1.

### Call-site gates to remove

**`tmux-alert-notify`:** delete skip `:46-49`; set `NOTIFY_VIA_BRIDGE=1` when
session remote; keep bell `@bell_osd` gate (`:34-40`). UX: activity/silence/bell
OSDs on the laptop with `mac-mini: …` prefix; status-bar flags unchanged.

**`copy-pwd`:** delete `:122-131` suppression; same `NOTIFY_VIA_BRIDGE` pattern.
Keep `tmux display-message` fallback only when `notify` fails, not preemptively.

### Linux dev-shell

Gains working OSDs over SSH when the forward is live — no Linux GUI changes.
Bridge down → today’s silent rc 1. `pick-clipboard:464-468` benefits automatically.

### Security

`public` endpoint (`clipboard-bridge-dispatch:142-146`, listener `:2489`
`services.toml.tmpl:65-77`) is reachable from every SSH host. Existing ops
already allow pasteboard writes (`T`, `C`) and terminal control (`W`). **`n`**
is annoyance (OSD + optional sound), not exfiltration — lower than `T`, higher
than `W` for spam.

**v1:** (1) **origin label** on every remote-originated toast (validated host,
provenance UX like `clipboard-picker.lua:602`); (2) **length caps** above; (3)
**no rate limit** — `W` has none; revisit only if abused. Trusted-only would
defeat the purpose.

### GPG signing UX sequencing

Ship **this first**. `docs/gpg-signing-ux.md` Part 1 option C (alert when
pinentry popup opens) consumes bridge-routed `notify` — single call from
`pinentry-mux-popup`, no duplicate SSH logic. Then pinentry-mux; Part 2
(dev-shell `USE_CURSES`) unchanged.

---

## Implementation

1. `clipboard-store-core.zsh` — `clip::parse_notify_payload`, caps, `valid_host`.
2. `clipboard-platform-macos.zsh` — `clip::op_notify` (parse, prefix, `hs_run`).
3. `clipboard-platform-linux-headless.zsh` — stub → `send_err`.
4. `executable_clipboard-bridge-dispatch` — `n) clip::op_notify "$payload"`.
5. `common.zsh` — bridge branch in `notify()`, payload builder, lazy-source
   `mux-bootstrap.zsh` + `clipboard-bridge-client.zsh`.
6. `executable_tmux-alert-notify` — remove skip; `NOTIFY_VIA_BRIDGE` when remote.
7. `executable_copy-pwd` — remove session suppression; same override.
8. `docs/clipboard-universal-project.md` §11 — document opcode `n` (follow-up).

No changes to `executable_notify`, `_notify` completion, or Hammerspoon Lua.

---

## Tests

**`tests/notify_bridge_spec.sh`:** US payload builder; dispatcher `n` frames
(valid → `O`, bad host/oversize → `E`, origin prefix); `notify()` routing
(SSH+probe → bridge not `hs`; local → `hs`; `NOTIFY_VIA_BRIDGE` without
`SSH_*`; bridge fail + remote → rc 1, no `hs`).

**`tests/clipboard-bridge_spec.sh`:** add `Describe` for opcode `n` (reuse
framing helpers at `:1-81`).

---

## Verification

Laptop → `mac-mini` tmux: activity alarm → laptop OSD `mac-mini: …`, not mini
screen. `copy-pwd` → laptop OSD. Local mini → local `hs` only. Dev-shell SSH +
bridge up → laptop OSD; bridge down → rc 1. Nested hop → mini screen (documented
limit). `pick-clipboard` Ctrl-Y toast over SSH → laptop with origin label.
`shellspec tests/notify_bridge_spec.sh tests/clipboard-bridge_spec.sh` after
`chezmoi apply`.

---

## As built

Three departures from the design above, each forced by something the design
got wrong or did not anticipate.

**1. The bridge probe is not part of the routing gate.** The design gave two
conflicting rules: the routing tree makes the route conditional on
`(remote) && probe`, which falls through to the local `hs` when the probe
fails, while the Fallback paragraph says "never fall back to local `hs` when
remote (recreates wrong-screen)". The tree's version is the wrong-screen bug
itself — on `mac-mini` with the tunnel down it paints the OSD on the mini.
Remoteness alone now selects the route, and the send is its own reachability
test (against loopback a missing listener refuses immediately, so the probe
bought nothing but a fork). `_notify_bridge_target` answers only "where is the
human"; `clipbridge::probe` is not called at all. Covered by
`notify_bridge_spec.sh`, "fails quietly rather than painting on the wrong
screen".

**2. The payload file is a bare `mktemp`, not `common::tmpfile`.** Found by
running copy-pwd rather than reasoning about it: over SSH it fell back to the
status line and no frame ever reached the wire. `common::tmpfile` allocates
inside the per-process scratch dir that the parent's `EXIT` trap removes, and
copy-pwd backgrounds its OSD (`notify … &`) and exits immediately — so the
payload was deleted mid-flight and `clipbridge::send` refused an unreadable
file. Since `notify`'s own contract invites backgrounding, the send now owns
its temp file exactly as `clipbridge::send` already does for its request and
response. Regression test: "still delivers when backgrounded and the parent
exits first".

**3. copy-pwd drops its `notify::available` pre-flight entirely.** The design
said to keep the `tmux display-message` fallback "only when `notify` fails";
with the OSD backgrounded, the only way to observe that failure is to move the
fallback inside the background job, which is where it now lives. The local-`hs`
probe went with it — over SSH "is there a local `hs`" is the wrong question,
and `notify`'s return code already answers the right one. `notify::available`
consequently has no callers outside `notify` itself.

Verified by direct execution of both call sites (local client → local `hs`;
remote client + bridge up → `n` frame only; remote client + bridge down →
status line, no local OSD), plus `notify_bridge_spec.sh` and the `n` Describe
in `clipboard-bridge_spec.sh`.

---

## Fact check

Verified: (1)–(7) as stated. **Corrections:** SSH skip is at `tmux-alert-notify:46-49`,
not `:1-25` (header comment at `:7-9` only). **`copy-pwd:122-131` duplicates
the same gate** — in scope, not in the seven facts.
