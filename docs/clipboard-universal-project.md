# Universal Clipboard — Project Spec

> **Recovery note**: this file was accidentally deleted (an `rm -rf
> ~/.local/share` during Phase 2 self-testing — a cleanup script resolved its
> "sandbox" path from the Hammerspoon daemon's environment instead of the
> shell's, and the daemon's `XDG_DATA_HOME` pointed at the real thing). It was
> never committed to git, so git couldn't recover it. **This is not a
> best-effort reconstruction — it's the actual original text**, recovered
> from an earlier session's transcript (a `Write` tool call's logged input
> happened to contain the full file). Phases 1–4 below are now implemented;
> see the status note added under §18 for what shipped vs. what this
> original spec called for (a few details evolved during implementation —
> notably Phase 4 became a full custom `hs.webview` UI, not the `hs.chooser`
> this spec describes, and Phase 1's provider doesn't push over the bridge
> during `copy()` the way §9 describes). Phase 5 (bridge evolution) is next
> and **has not been started** — its design below is still the live plan.

A single clipboard history + type-preserving copy/paste system that works
across the laptop, a mac-mini (used locally or over SSH), a Linux dev shell
over SSH, and an iPad via Blink Shell. One shared data model; idiomatic
front-ends per context. Evolves the **existing** `clipboard-bridge` already
in the repo — does not rebuild it from scratch.

> This is a requirements + design document, not a commit-history log. It is
> committed to a **public** repo: it must contain no company/work identifiers
> (employer names, work hostnames/SSH aliases, corporate usernames, internal
> tool names). References to the remote dev shell use the generic phrase
> "the dev shell" / `<remote>`, never a real alias.

---

## 1. Goals

- Browse clipboard history from the terminal (a Zellij floating picker) and
  from the macOS GUI (a Hammerspoon `hs.chooser`), both reading the **same**
  store.
- Paste selected items directly into the terminal pane (inject) or copy them
  back to the active machine's clipboard.
- Full **rich content** round-trip: plain text, RTF/HTML, images, file
  references — restored with all pasteboard representations, like Raycast.
- **Type-preserving** NeoVim copy/paste, including visual-**block** (`Ctrl+V`)
  selections, within a session **and** across machines. Fixes the existing
  `E5108: provider returned invalid data` error from yanky.nvim.
- Works on macOS (laptop + mac-mini), Linux (dev shell, Wayland/X11), and
  over SSH from the laptop or from Blink Shell on iPad.
- Sensitive clips (passwords, transient pasteboards) are never captured.

## 2. Non-goals

- Peer-to-peer automatic sync between two GUI machines' clipboards (e.g.
  mac-mini `⌘C` auto-flowing to the laptop without a command). The mac-mini
  is a standalone "laptop" when you sit at it; cross-machine flow is
  command/session-driven via the bridge.
- A separate in-editor yank ring. The universal store + picker **is** the
  yank ring (with `clipboard=unnamedplus`, every yank flows through the
  provider into the store).

## 3. Critical context: the bridge already exists

The repo already contains a working clipboard bridge for NeoVim over SSH.
Read these before designing anything:

- `home/dot_config/nvim/lua/config/options.lua` lines 50–92 — the SSH-gated
  NeoVim clipboard provider:
  - `clipboard = unnamedplus` on SSH.
  - **copy** = bundled `vim.ui.clipboard.osc52` (write-only; avoids the
    Zellij OSC 52 *read* hang).
  - **paste** = `nc -U -w 1 <socket>` against
    `$HOME/.local/state/runtime/chezmoi-system/clipboard-bridge.sock`,
    served by a macOS launchd `clipboard-bridge` service that returns
    `pbpaste`; brought up by a reverse SSH tunnel declared in the loose,
    untracked `~/.ssh/config.d/clipboard.config`.
  - Fallback: the unnamed register `""` when the socket/`nc` is unavailable.
  - Local (non-SSH): default `pbcopy`/`pbpaste`.
- The macOS `clipboard-bridge` launchd service (read its plist + the service
  script as the first implementation step — it is the existing transport to
  extend, not duplicate).
- `~/.ssh/config.d/clipboard.config` (loose, untracked, never committed —
  may reference work SSH aliases) — the existing reverse `StreamLocalForward`.

### The E5108 root cause, pinpointed in existing code

`options.lua:82` returns regtype **hardcoded to `"v"`**:

```82:82:home/dot_config/nvim/lua/config/options.lua
            return { out, "v" }
```

A visual-**block** yank (regtype `b`) is copied via OSC 52, then
`getreg('+')` → `paste()` reads `pbpaste` through the tunnel and returns
`{out, "v"}` — block-ness destroyed. yanky.nvim's `init_ring` rejects the
corrupted round-trip as "invalid data." The fix is a **type-preserving
provider** (Section 9) that returns the real regtype, not a hardcoded one.
Same socket, same tunnel — stop throwing the type away.

## 4. Architecture overview

