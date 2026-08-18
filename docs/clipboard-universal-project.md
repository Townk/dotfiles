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
> during `copy()` the way §9 describes). Phase 5 (bridge evolution) is now
> **implemented and live** too (commit `9819757`) — the §11 design below is
> what shipped. Phase 6 (file clips + yazi/zsh smart paste) shipped
> 2026-07-12 — see the §18 STATUS block and the §12/§13 as-built notes.
> Phase 7's Linux dev-shell store/bridge shipped 2026-07-14 — see the §18
> STATUS block; only Linux GUI capture remains.

A single clipboard history + type-preserving copy/paste system that works
across multiple Macs (each used locally or over SSH), a Linux dev shell over
SSH, and an iPad via Blink Shell. One shared data model; idiomatic front-ends
per context. No machine has a fixed role — each is "local" when you sit at it
and "remote" when reached over SSH. Evolves the **existing**
`clipboard-bridge` already in the repo — does not rebuild it from scratch.

> This is a requirements + design document, not a commit-history log. It is
> committed to a **public** repo: it must contain no company/work identifiers
> (employer names, work hostnames/SSH aliases, corporate usernames, internal
> tool names). References to the remote dev shell use the generic phrase
> "the dev shell" / `<remote>`, never a real alias.

---

## 1. Goals

- Browse clipboard history from the terminal (a floating picker — a Zellij pane or a tmux popup) and
  from the macOS GUI (a Hammerspoon `hs.chooser`), both reading the **same**
  store.
- Paste selected items directly into the terminal pane (inject) or copy them
  back to the active machine's clipboard.
- Full **rich content** round-trip: plain text, RTF/HTML, images, file
  references — restored with all pasteboard representations, like Raycast.
- **Type-preserving** NeoVim copy/paste, including visual-**block** (`Ctrl+V`)
  selections, within a session **and** across machines. Fixes the existing
  `E5108: provider returned invalid data` error from yanky.nvim.
- Works on macOS (any Mac), Linux (dev shell, Wayland/X11), and over SSH from
  a Mac or from Blink Shell on iPad.
- Sensitive clips (passwords, transient pasteboards) are never captured.

## 2. Non-goals

- Automatic sync between two GUI machines' clipboards (e.g. one
  Mac's `⌘C` auto-flowing to another without a command). Every Mac is a
  standalone local machine when you sit at it; cross-machine flow is
  command/session-driven via the bridge.
- A separate in-editor yank ring. The universal store + picker **is** the
  yank ring (with `clipboard=unnamedplus`, every yank flows through the
  provider into the store).

## 3. Critical context: the bridge already exists

The repo already contains a working clipboard bridge for NeoVim over SSH.
Read these before designing anything:

- `home/dot_config/nvim/lua/clipboard/universal.lua` — the SSH-gated
  NeoVim clipboard provider:
  - `clipboard = unnamedplus` on SSH.
  - **copy** = bundled `vim.ui.clipboard.osc52` (write-only; avoids the
    Zellij OSC 52 *read* hang).
  - **paste** = framed `G`/`R` requests to reverse-forwarded loopback TCP
    `127.0.0.1:2490` (origin listener `2489`).
  - Fallback: the last local cache/unnamed register when the bridge is absent.
  - Local (non-SSH): default `pbcopy`/`pbpaste`.
- The macOS `clipboard-bridge` launchd service (read its plist + the service
  script as the first implementation step — it is the existing transport to
  extend, not duplicate).