```
                ┌─────────────────────────────────────────────────────┐
                │                 SQLite store (per machine)           │
                │  clips(id, text_preview, text_plain, len,            │
                │         first_ts, last_ts, source_app, type_kind,    │
                │         origin, regtype, pinned)                     │
                │  clip_types(clip_id, uti, blob)   -- rich payloads    │
                └─────────────────────────────────────────────────────┘
                      ▲ write                        ▲ read        ▲ read
                      │                              │             │
   ┌──────────────────┴────────┐    ┌────────────────┴──┐   ┌──────┴──────┐
   │ Capture shim (per OS)     │    │ pick-clipboard    │   │ Hammerspoon  │
   │  macOS: hs.pasteboard.    │    │  (fzf, in Zellij) │   │ hs.chooser   │
   │   watcher  (rich)         │    │  Alt+w v          │   │ Cmd+Shift+V  │
   │  Wayland: wl-paste --watch│    └───────────────────┘   └──────────────┘
   │  X11: xclip-poll          │
   └───────────────────────────┘
                      │
                      │  (laptop→remote: text + metadata + id only, no BLOBs)
                      ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │ Bridge (evolve existing clipboard-bridge)                            │
   │  laptop→remote (-L StreamLocal): history mirror into remote DB       │
   │  remote→laptop (-R StreamLocal): copy-back, get-channel, rich BLOBs  │
   │  length-prefixed binary framing; regtype rides alongside             │
   └─────────────────────────────────────────────────────────────────────┘
                      │
                      ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │ NeoVim clipboard provider (type-preserving) + pbcopy/clip-copy shims │
   │  copy(lines, regtype) → cache + bridge push (OSC 52 / tunnel / pbcopy)│
   │  paste()              → {lines, regtype} from cache / get-channel    │
   └─────────────────────────────────────────────────────────────────────┘
```

## 5. Store

`${XDG_DATA_HOME:-~/.local/share}/pick-clipboard/history.db`, SQLite **WAL**
mode. Machine-local, **untracked, never committed, never synced via the repo**
(sensitive clips). Created on first use.

- `clips(id INTEGER PK, text_preview TEXT, text_plain TEXT, len INTEGER,
  first_ts REAL, last_ts REAL, source_app TEXT, type_kind TEXT, origin TEXT,
  regtype TEXT, pinned INTEGER DEFAULT 0)`
  - `type_kind` ∈ `text|rtf|html|image|files|mixed` (row badge).
  - `origin` ∈ `local|laptop-ref|remote-own` (drives the picker's
    union-vs-local filter, Section 8).
  - `regtype` ∈ `v|l|b` (Vim register type, when the write came from the
    NeoVim provider; NULL otherwise).
- `clip_types(clip_id INTEGER, uti TEXT, blob BLOB)` — one row per UTI, via
  `hs.pasteboard.readAllData()` on macOS. Enables full rich restoration.
- **Dedup** on a hash of the type-set; re-copy bumps `last_ts` (recency for
  free — no `--cache-usage` file). The most-recently-copied item floats to
  the top in every front-end.
- **Retention**: ≤1000 rows, skip images > ~5 MB, total-store cap with
  oldest-dropped sweep on write.
- Concurrency: WAL so the capture writer and the picker/chooser readers never
  block each other.

> **As-built note**: `source_bundle_id` was added by a later migration (not
> in this original schema) for app-icon lookup in the GUI picker's metadata
> pane. `type_kind` also grew `file`/`directory`/`url`/`mixed` refinements
> beyond the original `text|rtf|html|image|files|mixed` set.

## 6. Capture shims (per-OS, behind one shared SQLite writer)

The OS-specific part is ~20 lines: insert/dedup a row. Everything downstream
is OS-agnostic.

- **macOS** (laptop + mac-mini): `hs.pasteboard.watcher` (0.5s `changeCount`
  poll — macOS offers no native pasteboard notification) in Hammerspoon.
  Before storing, **skip** clips carrying `org.nspasteboard.ConcealedType`,
  `TransientType`, or `AutoGeneratedType` (inspect
  `hs.pasteboard.allContentTypes()`); plus an app-name deny-list (Keychain,
  1Password, Bitwarden, …). Store full `hs.pasteboard.readAllData()` →
  `clips` + `clip_types`. Records `source_app` via
  `hs.application.frontmostApplication():name()`.
- **Wayland**: `wl-paste --watch <writer>` (genuinely event-driven) → same
  schema, text-only.
- **X11**: xclip polling daemon → same.
- **Headless / dev shell**: no GUI clipboard; its DB is fed by the bridge
  (laptop mirror) + `pbcopy`/`clip-copy` shims + editor yanks.

The skip-filter runs **before any forward** to the bridge, so sensitive
content never leaves the originating machine.

## 7. `pick-clipboard` (picker, pick silo)

New `~/.local/libexec/executable_pick-clipboard`, modeled on
`~/.local/libexec/executable_pick-glyph`: stream rows straight from SQLite
into `pick::start` (no assembled-lines cache, no jq),
`ORDER BY pinned DESC, last_ts DESC LIMIT N`.

- **Wire format** (the `\x1f`/`\x1e` contract from `pick-common.zsh`):
  `<preview>\x1f<content>\x1e<id>`. Preview = first line (newlines → `⏎`,
  truncated ~60 cols) + dim `· {len}c · {app} · {reltime} · {type_kind}`.
- **Keys**:
  - `Enter` → `--output field:1` → emit content (inject into pane in Zellij).
  - `Alt-Enter` → `--key-background` insert-without-dismiss (existing FIFO
    broker → `PICK_INJECT_PANE`).
  - `Ctrl-Y` → **accept + dismiss**: copy the selected item to *my*
    clipboard (Section 8: target depends on access path; full rich where
    possible), then close the picker. This is the clipboard counterpart of
    `Enter` (which injects into the pane) — same accept-and-close behavior,
    different sink. Distinct from `Alt-Enter`, which is `--key-background`
    (insert without dismissing). If a copy-and-stay variant is ever wanted,
    add it as a separate `--key-background` binding, not by changing `Ctrl-Y`.
  - `Ctrl-D` / `Alt-D` → delete row (`--key-background` + custom
    `--on-key-background` hook, `DELETE WHERE id=?`).
  - `Ctrl-P` → toggle pin.
- `--on-items-picked` re-bumps `last_ts` (and re-copies on the local path).
- `--cache-state` / `--resume` for query + cursor restore.
- **Origin filter** (Section 8): `WHERE` clause gated on bridge-up.
- **Preview pane**: add a minimal `--preview` passthrough to
  `pick-common.zsh` (additive — no behavior change for existing pickers) so
  multi-line clips show full content by id.