- `~/.ssh/config.d/clipboard.config` (loose, untracked, never committed —
  may reference work SSH aliases) — the reverse TCP `RemoteForward`.

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
                │         source_host, regtype, pinned)                 │
                │  clip_types(clip_id, uti, blob)   -- rich payloads    │
                └─────────────────────────────────────────────────────┘
                      ▲ write                        ▲ read        ▲ read
                      │                              │             │
   ┌──────────────────┴────────┐    ┌────────────────┴──┐   ┌──────┴──────┐
   │ Capture shim (per OS)     │    │ pick-clipboard    │   │ Hammerspoon  │
   │  macOS: hs.pasteboard.    │    │  (fzf, in the mux) │   │ hs.chooser   │
   │   watcher  (rich)         │    │  Alt+w v          │   │ Cmd+Shift+V  │
   │  Wayland: wl-paste --watch│    └───────────────────┘   └──────────────┘
   │  X11: xclip-poll          │
   └───────────────────────────┘
                      │
                      │  (materialize-on-use: full reps + origin host, on demand)
                      ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │ Bridge (evolve existing clipboard-bridge) — live ops only            │
   │  {get}         → full representation set + source_host (materialize)  │
   │  {get-regtype} → current Vim regtype (block preservation)            │
   │  {set}         → write the peer's clipboard when copying toward it    │
   │  length-prefixed binary framing; no mirror, no restore-by-id         │
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
  first_ts REAL, last_ts REAL, source_app TEXT, type_kind TEXT,
  source_host TEXT, regtype TEXT, pinned INTEGER DEFAULT 0)`
  - `type_kind` ∈ `text|rtf|html|image|files|mixed` (row badge).
  - `source_host` — the hostname of the machine where the clip was
    **originally copied** (`scutil --get LocalHostName`). This is the *only*
    field that conveys origin: a row is "local" iff `source_host` equals this
    machine's hostname, "remote" otherwise. There is **no `origin` column and
    no cross-machine reference id** — every clip a machine holds, it holds in
    full (see §11, self-contained clips).
  - `regtype` ∈ `v|l|b` (Vim register type, when the write came from the
    NeoVim provider; NULL otherwise).
- `clip_types(clip_id INTEGER, uti TEXT, blob BLOB)` — one row per UTI, via
  `hs.pasteboard.readAllData()` on macOS. Enables full rich restoration.
  Present on **every** machine that holds the clip (a clip is materialized in
  full wherever it is used — §11), so restoration is always a local read.
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
> beyond the original `text|rtf|html|image|files|mixed` set. `clip_types`
> also carries synthetic (non-pasteboard) UTIs the watcher/bridge mint
> themselves: `x-resolved-path` (the resolved absolute path stored alongside
> a captured file clip's `public.file-url`) and, since Phase 6,
> `x-file-manifest` (§13 as-built note).

## 6. Capture shims (per-OS, behind one shared SQLite writer)

The OS-specific part is ~20 lines: insert/dedup a row. Everything downstream
is OS-agnostic.

- **macOS** (any Mac): `hs.pasteboard.watcher` (0.5s `changeCount`
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
- **Headless / dev shell** *(live as of Phase 7)*: no GUI clipboard; the
  bridge + store run locally (systemd user socket activation on 2489) and the
  DB is fed by materialize-on-use over the bridge (§11) + `pbcopy`/`pbpaste`
  shims + editor yanks. No watcher — capture stays out of scope by design.

The skip-filter runs **before any forward** to the bridge, so sensitive
content never leaves the originating machine.

> **As-built note (Phase 6)**: the Phase 6 design explicitly planned *no*
> edits to the Hammerspoon watcher module (`clipboard-history.lua`) — the
> bridge dispatcher was meant to drive Hammerspoon only via generated
> `hs_run` scripts. That held for every new op except `N` (push-manifest):
> its origin declaration needed a way to tell the watcher "the next
> pasteboard change is an echo of a manifest I just pushed, not a new copy,"
> or a phantom text row would shadow the manifest row in the store. The
> existing current-origin state-file contract (host + hash + epoch, 3 lines)
> gained an optional one-shot 4th line, `suppress-echo`, written only by op
> `N`'s origin declaration; `capture_now()` consumes it and skips capturing
> that one change. Plain `O` origin declarations (text-frame writes) are
> unchanged — still 3 lines, regression-pinned by existing tests. This is the
> one authorized deviation from "no Hammerspoon module edits" in the Phase 6
> design (coordinator-authorized plan deviation, tracked through the SDD
> progress log).

## 7. `pick-clipboard` (picker, pick silo)

New `~/.local/libexec/executable_pick-clipboard`, modeled on
`~/.local/libexec/executable_pick-glyph`: stream rows straight from SQLite
into `pick::start` (no assembled-lines cache, no jq),
`ORDER BY pinned DESC, last_ts DESC LIMIT N`.

- **Wire format** (the `\x1f`/`\x1e` contract from `pick-common.zsh`):
  `<preview>\x1f<content>\x1e<id>`. Preview = first line (newlines → `⏎`,
  truncated ~60 cols) + dim `· {len}c · {app} · {reltime} · {type_kind}`.
- **Keys**:
  - `Enter` → `--output field:1` → emit content (injected into the pane on either backend).
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

Two signals still gate behavior: `$SSH_CONNECTION` (am I in an SSH session?)
and **bridge-up** (is the reverse `-R` socket connectable?). But under the
**self-contained** model (§11) the picker is *always* a pure view of **this
machine's own store** — there is no union with a peer and no origin-relative
filter. Every clip a machine can show, it already holds in full.

| Scenario | `$SSH_CONNECTION` | bridge (`-R`) up | Picker shows | `Ctrl-Y` / `pbcopy` target |
|---|---|---|---|---|
| Sitting at a Mac (GUI) | unset | no | this machine's store | `/usr/bin/pbcopy` (local) + `Cmd+Shift+V` chooser |
| SSH into a machine | set | yes | that machine's store | local `writeAllData`; the copy also rides the reverse channel to the machine you're sitting at |
| iPad → Blink → SSH | set | no | that machine's store | **OSC 52 → iPad** (text) |

- **No origin filter.** The picker `SELECT`s the local store unconditionally,
  ordered by recency. `source_host` only decides the per-row local/remote
  **badge**, never which rows appear. Bridge-up no longer changes *what* the
  picker shows — only where a `Ctrl-Y` copy additionally lands.
- **`Ctrl-Y` is always a local copy first.** The selected clip's full content
  lives in this machine's store, so copy-back is `hs.pasteboard.writeAllData` /
  `pbcopy` locally — no reverse-channel restore, no dependency on any other
  machine being online. When bridge-up, the same bytes also ride the reverse
  channel to the machine you're sitting at (so your physical clipboard gets it),
  exactly as the `pbcopy` shim already routes.

## 9. NeoVim clipboard provider (type-preserving) + drop yanky

### Replace the `options.lua` provider

`g:clipboard` accepts Lua functions: `copy(lines, regtype)` receives the
regtype; `paste()` returns `{lines, regtype}` (regtype ∈ `v|l|b`). The new
provider (nvim silo, a Lua module under `home/dot_config/nvim/lua/`):

- **`copy(lines, regtype)`** — write `{lines, regtype}` to a tiny dedicated
  cache (`$XDG_CACHE_HOME/nvim-clipboard/last`), **and** push the text to the
  bridge:
  - SSH + bridge-up → reverse channel to the local machine (`writeAllData`
    there) + send `{regtype}` so the local machine records "current regtype."
  - SSH + bridge-down (iPad/Blink) → OSC 52 (text; Blink supports it over
    SSH, ~75 KB cap).
  - Local → `/usr/bin/pbcopy` (macOS) / `wl-copy` / `xclip`.
  Also write to the universal store (with `regtype`), so every yank enters
  history (the picker is the yank ring).
- **`paste()`** — return `{lines, regtype}`:
  - SSH + bridge-up → read the local clipboard via the existing tunnel
    `nc -U` **and** fetch the current regtype from the local machine (new
    `get-regtype` op on the bridge) → `{text, regtype}`. Block preserved
    across machines.
  - SSH + bridge-down → OSC 52 has no get; return from the local cache
    (in-session, type-correct, never errors).
  - Local → `pbpaste` / `wl-paste` / `xclip -o`, regtype from cache or
    inferred (trailing newline → `l`, else `v`).
- **"Current regtype" on the local machine**: the bridge records the regtype of the
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
> "current regtype on the local machine" mechanism described above. Cross-machine
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

## 11. Self-contained clips — materialize on use

> **Supersedes the Phase-5 pointer mirror** (commit `9819757`). The
> `[clipboard-mirror]` launchd service, the `M` mirror opcode, the `S`
> restore-by-id op, the `ref_id` column, and the `origin` column are **all
> removed**. The principle they violated: *a machine must never depend on
> another being online to reproduce a clip it has already shown you.*

**Principle.** A clip's content lives, *in full*, on every machine where it has
ever been **used**. Nothing is stored as a pointer; nothing is fetched back
later. The scenario that forces this:

> Copy on the laptop → SSH to the mac-mini and paste it (content flows over the
> live bridge while the laptop is up). The next day, iPad → SSH → mac-mini with
> the laptop shut in a bag: picking that same clip must just work, served
> locally, with nothing to phone home to.

**What travels, and when.** Only on *use*, and only over the already-live
bridge: the clip's **full representation set + its origin hostname**. There is
no eager mirror and no background mirror service.

- **Local capture** (`hs.pasteboard.watcher`): store the full clip;
  `source_host` = this machine's hostname. Unchanged from today, minus the
  fire-and-forget mirror push.
- **Use of a peer clip over the bridge** (nvim paste, picker `Ctrl-Y`, the
  `pbcopy` read-back): the bridge `get` response carries every UTI's bytes
  **plus the origin `source_host`**. The consuming machine writes a full clip
  into its own store, stamped with that origin host — so it badges "remote
  (laptop)" even though its bytes are now local — and dedups against what it
  already holds. From that moment the clip is indistinguishable from a
  locally-captured one except for `source_host`, and survives the origin
  machine going offline.
- **No identity token is needed.** Because content materializes on use,
  copy-back is never "ask host X for clip N" — it is a local `writeAllData`. So
  there is no `ref_id` and no shared `type_hash` has to travel. `type_hash`, if
  kept at all, is a purely *local* dedup key computed from the content in hand.

**Bridge ops that remain** (loose `~/.ssh/config.d/clipboard.config`,
`LocalForward`/`RemoteForward`, loopback TCP — `StreamLocalForward` is rejected
by macOS OpenSSH). The reverse channel keeps only the *live* ops the NeoVim
provider and the `pbcopy` shim need — no mirror, no restore-by-id:

- `{get}` → the current clipboard's **full representation set + `source_host`**
  (this is the materialization source; extends today's text-only `G`).
- `{get-regtype}` → current Vim regtype (block preservation, §9).
- `{set, reps, regtype}` → write the peer's clipboard when you copy toward it.

- **Receiver**: the existing `clipboard-bridge` launchd service handles these,
  shelling to Hammerspoon for `readAllData`/`writeAllData`. Do **not** use
  `hs.socket` for the listener (its Unix-domain server needs timer polling —
  CocoaAsyncSocket limitation); keep the standalone framed-socket dispatcher.
- Verify `AllowStreamLocalForwarding yes` on the dev shell's `sshd_config`
  (default `yes`).

### Migration (safe column drop + backfill)

The existing store predates this model. On first run of the revised
`ensure_schema`, in this order:

1. **Delete stale pointer rows** — `DELETE FROM clips WHERE origin='remote-ref'`.
   They are text-only references to a peer's history with **no blobs** and
   cannot be made self-contained. Must run *before* step 3 drops `origin`.
2. **Backfill origin** — `UPDATE clips SET source_host = <this host> WHERE
   source_host IS NULL OR source_host = ''`. Every pre-existing local capture
   becomes correctly "local" (its bytes were always here).
3. **Drop the dead columns** — `ALTER TABLE clips DROP COLUMN origin;` and
   `ALTER TABLE clips DROP COLUMN ref_id;` (SQLite ≥ 3.35; if the bundled
   `hs.sqlite3` predates `DROP COLUMN`, fall back to a `CREATE TABLE … AS
   SELECT` rebuild).

No data of value is lost: the only rows removed are peer-history pointers that
were never self-contained to begin with.

## 12. Remote file copy — scp-down + local file-url

File clips follow the same self-contained rule (§11): a `files`/`file` clip is
materialized by pulling the bytes down **at use time**, then stored locally.

- **Locally-copied file** (Finder): the `public.file-url` and the file are
  already on this machine. No transfer; `Ctrl-Y` restores the local file-url.
- **Peer file, used over the bridge**: `Ctrl-Y` on a `files`-kind row `scp`s
  the file down to a local temp dir at use time, puts a real `public.file-url`
  (pointing to the temp file) on the pasteboard, and records it in the local
  store (`source_host` = the origin host) so a later paste needs no re-fetch.
  Pasting into Finder then works.
  - An `scp:` URI alone does **not** paste into Finder (Finder pastes
    `public.file-url`, not `scp:`); the scp-down-to-temp + local-url path is
    the honest way. `scp:` URIs only matter for apps that explicitly handle
    them (Transmit, Cyberduck) — out of scope.

> **As-built note (Phase 6)**: the flow name "scp-down" is kept for the
> Mac←remote pull described above, but the engine is brew rsync
> (`rsync -a --info=progress2 -e ssh`), not `scp` — chosen for its resumable
> `--partial` and live progress meter on many-small-file pulls. The terminal
> picker's `Ctrl-Y` on a remote-manifest row localizes into
> `~/.cache/pick-clipboard/files/<clip-id>/<idx>/` via that engine, then
> restores a real local file clip through the bridge's new `U` op (§13
> below) — same local-url outcome this section describes, with an extra
> localization hop first.
>
> The reverse direction — a dev shell pasting a Mac-origin clip, which has no
> ssh path back to the Mac — uses capability-bound bridge ops instead of rsync.
> `K` snapshots the current trusted file manifest and returns a short-lived
> opaque token plus its display paths. `f` fetches one token-indexed file
> (replying with the exact `is-directory` error that makes the client retry
> the same token/index through `a`), while `a` streams a directory as a `tar`
> archive
> whose reply carries a `BE64` size prefix computed from a pre-flight
> `du -sk` — an **estimate for progress display only, with no directional
> guarantee** (block-accounting rounding and sparse files can push the real
> stream above *or* below it). Clients read to EOF rather than trusting the
> count, clamp progress display at 100% instead of overshooting, and treat
> the tar stream's own extraction exit status — not the size prefix — as the
> integrity check. Every detectable failure, including an unreadable entry
> found by a pre-flight readability walk over the source tree, is reported
> as an error frame *before* any stream byte goes out; an I/O fault striking
> truly mid-stream (after the walk, before `tar` gets there) can only
> manifest as a short-but-clean stream, caught client-side by `pbpaste`'s own
> tar-extraction check.
>
> Local materialization (same host, either direction) is tiered: APFS
> clonefile (`cp -Rc`, copy-on-write, instant) → brew rsync (cross-volume or
> non-APFS) → `cp -a` (rsync absent). All materialization — local and
> cross-machine — stages into a temp directory next to the target and
> renames each item into place atomically on completion, so an interrupt
> never leaves a partial file at the destination. `--force` on an existing
> name uses rename-aside (moves the existing item out of the way first),
> never `rm` followed by `mv`.
>
> A Mac sitting locally resolves a remote manifest through the healthy
> read-only peer mount and feeds those mapped paths into the same staged local
> copy engine. This is the path Yazi smart-paste uses for dev-shell → Mac
> `y`/`p`. When the mount is absent or unhealthy, `pbpaste --files` refuses
> with a pointer to `pick-clipboard`'s `Ctrl-Y`; that picker's rsync pull
> remains the explicit no-mount fallback. Picker-localized cache rows carry
> file authority, so a same-shaped public pointer can never claim an existing
> cache path. Mounted sizes/caps are preflighted before any item is placed.
>
> **As-built note (R2)**: `rsync -e ssh <source_host>:...` only resolves if
> the puller's own ssh config knows `source_host` by that exact name — and
> `source_host` is always the origin's own LocalHostName (§5), which need not
> equal the alias the puller calls it by. `system-onboard` closes that gap:
> once it can SSH into a peer, it captures the peer's `scutil --get
> LocalHostName` (or `hostname -s`) and persists it in the loose ssh
> fragment's front matter (`# peer-hostname: <name>`, see
> `~/.ssh/config.example`), then renders `Host <alias> <peer-hostname>` so
> both names resolve. `system-onboard update <alias> --clipboard|--prepare`
> reconstructs that second name from the front matter without reconnecting.