> **As-built note**: the wire format, keybindings, and preview shipped
> differently from this early sketch — see the *actual* keys/format/preview
> footer as implemented in `pick-clipboard` (§7 continues to evolve after
> Phase 4's GUI parity work; treat the live script as the source of truth for
> the terminal picker's current behavior, this section as historical intent).

### Zellij integration (terminal-mux silo)

- `~/.config/zellij/scripts/executable_pick-clipboard-zellij` — twin of
  `executable_pick-glyph-zellij`: sets `PICK_CLIPBOARD_HEIGHT=-4` etc. and
  `exec pick-clipboard --no-border "$@"`.
- One `bind` in `~/.config/zellij/config.kdl.tmpl` via the existing
  `zellijModalRun` template: `inject true`, `borderless true`,
  `no_chrome true`, `width 70%`, `height 60%`, **`Alt w v`** (leader chord —
  no collision with terminal paste, matches the `Alt w U`/`G` resume
  chords).

> **As-built note**: the landed keybind is `Alt+w c` (for "clipboard"), not
> `Alt+w v` — `Alt+w v` collided with the existing tmux-mode `v` (split-right).

## 8. Access-path matrix and the 3-way detection

The picker and the `pbcopy`/`clip-copy` shims key off two signals:
`$SSH_CONNECTION` (am I in an SSH session?) and **bridge-up** (is the reverse
`-R` socket connectable, i.e. is a laptop driving this remote?). Bridge-up is
also the signal the existing `pbcopy` shim uses to route.

| Scenario | `$SSH_CONNECTION` | bridge (`-R`) up | Picker shows | `Ctrl-Y` / `pbcopy` target |
|---|---|---|---|---|
| Sitting at mac-mini (GUI) | unset | no | **local-only** | `/usr/bin/pbcopy` (local) + `Cmd+Shift+V` chooser |
| Laptop → SSH → mac-mini/dev shell | set | yes | **union** (local + live laptop mirror) | reverse channel → laptop (restore-by-id / BLOB-ship) |
| iPad → Blink → SSH → mac-mini | set | no | **local-only** | **OSC 52 → iPad** |

- **Picker origin filter**: bridge-up → `origin IN ('local','remote-own','laptop-ref')`
  (union; `laptop-ref` is live). bridge-down →
  `origin IN ('local','remote-own')` — **excludes stale `laptop-ref` rows**
  from prior laptop sessions, so the iPad / sitting-at views never show
  dusty laptop history.
- **`laptop-ref` refresh**: on each laptop connect, the remote clears
  `origin='laptop-ref'` rows and re-feeds from the laptop's current history,
  so the mirror stays current and bounded.

### `Ctrl-Y` resolution by origin (when bridge-up)

- `laptop-ref` row → restore-by-id: send `{restore, laptop_id}` on the
  reverse channel; the laptop restores from its own DB via
  `hs.pasteboard.writeAllData`. **Full rich, zero BLOB transfer** (the
  payload already lives on the laptop). Fallback on id-miss → OSC 52 text.
- `local` / `remote-own` row → ship BLOBs over the reverse channel directly
  to the laptop receiver → `writeAllData`.

## 9. NeoVim clipboard provider (type-preserving) + drop yanky

### Replace the `options.lua` provider

`g:clipboard` accepts Lua functions: `copy(lines, regtype)` receives the
regtype; `paste()` returns `{lines, regtype}` (regtype ∈ `v|l|b`). The new
provider (nvim silo, a Lua module under `home/dot_config/nvim/lua/`):

- **`copy(lines, regtype)`** — write `{lines, regtype}` to a tiny dedicated
  cache (`$XDG_CACHE_HOME/nvim-clipboard/last`), **and** push the text to the
  bridge:
  - SSH + bridge-up → reverse channel to laptop (`writeAllData` there) +
    send `{regtype}` so the laptop records "current regtype."
  - SSH + bridge-down (iPad/Blink) → OSC 52 (text; Blink supports it over
    SSH, ~75 KB cap).
  - Local → `/usr/bin/pbcopy` (macOS) / `wl-copy` / `xclip`.
  Also write to the universal store (with `regtype`), so every yank enters
  history (the picker is the yank ring).
- **`paste()`** — return `{lines, regtype}`:
  - SSH + bridge-up → read the laptop clipboard via the existing tunnel
    `nc -U` **and** fetch the current regtype from the laptop (new
    `get-regtype` op on the bridge) → `{text, regtype}`. Block preserved
    across machines.
  - SSH + bridge-down → OSC 52 has no get; return from the local cache
    (in-session, type-correct, never errors).
  - Local → `pbpaste` / `wl-paste` / `xclip -o`, regtype from cache or
    inferred (trailing newline → `l`, else `v`).
- **"Current regtype" on the laptop**: the bridge records the regtype of the
  most recent clipboard write. The Hammerspoon watcher resets it to inferred
  whenever a non-NeoVim app overwrites the clipboard (changeCount bump from a
  non-provider source). This is the currency tracking for cross-machine block.
- The existing `clipboard-bridge` launchd service is **extended** to serve
  rich (`{uti,blob}` sets, not just `pbpaste` text) + a `get-regtype` op +
  the store-backed `get`. Same socket path.
- `cache_enabled` is ignored for function providers — the provider owns its
  cache file. If `vim.g.clipboard` is set after startup, reload:
  `vim.g.loaded_clipboard_provider = nil; vim.cmd('runtime autoload/provider/clipboard.vim')`.

> **As-built note (Phase 1, already landed — differs from the above)**: the
> landed `universal.lua` provider is simpler than this original design. It
> keeps `copy()` write-only-OSC-52 (no bridge push, no store write from
> inside the provider — capture into the store is Phase 2's separate
> Hammerspoon watcher, not the nvim provider itself) plus a **per-process,
> local-only** `{lines, regtype}` cache — not the shared, cross-machine
> "current regtype on the laptop" mechanism described above. Cross-machine
> block preservation (real §9, not this simplified stand-in) is still
> Phase 5 scope, tracked in the current doc's own §9 gap note alongside the
> bridge evolution work.

### Drop yanky.nvim

Remove `gbprod/yanky.nvim` (in `home/dot_config/nvim/lua/plugins/coding.lua`)
and the `lazyvim.plugins.extras.coding.yanky` extra in
`home/dot_config/nvim/lazyvim.json`. Rationale: it is the active error source;
its ring is subsumed by the universal store + picker (cross-machine, richer);
its config maps only `p`/`P`/`gp`/`gP` (no cycle keys) so its distinctive
inline paste-cycle is unused; stock `p`/`P` covers plain put. With
`clipboard=unnamedplus`, every yank flows through our provider into the store.
If inline paste-cycle is ever wanted later, a small keymap reading from the
store can add it — not part of this project.

## 10. Hammerspoon chooser (macOS GUI)

- `hs.chooser` bound globally to **`Cmd+Shift+V`** (accept the Raycast /
  Paste-and-Match-Style shadow — Raycast already owns this chord today).
- Reads the same `history.db` on each open; rows =
  `{text=preview, subText=badge · app · time, content/id/type_kind}`.
- Select → load `clip_types` for id → `hs.pasteboard.writeAllData({uti=blob,…})`
  → the chooser's default `globalCallback` (`willOpen` saves
  `frontmostWindow()`, `didClose` refocuses it) has pulled focus back to the
  target app → post `⌘V` (drop to `hs.eventtap.event.newKeyEvent` if
  `keyStroke` inter-key delay bites).
- **Full rich restore** (RTF, images, file refs) — matches Raycast.
- Re-bump `last_ts` on pick. **Select = paste** (fast path); delete / pin /
  insert-without-dismiss live in the terminal picker (`hs.chooser` doesn't
  bind arbitrary in-overlay keys).

> **As-built note**: Phase 4 shipped as a full custom `hs.webview` UI
> (`apps/clipboard-picker.lua`), not `hs.chooser` — `hs.chooser` turned out
> unable to do split panes, custom border/corner-radius styling, or bind
> in-panel keys (Ctrl-D delete, Ctrl-P pin, Ctrl-Enter/Alt-Enter), all of
> which the terminal picker had already grown by the time Phase 4 landed.
> The webview matches the WhichKey overlay's visual identity and does
> support all of those, unlike `hs.chooser`.

## 11. Bridge — evolve the existing `clipboard-bridge`

> **Status: not started (Phase 5, next up).** Everything in this section is
> still the live, agreed design — nothing here has been superseded.

Loose `~/.ssh/config.d/clipboard.config` (untracked, never committed),
`StreamLocalBindUnlink yes`:

- **laptop→remote (`-L` StreamLocal forward)**: the capture shim writes
  **text + metadata + laptop-id only (no BLOBs)** to a local forwarded
  socket. A remote framed-socket daemon (systemd user unit on Linux;
  launchd on a macOS remote) listens on
  `~/.local/state/runtime/chezmoi-system/clipboard-bridge.sock`, ingests
  into the remote DB as `origin='laptop-ref'`. Length-prefixed binary
  framing. Bandwidth stays tiny.
- **remote→laptop (`-R` StreamLocal forward)** — already exists for `pbpaste`;
  extend to carry:
  - `{restore, laptop_id}` — copy-back by id (full rich, no BLOB transfer).
  - `{copy, uti, blob}` — remote-originated rich (rare; e.g. an image file
    on the dev shell) → laptop `writeAllData`.
  - `{get}` / `{get-regtype}` — the NeoVim provider's cross-machine paste.
  - `{fetch_file, remote_path}` — Section 12.
- **Laptop receiver**: extend the existing `clipboard-bridge` launchd
  service (or a sibling helper) to handle these ops, dispatching to
  Hammerspoon via `hs -c 'clipboard.restore_by_id(N)'` (rich) or `pbcopy`
  (text). Do **not** use `hs.socket` for the Unix listener — its Unix-domain
  server requires timer polling (CocoaAsyncSocket limitation, confirmed
  upstream); use a standalone framed-socket daemon that shells out to `hs`.
- Verify `AllowStreamLocalForwarding yes` on the dev shell's `sshd_config`
  (default is `yes`).

**Why this beats a custom base64-over-socket protocol for the common case**:
the reverse channel is already a raw byte-capable unix socket (via SSH
`StreamLocalForward`), so nothing here needs text-armoring — length-prefixed
binary framing carries `{copy, uti, blob}` bytes directly when a blob truly
must move. But for the *far more common* case — you copied something rich
on the laptop and you're just picking it from a remote session — the blob
never needs to travel at all: `{restore, laptop_id}` tells the laptop to
restore its own stored clip onto its own pasteboard via
`hs.pasteboard.writeAllData`. The "protocol" for that path is just an id.

## 12. Remote file copy — scp-down + local file-url

- **Laptop-originated file ref** (copied in Finder): restore-by-id (Section
  8) restores the original `public.file-url` on the laptop — works, the file
  is local. No transfer.
- **Remote→local file copy**: `Ctrl-Y` on a `files`-kind row sends
  `{fetch_file, remote_path}` on the reverse channel. The laptop receiver
  `scp`s the file to a local temp dir, puts a real `public.file-url`
  (pointing to the temp file) on the pasteboard, and schedules cleanup on
  paste-or-timeout. Pasting into Finder then works.
  - An `scp:` URI alone does **not** paste into Finder (Finder pastes
    `public.file-url`, not `scp:`); the scp-down-to-temp + local-url path is
    the honest way. `scp:` URIs only matter for apps that explicitly handle
    them (Transmit, Cyberduck) — out of scope.

## 13. `pbcopy` / `clip-copy` shims

A bridge-aware `pbcopy` shim on the mac-mini and the dev shell (and
`clip-copy` for files/images), so `pbcopy` always writes to *your* clipboard,
where "you" is decided by bridge-up:

- bridge-up (laptop SSH'd in) → reverse-channel send to the laptop
  (`writeAllData` / `pbcopy` there) → lands on the laptop clipboard. The
  laptop's own watcher then captures it into the laptop store (full circle).
- no bridge + SSH (iPad/Blink) → OSC 52 to the iPad (text).
- no bridge + no SSH (sitting at mac-mini) → `exec /usr/bin/pbcopy` (real,
  local-to-mac-mini).
- `clip-copy <file>` = same shim, file/image mode with UTI detection
  (`png`→`public.png`, `jpg`→`public.jpeg`, `tif`→`public.tiff`,
  `pdf`→`com.adobe.pdf`, `txt`→`public.utf8-plain-text`, …).
- `clip-copy --clipboard` = read this remote's own clipboard and forward
  (mac-mini: `osascript … as «class PNGf»` / `pngpaste`; Linux: `wl-paste -t
  image/png` / `xclip -o -t image/png`).

> **As-built note**: the landed `pbcopy`/`pbpaste` shims (Phase 1/pre-project)
> are simpler than this — plain text only, no `clip-copy` file/image mode
> yet. This section is Phase 6 scope, not started.

## 14. Honest limits (must be handled, not hidden)

- **OSC 52 is text-only and capped**: Blink ~75 KB over SSH (not mosh);
  ghostty/wezterm have their own caps. Oversized `Ctrl-Y`/`pbcopy` text
  fails with a clear message, not silent truncation. Images cannot cross
  OSC 52 at all — they only reach a *laptop* via the reverse bridge, never
  an iPad.
- **zellij OSC 52 passthrough — verify first**. The picker and provider run
  inside a Zellij pane, so OSC 52 must pass through Zellij to reach the host
  terminal (Blink/ghostty/wezterm). Zellij has OSC 52 support but
  passthrough from a pane must be confirmed against the installed
  Zellij version/config. **This is the first implementation verification** —
  every OSC 52 copy-back path depends on it.
- **No images to the iPad.** `Ctrl-Y` on an image row from the iPad = no-op
  with a message.
- **UTI detection**: wrong UTI → garbage on the pasteboard. Detect from
  extension first, then `file --mime-type`.
- **`laptop-ref` rows are text + id only** on the remote. The remote can
  *show* them (origin-badged) and copy them back by id, but cannot inject
  rich BLOBs into a terminal pane (terminals take text). Rich copy-back of
  a `laptop-ref` row resolves the BLOB on the laptop via restore-by-id.
- **Storage cost**: image BLOBs can be MBs. Per-representation cap (~5 MB),
  total-store cap, oldest-dropped retention sweep.

## 15. Security

- The store contains sensitive clips. It is **machine-local, untracked,
  never committed, never synced via the repo**. Same for the
  `nvim-clipboard` cache file.
- Capture skips `Concealed`/`Transient`/`AutoGenerated` pasteboard types and
  a password-manager app deny-list, **before** any bridge forward.
- The reverse bridge only runs over your own SSH session to your own
  machines. The laptop receiver writes to the pasteboard only from the
  socket — no network listener.
- The loose `~/.ssh/config.d/clipboard.config` is never committed (it may
  reference work SSH aliases).

## 16. Files touched

**New**
- `home/dot_local/libexec/executable_pick-clipboard` (pick silo)
- `home/dot_config/zellij/scripts/executable_pick-clipboard-zellij` (terminal-mux)
- `home/dot_config/hammerspoon/modules/apps/clipboard-history.lua` + wiring in
  Hammerspoon `init.lua` (watcher + chooser + `restore_by_id` + `writeAllData`)
- `home/dot_config/nvim/lua/clipboard/universal.lua` (the type-preserving
  provider) + wiring in `options.lua` (replaces lines 50–92's provider)
- Laptop framed-socket receiver / extended `clipboard-bridge` launchd service
  (utils/shell)
- Remote framed-socket daemon + systemd user unit (Linux dev shell)
- `pbcopy` / `clip-copy` shims (utils/shell)
- Wayland `wl-paste --watch` writer + X11 xclip-poll writer (utils/shell)
- The untracked SQLite store + nvim cache (runtime data, not in the repo)
- Loose `~/.ssh/config.d/clipboard.config` additions (untracked)

**Edited**
- `home/dot_local/lib/pick-common.zsh` — additive `--preview` passthrough
  (pick silo; no behavior change for existing pickers).
- `home/dot_config/zellij/config.kdl.tmpl` — one `bind "v"` in the `tmux`
  leader mode block (terminal-mux).
- `home/dot_config/nvim/lua/config/options.lua` — replace the SSH clipboard
  provider block with the type-preserving one (nvim).
- Hammerspoon `init.lua` — wire the watcher + chooser.

**Removed**
- `gbprod/yanky.nvim` block in `home/dot_config/nvim/lua/plugins/coding.lua`.
- `"lazyvim.plugins.extras.coding.yanky"` from
  `home/dot_config/nvim/lazyvim.json`.

## 17. Silo routing

This is a cross-silo project. Each piece lands in its owner silo; coordinate
the seams.

- `pick-common.zsh` + `pick-clipboard` → **pick** silo (start in a
  `work-on-pick` worktree — see `.cursor/commands/work-on-pick.md`).
- `pick-clipboard-zellij` + the `Alt+w v` keybind → **terminal-mux** silo.
- NeoVim provider + `options.lua` + yanky removal → **nvim** silo.
- Hammerspoon watcher + chooser → **hammerspoon** (its own area).
- `pbcopy`/`clip-copy` shims, laptop receiver, remote daemon, Wayland/X11
  writers, SSH config → **utils/shell** silos.
- The SQLite store schema is a new contract shared by capture, picker, and
  chooser — coordinate across pick + hammerspoon + utils.

## 18. Implementation phases (ordering, not scope tiers — all are required)

1. **Verify + fix the E5108.** Confirm the current provider on a remote
   (`:lua =vim.g.clipboard`, `:checkhealth provider`), reproduce the block
   yank/paste. Verify Zellij OSC 52 passthrough. Replace the `options.lua`
   provider with the type-preserving one (in-session block via the cache).
   Drop yanky + the lazyvim extra. Smallest landing; kills the reported bug.
2. **Universal store + macOS capture.** SQLite WAL schema + the Hammerspoon
   `hs.pasteboard.watcher` writer (with sensitive-type skip + rich
   `readAllData`).
3. **`pick-clipboard` + Zellij `Alt+w v` + `--preview` passthrough.**
   Terminal picker reading the store.
4. **Hammerspoon `Cmd+Shift+V` chooser.** GUI picker, full rich restore.
5. **Bridge evolution.** Extend `clipboard-bridge` for rich + `get-regtype` +
   store-backed `get`; add laptop→remote `-L` history mirror; add the
   reverse get-channel for cross-machine paste. Cross-machine **block**
   preservation lands here (regtype column + current-regtype tracking).
6. **`pbcopy`/`clip-copy` shims + 3-way detection + scp-down file
   localization.**
7. **Linux capture** (`wl-paste --watch` / xclip-poll) + dev-shell framed
   daemon.

Each phase is independently testable. The end state is the whole system
working.

> **STATUS as of this recovery**: Phases 1–4 are **done and live** (with the
> as-built deltas noted inline in §7/§9/§10 above). **Phase 5 has not been
> started** — it's next. Phases 6–7 are also not started.

## 19. Verification

- **Per phase**: run the relevant ShellSpec (`make test` for `lib/`
  primitives); reproduce with a real picker / a real NeoVim block yank.
- **Contracts to preserve** (load-bearing for ≥3 silos):
  - `pick::start` flag set and the `\x1f`/`\x1e` wire format — confirm
    `quick-launch-pick` (terminal-mux) and the `ai-assist`/`ai-commit`
    pickers (ai-harnesses) still work unchanged after the `--preview`
    passthrough.
  - `zj::pick` floating adapter.
  - The existing `clipboard-bridge` socket path and the `options.lua`
    SSH-gating (`SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY`) — local NeoVim
    keeps `pbcopy`/`pbpaste`.
- **End-to-end checks**:
  - Block yank (`Ctrl+V` … `y`) then put in remote NeoVim → no E5108,
    block shape preserved.
  - Copy rich text in a GUI app → `Cmd+Shift+V` → paste styled into another
    GUI app.
  - `Alt+w v` in a local Zellij → pick a recent clip → injects into the pane.
  - SSH laptop→dev shell → `Alt+w v` shows union → `Ctrl-Y` on a
    laptop-originated image restores it to the laptop clipboard.
  - SSH iPad→mac-mini (Blink) → `Alt+w v` shows mac-mini local only →
    `Ctrl-Y` text → on the iPad clipboard (OSC 52).
  - Sensitive copy (e.g. from a password manager) → never appears in history.
- **Post-edit**: every file write in this chezmoi repo is followed by
  `chezmoi apply` (per `AGENTS.md`). The store + nvim cache are runtime
  data, not chezmoi-managed.
- **No company info** in any committed file (per
  `.cursor/rules/no-company-info.mdc`). The loose `~/.ssh/config.d/`
  config is the only place real SSH aliases may appear.

## 20. Decisions log (settled)

- Capture: per-OS shim → shared SQLite writer (Hammerspoon watcher on macOS,
  `wl-paste --watch` on Wayland, xclip-poll on X11).
- Store: multi-representation (`clips` + `clip_types`), WAL, dedup on
  type-set hash, re-bump `last_ts`, retention cap, machine-local untracked.
- Picker: `pick-clipboard` reading the store; `Alt+w v` leader chord.
- GUI: Hammerspoon `hs.chooser` on `Cmd+Shift+V` (accept the Raycast shadow),
  full rich restore, select = paste.
- Bridge: evolve the existing `clipboard-bridge`; laptop→remote forwards
  text+metadata+id (no BLOBs); reverse channel does restore-by-id (full
  rich, no BLOB transfer for laptop-originated) + BLOB-ship for
  remote-originated + `get`/`get-regtype` for cross-machine paste.
- NeoVim: type-preserving Lua provider; **drop yanky.nvim**.
- Cross-machine block: in scope (regtype column + current-regtype tracking
  on the laptop, reset on non-NeoVim writes). No "v1.5" — the project
  delivers the whole thing.
- Remote picker view: **union** of local DB + laptop mirror, origin-badged.
- Remote file copy: scp-down to temp + local `public.file-url`.
- mac-mini: full laptop-equivalent install when local; dev-shell-equivalent
  when SSH'd in. `pbcopy` shim auto-detects via bridge-up × `$SSH_CONNECTION`.
- iPad/Blink: local-only picker, OSC 52 copy-back (text, ≤75 KB, SSH not
  mosh). No images to the iPad.

---

## 21. Prompt for a fresh implementing agent

Paste the block below to a new agent with no prior context.

```text
You are implementing the "Universal Clipboard" project in this chezmoi
dotfiles repo. The full spec is in docs/clipboard-universal-project.md —
READ IT FIRST, in full. It is the source of truth; this prompt only orients
you.

Repo: /Users/KZ9PCF/.local/share/chezmoi (a chezmoi source directory; files
here are templates/sources rendered into $HOME, so after every file write run
`chezmoi apply`).

Hard rules (read these files before touching anything):
- .cursor/rules/no-company-info.mdc — this repo is PUBLIC. No
  company/work identifiers (employer names, work hostnames/SSH aliases,
  corporate usernames, internal tool names) in any committed file, commit
  message, or comment. Real SSH aliases live only in the loose, untracked
  ~/.ssh/config.d/ layer. Use the generic phrase "the dev shell" / <remote>
  in docs and code.
- AGENTS.md — after every file write, run `chezmoi apply`. Never `rm -rf` a
  parent directory to clear a git collision (there are gitignored precious
  dirs under docs/). No Co-Authored-By / Signed-off-by trailers on commits.
- .cursor/rules/baseline.mdc — verify, don't assume. Read before editing.
  Run the command before claiming it works. Surgical changes; match existing
  style; minimum code for the task.
- .cursor/rules/consent.mdc — do not implement beyond what the user
  explicitly approves; ask when unclear.

Critical context the spec depends on (read these files):
- home/dot_config/nvim/lua/config/options.lua lines 50-92 — the EXISTING
  clipboard bridge (SSH-gated provider: OSC 52 copy out, nc -U paste in via
  ~/.local/state/runtime/chezmoi-system/clipboard-bridge.sock served by a
  macOS launchd clipboard-bridge service over a reverse SSH tunnel). The
  E5108 root cause is line 82 returning regtype hardcoded to "v". You are
  EVOLVING this bridge, not rebuilding it. Read the launchd service + the
  loose ~/.ssh/config.d/clipboard.config as your first step.
- home/dot_local/lib/pick-common.zsh — the pick::start engine and the
  \x1f/\x1e wire format. pick-clipboard is modeled on
  home/dot_local/libexec/executable_pick-glyph.
- home/dot_config/zellij/scripts/executable_zellij-modal and
  home/dot_config/zellij/config.kdl.tmpl (the zellijModalRun template) —
  the floating-modal scaffolding and keybind pattern.
- home/dot_local/lib/zellij.zsh — zj::pick (the floating adapter).
- home/dot_config/hammerspoon/modules/apps/clipboard-history.lua and
  apps/clipboard-picker.lua — the landed Phase 2/4 code you're extending.
- home/dot_config/nvim/lua/clipboard/universal.lua — the landed Phase 1
  provider you're extending for cross-machine regtype (§9).

First verifications (do these before writing code):
1. Confirm Zellij passes OSC 52 through to the host terminal (ghostty /
   wezterm / Blink). Every OSC 52 copy-back path depends on it.
2. Read the existing clipboard-bridge launchd service and
   ~/.ssh/config.d/clipboard.config so you extend, not duplicate.
3. Read §11's "why this beats a custom base64-over-socket protocol" note —
   the reverse channel is a raw binary-capable unix socket already; no
   text-armoring is needed, and the common case (laptop-originated content)
   needs no byte transfer at all (restore-by-id).

Silo workflow: this is cross-silo. Start in a `work-on-pick` worktree for
the pick-common.zsh + pick-clipboard pieces if touching them (see
.cursor/commands/work-on-pick.md). Route the bridge daemon + receiver to
whichever silo owns system services/shell utilities; the NeoVim provider
changes to nvim; the Hammerspoon watcher extension to hammerspoon.

Implementation order: Phases 1-4 (spec §18) are DONE — start at Phase 5
(bridge evolution, §11).

Contracts you MUST NOT break (load-bearing for >=3 silos):
- pick::start flag set and the \x1f/\x1e wire format — confirm
  quick-launch-pick (terminal-mux) and any ai-assist/ai-commit pickers
  still work unchanged.
- zj::pick.
- The clipboard-bridge socket path and the SSH_CONNECTION/SSH_CLIENT/SSH_TTY
  gating — local (non-SSH) NeoVim keeps pbcopy/pbpaste.

Verification before claiming done (spec §19): run make test for lib/
primitives; test cross-machine copy-back over SSH (restore-by-id path);
test the iPad/Blink OSC 52 path; confirm a password-manager copy never
enters history. Run chezmoi apply after every edit. Scan diffs for company
info before staging.

Self-test via the `validate` skill (Mode A sandbox) per the work-on-<silo>
flow. Stop on the work-on-<silo> branch for the user to close with
/end-work; do not merge to master yourself.

Begin by reading docs/clipboard-universal-project.md in full, then the
files listed above. Report what you found before making changes.
```