> **As-built note (mount subsystem, 2026-07-13)**: the lazy-manifest contract
> above still holds, and gains a fast path. When the home Mac holds a healthy
> read-only `rclone mount` (SFTP on MacFUSE) of the origin host — auto-mounted
> by the `mount` prepare step at ssh connect, health-swept by launchd, spec:
> `docs/superpowers/specs/2026-07-13-clipboard-mount-subsystem-design.md` —
> the bridge's `M` handler additionally sets the home pasteboard with
> **mount-relative file-urls** right after the manifest row lands (marked
> untrusted, changeCount-guarded, self-healing remount when the mount died
> mid-session). Cmd+V in Finder is then a native Finder copy off the mounted
> volume — progress window, ETA, Cancel — with the bytes still moving only at
> paste time. The store row stays the lazy manifest: `Ctrl-Y` rsync
> materialization is unchanged and remains the fallback whenever no healthy
> mount exists (iPad/Blink sessions, mount failure, Linux sit-at). This
> refines the DRIVEN→HOME rule (§13): the home pasteboard IS set on copy when
> — and only when — a healthy mount makes the pointer directly pasteable.

## 13. `pbcopy` / `clip-copy` shims

A bridge-aware `pbcopy` shim on macOS and the dev shell (and
`clip-copy` for files/images), so `pbcopy` always writes to *your* clipboard,
where "you" is decided by bridge-up:

- bridge-up (SSH'd in from your local machine) → reverse-channel send to that
  machine (`writeAllData` / `pbcopy` there) → lands on your local clipboard. Its
  own watcher then captures it into the local store (full circle).
- no bridge + SSH (iPad/Blink) → OSC 52 to the iPad (text).
- no bridge + no SSH (sitting at the machine) → `exec /usr/bin/pbcopy` (real,
  fully local).
- `clip-copy <file>` = same shim, file/image mode with UTI detection
  (`png`→`public.png`, `jpg`→`public.jpeg`, `tif`→`public.tiff`,
  `pdf`→`com.adobe.pdf`, `txt`→`public.utf8-plain-text`, …).
- `clip-copy --clipboard` = read this machine's own clipboard and forward
  (macOS: `osascript … as «class PNGf»` / `pngpaste`; Linux: `wl-paste -t
  image/png` / `xclip -o -t image/png`).

> **As-built note (Phase 1/pre-project)**: the shims started out plain
> text-only, no `clip-copy` file/image mode. Superseded below.

> **As-built note (Phase 6, supersedes the note above)**: `clip-copy` was
> never built as a separate command. File/content modes folded into the
> existing shims instead, so `pbcopy`/`pbpaste` remain the only two entry
> points:
>
> - `pbcopy <paths…>` — file-object mode. Sitting at the Mac → local bridge
>   op `U` (set-file-urls) writes a real file clip straight to the
>   pasteboard. SSH + bridge-up → op `N` (push-manifest): the Mac records an
>   `x-file-manifest` store row and puts the paths on its own pasteboard as
>   text, so the clip is visible in history without the bytes crossing yet
>   (§12's lazy rule). No bridge (iPad) → clear error; file clips never ride
>   OSC 52 (§14).
>
> **As-built note (X2, corrects the bullet above)**: the description above
> was push-only and wrong — a live self-test showed a file copied over SSH
> from a mini never showed up in the *mini's own* picker, only the laptop's.
> The design principle (a file belongs to the machine whose bytes it is)
> means the origin always gets a local clip too. `pbcopy <paths…>` over SSH
> now does BOTH, in order: (1) the same local `U` send this section already
> describes for sitting-at-the-Mac (to 127.0.0.1:2489, this machine's own
> bridge) — the PRIMARY action, so the origin's own watcher records a local
> `files` row and its own picker shows the clip; then (2) a best-effort peer
> `N` push to the reverse-tunneled bridge (2490), so the far side can still
> pull lazily. The peer push is now secondary: a down, outdated, or erroring
> peer bridge only warns on stderr ("peer not notified") and exits 0 —
> only a failure of the LOCAL `U` (no reachable bridge on this machine, or
> an `E` reply) hard-fails the command, since that's the one action with no
> fallback.
>
> **As-built note (X2-redo, corrects the LOCAL send in the X2 note above)**:
> live validation caught a second bug in the same flow — the local `U` send
> sets the origin's pasteboard and relies on the Hammerspoon watcher to
> capture that write into the store, but the watcher's `loginwindow` guard
> skips ALL capture when the origin has no interactive GUI user, which is
> ALWAYS true for a machine reached over SSH (locked/headless). Confirmed
> live: `U` set the pasteboard (a real file-url landed) but no store row
> ever appeared. The fix: `pbcopy`'s SSH files branch now sends a new op `M`
> (manifest-persist-local) to the trusted local Unix socket instead of `U` —
> same payload
> shape as `N` (`<host> US path NUL path …`), but record-only: it inserts
> the `files` store row DIRECTLY via SQL (dedup-scoped exactly like `N`),
> bypassing the watcher entirely, and never touches the pasteboard at all.
> This brings files-over-SSH in line with how text-over-SSH already behaves
> — plain `pbcopy` over SSH never sets the origin pasteboard either, it only
> `P`-persists to the store (§13's own text-mode description above). `M` is
> otherwise a drop-in replacement for `U` in this one branch: still the
> PRIMARY, reply-checked, hard-failing action; the peer `N` push (2490) is
> unchanged. A later `Ctrl-Y` on the resulting row, run on the origin
> machine itself, is still fully restorable: `pick-clipboard`'s
> `clip::copy_files_by_id` now recognizes a self-origin row whose only blob
> is `x-file-manifest` (impossible for a genuine Hammerspoon capture, which
> always writes `NSFilenamesPboardType`/`public.file-url` too) and routes it
> through the same paths-direct `U` form its remote-origin cache-hit case
> already used, instead of the `id:<n>` full-fidelity restore that would
> otherwise try to restore a private UTI Finder can't paste.
>
> **As-built note (Fix A, corrects the peer `N` push described by X2-redo
> above)**: files-over-SSH now persists a RECORD-ONLY manifest on **both**
> the origin (local, 2489) and the peer (remote, 2490) via the same op `M` —
> it does **not** set the peer's pasteboard. Files are lazy (§12): the peer
> is only supposed to get a manifest *pointer*, materialized on `Ctrl-Y`, so
> its live pasteboard must never be touched by this push. The peer send used
> to be op `N` (push-manifest), which — on top of the row-insert — also
> declared origin and set the peer's pasteboard to the paths as plain TEXT.
> That text placeholder got reflected back up through the peer's live
> clipboard and surfaced as a confusing "remote text" twin of the same clip
> on the origin's own TUI picker (whose live-peer entry mirrors the peer's
> current clipboard). `pbcopy` was the only caller of `N`, so the op has been
> retired from the dispatcher entirely — both the local and peer sends in
> `pbcopy`'s SSH files branch are now `M`, byte-identical payload, sent to
> `~/.local/state/cb.sock` then (best-effort)
> `CLIPBOARD_BRIDGE_PORT`/2490. The
> `M`-inserted row's `source_host` is what tells the two sides apart: on the
> origin it equals the local host (a local clip); on the peer it differs (a
> remote clip) — same distinction the picker already made, just without a
> pasteboard write triggering it. The suppress-echo origin-file mechanism
> (Task 11) that used to guard `N`'s pasteboard echo is left in place,
> unused but harmless, in `clipboard-bridge-dispatch`'s
> `clip::declare_origin_core` and `clipboard-history.lua`'s
> `captured_origin()`.
>
> **As-built note (Phase 7, 2026-07-14)**: between Fix A above and Phase 7
> landing, an interim on platforms with no local store (headless Linux,
> before Phase 7's dev-shell store existed) had nothing for the local send to
> persist to, so the peer `M` push was — in practice, if not in code intent —
> the operative primary there ("peer push becomes primary", Phase 7 interim).
> That gap is **retired**: design of record
> `docs/superpowers/specs/2026-07-14-clipboard-phase7-linux-store-design.md`.
> Every onboarded machine, macOS or headless Linux, now has its own local
> bridge/store, so the local `M` send is the unconditional, hard-failing
> primary everywhere exactly as Fix A describes; the peer push remains
> strictly secondary and best-effort, with a self-heal (`systemctl --user
> start`) covering a stopped socket on either end.
> - `pbcopy --content <file>` — the file's *bytes* under a detected UTI
>   (extension first, then `file --mime-type`) via the existing `C` op. This
>   is the mode this section originally called `clip-copy`.
> - `pbpaste --manifest` — prints the current file clip's manifest (kind,
>   host, timestamp, NUL-joined paths) via the new `L` op (list-files); no
>   filesystem writes.
> - `pbpaste --files [--force] [--quiet|--progress|--porcelain] [dir]` —
>   materializes the current file clip into `dir` (default cwd); see §12's
>   as-built note for the transfer engines, tiers, and staging behavior.
>
> **Rationale for folding rather than adding sibling commands**: `pbpaste`'s
> plain invocation is `$(pbpaste)`-safe by contract — scripts and editors
> call it blind and must never trigger a filesystem write. Keeping one
> command with the file behavior strictly flag-gated (`--files`) preserves
> that contract; a `clip-paste` sibling would have split callers across two
> tools for no safety gain. `pbcopy` overloads safely on path arguments
> because that syntax was already dead: neither the shim nor Apple's own
> binary accepted operands before Phase 6, so the no-arg stdin path stays
> byte-identical.
>
> **New bridge ops** (same framed protocol —
> `<opcode><BE32 len><payload>` — and `hs_run` pattern as the existing
> `get`/`get-regtype`/`set`/`C` ops):
> - `U` set-file-urls — NUL-separated absolute paths → writes
>   `NSFilenamesPboardType` + `public.file-url` via Hammerspoon; the watcher
>   then captures the clip like any other copy (full circle, same design as
>   the `O`/`P` text frames). Also has an `id:<n>` full-fidelity restore form
>   (used by the picker's `Ctrl-Y`).
> - `L` list-files — no payload; returns
>   `type_kind US source_host US last_ts US <path NUL path …>` for the
>   current clip (the store row's `last_ts`, which `pbpaste --manifest`
>   prints under the wire label `ts`), or an error frame if it isn't a
>   files clip. Retries briefly
>   (~0.3s) to tolerate the watcher's capture lag before declaring "not
>   files" (§14).
> - `M` manifest-persist-local (X2-redo; Fix A) — record-only: inserts ONLY
>   the `x-file-manifest` store row, no pasteboard write, no origin
>   declaration. `pbcopy`'s SSH files branch sends this to BOTH its own
>   bridge (local origin record, since the origin is typically
>   locked/headless over SSH and the Hammerspoon watcher can't capture a
>   pasteboard write there) and the reverse-tunneled peer bridge (remote
>   manifest push, so the peer's live pasteboard is never touched — see the
>   X2-redo and Fix A as-built notes above). Only the trusted local-socket form
>   authorizes those paths for later `K` grants; the public peer form is a
>   pointer row only. Supersedes the original
>   `N` push-manifest op (removed): `N` did the same row-insert but also set
>   the peer's pasteboard to the paths as plain TEXT, which reflected back
>   as a confusing "remote text" twin on the origin's own TUI picker.
> - `K` grant-files — no payload; returns
>   `type_kind US source_host US last_ts US token-or-- US <path NUL path …>`.
>   A 256-bit token names an immutable trusted path snapshot, not a caller-
>   supplied path. `-` means the manifest remains usable only by a client for
>   which its paths are already local.
> - `f` fetch-authorized-file — payload `token US item-index`; response framing
>   matches the retired `F`, including exact `is-directory`.
> - `a` archive-authorized-directory — payload `token US item-index`; directory
>   tar stream as described in §12.
> - `n` notify — payload `origin_host US fn US icon US sound US text`; raises a
>   Hammerspoon OSD on the machine running the dispatcher, for a caller at the
>   far end of the tunnel. Not clipboard traffic at all: it rides this wire for
>   the same reason `W` does, because the bridge is already the link between a
>   remote session and the machine whose screen the human is watching. `fn` is
>   `notify` or `notifyAnsi`; a toast whose `origin_host` is not the dispatcher's
>   own host is prefixed with that host, so remote-raised OSDs are always
>   distinguishable from local ones. Refused on the Linux headless backend
>   rather than accepted and dropped. Lowercase because uppercase `N` is retired
>   (above), not because it is a variant of it.
>
> Uppercase `F`/`A` raw-path requests are retired and fail with an actionable
> capability-required error. Clients never send a filesystem path as authority.
>
> **`W` window action (2026-07-28)** — the first op that is not about the
> clipboard at all. The bridge had quietly become the general wire between a
> remote mux session and the machine its TERMINAL lives on; the clipboard was
> just the first thing to need it. Payloads:
> - `fullscreen-toggle <ghostty|wezterm>` — runs the origin's own
>   `terminal-toggle-fullscreen`, so there is one implementation of "how does
>   this terminal go fullscreen", not a second copy behind the wire. The
>   terminal is named by the CALLER: the service has no terminal environment
>   to detect from, while the remote end knows exactly what it is talking to
>   (`TERM` is the one thing ssh carries). `MUX_TERMINAL` short-circuits
>   detection, and `SSH_*` are cleared so the origin doesn't decide it is
>   itself remote.
> - `fullscreen-state` — `true` / `false` / **empty when unknowable**. Empty
>   travels all the way back: the asker leaves its mirror untouched rather
>   than writing a wrong `false`, because a `NOT_RUNNING` verdict from a
>   plainly-running Ghostty means the *asker* lacks the Accessibility grant.
>
> Before this, `Alt+Enter` over SSH failed with "cannot control the local
> terminal from an SSH-hosted session" — a statement about the plumbing of
> the day rather than about what was possible. The ribbon's fullscreen mirror
> follows the same route, but only ever from `mux-fullscreen-probe` on the
> `client-resized` hook: a round trip in the status renderer would repeat the
> 5s stall that made every mode pill vanish (see `docs/mux-parity.md`).
>
> **Store**: new synthetic UTI `x-file-manifest` (NUL-joined absolute
> paths), following the `x-resolved-path` precedent (§5). Rows carry
> `type_kind='files'` and `source_host=<origin host>`; a manifest row is
> replaced by a fully local row once the clip is materialized, so later
> pastes need no re-fetch.

### Yazi + zsh smart-paste (net-new, Phase 6 — beyond the original master-spec scope)

Yazi was never in this document's original scope; Phase 6 added it as a thin
consumer of the shims above — no clipboard protocol logic lives in Lua:

- `y` mirrors the selection to the system clipboard via `pbcopy` (best
  effort, silent — a dead bridge or iPad session never blocks or fails a
  plain internal yank) and stamps a `last-yank` marker, then runs yazi's
  native internal yank. `x` (cut) stamps the marker only, never mirrored —
  a mirrored cut pasted elsewhere would silently become a copy, breaking
  the move contract.
- `p`/`P` run the `smart-paste.yazi` plugin: a 5-rule resolver that compares
  the yank list against the current clipboard manifest, host, and the
  `last-yank`/`last-paste` marker timestamps to choose between yazi's native
  paste (internal yank — preserves cut/move semantics) and
  `pbpaste --files` (system clipboard). Marker mtimes use BSD stat on macOS
  and GNU stat on Linux. Remote manifests run asynchronously with porcelain
  progress surfaced as Yazi notifications, whether bytes stream through f/a
  or copy through the Mac's peer mount.
- zsh got a matching `Alt+p` ZLE widget (`smart-paste`, bound in
  `keybindings.sh`): a text clip is inserted at the cursor; a files clip
  fills the buffer with `pbpaste --files` and accepts it as a normal,
  visible, cancellable command, rather than blocking inside ZLE.

This is called out explicitly because it is scope this document never
claimed before Phase 6 — see §18/STATUS.

## 14. Honest limits (must be handled, not hidden)

- **OSC 52 is text-only and capped**: Blink ~75 KB over SSH (not mosh);
  ghostty/wezterm have their own caps. Oversized `Ctrl-Y`/`pbcopy` text
  fails with a clear message, not silent truncation. Images cannot cross
  OSC 52 at all — they only reach your *local machine* via the reverse
  bridge, never an iPad.
- **zellij OSC 52 passthrough — verify first**. The picker and provider run
  inside a mux pane, so OSC 52 must pass through the multiplexer to reach the host
  terminal (Blink/ghostty/wezterm). Zellij has OSC 52 support but
  passthrough from a pane must be confirmed against the installed
  Zellij version/config. **This is the first implementation verification** —
  every OSC 52 copy-back path depends on it.
- **No images to the iPad.** `Ctrl-Y` on an image row from the iPad = no-op
  with a message.
- **UTI detection**: wrong UTI → garbage on the pasteboard. Detect from
  extension first, then `file --mime-type`.
- **Remote-origin rows carry their own BLOBs** (self-contained, §11): a clip
  materialized from a peer is stored in full locally, so it is copied back by a
  local `writeAllData` like any other — no cross-machine resolve. A terminal
  pane still only receives text (rich BLOBs go to the GUI clipboard, not the
  pane); that limit is about the sink, not about where the payload lives.
- **Storage cost**: image BLOBs can be MBs. Per-representation cap (~5 MB),
  total-store cap, oldest-dropped retention sweep.
- **File clips never ride OSC 52** (Phase 6). An iPad/no-bridge
  `pbcopy <paths>` fails with a clear error; picker `Ctrl-Y` on a files row
  from the iPad is a no-op — same honesty rule as images, above.
- **`CLIP_FILE_MAX`** (Phase 6, default 200 MB / 209715200 bytes,
  env-overridable): cross-machine fetches above the cap prompt for
  confirmation on an interactive TTY; non-interactive callers fail with the
  limit named, rather than silently pulling an arbitrarily large transfer.
  Mounted manifests preflight every item before placing any, so Yazi's
  confirm-and-retry loop cannot collide with an item placed by an earlier
  partial attempt.
- **`a` (archive-stream) sizes are estimates** (Phase 6), computed via a
  pre-flight `du` before the tar stream starts — not a byte-exact guarantee
  in either direction (§12's as-built note). Clients clamp progress at 100%
  rather than overshoot and treat the tar stream's own exit status, not the
  size prefix, as the integrity check.
- **Watcher lag** (Phase 6): the `L` op resolves through the store, which
  trails the pasteboard by up to ~0.5s; it retries briefly (~0.3s) before
  declaring "not a files clip." A paste executed inside that window can
  still see the previous clip.
- **Clock skew** (Phase 6): the yazi resolver's rule 5 compares a
  manifest's timestamp (the store row's `last_ts`, wire-labeled `ts` in
  `pbpaste --manifest`) against the local `last-yank` marker's mtime,
  potentially across different machines. NTP keeps skew sub-second, but a
  copy race inside that window can pick the wrong source. Documented, not
  hidden.
- **Mid-stream truncation** (Phase 6): a dropped connection or I/O fault
  during an `f` or `a` stream can't be caught from the byte count (an
  estimate for `a`) — it surfaces client-side, as a short `f` file or a
  tar stream that fails to extract cleanly.

## 15. Security

- The store contains sensitive clips. It is **machine-local, untracked,
  never committed, never synced via the repo**. Same for the
  `nvim-clipboard` cache file.
- Capture skips `Concealed`/`Transient`/`AutoGenerated` pasteboard types and
  a password-manager app deny-list, **before** any bridge forward.
- The reverse bridge is loopback TCP because SSH-forwarded Unix sockets leave
  stale pathnames on macOS. It is still an unauthenticated RPC endpoint to
  every process that can reach the forwarded port.
- File reads therefore use capabilities, not paths. A public client can ask
  `K` only for the latest manifest that a trusted local capture authorized,
  then use the returned token with an item index. Public `M`, `U`, rich
  file-reference UTIs, and raw `F`/`A` cannot mint or exercise file authority.
- Grants copy the authorized path snapshot, idle-expire after 30 minutes, and
  hard-expire after 24 hours. Clipboard changes and row retention cannot
  retarget an issued token. Historical rows receive no inferred authority;
  they must be explicitly recopied.
- Top-level symlinks and non-regular file types are never granted or streamed:
  following a localized symlink could otherwise escape the cache/mount and
  read a same-shaped path on the receiving machine. Nested directory symlinks
  remain archive metadata and are not followed by tar.
- Public `M` cannot claim this machine's own hostname or deduplicate into an
  authoritative row; `P` cannot persist file kinds. Self-host manifest restore
  through the trusted socket also requires an authority row.
- Mount enrichment marks its exact pasteboard write with
  `org.chezmoi.clipboard.UntrustedFileURLs`; the watcher skips that change.
  Its final `changeCount` comparison and `writeAllData` happen in one
  Hammerspoon script, so a newer user copy cannot be overwritten in between.
- Privileged local file operations use a separate mode-0600 Unix socket owned
  by socat/systemd and never forwarded by SSH. TCP remains the cross-machine
  transport; this does not reintroduce the stale remote-socket failure.
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
- Local framed-socket receiver / extended `clipboard-bridge` launchd service
  (utils/shell)
- Remote framed-socket daemon + systemd user unit (Linux dev shell)
- `pbcopy` / `clip-copy` shims (utils/shell) *(clip-copy superseded — folded
  into `pbcopy`/`pbpaste`, see §13 as-built note)*
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
- `pbcopy`/`clip-copy` shims *(clip-copy superseded — see §13 as-built
  note)*, local receiver, remote daemon, Wayland/X11
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
   store-backed `get`; add local→remote `-L` history mirror; add the
   reverse get-channel for cross-machine paste. Cross-machine **block**
   preservation lands here (regtype column + current-regtype tracking).
6. **`pbcopy`/`clip-copy` shims + 3-way detection + scp-down file
   localization.**
7. **Linux capture** (`wl-paste --watch` / xclip-poll) + dev-shell framed
   daemon.

Each phase is independently testable. The end state is the whole system
working.

> **STATUS**: Phases 1–**5** are **done and live** (with the as-built deltas
> noted inline in §7/§9/§10/§11 above). Phase 5 (bridge evolution) shipped in
> commit `9819757` — dispatcher wired into the service, type-preserving
> cross-machine nvim paste, `Ctrl-Y` in both pickers, and a local→remote
> history mirror. Absolute `source_host` provenance + the `loginwindow` echo
> guard landed in `eee3cf2`.
>
> **Phase 6 — file clips + yazi/zsh integration — done and live as of
> 2026-07-12** (as-built deltas in §6, §12, §13 above; design of record:
> `docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md`).
> Landed: the `U`/`L`/`M`/`A` bridge ops and the `x-file-manifest` synthetic
> UTI; `pbcopy`/`pbpaste` file modes with no `clip-copy` sibling (folded in,
> §13); the rsync-engine scp-down + picker `Ctrl-Y` file-row localization
> (§12); the one-shot `suppress-echo` extension to the Hammerspoon watcher's
> origin-file contract (§6) — the plan's one authorized deviation from "no
> Hammerspoon module edits." **Beyond the original master spec's scope**:
> yazi `y`/`x`/`p`/`P` clipboard integration and the `smart-paste.yazi`
> plugin, plus a zsh `Alt+p` smart-paste ZLE widget (§13) — yazi was never
> covered by this document before Phase 6.
>
> The **mount subsystem** (Finder-native paste: rclone SFTP on MacFUSE,
> receiver-side M enrichment — spec 2026-07-13) is built on top of Phase 6;
> see the §12 as-built note.
>
> **Capability hardening (2026-07-31)** supersedes Phase 6's raw-path `F/A`
> transport: trusted local captures mint authority; `K/f/a` exercise it;
> public path-bearing operations cannot. The trusted local socket is separate
> from, and never replaces, the TCP SSH forward.
>
> **Phase 7 — Linux dev-shell store & bridge — done (2026-07-14).** Scope was
> the dev-shell flavor only (store + dispatcher + socket, **no capture** —
> design of record:
> `docs/superpowers/specs/2026-07-14-clipboard-phase7-linux-store-design.md`).
> As built: the dispatcher split into `clipboard-store-core.zsh` + per-platform
> `pb::*` backends (`clipboard-platform-{macos,linux-headless}.zsh`); on
> headless Linux the store's latest row IS the clipboard (G/T/R/S answer from
> it, C/U persist directly, every opcode supported). The listeners are systemd
> user socket activation (`clipboard-bridge.socket`, loopback 2489, plus
> `clipboard-bridge-trusted.socket`, mode-0600 Unix,
> both `Accept=yes`) — unit files + enable symlinks live in the
> homedir, so an image recycle restores the bridge at first login with no
> chezmoi run. sqlite3 ships via mise (homedir; apt is wiped on reboot).
> `pbcopy`'s store-less interim ("peer push becomes primary") is **retired**:
> the local `M` is the unconditional hard-fail primary everywhere, and both
> shims self-heal a stopped socket via `systemctl --user start`. GUI-Linux
> capture (wl-paste/xclip watchers) remains the only unbuilt corner of the
> original Phase 7 wording and is explicitly deferred.
>
> **Phase 5-R — self-contained clips (revision, supersedes the mirror).** The
> Phase-5 pointer mirror is being replaced per §11: clips materialize in full
> wherever they are *used*, so no machine ever depends on another being online.
> **Removed**: `[clipboard-mirror]` service, `M` mirror opcode, `S`
> restore-by-id, `ref_id`, `origin`, the dead `remote-own`, and the whole
> bridge-up *union* view. **Kept**: local capture, `source_host` (now the sole
> origin field), and the live bridge `get`/`get-regtype`/`set` ops — with
> `get` extended to return the full representation set + origin host so the
> consumer can persist a self-contained copy. Migration in §11 (drop stale
> pointer rows, backfill `source_host`, drop dead columns). **Design approved;
> implementation pending** (this doc is the spec of record).

## 19. Verification

- **Per phase**: run the relevant ShellSpec (`make test` for `lib/`
  primitives); reproduce with a real picker / a real NeoVim block yank.
- **Contracts to preserve** (load-bearing for ≥3 silos):
  - `pick::start` flag set and the `\x1f`/`\x1e` wire format — confirm
    `quick-launch-pick` (terminal-mux) and the `ai-assist`/`ai-commit`
    pickers (ai-harnesses) still work unchanged after the `--preview`
    passthrough.
  - `mux::pick` floating adapter (popup on either backend).
  - The existing `clipboard-bridge` socket path and the `options.lua`
    SSH-gating (`SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY`) — local NeoVim
    keeps `pbcopy`/`pbpaste`.
- **End-to-end checks**:
  - Block yank (`Ctrl+V` … `y`) then put in remote NeoVim → no E5108,
    block shape preserved.
  - Copy rich text in a GUI app → `Cmd+Shift+V` → paste styled into another
    GUI app.
  - `Alt+w v` in a local Zellij → pick a recent clip → injects into the pane.
  - SSH from your Mac → dev shell → paste a clip you copied on the Mac (it
    materializes into the dev shell's store) → next day, offline from the Mac,
    the same clip is still pickable there and `Ctrl-Y` copies it locally.
  - SSH iPad→a Mac (Blink) → `Alt+w v` shows that Mac's store →
    `Ctrl-Y` text → onto the iPad clipboard (OSC 52).
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
- Bridge: evolve the existing `clipboard-bridge`; live ops only — `{get}`
  (full representation set + origin host), `{get-regtype}`, `{set}`. No mirror,
  no restore-by-id (self-contained clips, §11): a clip materializes in full on
  any machine that uses it.
- NeoVim: type-preserving Lua provider; **drop yanky.nvim**.
- Cross-machine block: in scope (regtype column + current-regtype tracking
  on the local machine, reset on non-NeoVim writes). No "v1.5" — the project
  delivers the whole thing.
- Picker view: **this machine's store only** — no peer union. `source_host`
  drives the per-row local/remote badge, not row visibility.
- Remote file copy: scp-down to temp + local `public.file-url`.
- Any GUI Mac: full install when used locally; dev-shell-equivalent when SSH'd
  into. `pbcopy` shim auto-detects via bridge-up × `$SSH_CONNECTION`.
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

Repo: ~/.local/share/chezmoi (a chezmoi source directory; files
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
- home/dot_config/nvim/lua/clipboard/universal.lua — the EXISTING
  clipboard bridge (SSH-gated provider: OSC 52 copy out, framed TCP paste in
  via reverse-forwarded 2490 → 2489, served by the macOS launchd
  clipboard-bridge service). You are
  EVOLVING this bridge, not rebuilding it. Read the launchd service + the
  loose ~/.ssh/config.d/clipboard.config as your first step.
- home/dot_local/lib/pick-common.zsh — the pick::start engine and the
  \x1f/\x1e wire format. pick-clipboard is modeled on
  home/dot_local/libexec/executable_pick-glyph.
- home/dot_config/zellij/scripts/executable_zellij-modal and
  home/dot_config/zellij/config.kdl.tmpl (the zellijModalRun template) —
  the floating-modal scaffolding and keybind pattern.
- home/dot_local/lib/mux.zsh — mux::pick (the floating adapter; `zj::pick` survives as an alias).
- home/dot_config/hammerspoon/modules/apps/clipboard-history.lua and
  apps/clipboard-picker.lua — the landed Phase 2/4 code you're extending.
- home/dot_config/nvim/lua/clipboard/universal.lua — the landed Phase 1
  provider you're extending for cross-machine regtype (§9).

First verifications (do these before writing code):
1. Confirm Zellij passes OSC 52 through to the host terminal (ghostty /
   wezterm / Blink). Every OSC 52 copy-back path depends on it.
2. Read the existing clipboard-bridge launchd service and
   ~/.ssh/config.d/clipboard.config so you extend, not duplicate.
3. Read §11 (self-contained clips): the bridge is now live-ops-only
   (`get`/`get-regtype`/`set`); a clip materializes in full wherever it is
   used, so there is no mirror, no `ref_id`, and no restore-by-id fetch.

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
- mux::pick.
- The clipboard-bridge socket path and the SSH_CONNECTION/SSH_CLIENT/SSH_TTY
  gating — local (non-SSH) NeoVim keeps pbcopy/pbpaste.

Verification before claiming done (spec §19): run make test for lib/
primitives; test cross-machine materialize-on-use over SSH (use a peer clip,
then confirm it survives the peer going offline); test the iPad/Blink OSC 52
path; confirm a password-manager copy never enters history. Run chezmoi apply
after every edit. Scan diffs for company
info before staging.

Self-test via the `validate` skill (Mode A sandbox) per the work-on-<silo>
flow. Stop on the work-on-<silo> branch for the user to close with
/end-work; do not merge to master yourself.

Begin by reading docs/clipboard-universal-project.md in full, then the
files listed above. Report what you found before making changes.
```

---

## 22. Live peer clipboard entry in the picker

> **✅ Implemented** (commit `541976c`, 2026-07-08; UI polish in the same
> commit). Live-verified over a real SSH session against the reverse bridge —
> the §22.7 checks pass. The few deviations from this section as first written
> are folded into §22.3 and logged in §22.8.

> **Addendum to §11 (extends §7 `pick-clipboard` and §8 the access-path
> matrix).** Numbered §22 because §12 is already "Remote file copy"; this is a
> feature section living after the meta sections rather than renumbering the
> §12–§21 cross-references.

**The gap.** When you're SSH'd into a machine, the terminal picker (§7) shows
only *that* machine's own store — a copy you made moments ago on the machine
you're sitting at is reachable by *pasting* (`pbpaste` / nvim `p` read it live
over the reverse tunnel, §9) but is **invisible in the picker**. Users
reasonably expect to *see* it there. This section makes the picker surface the
peer's current clipboard as a single live entry, without weakening §11.

**Principle (unchanged from §11): viewing ≠ owning; using = owning.** Merely
seeing the peer's clipboard in the picker persists nothing. The row is fetched
live and shown; it is **not** in `history.db`. Only when you *act* on it
(Enter = paste, Ctrl-Y = copy) does it materialize into this machine's store —
the exact same `P`-op path nvim `p` already uses (§9, §11). This is not a
revival of the removed Phase-5 mirror: nothing is pushed eagerly and nothing
is stored as a pointer.

### 22.1 Detection (reuse, no new signal)

Show the live entry **iff `bridge_up`** — the flag `pick-clipboard` already
computes: a real connect probe to the reverse-forwarded peer clipboard on
`127.0.0.1:2490` succeeds (`clipbridge::probe`). Sitting locally at a Mac →
nothing is listening there → no peer, no entry. Bridge-down (iPad/Blink, no
tunnel) → no entry. The picker otherwise behaves exactly as today.

> **Amended in Phase 6b (§22.9).** This gate used to *also* require the
> `SSH_CONNECTION` / `SSH_CLIENT` / `SSH_TTY` triple. It no longer does. The
> triple describes the environment of whichever process happens to be asking,
> and the GUI picker asks from `hs.task`'s `zsh -lc` (the job runner, from
> pueue) — neither carries a single `SSH_*` variable, which made the headless
> verbs return nothing exactly where §22.9 needs them. The reverse forward is
> created by the ssh *client* and so exists only on the machine being ssh'd
> **into**: "something accepts on `127.0.0.1:2490`" is the environment-free
> form of the same question, and it also lights the live rows up for a TUI
> opened locally (VNC) on a machine someone is ssh'd into. Every OTHER use of
> the triple in the picker (which endpoint a Ctrl-Y copy ships to) is
> unchanged.

### 22.2 Fetch (open time — bounded, best-effort)

On picker open, when `bridge_up`, issue over the reverse tunnel (port 2490):

- `G` (get) → the peer's **current** clipboard text.
- `H` (get-host) → the peer's hostname, for the badge label.

Both with a **short timeout (~400 ms each)**. On timeout / error / empty, the
entry is simply omitted — **never block or delay the picker**. `R` (get-regtype)
and the materialize `P` are deferred to accept time (§22.4), so open costs at
most two sub-second loopback round-trips.

> **Empty guard applies here too.** If the peer's current clipboard is empty or
> whitespace-only, omit the live entry — the same rule the capture watcher uses
> (an empty/whitespace copy is never a real clip). Reuses the `^%s*$` test.

> **Scope: one entry, text only.** The bridge vends the *current* clipboard,
> not the peer's history — so this surfaces exactly one live row. `G` is
> text-only; a peer image/RTF clip surfaces as its text representation or (no
> text) is omitted. Rich live fetch is out of scope for v1 (see §22.6).

### 22.3 Display (synthetic top row, not a DB row)

The entry is **prepended** to the row stream (it cannot come from the `clips`
`SELECT`), sorted above every stored row, with a sentinel tail id `LIVE`
(no numeric id — it is not a row):

- Glyph + color: the mauve **origin** color already used for `source_host ≠
  me` (`c_origin`), with the `nf-md-access-point` glyph (`char(983043)`,
  U+F0003 — radiating waves), so it reads as live/not-from-here at a glance.
  *(Shipped as access-point; the first draft left the glyph unspecified.)*
- Preview: first line of the fetched text, truncated to the same `CW` width as
  other rows.
- Badge: carried by the mauve access-point glyph + top position — there is no
  inline `<peerhost> · live` text on the row line; the peer host and liveness
  live in the preview footer instead (`H` failure falls back to `peer`).
- Preview-pane footer: the preview script special-cases the `LIVE` sentinel —
  it renders from the fetched text held in a temp file (not a DB lookup, which
  would return nothing for `LIVE`): `Source: —` (the copying app is unknown for
  a live clip), `Content Type: text`, `Origin: remote (<peerhost>)`,
  `Characters`/`Words` from the text, `Copied: live`. The host is shown **once**
  (in `Origin`, not also `Source`) and middle-ellipsized (`remote (ZTMA…Q5P)`)
  so long `LocalHostName`s fit; every value field char-pads (`printf`'s `%!`
  flag) so the multibyte ellipsis / em-dash still right-align. *(The first draft
  put the host in both `Source` and `Origin` and byte-padded — corrected here.)*

### 22.4 Accept → materialize (the ownership step)

On accept of the `LIVE` entry, the wrapper (which today branches on the
`CP:`/`MD:`/plain-id accept markers) special-cases the sentinel:

1. **Deliver the content** using the *already-fetched* text (no second `G`):
   - Enter → inject the text into the originating pane (as normal Enter does).
   - Ctrl-Y → set my clipboard to the text (local set / ship, as `clip::copy_by_id`).
   - Alt-Enter → text (no rich-vs-raw distinction in a terminal).
2. **Materialize** it into this machine's store: fetch `R` (regtype) over 2490,
   then send `P` to the **local** bridge (`127.0.0.1:2489`) with the op-persist
   payload `source_host=<peerhost> US kind=text US app='' US regtype=<R> RS text`.
   After this it is an ordinary local row, badged `remote (<peerhost>)`, and the
   next picker open shows it as a normal stored row (and the live entry dedups
   against it — §22.5).

`Ctrl-D` (delete) and `Ctrl-P` (pin) are **no-ops** on the `LIVE` entry — there
is no row to delete or pin. The background-key hook ignores the sentinel id.

> **Ephemerality invariant (must hold):** opening the picker, scrolling over
> the live entry, and dismissing without accepting it writes **nothing** to
> `history.db`. Assert this in verification (§22.7): row count is unchanged
> across an open+dismiss that showed a live entry.

### 22.5 Dedup

If you already materialized the peer's current clip (e.g. you just `p`'d it),
don't show a twin. Suppress the live entry when a stored row already matches —
using **op-persist's dedup key**: `source_host = <peerhost>` AND
`type_hash = sha256(text)`.

> **type_hash caveat:** `op_persist` stores `type_hash = sha256(text)` (the
> dispatch handler, §3), whereas the Hammerspoon watcher stores
> `sha256("<uti>=<blob>"…)`. They differ, so the live-entry dedup must use the
> `sha256(text)` form to match rows that arrived via `P` (the only way a
> peer-origin text row is created). A locally-captured row with the same text
> won't collide — acceptable: it has a different `source_host` anyway.

### 22.6 Honest limits

- **Current clip only** (§22.2). No peer history. *(Amended in §22.9: the
  peer's current clip now surfaces as up to TWO live rows — its text clip and
  its file clip. Still no history, and still no live image/RTF.)*
- **Best-effort** — a slow/again-down bridge just omits the entry; the picker
  never hangs on it.
- **No auto-refresh** — the entry reflects the peer clipboard as of picker
  open. Copying on the peer while the picker is open does not live-update it
  (consistent with how the stored rows are a snapshot at open).

### 22.7 Files touched & verification

**Files** (picker-only; the bridge already speaks `G`/`R`/`H`/`P` — no
dispatcher or schema change):

- `home/dot_local/libexec/executable_pick-clipboard` — open-time fetch +
  prepend the synthetic `LIVE` row; preview-script `LIVE` special-case; accept
  branch for the sentinel (deliver + materialize); ignore `LIVE` in
  delete/pin/background hooks.
- `home/dot_local/lib/clipboard-bridge-client.zsh` — add thin `clipbridge::get`
  / `clipbridge::get_host` helpers if not already present (`send` + read the
  framed `O` response); the `P` send reuses `clipbridge::send`.

**Verification** (over a real SSH session, machine you're sitting at → remote):

1. Copy text on the peer → open the picker on the remote → the live entry
   appears at the top, badged `<peerhost> · live`.
2. Dismiss without selecting → `SELECT COUNT(*) FROM clips` unchanged
   (ephemerality invariant, §22.4).
3. Select it (Enter) → text is injected **and** a new row exists, badged
   `remote (<peerhost>)`; reopen → it's a normal stored row and the live entry
   is now deduped away (§22.5).
4. Empty/whitespace peer clipboard → no live entry (§22.2).
5. Bridge down (kill the tunnel) → no live entry, picker otherwise unaffected.

### 22.8 Decisions log (this section)

- Live entry gated on `bridge_up` only; reuses the existing probe. No new state.
- Open-time cost bounded to `G`+`H` with short timeouts; `R`+`P` deferred to
  accept. Never blocks the picker.
- Ephemeral until accepted; accept materializes via the existing `P` op — same
  ownership rule as nvim `p`. Does **not** revive the Phase-5 mirror.
- One entry, text-only, current-clip-only for v1; rich/history explicitly out
  of scope.

**Implementation notes (commit `541976c`):**

- Payload reads use a new `clipbridge::request` (framed send + byte-exact
  response via `head -c 1` / `tail -c +6`, never a `$(...)` capture) with thin
  `clipbridge::get` / `clipbridge::get_host` wrappers; `P` still reuses
  `clipbridge::send`.
- The `LIVE` row is pre-rendered once at open into a temp file and catted above
  the stored rows by **both** emit paths (`emit_rows` and the `start:reload`
  `emit_script`), so it survives delete/pin reloads without re-fetching —
  honoring "no auto-refresh" (§22.6).
- Row glyph: `nf-md-access-point`. Footer: host shown once, middle-ellipsized,
  char-padded (`%!`). See §22.3.
- Verified end-to-end over the live bridge (reads, render, field extraction,
  accept→deliver+materialize, dedup, ephemerality) — the DB row count is
  unchanged across an open+dismiss that showed a live entry.

### 22.9 Phase 6b — the peer's FILE clip, and the GUI's way in

> **Addendum to this section** (spec
> `docs/superpowers/specs/2026-08-18-clipboard-phase6b-remote-pull-design.md`).
> §22 as written above surfaces one live row, text only, in the TUI picker.
> The scenario that exposed the gap: yank a file in yazi on the laptop, ssh to
> the mini, open the picker — the file clip was invisible, because a peer files
> clip had no row to be. The ruling is that sitting→remote is **pull**-based
> (the remote asks; the sitting machine never pushes), so this extends the
> same live-entry mechanism rather than adding a channel.

**One snapshot, two exchanges.** `clipbridge::peer_snapshot` replaces the
three per-field `clip.get` round trips §22.2 described: one `clip.get` and one
`files.list` against the peer, emitted as up to two jq-built JSON lines (the
text candidate, the files candidate). `files.list` answering
`not-found{reason=not-files}` means "no files candidate", never an error. No
wire change, no PROTO bump — and the picker's contribution to the listener's
"no preamble" log flood drops with the retired handshakes.

**A second live row.** The files candidate renders as its own synthetic row
with the sentinel tail id `LIVEF` (`LIVE` stays the text row's) — same mauve
origin color, but the kind glyph of the stored `files`/`file`/`directory`
rows, and the same tail-truncating path rendering (§X8). The two live rows
each interleave by **their own** peer timestamp, so the picker shows
ABOVE-rows, whichever live row is newer, MID-rows, the older live row, then
BELOW-rows; a missing candidate collapses its segment and the split degrades
to §22.3's single-row shape, then to the plain query.

**Dedup by manifest.** The live FILES row is suppressed when a stored row
already holds this manifest from this origin: `source_host = <peerhost>` AND a
byte-equal `x-file-manifest` blob (the NUL-joined paths, exactly as the daemon
writes them). That is the files analogue of §22.5's `sha256(text)` key.

**Accept.** Enter/Alt-Enter deliver the newline-joined paths and record the
row; Ctrl-Y is the real pull — record the row, then hand its id to the same
`clip::copy_files_by_id` engine every stored files row uses (cache, size
caps, toasts, and the job-runner path for big files). "Record" is
a **pointer row** written by the picker straight to SQLite: `clips`
(`type_kind='files'`, `source_host=<peerhost>`, `text_preview`/`len`/
`type_hash` over the newline-joined paths) plus one `clip_types` row
(`uti='x-file-manifest'`, the NUL-joined blob), and **never** a
`file_authorities` row. It mirrors the daemon's `persist_files_row`
non-trusted branch statement for statement, including its dedup — a re-accept
bumps `last_ts` on the existing row instead of adding a twin.

**Pull transport (the Mode B freeze, fixed).** Case 3 of
`clip::copy_files_by_id` now has TWO transports. When the row **is the live
peer's current clip** (`clip::row_is_peer_current`: bridge up, one
`files.list` exchange, host + byte-equal path set), the bytes ride the
bridge — `system-clip paste --files --from-peer` streams the grant
(`files.grant`/`files.fetch`, credential = the tunnel token) into a staging
dir the picker distributes into its per-index cache. `--from-peer` exists
because the restore often runs where `is_ssh()` cannot answer (a GUI job
under pueue, a VNC-local TUI); a refused tunnel under the flag is a hard
error, never the trusted fallback (a different clip's bytes). Anything the
grant no longer covers — a stale manifest, or a row from a host this machine
genuinely can ssh to — takes the original `rsync -e ssh` pull-down, now with
`BatchMode=yes` on BOTH branches: the sitting→remote direction has no ssh
provisioning, and the unconditional rsync used to open an interactive
host-key/password prompt inside fzf's raw tty that wedged the terminal
(found live, Mode B 2026-08-18). Headless bridge pulls feed the job sidecar
via `--porcelain` (`clip::porcelain_progress_stream`, item completion counted
once per basename since the engine echoes the done moment twice).

> **Why not `store.persist.files`?** Because a *trusted* persist mints file
> authority over the named paths, so the daemon refuses one whose `host` is not
> itself (§9.3 evaluates `mints_authority` against the endpoint, never the
> caller-supplied host) — letting a trusted call claim a foreign host would be
> a confused deputy. The row a pull wants is the authority-free *pointer* row,
> which the daemon only ever produces on its public endpoint, i.e. for a push
> **from** the peer. The picker therefore writes that row itself; the daemon
> check stays exactly as it is. Locked by a spec example that diffs the
> picker's row against a real `recobd`'s, column for column.

**Headless verbs (the GUI's way in).** All bridge logic stays in
`pick-clipboard`; Lua never speaks the wire:

- `pick-clipboard --peer-snapshot` — prints the JSON candidates (the text one
  carrying a flattened ~200-char preview so the webview needs no clip bytes),
  empty output and rc 0 when there is nothing live.
- `pick-clipboard --pull-live text|files` — the accept-time pull. `text` sends
  one trusted `clip.set{text,regtype,origin_host}` from a **fresh** fetch (the
  GUI's accept can be minutes after its snapshot); `files` records the pointer
  row and restores it.

`clipboard-picker.lua` renders the local list immediately (snappiness is a
standing ruling), then spawns one `hs.task` for `--peer-snapshot` and injects
the live rows when it answers, if the picker is still open.

**Direct paste, newer-wins.** `system-clip paste` over SSH now compares the
peer's `clip.get` timestamp against its own and prints the newer, persisting a
used peer clip locally (§11's "a used peer clip survives the origin going
offline"). A *refused* tunnel degrades to the own clipboard; any slower
failure is still loud. Clock skew between machines remains the documented
accepted hazard.

---

## 23. Remote-copy provenance

> **✅ Implemented** (2026-07-08). **Extends §11 (provenance) and §9 (the copy
> paths).** Design doc: `docs/superpowers/specs/2026-07-08-remote-copy-provenance-design.md`.

**The gap.** A copy made while you're SSH'd into a machine is routed to the
clipboard of the Mac you're sitting at — `pbcopy` writes OSC 52 up through
Zellij/WezTerm, nvim `y` sends a `T` op to `:2490`. So the **origin** machine
never records it (its pasteboard is untouched), and the **sit-Mac** captures it
stamped `source_host = itself` → it reads *local*, never `remote(origin)`.
Provenance reflected *where the bytes landed*, not *where the copy happened*.

**Principle: a copy's origin is where the copy happened.** A copy on the origin
is now stamped `source_host = origin` **everywhere** — a **local** row on the
origin, a **remote(origin)** row on the sit-Mac — while the bytes still land on
the sit-Mac's clipboard for `Cmd+V`.

### 23.1 Mechanism

- **New bridge op `O` (declare-origin).** Request `<source_host> US <text>`;
  writes a hash-keyed, TTL'd state file
  `${XDG_STATE_HOME}/pick-clipboard/current-origin` (three lines: host /
  `sha256(text)` / epoch). Mirrors the `current-regtype` file `T` already writes.
  No schema change; `G/R/H/T/P/C/F` untouched.
- **Watcher override.** `clipboard-history.lua` gains `captured_origin(plain)`
  (mirrors `captured_regtype`): if a fresh declaration (within `ORIGIN_TTL = 5 s`)
  hashes to the captured text, `capture_now` stamps `source_host = origin`
  instead of `my_host()`. The watcher stays the sole DB writer — one row,
  correctly tagged, no duplicate.
- **Both copy paths declare before delivering.** Over SSH, `pbcopy` and nvim
  `copy()` buffer the text once and send `O`→`:2490` (awaited, so the state file
  exists before the bytes trigger the watcher), deliver the bytes (OSC 52 / `T`),
  and record a local row via `P`→`:2489` (`source_host = origin`).

### 23.2 Invariants & degradation

- **Hash-domain invariant:** the `O` hash and the watcher's `hash.SHA256(plain)`
  are over identical bytes — each path buffers the text once (temp file / single
  local) and reuses it for `O`, delivery, and `P`, trailing newline included.
- **Ordering:** `O` is synchronous and strictly precedes the clipboard set.
- **Best-effort / no-hang:** `O` and `P` are silent no-ops on any failure
  (`pbcopy`'s secondary `mktemp`s and `nc` calls all degrade); a down bridge
  falls back to today's OSC 52 behavior. The copy never blocks or aborts.
- **Limits (v1):** text only; `source_app` on the sit-Mac row reflects the
  sit-Mac's frontmost app (deferred refinement); an identical-text physical copy
  on the sit-Mac within the 5 s TTL can be mis-tagged (accepted, same class as
  the regtype file).

### 23.3 Files

`clipboard-bridge-dispatch` (op `O` + `current-origin` writer),
`clipboard-history.lua` (`captured_origin` + the one-line `host` stamp),
`executable_pbcopy` (buffer, `O` before OSC 52, `P`, `PBCOPY_OSC52_SINK` test
seam), `universal.lua` (nvim `copy()`: `O` before `T`, `P`). Deployed to both
Macs via chezmoi; symmetric — either can be origin or sit-Mac.
