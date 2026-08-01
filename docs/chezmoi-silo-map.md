# Silo & Integration Map — chezmoi dotfiles repo

A dispatch guide for parallel agents. Each silo is a **bounded ownership area**
an agent can work in without stepping on other agents, plus the **contracts**
it must preserve (the seams other silos depend on) and the **dependencies** it
consumes. Use this to brief a cold agent: "You own silo X; here are its files,
its public contract, and what it consumes."

Worktree for any agent that will edit: `../chezmoi-scan` on `master`
(or a fresh `git worktree add ../<silo-name> master`). The live working tree is
on `feat/ai-assist-phase-c1` with uncommitted edits — keep agents off it.

Evidence base: `/tmp/chezmoi-unique-features.md` (90-feature catalog).
Repo's own module map: `home/dot_local/bin/README.md` (authoritative for the
`dot_local` library layering and naming conventions).

## Global rules (read first)

1. **Naming convention** (`common.zsh`): *bare* = stdlib (`die`, `log_info`),
   `module::fn` = a library module (`pkg::*`, `sec::*`, `pick::*`, `mux::*`,
   `platform::*`, `cagent::*`, `assist::*`, `prompt::*`), `MODULE_UPPER` =
   module constant. An agent adding a function to a silo's library MUST follow
   the silo's `::` prefix.
2. **Library layering** (see `bin/README.md` diagram): everything bottoms out
   at `common.zsh`. A silo's library may source `common.zsh` and its own
   children only — do not introduce cross-silo library sourcing without
   updating the diagram.
3. **`common.zsh` is a shared coordination point.** Any silo needing a *new*
  shared primitive must add it here → that's a merge-conflict hotspot for
   parallel agents. Prefer a silo-local helper unless ≥2 silos need it.
4. **Tests**: ShellSpec suite in `tests/` at repo root (`make test` /
   `shellspec`, pinned `--shell zsh`). Libraries are sourced from the repo
   path. An agent changing a library MUST run the relevant spec file(s).
5. **chezmoi rendering**: most config files are `*.tmpl` (chezmoi templates
   with `{{ }}`). An agent editing config must understand the template data
   (`os`, `profile` personal/work/dev-shell, `chezmoi.*`) — see
   `.chezmoidata/` and `.chezmoiignore.tmpl`. Don't strip template guards.
6. **macOS vs Linux vs dev-shell**: behavior is gated by `os`/`profile` in
   templates and `otherword` guards in scripts. An agent must preserve these
   guards — the dev-shell profile is headless and `.chezmoiignore`s most GUI
   config (`hammerspoon`, `wezterm`, `ghostty`).
7. **Custom-build outputs are not in the repo.** Built artifacts
   (`symbols.db`, the patched font, the custom `zsh` binary) land under
   `$XDG_DATA_HOME/fonts/nerd-font/`, `~/.local/opt/zsh`, etc. The repo holds
   only the *builders* and the *chezmoi hooks that trigger them*.

## Silo index

| Silo | Area | Owner root | Library | Flagship contract |
|---|------|-----------|---------|-------------------|
| terminal-mux | Terminal & mux integration (tmux default, Zellij one knob away) | `dot_config/{wezterm,ghostty}/`, `dot_config/{tmux,zellij,mux}/`, `.chezmoidata/keymap.yaml` | `lib/mux.zsh` + `lib/mux/*`, `libexec/tmux-status-right`, `lib/image-protocol-support.zsh` | `mux::pick`, `mux::resolve_session`, OSC-52 clipboard, fullscreen mirrors, workspace-rename side-channel |
| clipboard | Universal clipboard (store + bridge + mount) | `dot_local/bin/pb{copy,paste}`, `libexec/clipboard-*`, `libexec/pick-clipboard` | `lib/clipboard-{store-core,bridge-client,platform-*}.zsh` | the framed wire protocol (opcode/BE32-length), ports 2489 local / 2490 peer |
| neovim | NeoVim config | `dot_config/nvim/` | (lua, none in `lib/`) | filetype registry (consumed by chezmoi), chezmoi auto-apply (consumes utils) |
| hammerspoon | Hammerspoon | `dot_config/hammerspoon/` | (lua, in-process) | `hs` CLI `notify`/`notifyAnsi` globals (consumed by shell/terminal-mux) |
| pick | pick framework + symbols pickers | `dot_local/lib/pick-common.zsh`, `pick-symbols-common.zsh`, `libexec/pick-*` | `pick::*`, `pick_symbols::*` | `pick::start` wire format (consumed by terminal-mux/custom-builds/ai-harnesses) |
| custom-builds | Custom builds | `custom-builds/` | (shell/python builders) | `symbols.db` schema+path (consumed by pick/hammerspoon), patched font (consumed by terminal-mux/hammerspoon) |
| theme | Single-source theming | `.chezmoidata/theme.yaml`, `custom-builds/theme/` | `lib/theme-common.zsh`, `libexec/theme-apply` | slot vocabulary + "no raw hex outside theme.yaml" (lint-enforced) |
| ai-harnesses | AI agent harnesses | `dot_local/bin/ai-assist*`, `ai-commit*` | `lib/{assist,commit}-agent-common.zsh` | `request.json` shape, harness `--probe` contract (consumed by terminal-mux pane render) |
| secrets | Secrets & onboarding | `dot_local/bin/system-secrets`, `system-onboard` | `lib/system-secrets-common.zsh` | `sec::*` slot API, `.leak-patterns` audit, `secrets.yaml` manifest |
| system | System management | `dot_local/bin/system-{package,service,images,update}*` | `lib/system-package-common.zsh` | `pkg::restart_services_for` → `system-service restart-for` (system internal seam), `services.toml.tmpl` |
| system-backup | Terminal Time Machine backups | `dot_local/bin/{system-backup,system-backup-capture,system-backup-reconcile}`, `dot_config/backup/` | `lib/backup.zsh` (`bkp::*`) | `bkp::thin` pure retention planner, `bkp::restic` storage seam, manifest = roots−deny−chezmoi−gitignored, `tm` |
| shell | Shell (zsh) bootstrap & widgets | `dot_config/zsh/`, `dot_zshrc`/`dot_zshenv`/`dot_p10k.zsh` | `lib/{common,prompt-common,platform}.zsh` | `environment.sh` (XDG source of truth), ZLE widgets, `notify` primitive |
| preview | File preview & terminal viewers | `dot_local/bin/preview`, `libexec/{fzf-tab-preview-open,ics-view,sqlite-view,disk-image-view}` | (uses `image-protocol-support.zsh` from terminal-mux) | `preview` as fzf/Yazi `--preview` backend |
| yazi | Yazi | `dot_config/yazi/` | (lua plugins) | Yazi previewer contract (consumes preview), `cd` event plugins |
| chezmoi | chezmoi orchestration & run-scripts | `.setup.sh`, `.chezmoiscripts/`, `.chezmoi*.{tmpl,yaml}` | — | `run_onchange_*` ordering + hash-baking, `zellij-plugin-path.tmpl` shared resolver |
| utils | Cross-cutting utilities | `dot_local/bin/{notify,wait-until,chezmoi-reverse}`, `libexec/tab-edit` | `lib/common.zsh` (`notify`), `lib/platform.zsh` | `notify` CLI, `chezmoi-reverse --no-merge`, `tab-edit` launcher |
| pi | pi coding agent config | `dot_pi/` + `pi-settings-merge.tmpl` + pi blocks in `.chezmoi.toml.tmpl`/`.chezmoiignore.tmpl`/`.chezmoiscripts/` | (none in `lib/`) | agent-local↔agent symlink sharing (extensions/lsp/skills/themes/Librarian), `modify_settings.json.tmpl` declarative-keys merge + `pi-settings-merge.tmpl`, `.pi.devExtensions` dev-extension symlink resolution |
| cursor | Cursor coding agent config | `dot_cursor/` | (none in `lib/`) | MDC rule format + `alwaysApply` semantics, agents/skills parallel structure (mirrors pi) |

> **utils is a coordination silo** — its files are shared deps. Treat
> `common.zsh`, `notify`, `tab-edit`, `chezmoi-reverse` as read-mostly by
> other silos; changes here ripple. Where a "feature" feels like it spans utils
> and another silo, the other silo owns the *consumer* and utils owns the
> *primitive*.

---

## terminal-mux — Terminal & multiplexer integration

**Owner area (safe to edit):**
- `home/dot_config/wezterm/` (all lua)
- `home/dot_config/ghostty/config`
- `home/dot_config/zellij/config.kdl.tmpl`, `layouts/default.kdl.tmpl`, `quick-launch/`, `scripts/` (backend-private: zellij-modal, pick-*-zellij, quick-launch-zellij, ensure-plugins, lib/zellij-session.zsh); `home/dot_config/mux/scripts/` (backend-neutral: quick-launch{,-pick,-window}, mux-open, mux-preview-{file,image}, mux-quit-confirm, the mux-*/tmux-* helpers, copy-pwd, edit-terminal-config, terminal-toggle-fullscreen, nested-session-check, resolve-terminal-location, lib/{config,command,dispatch,dispatch-tmux,terminal-location}.zsh); `home/dot_config/tmux/`
- `home/dot_local/lib/mux.zsh` (`mux::*`) + `home/dot_local/lib/mux/{tmux,zellij,stack,mode,dialog}.zsh`; `home/dot_local/lib/mux-bootstrap.zsh` is the fzf-free half (detection + session/pane/tab query verbs) that `mux.zsh` sources — startup paths such as `.zshrc` source the bootstrap, since pick-common `die`s at source time without fzf and the widget stack costs ~50ms; `home/dot_local/lib/zellij.zsh` is a compat shim sourcing `mux.zsh` (`zj::*` survive as permanent aliases); `home/dot_local/libexec/tmux-status-right`; `home/.chezmoidata/keymap.yaml` (single source for the tmux tables AND the which-key panel); `home/dot_local/lib/image-protocol-support.zsh`
- Zellij chezmoiscripts in chezmoi: `run_after_45-grant-zellij-plugin-permissions`, `run_onchange_after_40-install-snaps` (snap is system's data, the hook wiring is shared — coordinate)

**Out of scope:** the custom wasm plugin *source* (`zj-hud`, `zj-promptjump`, `zj-context-keys`, `vim-navigator`) lives **outside** this repo in `~/Projects/apps/zellij/`. This silo owns only the KDL that *loads* them and the scripts they *invoke*. The patched font/Symbols DB are custom-builds. nvim's SSH-paste consumer is neovim. The `clipboard-bridge` launchd *service definition* lives in `services.toml.tmpl` (system) — terminal-mux owns the nvim→socket protocol, system owns the agent plist.

**Public contract (preserve):**
- `mux::pick` — drop-in for `pick::start` (pick). Same argv, floats in a popup on either backend, else inline. Consumed by `ai-assist`/`ai-commit` (ai-harnesses) and `quick-launch-pick`. `zj::pick` remains as a permanent alias; nothing new should call it.
- `mux::resolve_session <client_pid>` / `mux::client_sessions` in `~/.local/lib/mux.zsh` — backend-dispatching session resolvers (the zellij half is the unix-socket scan; the tmux half asks the server). Consumed by `mux-open`, `tab-edit` (utils), quick-launch.
- **OSC 52 + framed clipboard protocol**: `copy_command` intentionally unset in `config.kdl.tmpl`; copy is origin-relative via re-emitted OSC 52. SSH paste-back uses framed requests to reverse-forwarded TCP 2490 (served by system's public `clipboard-bridge` listener on 2489). nvim implements the client.
- **Workspace-rename side-channel**: `__TOGGLE_FULLSCREEN__` / `__QL_FOCUS__=<id>` workspace names drive WezTerm handlers. `terminal-toggle-fullscreen` (this silo) and quick-launch depend on these exact sentinel strings.
- **Fullscreen-state mirrors** (atomic write-on-change), read by the tmux ribbon and the zj-hud bar: `~/.local/state/wezterm/fullscreen_state` pushed by `wezterm.lua`; `~/.local/state/mux/ghostty_fullscreen` filled by `mux-fullscreen-probe` off the tmux `client-resized` hook, because Ghostty has no equivalent hook and asking costs seconds. The ribbon renderer is a `#()` job: nothing in it may block, or the bar stops being re-expanded at all.
- **`W` window opcode** on the clipboard bridge (`fullscreen-toggle <ghostty|wezterm>`, `fullscreen-state`) — lets a session act on the terminal of the machine it came from over SSH. terminal-mux owns the mux half, clipboard owns the wire protocol.
- `get_terminal_image_protocol()` in `image-protocol-support.zsh` — returns the Kitty/iTerm2/Sixel capability list as constrained by whichever multiplexer is in play (they clamp differently). Consumed by `preview` (preview).
- `zellij-plugin-path.tmpl` (in this dir, shared with chezmoi) — resolves managed plugin `file:` paths; the permission-grant hook and `ensure-plugins` must agree with `config.kdl`'s loaded paths.

**Consumes from:** pick (`pick::start`), custom-builds (patched font + symbols.db for glyph pickers), shell (`environment.sh` XDG vars, `notify`), utils (`notify`, `tab-edit`, `platform::`), system (`services.toml` clipboard-bridge agent), chezmoi (chezmoi hooks trigger plugin perms / snaps).

**Entry points to start an investigation:** `lib/mux.zsh`, `lib/mux/{tmux,zellij}.zsh`, `.chezmoidata/keymap.yaml`, `scripts/lib/dispatch.zsh`, `wezterm.lua`, `config.kdl.tmpl`. Read `docs/mux-parity.md` first — parity ledger and gotcha record in one.

**Dispatch example:** *"Review the Zellij quick-launch dispatcher for correctness/performance. You own terminal-mux's `dot_config/mux/scripts/quick-launch*` and `lib/dispatch.zsh`. Preserve `mux::pick`/`mux::resolve_session`/`@window:<id>` contracts. Don't touch the wasm plugin sources (outside repo) or `services.toml` (system)."*

---

## clipboard — Universal clipboard

**Owner area (safe to edit):**
- `home/dot_local/bin/executable_pb{copy,paste}` (the CLI surface, incl. the SSH branches)
- `home/dot_local/libexec/executable_clipboard-bridge-dispatch` (per-connection handler; socat EXECs it per connection, so changes need no restart), `executable_clipboard-mount` (FUSE), `executable_pick-clipboard`
- `home/dot_local/lib/clipboard-store-core.zsh` (store + framing + every `clip::op_*`), `clipboard-bridge-client.zsh` (`clipbridge::*`), `clipboard-platform-{macos,linux-headless}.zsh` (`pb::*`)
- `home/dot_config/systemd/user/clipboard-bridge{,-trusted}{@.service,.socket}`, `run_onchange_after_37-setup-clipboard-bridge.sh.tmpl` (logic only)
- `docs/clipboard-universal-project.md` (the wire record — keep in step with the code)

**Out of scope:** `nvim/lua/clipboard/**` (neovim owns the Lua, clipboard owns the protocol it speaks); the Hammerspoon clipboard modules + picker HTML (hammerspoon owns the UI); `pick-clipboard-zellij` (terminal-mux modal adapter); the `clipboard-bridge` agent *definition* in `services.toml.tmpl` (system-services owns the plist); `pick::start` (pick); the `W` opcode's *window* half — `terminal-toggle-fullscreen` / `mux-fullscreen-probe` (terminal-mux).

**Public contract (preserve):**
- **Wire protocol**: `<opcode><BE32 len><payload>` → `<'O'|'E'><BE32 len><payload>`. Opcode table in `docs/clipboard-universal-project.md` §11 and the dispatcher header — both must agree. Adding an opcode is additive; changing one is a cross-machine break, because the two ends update independently.
- **Ports**: 2489 = this machine's own bridge, 2490 = the reverse-forwarded peer. 2490 listening is also the honest "am I the remote end" test.
- **Cross-machine TCP, trusted-local Unix socket** — 2489 remains the SSH-forward target because macOS OpenSSH ignores `StreamLocalBindUnlink` for remote unix-socket forwards. Privileged local file operations use the separate mode-0600 `~/.local/state/cb.sock`, owned by socat/systemd and never forwarded.
- **Capability-bound file reads** — `L` remains the human manifest view; `K` returns an opaque grant over one trusted path snapshot; lowercase `f`/`a` accept only that token plus an item index. Raw-path `F`/`A` are retired. Public `M` is pointer-only, while trusted local `M`/`U` and native file captures create authority.
- `clipbridge::probe|send|request`; `CLIPBRIDGE_TIMEOUT_S` (2s default suits a read answered from memory, not an op that makes the origin *act*).
- Legacy bare-connect grace path; byte-safe framing (`sysread`, never `$(...)`, because manifests are NUL-joined).
- `x-file-manifest` UTI + `source_host` provenance; `clip::self_host` identity.

**Consumes from:** pick (`pick::start`), terminal-mux (`mux::pick`/popup mechanics), utils (`notify`, `common.zsh`), system-services (the socat agent), shell (XDG vars).

**Entry points:** `docs/clipboard-universal-project.md`, `lib/clipboard-store-core.zsh`, `libexec/clipboard-bridge-dispatch`, `bin/pbcopy`.

**Dispatch example:** *"Add an opcode for X. You own the dispatcher, the store core and the bridge client. Preserve the framing and the legacy grace path; an old peer must get a loud `E`, never a hang. Don't edit the nvim provider or the Hammerspoon picker — they're consumers."*

## neovim — NeoVim config

**Owner area:** `home/dot_config/nvim/` — `init.lua`, `lua/config/{options,autocmds,keymaps,lazy}.lua`, `lua/plugins/*.lua`, `lua/lualine/`, `lua/utils/*.lua`, `after/`, `local-plugins/smart-comment-wrap/`, `spell/`, `lazyvim.json`, `lazy-lock.json`, `dot_luarc.json`, `dot_editorconfig`.

**Out of scope:** the `chezmoi-reverse` binary (utils) — nvim *calls* it. The `clipboard-bridge` service (system) and WezTerm paste path (terminal-mux) — nvim *consumes* them. The Finder droplet generator (chezmoi) *queries* nvim's filetype registry headlessly but doesn't modify nvim.

**Public contract (preserve):**
- **Filetype registry**: `vim.filetype.add` patterns (`.json.tmpl`→`json.gotmpl`, etc.) and `vim.filetype.inspect().extension` — the chezmoi "Open in NeoVim" app generator queries this headlessly to build UTI lists. Adding/removing filetype mappings changes Finder's "Open With" coverage.
- **SSH clipboard client** (`lua/clipboard/universal.lua`): `vim.g.clipboard` custom paste uses framed `G`/`R` requests on reverse-forwarded TCP 2490; copy uses OSC 52 / framed writes. Gated to SSH. The framed protocol is owned by clipboard.
- **Chezmoi auto-apply** (`autocmds.lua`): `BufReadPre` redirect → `chezmoi-reverse --no-merge` (utils); `BufWritePost` debounced `chezmoi apply --force`. Depends on `chezmoi-reverse`'s `needs-merge` exit semantics (utils).
- **Harper shared dictionary**: `spell/en.utf-8.add` is chezmoi `create_`-prefixed (so apply never reverts). The `uv.new_fs_event` watcher + `workspace/didChangeConfiguration` ping to harper-ls.
- **gotmpl treesitter injection**: `after/queries/gotmpl/injections.scm` + custom `inject-inner-ft!` directive.
- **lualine `dynamic-fqn`** uses `lua/utils/path.lua`, also consumed by Snacks `yank_path`.

**Consumes from:** utils (`chezmoi-reverse`), terminal-mux/system (clipboard-bridge socket, OSC 52 via WezTerm), chezmoi (chezmoi apply), external LazyVim/Mason/Harper.

**Entry points:** `lua/config/options.lua`, `lua/config/autocmds.lua`, `lua/plugins/`.

**Dispatch example:** *"Investigate the chezmoi auto-apply debounce in nvim. You own `dot_config/nvim/lua/config/autocmds.lua`. The seam is `chezmoi-reverse --no-merge` (utils, read-only for you) emitting `needs-merge`; preserve the `BufReadPre` redirect + 5s debounced `BufWritePost` apply + `VimLeavePre` flush contract."*

---

## hammerspoon — Hammerspoon

**Owner area:** `home/dot_config/hammerspoon/` — `init.lua`, `modules/{keybindings,streamdeck,osd,system,audio,windows,apps,clipboard,bootstrap,lifecycle}/*.lua`, `Assets/`.

**Out of scope:** the `notify` *caller* in `common.zsh`/`bin/notify` (shell/utils) — Hammerspoon owns the *receiver* (`hs` CLI globals `notify`/`notifyAnsi`); utils owns the *sender*. The symbols.db (custom-builds) — Hammerspoon's OSD `glyph:` resolver *queries* it read-only. Stream Deck hardware/Elgato app. Raycast/Shottr/ColorSlurp/PixelSnap (external apps, only URL-scheme integration here).

**Public contract (preserve):**
- **`hs` CLI globals `notify` / `notifyAnsi`**: the OSD entry points invoked by `common.zsh`'s `notify` primitive (shell/utils) via `hs -c`. Arg shape: Lua string literals (env vars are invisible inside the running HS process — that's why `notify` serializes env to literals). Icon specs `glyph:<name>` (resolved via symbols.db query), `swatch:#RRGGBB`, SVG name. Sound names. This is the single most important hammerspoon seam.
- **`optimistic_state`** generic (`modules/system/optimistic_state.lua`) — reused by controls + Stream Deck re-render-on-external-change.
- **keybinding tree shape** (`modules/keybindings/init.lua` `kb.setup{...}`) — numeric actions = macOS symbolic hotkeys managed via `system_shortcuts.lua` plist diffing.
- **media-key interception** (`lifecycle.lua` `systemDefined` eventtap) — routes SOUND/BRIGHTNESS to controls.

**Consumes from:** custom-builds (symbols.db for `glyph:` icons), shell/utils (`notify` senders), external apps via URL schemes.

**Entry points:** `init.lua`, `modules/keybindings/`, `modules/streamdeck/`, `modules/osd/`.

**Dispatch example:** *"Review the Stream Deck+ engine for performance. You own `dot_config/hammerspoon/modules/streamdeck/`. Preserve the `hs` CLI `notify`/`notifyAnsi` global contract (utils calls it) and the `onChange` callback that Stream Deck subscribes to from `modules/system/controls.lua` (same silo)."*

---

## pick — pick framework + symbols pickers

**Owner area:**
- `home/dot_local/lib/pick-common.zsh` (`pick::*`), `pick.jq`
- `home/dot_local/lib/pick-symbols-common.zsh` (`pick_symbols::*`)
- `home/dot_local/libexec/executable_pick-list`, `pick-glyph`, `pick-gitmoji`
- `home/dot_local/lib/input-common.zsh` + `libexec/executable_input-widget` — the modal INPUT widget (adopted 2026-07-28): a picker with the list removed, same modal plumbing, same callers

**Out of scope:** `mux::pick` (terminal-mux — the floating adapter, but it's a thin drop-in that *calls* `pick-list`/`pick::start`). The Zellij modal adapters `pick-{glyph,gitmoji}-zellij` (terminal-mux). The symbols.db *builder* (custom-builds). Consumers in ai-harnesses (`ai-assist`/`ai-commit` pickers) and terminal-mux (`quick-launch-pick`).

**Public contract (preserve — load-bearing for ≥3 silos):**
- **`pick::start [flags] LINES_CACHE_OR_STDIN`** — the core entry. Flags include `--cache-usage` (recency), `--cache-state`/`--resume` (cursor restore), `--selector`/`--selector-shortcuts`/`--selector-nav`, `--key-background` (insert-without-dismiss FIFO broker), `--key-output <key>:<kind>:<field>`, `--multi[=SEP]`, `--copy-only`, `--on-items-picked <cmd>`, `--output`, `--name`. Also `pick::line`, `pick::run`, `pick::feed`, `pick::clipboard`, `pick::record`.
- **Wire format** (shared with `pick.jq`): each line `<visible>\x1f<tail[0]>\x1e<tail[1]>…`. US (`\x1f`) splits ANSI-colored visible display (fzf renders via `--with-nth=1`) from hidden plain-text tail; RS (`\x1e`) splits tail fields. Last tail field = raw glyph by convention (so ANSI never leaks to stdout). `pick.jq` defines canonical Catppuccin SGR sequences + `emit_line`.
- **Recency**: file-based for non-DB pickers (`--cache-usage`), SQLite `last_used` via `--on-items-picked` for DB pickers.
- **`PICK_INJECT_PANE` / `PICK_INJECT_ZELLIJ`** env — the `--key-background` FIFO broker injects into these.
- **`PICK_GLYPH_DB`** env (default `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`) — the DB path contract with custom-builds.

**Consumes from:** custom-builds (symbols.db at `PICK_GLYPH_DB`), shell (`common.zsh` stdlib), terminal-mux (`mux::pick` adapter, `zellij-modal --capture` FIFO for floating pickers).

**Entry points:** `pick-common.zsh` (`pick::start` at line ~650), `pick.jq`, `pick-glyph`.

**Dispatch example:** *"Review the `pick::` engine for performance. You own `lib/pick-common.zsh` + `pick.jq` + `libexec/pick-list`. The wire format (`\x1f`/`\x1e`) and the `pick::start` flag set are a public contract consumed by terminal-mux (quick-launch-pick, mux::pick) and ai-harnesses (ai-assist/ai-commit pickers) — preserve them. The symbols.db path (`PICK_GLYPH_DB`) is owned by custom-builds; treat the DB as read-only."*

---

## custom-builds — Custom builds

**Owner area:**
- `custom-builds/nerd-fonts/` — `build-updated-font.sh` (~2740 lines), `recalibrate-fa.sh`, `custom-icons/*.{svg,metadata.json}`, `unicode-donor-glyphs.txt`, `symbols-db/build-symbols-db.py` (~46K) + `README.md`
- `custom-builds/zsh/` — `build-zsh.sh` + `README.md`
- The build-trigger chezmoiscripts in chezmoi: `run_onchange_after_70-symbols-nerd-font`, `run_onchange_after_60-symbols-db`, `run_after_80-symbols-nerd-font-prompt`, `run_onchange_after_50-custom-build-zsh` (the *trigger logic* is chezmoi; the *builder* is custom-builds — coordinate the hash-baked fingerprints)

**Out of scope:** the font *consumers* (terminal-mux WezTerm/Ghostty font chains, hammerspoon OSD glyph rendering) — they reference the built artifacts by path; custom-builds only owes them a stable artifact path + format. The pickers (pick) — they read the DB.

**Public contract (preserve):**
- **`symbols.db`** at `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db` — single flat `symbols` table, one row per symbol, faceted columns (primary shortcode by source priority `gitmoji>github>slack>emoticon`, `extra_shortcodes`, `source_keys`, `keywords`, `tags`, `last_used`). Schema is consumed read-only by pick (`pick-glyph`/`pick-gitmoji`) and hammerspoon (OSD `glyph:` resolver). **Schema changes require coordinating pick.**
- **Renderability probe**: `wezterm ls-fonts --text` oracle (drops `.notdef`), CoreText fallback; verdicts cached under `$XDG_CACHE_HOME/symbols-db/`. Re-running preserves `last_used`.
- **Patched font artifacts**: the Symbols Nerd Font (and the JetBrains-Mono NF for Blink) installed to the user font dir; the Blink CSS (embedded fonts + Noto OT-SVG). terminal-mux's WezTerm `font_with_fallback` chain and Ghostty `font-codepoint-map` reference these by family name; the custom-icons `code` pins in `metadata.json` must stay stable (terminal-mux/hammerspoon glyph lookups depend on them).
- **Custom `zsh`** at `~/.local/opt/zsh` + symlink `~/.local/bin/zsh`, registered in `/etc/shells` + `chsh`. Built *without* `--enable-unicode9`. macOS work/personal only (template-gated).

**Consumes from:** chezmoi (chezmoi onchange triggers + the hash-baked fingerprints), upstream zsh/Font-Awesome/Nerd-Fonts patcher, `wezterm ls-fonts` (oracle).

**Entry points:** `custom-builds/nerd-fonts/build-updated-font.sh`, `symbols-db/build-symbols-db.py`, `custom-builds/zsh/build-zsh.sh`.

**Dispatch example (matches your stated need):** *"The custom Nerd Font build is too slow — investigate. You own `custom-builds/nerd-fonts/build-updated-font.sh` + `recalibrate-fa.sh` + `symbols-db/build-symbols-db.py`. The build is triggered by chezmoi's `run_onchange_after_70`/`run_after_80` hooks (read-only for you — the trigger hashes live there). You must preserve the output contract: `symbols.db` schema+path (consumed read-only by pick pickers and hammerspoon OSD) and the patched font family name + custom-icon `code` pins (consumed by terminal-mux font chains). Don't touch the consumers."*

---

## theme — Single-source theming

**Owner area (safe to edit):**
- `home/.chezmoidata/theme.yaml` — the single source; slot names (`roles.*`, `extended.*`, `palette.*`) are an API referenced by path from shell, Lua and Rust
- `custom-builds/theme/generate-theme.sh` + `templates/` (one per projection)
- `home/dot_local/lib/theme-common.zsh`, `libexec/executable_theme-apply`, `bin/executable_theme-reset`
- `run_onchange_after_54-generate-theme.sh.tmpl` (logic only), `tests/lint-theme.sh`

**Out of scope:** the *consumers* that read a projection (terminal-mux, yazi, neovim, preview, shell, pi, cursor own their own files — a wrong colour is usually a slot or template here, but the reader belongs to them); generated outputs under `~/.config/theme/` and `~/.config/*/themes/` (build products); the rest of `custom-builds/`.

**Public contract (preserve):**
- **No raw hex outside `theme.yaml`** — `lint-theme.sh` runs in `make test` and is the reason the palette can move at all.
- **The projections and their paths** (see `generate-theme.sh`): ~14 outputs incl. `~/.config/theme/chezmoi-system.{json,zsh,lua}`, per-terminal themes, bat/glow/yazi/zsh/pi/Claude Code. The JSON is the machine-readable one (POSIX consumers read it with `jq`).
- Regeneration is automatic on `chezmoi apply` via the onchange hook; a tmux/Zellij *reload* is a separate concern (terminal-mux).

**Consumes from:** chezmoi (template rendering + hash triggers), shell (`common.zsh`, XDG), utils (`notify`).

**Entry points:** `.chezmoidata/theme.yaml`, `custom-builds/theme/generate-theme.sh`, then the consumer's template.

**Dispatch example:** *"Add a slot for X and project it into tmux and yazi. You own theme.yaml, the generator and its templates. Don't edit the files that read the projection — and don't hand-edit a generated output."*

## ai-harnesses — AI agent harnesses

**Owner area:**
- `home/dot_local/bin/executable_ai-assist`, `ai-assist-{claude,pi,cursor,test}`
- `home/dot_local/bin/executable_ai-commit`, `ai-commit-{claude,pi,cursor}`
- `home/dot_local/lib/assist-agent-common.zsh` (`assist::*`), `commit-agent-common.zsh` (`cagent::*`)
- `home/dot_local/libexec/ai-assist-{summon,popup,render,input,action-broker}` (the popup is a `zellij-modal --capture` adapter)
- The ZLE widget `ai-assist-trigger` in `home/dot_config/zsh/functions.d/widgets.sh` (shared file with shell — coordinate) bound to `Ctrl+Shift+/` (kitty `CSI 47;6u`, delivered by terminal-mux's `zj-context-keys`)

**Out of scope:** the `mux::pick`/`pick::start` framework (pick) — harnesses *call* it for the harness picker. The Zellij docked-pane spawn (`assist::spawn_pane`) uses terminal-mux's `zellij action` API. Atuin and the LLM harness CLIs (claude/cursor/pi) are external.

**Public contract (preserve):**
- **Harness `--probe` contract**: each `ai-assist-*`/`ai-commit-*` worker answers `--probe` with a label iff its CLI is present. The dispatcher discovers workers by globbing `ai-assist-*`/`ai-commit-*` siblings and probing. Adding a harness = add a sibling respecting `--probe`.
- **`request.json` shape** (ai-assist): `{origin:{session,pane,cwd}, last_command, exit, scrollback, user_request, project:{root,branch}}` — consumed by `assist-agent-common.zsh` and the worker.
- **Commit plan JSON** (ai-commit): `{commits:[{files:[...], message}]}` — the worker writes it to a tempfile; `cagent::execute_plan` reads it. **The agent never runs git** — `cagent::*` owns all `git add`/`git commit -F`. Plan cache under `.git`; `--replan` forces refresh.
- **Session pin**: `$XDG_STATE_HOME/ai-assist/sessions/<session>/harness`.
- **Per-project KB**: `$XDG_DATA_HOME/ai-assist/projects/<sha1(root)>/knowledge.md`.

**Consumes from:** pick (`mux::pick`/`pick::start` for harness + plan pickers), terminal-mux (Zellij docked pane, `zellij-modal` for popup), shell (`prompt::confirm`, `common.zsh`), utils (`notify`), external Atuin + LLM CLIs.

**Entry points:** `assist-agent-common.zsh`, `commit-agent-common.zsh`, `bin/ai-assist`, `bin/ai-commit`.

**Dispatch example:** *"Review the `ai-commit` plan-cache + stage/commit loop for robustness. You own `lib/commit-agent-common.zsh` + `bin/ai-commit*`. Preserve the `{commits:[{files,message}]}` plan JSON shape and the 'agent plans, script owns all git' invariant. You consume `mux::pick` (pick) and `prompt::confirm` (shell) — read-only. Don't touch the ZLE widget file (shared with shell)."*

---

## secrets — Secrets & onboarding

**Owner area:**
- `home/dot_local/bin/executable_system-secrets`, `executable_system-onboard`
- `home/dot_local/lib/system-secrets-common.zsh` (`sec::*`, 24K — also sources `prompt-common.zsh`)
- `home/dot_config/zsh/private_secrets.d/private_slot-*.sh.tmpl`
- `home/.chezmoidata/secrets.yaml` (manifest of env-var NAMES + prompts + `requiredFor` profiles — no values)
- `secrets/<slot>/<NAME>.sops.sh` (outside the chezmoi source root), `.sops.yaml`, `.leak-patterns`
- GPG chezmoiscript `run_after_25-setup-gpg-key.sh.tmpl` + the op-daemon reaper `run_before_05-reap-stale-op-daemon.sh.tmpl` (trigger wiring is chezmoi; the *logic* is secrets)

**Out of scope:** the 1Password CLI / SOPS / age tools (external). The `op-cache-v1` content-hash cache is secrets-internal. The operator map `~/.config/chezmoi/onboard-map.yaml` is loose/unmanaged (not in repo).

**Public contract (preserve):**
- **Opaque slot IDs** `slot-<6hex>` — never alias/hostname/username in committed artifacts. The committed manifest `secrets.yaml` carries NO values, only declarations. This leak-safety boundary is the core invariant.
- **Two materialization paths**: human = `op read "op://..."` in chezmoi templates (cached via `op-cache-v1` content hash, refresh on `CHEZMOI_REFRESH_SECRETS=1`); headless = SOPS+age blobs decrypted to 0600 files. Over SSH, `op` switches to a loose service-account token.
- **`sec::leak_audit`** runs on every commit path against `.leak-patterns` — the leak-patterns file is part of the contract.
- **GPG import** (`run_after_25`): keys as 1Password **Private** vault docs; `env -u OP_SERVICE_ACCOUNT_TOKEN` forces account mode; defers (exit 0, `run_after` not `run_once`) when no tty; completion marker keyed on `expected_key_spec` + keyring stat hash.

**Consumes from:** shell (`prompt-common.zsh` for prompts, `common.zsh`), chezmoi (chezmoi template `op read` resolution, run-script ordering), external `op`/SOPS/age.

**Entry points:** `system-secrets-common.zsh`, `bin/system-onboard`, `secrets.yaml`, `.leak-patterns`.

**Dispatch example:** *"Review the secrets leak-audit coverage. You own `lib/system-secrets-common.zsh` + `.leak-patterns` + `bin/system-secrets`. Preserve the opaque-slot-id invariant and the `op-cache-v1` cache semantics. The GPG import hook (`run_after_25`) and op-daemon reaper are yours but live in chezmoi's `.chezmoiscripts/` — coordinate if you touch trigger hashes."*

---

## system — System management

**Owner area:**
- `home/dot_local/bin/executable_system-package`, `system-package-{brew,cargo,go,npm,snap,uv}`
- `home/dot_local/bin/executable_system-service`, `system-service-{launchd,brew}`
- `home/dot_local/bin/executable_system-images`, `executable_system-update`
- `home/dot_local/lib/system-package-common.zsh` (`pkg::*` — also backs `system-service` and `system-images` per `bin/README.md`)
- `home/dot_config/packages/{Brewfile,Brewfile.bootstrap,Cargofile,Gofile,Npmfile,Snapfile,Uvfile}.tmpl`, `services.toml.tmpl`, `images.toml.example`

**Sub-silos (independently dispatchable, shared `pkg::*` lib):**
- **system-packages packages** — `system-package*` + `pkg::*` + `*file.tmpl` (not `services.toml`/`images.toml`)
- **system-services services** — `system-service*` + `services.toml.tmpl`
- **system-images images** — `system-images` + `images.toml.example`
- **system-update update orchestrator** — `system-update` (orchestrates system-packages/system-services + external brew/mise/yazi/nvim/pi)

**Out of scope:** the package ecosystems themselves (brew/cargo/go/npm/snap/uv — external). The services *declared* in `services.toml.tmpl` that belong to other silos: `clipboard-bridge` (terminal-mux protocol, system owns the plist), `images-automount` (system-images consumer), `mlx-gemma` (local-LLM stack — on-demand `mlx_vlm.server` on :8799; treat as system-internal, model/runtime owned by the local-LLM stack). mise-managed runtimes are external (mise), but `system-package-brew` guards them.

**Public contract (preserve):**
- **`pkg::restart_services_for <pkg>...`** → calls `system-service restart-for "$@"` (system internal seam between system-packages and system-services). `pkg::restart_changed <before> <after>` diffs version snapshots and restarts only changed. **This is the seam your "system packages manager" agent must preserve** — `system-service restart-for` maps a package name to services (launchd by key or `cmd[0]` basename, brew by name) and restarts **only if currently running**.
- **Manifest grammar** (`pkg::manifest_read`): comment-stripping, canonical-name tokenizer (`${(z)}`), `<name> -- <spec>` alternate install form for git/local. Shared across all 6 ecosystem workers.
- **`list [-u|--update] [-a|--all]` TSV rows** + `sync` (install declared / uninstall extras, strict where safe). Brew worker merges `Brewfile.bootstrap`+`Brewfile`, guards mise-owned runtimes (`^(go|python|node|...)@?`), tracks taps. Snap worker intentionally does **not** remove undeclared (snapd auto-installs base/platform snaps).
- **`services.toml.tmpl`** schema: TOML sections → launchd user agents rendered to plists (`yq`/`jq`), `~`-expansion + `command -v` resolution of `cmd[0]`, working/log dirs auto-created, bootstrapped into `gui/$(id -u)`. OS-aware cache dir (Library/Caches on macOS, `~/.cache` elsewhere).
- **`system-update`** ordering invariants: `git fetch`+ff-only (no rebase) → `chezmoi apply` → **self re-exec** if source advanced (`SYSTEM_UPDATE_REEXECED`) → `brew update` → `mise install/upgrade/prune` **before** `system-package sync` (so npm globals don't orphan on a node upgrade) → `system-package sync` → `brew cleanup` → `pinentry-touchid -fix` (SSH-skipped) → `system-service sync` → `ya pkg upgrade` → yazi lockfile commit/push (copies `package.toml` into chezmoi source, not `chezmoi re-add`, to avoid the apply lock when invoked from chezmoi's own `run_once`) → `Lazy! sync`/`MasonToolsUpdateSync` → `pi update --extensions` → git-pull zsh plugins. Detects `CHEZMOI=1` re-entrancy.

**Consumes from:** chezmoi (Snapfile onchange hook `run_onchange_after_40`), shell (`common.zsh`), external brew/cargo/go/npm/snap/uv/mise.

**Entry points:** `system-package-common.zsh`, `bin/system-package`, `bin/system-service-launchd`, `bin/system-update`, `packages/services.toml.tmpl`.

**Dispatch example (matches your stated need):** *"Review the system-packages manager for performance improvements. You own silo **system-packages**: `bin/system-package*` + `lib/system-package-common.zsh` + `packages/{Brewfile,Cargofile,Gofile,Npmfile,Snapfile,Uvfile}.tmpl`. Don't touch `services.toml.tmpl` (system-services) or `system-update` (system-update). The cross-seam contract you must preserve is `pkg::restart_services_for` → `system-service restart-for` (system-services owns the receiver) and the manifest grammar (`<name> -- <spec>`, comment-stripping). Each worker's `list -u` fans out parallel outdated-checks to registries — start there."*

---

## system-backup — Terminal Time Machine backups

**Owner area (safe to edit):**
- `home/dot_local/bin/executable_system-backup` (dispatcher), `executable_system-backup-capture` / `executable_system-backup-reconcile` (workers), `libexec/executable_system-backup-tm` (scrub session worker: timeline/lens/route/apply — libexec, invoked by absolute path from zellij/yazi)
- `home/dot_local/lib/backup.zsh` (`bkp::*` — thinning engine, manifest resolver, capture/reconcile, restore/UX), `home/dot_local/lib/backup-tm.zsh` (`bkp::tm::*` — scrub session state machine + yazi/hunk lens plumbing)
- `home/dot_config/backup/manifest.toml` (committed capture spec) + `config.toml.example` (the real `config.toml` is local-only, never committed)
- `home/dot_config/zsh/functions.d/tm.sh` (the `tm` front-end function)
- The three `backup-*` sections in `packages/services.toml.tmpl` (the *scheduling keys* schema itself — `start_interval`, `watch_paths`, etc. — belongs to system-services; coordinate)
- `docs/system-backup-recovery.md` (bare-metal runbook)

**Out of scope:** restic/zellij/hunk/fzf (external; installed via system-packages' Brewfile). `system-service-launchd` and the Servicefile *schema* (system-services — system-backup only declares entries). chezmoi's `managed` query and git (consumed read-only as filters). The `sec::` secret slot holding the repo passphrase (secrets).

**Public contract (preserve):**
- **`bkp::thin (now, [id\tepoch…], policy) → keep/drop`** — pure, deterministic, idempotent; wall-clock-aligned grids (LOCAL time, ISO-Monday weeks); half-open age bands; `keep_last=1`. The ladder counts are emergent (band÷grid), never enforced.
- **`bkp::restic <repo> <args…>`** — the single storage seam; every test stubs it. Passphrase only ever flows via `RESTIC_PASSWORD_COMMAND`.
- **Manifest semantics**: `capture = roots − deny − chezmoi-managed(files) − per-repo gitignored(full resolution)`; fail-safe is always over-capture; roots are string-or-table (`bundle_unpushed`, `untracked_warn_size`).
- **Sidecar format**: `~/.local/state/terminal-backup/wip/<basename>-<12hex>.{bundle,meta.json}` — `restore-project` depends on it.
- **Reconcile identity**: snapshots compare as `original // id` (restic copy rewrites ids); `role = "master"` never forgets/prunes.
- **`bkp-undo` tag**: pre-restore safety snapshots; excluded from the thin ladder, expire after 7 days, consumed by `undo`.
- **Workers no-op silently without `config.toml`** (the committed launchd agents must be harmless pre-onboarding); the dispatcher dies loudly instead.

**Consumes from:** system-services (Servicefile schema + `system-service sync`), secrets (`system-secrets get backup-repo` via `password_command`), shell (`common.zsh` stdlib), chezmoi (`chezmoi managed` filter), terminal-mux (`zellij action` for scrub sessions), external restic/git/hunk/fzf/yq/jq.

**Entry points:** `lib/backup.zsh` (top: thinning; middle: manifest/capture; tail: reconcile/UX), `bin/system-backup`, `docs/system-backup-recovery.md`, spec `docs/superpowers/specs/2026-07-03-terminal-time-machine-design.md` (gitignored working doc).

**Dispatch example:** *"Tune the retention ladder boundaries. You own silo **system-backup**: `lib/backup.zsh` + `bin/system-backup*` + `dot_config/backup/`. `bkp::thin` must stay pure/deterministic/idempotent (tests pin 48/24/4/2/7/8/12 emergent counts). Don't touch the Servicefile schema (system-services) — only the `backup-*` entries are yours. All restic calls go through `bkp::restic`; stub it, never touch a real repo or \$HOME."*

---

## shell — Shell (zsh) bootstrap & widgets

**Owner area:**
- `home/dot_config/zsh/` — `dot_zshrc` (rendered from `home/dot_zshrc`), `environment.sh`, `completion.sh`, `keybindings.sh`, `functions.d/`, `aliases.d/`
- `home/dot_zshrc`, `home/dot_zshenv`, `home/dot_p10k.zsh` (chezmoi top-level)
- `home/dot_local/lib/common.zsh` (stdlib — **shared, coordinate**), `prompt-common.zsh` (`prompt::*`), `platform.zsh` + `platform-{macos,linux}.zsh` (`platform::*`)

**Out of scope (shared-file hazards):**
- `home/dot_config/zsh/functions.d/widgets.sh` — contains both shell widgets (dir-ring, smart-space) **and** the ai-harnesses `ai-assist-trigger` widget. If both a shell agent and an ai-harnesses agent run, this file is a collision point → serialize or split.
- `home/dot_config/zsh/private_secrets.d/` — owned by secrets (shell owns the dir's sourcing plumbing in `dot_zshrc`).
- `common.zsh` — shared stdlib (utils coordination).

**Public contract (preserve):**
- **`environment.sh`** — the single source of truth for XDG vars, sourced by both `.zshenv` and the `my.environment.variables` LaunchAgent (`launchctl setenv` to GUI apps). The chezmoi `run_onchange_after_30-reload-environment-launchagent` hook re-boots that agent when `environment.sh`'s hash changes. Notable: `PIP_REQUIRE_VIRTUALENV=true`, static Homebrew PATH (no `brew shellenv` fork), `MISE_CARGO_HOME`/`RUSTUP_HOME`, `XDG_RUNTIME_DIR` auto-created for the `op` daemon.
- **`notify` primitive** in `common.zsh` — best-effort (returns non-zero quietly on missing `hs`); the `bin/notify` front-end (utils) wraps it with a hard error. Consumed on hot paths (terminal-mux `copy-pwd`). Icon/sound spec shape matches hammerspoon's `hs` globals.
- **`prompt::*`** (`prompt-common.zsh`) — `required`/`default`/`secret`/`choice`/`confirm`, read from `/dev/tty`. `prompt::secret` does masked entry via `-echo -icanon` + `read -rk 1`. Consumed by ai-harnesses (`cagent`), secrets (`sec`).
- **`platform::*`** — `launch_gui`/`raise_app`; macOS `open -a`+AppleScript, Linux detached exec + hyprctl/swaymsg/wmctrl/xdotool. Consumed by utils `tab-edit`.
- **ZLE widgets**: dir-navigation ring (`_dir_ring`), `smart-space-expansion`, `super-cd` (aliased to `cd`). Bound to raw CSI sequences (WezTerm/Ghostty Shift+arrows, Shift+Tab=undo, Option+/=redo).
- **Mux auto-attach** in `dot_zshrc` — tmux or Zellij per the `.muxBackend` knob, "Main" session reuse logic, over-SSH scrollback wipe to suppress pam_motd flash, quick-launch recency seeding (calls into terminal-mux).

**Consumes from:** terminal-mux (mux auto-attach, quick-launch recency seeding), pick (pick widget), preview (fzf wired to `preview`), utils (`notify`, `wait-until`), external z4h/p10k/zsh-defer/fzf/zoxide/atuin.

**Entry points:** `dot_zshrc`, `environment.sh`, `functions.d/widgets.sh`, `lib/common.zsh`, `lib/prompt-common.zsh`.

**Dispatch example:** *"Review zsh startup time. You own `dot_config/zsh/dot_zshrc` + `environment.sh` + `lib/{common,prompt-common,platform}.zsh`. The `notify` primitive and `environment.sh` XDG vars are public contracts (terminal-mux/ai-harnesses/secrets/utils consume them) — preserve signatures. `functions.d/widgets.sh` is shared with the ai-harnesses `ai-assist-trigger` — don't remove that widget. The `my.environment.variables` LaunchAgent (chezmoi) watches `environment.sh`'s hash; changing its content triggers a reload."*

---

## preview — File preview & terminal viewers

**Owner area:**
- `home/dot_local/bin/executable_preview` (15K), `libexec/executable_fzf-tab-preview-open`
- `home/dot_local/libexec/executable_ics-view`, `sqlite-view`, `disk-image-view` (Python stdlib)

**Out of scope:** `image-protocol-support.zsh` (terminal-mux — preview *sources* it read-only). Yazi's previewer *wiring* (yazi — yazi calls `preview`/the libexec viewers). fzf itself (external).

**Public contract (preserve):**
- **`preview` as the universal `--preview` backend** — invoked by fzf (`FZF_DEFAULT_OPTS`) and Yazi. Routing order: pre-guards (empty/dir/missing/zero-byte) → by-extension (`.ipynb` despite json MIME, csv/md/json/yaml/xml/ics/sqlite/archive/pdf) → by-MIME (image via chafa/Kitty graphics, audio/video via mediainfo, disk images) → binary hexdump → `bat`. Lives as a *script* (not a zsh function) so fzf's non-interactive preview subshell finds it via PATH.
- **`stamp-msg()`** figlet banners (custom `phm-minecraft.flf` font, true-footprint measurement, plain-text fallback).
- **libexec viewer contract**: stdin = file path, stdout = rendered card; rounded Unicode box-drawing, Catppuccin Mocha truecolor, Nerd Font icons. Consumed by `preview` and Yazi (yazi).

**Consumes from:** terminal-mux (`get_terminal_image_protocol()`), external bat/chafa/mediainfo/ouch/rich/hexyl/figlet.

**Entry points:** `bin/preview`, `libexec/{ics,sqlite,disk-image}-view`.

**Dispatch example:** *"Add a previewer for a new file type. You own `bin/preview` + `libexec/*-view`. Preserve the routing order and the libexec viewer contract (stdin path → stdout card, Catppuccin styling). `image-protocol-support.zsh` (terminal-mux) is read-only — call `get_terminal_image_protocol`, don't modify it."*

---

## yazi — Yazi

**Owner area:** `home/dot_config/yazi/` — `init.lua`, `yazi.toml`, `keymap.toml`, `plugins/{folder-rules,parent-arrow}.yazi/`.

**Out of scope:** the `mux-open` script (terminal-mux) that opens dirs in a Yazi tab. The `preview` backend + libexec viewers (preview). The `mactag`/`bypass`/`smart-switch`/`full-border`/`git` plugins (external Yazi plugins — only config here).

**Public contract (preserve):**
- **Previewer wiring** in `yazi.toml`/`init.lua` — prepend_previewers route to `ouch`/`mediainfo`/`rich`/the preview libexec viewers. The `preview` script (preview) is the backend.
- **`cd` event plugins** (`folder-rules`) — Downloads→mtime reverse, else alphabetical dirs-first.
- **`$NVIM` detection** — auto-toggles min-preview when nested under nvim (cooperates with neovim).
- **keymap contract** — `K`/`J` parent-arrow, `H`/`L` bypass, color-tag keys, `yazi-quick-look` on Ctrl+Space (Quick Look locally, floating zellij `preview` pane over SSH).

**Consumes from:** preview (preview + viewers), terminal-mux (mux-open), neovim (`$NVIM`), external Yazi plugins.

**Entry points:** `init.lua`, `yazi.toml`, `keymap.toml`, `plugins/`.

**Dispatch example:** *"Review Yazi preview performance. You own `dot_config/yazi/{init.lua,yazi.toml}`. The previewer routes to the `preview`/libexec viewers — those are read-only for you. Preserve the `$NVIM` min-preview toggle (cooperates with neovim)."*

---

## chezmoi — chezmoi orchestration & run-scripts

**Owner area:**
- `.setup.sh`, `Makefile`, `README.md`, `.chezmoiroot`, `.chezmoiignore.tmpl`, `.chezmoi.toml.tmpl`, `.chezmoidata/*.yaml`, `.shellspec`, `.gitattributes`, `.gitignore`
- `home/.chezmoiscripts/run_*` — **all** the numbered run-scripts
- `home/dot_config/zellij/zellij-plugin-path.tmpl` (shared resolver — also used by terminal-mux; coordinate)

**Out of scope:** the *logic* each run-script invokes belongs to its feature silo (custom-builds builds, secrets GPG/secrets, system snaps, terminal-mux zellij perms). chezmoi owns the **trigger mechanics**: the numeric ordering, the hash-baking into rendered comments (so `run_onchange` re-fires on source change), the `run_after` vs `run_once` vs `run_onchange` choice, and the interactive-prompt gating (TTY + not-CI + `CHEZMOI_NONINTERACTIVE`).

**Public contract (preserve):**
- **Numeric prefix ordering** (`run_*_after_NN-…`): chezmoi runs `after` scripts in alphabetical order, so the prefix fixes execution order. Current map (don't renumber without tracing deps): `05` op-daemon reaper (secrets), `08` ssh config.d Include (chezmoi; mirrors onboard's `reconcile_ssh`), `10` bootstrap-tools, `15` dev-shell tools, `20` system-settings, `25` GPG key (secrets), `30` env LaunchAgent reload, `34` sudo touchid, `35` open-in-neovim app (terminal-mux/neovim) + dev-shell sudo links, `36` tab-edit desktop (terminal-mux/utils), `40` snaps (system), `45` zellij plugin perms (terminal-mux), `50` custom zsh build (custom-builds), `60` symbols-db mark (custom-builds), `70` symbols-nerd-font mark (custom-builds), `80` symbols font/DB prompt (custom-builds), `90` dev-shell prune.
- **Hash-baking**: `run_onchange` scripts bake a SHA256 of their inputs (builder, donor glyphs, custom-SVG `code` pins, manifest content) into rendered comments so chezmoi re-runs on change. Editing a builder (custom-builds) without updating the baked hash logic breaks the trigger.
- **Open-in-NeoVim app generator** (`run_onchange_after_35`): builds the `.app` via `osacompile`, stamps `neovim-hicontrast.icns`, registers `CFBundleDocumentTypes`, and **queries nvim's filetype registry headlessly** (`vim.filetype.inspect().extension` + `mdls`) — this is a hard dependency on neovim's filetype map.
- **`.chezmoiignore.tmpl`** — the profile/os gating that makes dev-shell headless (excludes `hammerspoon`/`wezterm`/`ghostty`/`espanso` etc. on dev-shell).

**Consumes from:** every feature silo (the run-scripts trigger their builds/imports/permissions).

**Entry points:** `.setup.sh`, `home/.chezmoiscripts/`, `.chezmoiignore.tmpl`.

**Dispatch example:** *"Review the chezmoi run-script ordering for safety. You own `.chezmoiscripts/run_*` + `.chezmoiignore.tmpl`. The hash-baking in the `run_onchange` scripts is the trigger contract with custom-builds (custom builds) — if you change how hashes are computed, custom-builds's builders must still re-fire. The `run_after_35` open-in-neovim generator depends on neovim's `vim.filetype.inspect()` — preserve that headless query."*

---

## utils — Cross-cutting utilities

**Owner area:**
- `home/dot_local/bin/executable_notify` (front-end), `executable_wait-until` (standalone POSIX sh), `executable_chezmoi-reverse`, `libexec/executable_tab-edit`
- `home/dot_local/lib/common.zsh` (`notify` primitive, stdlib) — **shared with shell**
- `home/dot_local/lib/platform.zsh` + `platform-{macos,linux}.zsh` — **shared with shell**
- `home/dot_local/libexec/pinentry-auto` (libexec, reached by absolute path)

**Out of scope:** the `hs` CLI receivers (hammerspoon), the Zellij session resolver (terminal-mux) that `tab-edit` calls, the chezmoi apply machinery that `chezmoi-reverse` cooperates with.

**Public contract (preserve):**
- **`notify [--icon SPEC] [--sound NAME] [--ansi] MESSAGE...`** — SPEC = SVG name / `glyph:<nerd-font-name>` / `swatch:#RRGGBB`. The *primitive* in `common.zsh` is best-effort (silent on missing `hs`); the *bin* is a hard-error front-end. Serializes args as Lua string literals to `hs -c`. `gtimeout`-capped. Consumed on hot paths (terminal-mux `copy-pwd`).
- **`chezmoi-reverse [--no-merge] [--] <file>...`** — destination→source propagation. `--no-merge` emits `needs-merge` (per-file tabular status: `clean`/`applied`/`merged`/`needs-merge`/`skipped`/`failed`) instead of interactive `chezmoi merge`. Skips `encrypted_*`/`run_*`/`symlink_*`/`modify_*`. **Consumed by neovim's nvim autocmd** — the `needs-merge` exit semantics are the seam.
- **`tab-edit`** — opens files in nvim inside the focused Zellij session (resolves pane TTY → Zellij client → session via terminal-mux's `resolve_session`), falls back to bare WezTerm. Tab title + CWD=git root. Engine behind the chezmoi Finder droplet + Linux desktop handler.
- **`wait-until [--timeout 2s] [--interval 0.1] [--quiet] -- CMD...`** — standalone POSIX sh, polls before first sleep. Any caller can `exec` it.
- **`platform::*`** — see shell.

**Consumes from:** terminal-mux (`resolve_session` for `tab-edit`), hammerspoon (`hs` CLI for `notify`), custom-builds (symbols.db for `glyph:` icons), chezmoi (for `chezmoi-reverse`).

**Entry points:** `bin/notify`, `bin/chezmoi-reverse`, `libexec/tab-edit`, `lib/common.zsh`.

**Dispatch example:** *"Review `chezmoi-reverse` patch robustness. You own `bin/chezmoi-reverse`. Preserve the `--no-merge` → `needs-merge` status contract (neovim's nvim `BufReadPre` autocmd depends on it) and the skip list (`encrypted_*`/`run_*`/`symlink_*`/`modify_*`)."*

---

## pi — pi coding agent config

**Owner area (safe to edit):**
- `home/dot_pi/agent/` — `AGENTS.md` (cloud baseline), `README.md`, `lsp.json`, `modify_settings.json.tmpl`, `private_models.json.tmpl`, `agents/{Architect,Librarian,Reviewer}.md`, shared-skill adapters under `skills/`, `themes/catppuccin-mocha.json`, `extensions/pi-rtk-optimizer/config.json`, `extensions/symlink_pi-{cockpit,plannotator-bridge}.tmpl`
- `home/dot_pi/agent-local/` — `AGENTS.md` (local 32K-context variant), `agents/{Architect,Reviewer}.md`, `agents/symlink_Librarian.md.tmpl`, `modify_settings.json.tmpl`, `private_models.json.tmpl`, `symlink_{extensions,lsp.json,skills,themes}.tmpl`
- `home/dot_config/agent-skills/` — canonical harness-neutral skills shared with Pi, Cursor, and Claude Code
- `home/dot_claude/agents/reviewer.md` — Claude Code's harness-specific adapter for the shared `code-review` router
- `home/dot_pi/web-search.json`
- `home/.chezmoitemplates/pi-settings-merge.tmpl` (pi-specific FORCE/SEED/KEEP merge policy)
- **pi-specific content blocks in shared chezmoi files** (pi owns the pi content; chezmoi owns the machinery — ordering, `run_once`/`run_after` mechanics, hash-baking, `.chezmoi*` scaffolding): the `[data.pi.devExtensions]` block in `.chezmoi.toml.tmpl`, the pi-cockpit/pi-plannotator-bridge suppression blocks in `.chezmoiignore.tmpl`, the consumer-machine `pi install` blocks in `run_once_after_10-setup-bootstrap-tools.sh.tmpl`, and the `~/.pi/agent-local` prune block in `run_after_90-prune-dev-shell-state.sh.tmpl`.

**Out of scope:** the `pi-local` zsh function in `dot_config/zsh/functions.d/commands.sh` (shell) — pi owns the `agent-local` config it points at, not the function. The `ai-assist-pi`/`ai-commit-pi` wrappers (ai-harnesses) — they CALL the pi CLI; pi owns the CLI's config. The **chezmoi** silo owns the *machinery* of the shared files the pi blocks live in (run-script ordering/numbering, `run_once` vs `run_after` choice, hash-baking, `.chezmoi*.{tmpl,yaml}` scaffolding) — pi owns the pi *content* within those files; coordinate with chezmoi only when adding a brand-new run-script (needs an ordering number) or restructuring a shared file's skeleton. The pi CLI (npm `pi-coding-agent`) and the `pi-cockpit`/`pi-plannotator-bridge` source repos (external, outside this repo, referenced by symlink).

**Public contract (preserve):**
- **agent-local ↔ agent symlink sharing**: `agent-local/symlink_{extensions,lsp.json,skills,themes}.tmpl` → `~/.pi/agent/{extensions,lsp.json,skills,themes}` and `agent-local/agents/symlink_Librarian.md.tmpl` → `~/.pi/agent/agents/Librarian.md`. A change to a shared resource in `agent/` propagates to `agent-local/` (and `pi-local`). Do not duplicate a shared resource into `agent-local/` as a real file (would shadow the symlink).
- **`modify_settings.json.tmpl` declarative-keys merge**: the `modify_` script declaratively owns STRUCTURAL keys of `~/.pi/agent/settings.json` (theme, `extensions`/`skills`/`packages` lists, defaultProvider/model, thinking by profile, `npmCommand` via mise, observational-memory). Pi rewrites settings.json at runtime. The merge policy in `pi-settings-merge.tmpl`: FORCE (`extensions`,`skills`,`packages`,`npmCommand`,`observational-memory` — always from `$desired`), SEED (absent keys written once), KEEP (Pi-owned runtime toggles). Byte-identical result → emit ORIGINAL BYTES so chezmoi reports no diff. Do not move a key between FORCE and KEEP without understanding the consequence.
- **`.pi.devExtensions` dev-extension symlink resolution**: `agent/extensions/symlink_pi-{cockpit,plannotator-bridge}.tmpl` resolve from `.pi.devExtensions` (declared in the `[data.pi]` block of `.chezmoi.toml.tmpl`, pi-owned). Dev machine → value is a path → symlink to live working tree. Consumer machine → value empty → symlink suppressed by the pi-owned `.chezmoiignore.tmpl` block and the pi-owned `run_once_after_10` block runs `pi install git:…` instead. Adding/removing a dev extension touches FOUR places, all pi-owned: the `.chezmoi.toml.tmpl` data block, the `.chezmoiignore.tmpl` suppression, the `run_once_after_10` install block, and a `symlink_*.tmpl` under `dot_pi/agent/extensions/`. (Coordinate with chezmoi only for an ordering number if a brand-new run-script file is added.)
- **Profile gating**: `modify_settings.json.tmpl`/`private_models.json.tmpl` are profile-gated (`work`/`dev-shell`/personal) — preserve the guards.
- **`packages`/`extensions`/`skills` array pinning**: FORCE keys; changing them changes what pi loads on every machine.

**Consumes from:** ai-harnesses (`ai-assist-pi`/`ai-commit-pi` wrappers — read-only consumers), shell (the `pi-local` function — points at pi's config), chezmoi (the *machinery* of the shared files the pi blocks live in — pi owns the pi content, chezmoi owns the mechanics), external pi CLI + `pi-cockpit`/`pi-plannotator-bridge` repos.

**Entry points:** `dot_pi/agent/AGENTS.md`, `dot_pi/agent/modify_settings.json.tmpl`, `.chezmoitemplates/pi-settings-merge.tmpl`, `dot_pi/agent-local/AGENTS.md`.

**Dispatch example:** *"Tighten the pi settings-merge FORCE key set. You own `dot_pi/agent/modify_settings.json.tmpl` + `.chezmoitemplates/pi-settings-merge.tmpl`. Preserve the FORCE/SEED/KEEP policy and the byte-identical-emit invariant (chezmoi must report no diff when no forced key drifted). The `agent-local`↔`agent` symlinks mean a change to `agent/skills/` or `agent/extensions/` propagates to `pi-local` — understand the sharing before editing shared resources. Don't touch the `pi-local` function (shell) or the `ai-assist-pi` wrappers (ai-harnesses); the pi blocks in `.chezmoi.toml.tmpl`/`.chezmoiignore.tmpl`/`run_once_after_10` are yours — coordinate with chezmoi only if you add a brand-new run-script."*

---

## cursor — Cursor coding agent config

**Owner area (safe to edit):** `home/dot_cursor/` — `agents/{architect,librarian,reviewer}.md`, shared-skill adapters under `skills/`, and `rules/baseline.mdc`; `home/dot_config/agent-skills/` contains the canonical portable skill content.

**Out of scope:** the `ai-assist-cursor`/`ai-commit-cursor` wrappers (ai-harnesses) — they CALL cursor; cursor owns the agent's own config. The Cursor app/CLI (external).

**Public contract (preserve):**
- **MDC rule format**: `rules/baseline.mdc` uses Cursor's `.cursor/rules` MDC format — markdown body + YAML frontmatter (`description`, `alwaysApply: true`). `alwaysApply: true` injects the rule into every Cursor session's context. Preserve the frontmatter schema and the `alwaysApply` semantics.
- **agents/skills parallel structure**: `agents/{architect,librarian,reviewer}.md` mirrors `dot_pi/agent/`'s harness-specific subagent structure. Portable `skills/*/SKILL.md` files are symlinked from `~/.config/agent-skills/`, which is also exposed to Pi and Claude Code. Keep harness-specific tool/model metadata in each harness's agent definitions, not in shared skills.

**Consumes from:** ai-harnesses (`ai-assist-cursor`/`ai-commit-cursor` wrappers — read-only consumers), external Cursor app/CLI.

**Entry points:** `dot_cursor/rules/baseline.mdc`, `dot_cursor/agents/`, `dot_cursor/skills/`.

**Dispatch example:** *"Review the Cursor baseline rule for clarity. You own `dot_cursor/rules/baseline.mdc` + `dot_cursor/agents/` + `dot_cursor/skills/`. Preserve the MDC frontmatter (`description` + `alwaysApply: true`) — `alwaysApply` is what injects the rule into every session. Keep the agents/skills structure parallel to `dot_pi/agent/` (pi). Don't touch the `ai-assist-cursor` wrappers (ai-harnesses)."*

---

## Concurrency & collision matrix

Which silos can run agents **in parallel** without file collisions. `✓` = safe to
run concurrently; `⚠` = shared file, serialize or pre-agree ownership; `✗` = same
owner area, don't parallelize.

> **Matrix coverage.** The grid below predates `system-backup`, `clipboard`
> and `theme` and has not been extended to them — the cells are per-pair
> judgements about shared files, and inventing 50 of them would look like
> knowledge it isn't. What IS known about the newer silos: **clipboard**
> collides with terminal-mux (the `W` opcode, `pick-clipboard-zellij`),
> neovim (the provider), hammerspoon (the picker UI) and system-services
> (the agent plist); **theme** writes into terminal-mux's, yazi's, neovim's
> and preview's trees as *generated outputs*, so the collision is on the
> template, never the product; **system-backup** collides with terminal-mux
> on the scrub session's chrome. Treat those pairs as ⚠ and the rest as ✓
> until someone does the pairwise pass.

|  | terminal-mux | neovim | hammerspoon | pick | custom-builds | ai-harnesses | secrets | system | shell | preview | yazi | chezmoi | utils | pi | cursor |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| terminal-mux | — | ✓ | ✓ | ✓ | ⚠¹ | ✓ | ✓ | ⚠² | ⚠³ | ⚠⁴ | ⚠⁵ | ⚠⁶ | ⚠⁷ | ✓ | ✓ |
| neovim | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠⁸ | ⚠⁹ | ✓ | ✓ | ✓ |
| hammerspoon | ✓ | ✓ | — | ✓ | ⚠¹ | ✓ | ✓ | ✓ | ⚠⁷ | ✓ | ✓ | ✓ | ⚠⁷ | ✓ | ✓ |
| pick | ✓ | ✓ | ✓ | — | ⚠¹⁰ | ✓ | ✓ | ✓ | ⚠¹¹ | ✓ | ✓ | ✓ | ⚠¹¹ | ✓ | ✓ |
| custom-builds | ⚠¹ | ✓ | ⚠¹ | ⚠¹⁰ | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠⁶ | ✓ | ✓ | ✓ |
| ai-harnesses | ✓ | ✓ | ✓ | ✓ | ✓ | — | ✓ | ✓ | ⚠¹² | ✓ | ✓ | ✓ | ✓ | ✓¹⁵ | ✓¹⁵ |
| secrets | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | ✓ | ⚠¹³ | ✓ | ✓ | ⚠⁶ | ✓ | ✓ | ✓ |
| system | ⚠² | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | —¹⁴ | ✓ | ✓ | ✓ | ⚠⁶ | ✓ | ✓ | ✓ |
| shell | ⚠³ | ✓ | ⚠⁷ | ⚠¹¹ | ✓ | ⚠¹² | ⚠¹³ | ✓ | — | ✓ | ✓ | ⚠⁶ | ⚠¹¹ | ✓¹⁶ | ✓ |
| preview | ⚠⁴ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | ⚠⁸ | ✓ | ✓ | ✓ | ✓ |
| yazi | ⚠⁵ | ⚠⁸ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠⁸ | — | ✓ | ✓ | ✓ | ✓ |
| chezmoi | ⚠⁶ | ⚠⁹ | ✓ | ✓ | ⚠⁶ | ✓ | ⚠⁶ | ⚠⁶ | ⚠⁶ | ✓ | ✓ | — | ✓ | ⚠¹⁷ | ✓ |
| utils | ⚠⁷ | ✓ | ⚠⁷ | ⚠¹¹ | ✓ | ✓ | ✓ | ✓ | ⚠¹¹ | ✓ | ✓ | ✓ | — | ✓ | ✓ |
| pi | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹⁵ | ✓ | ✓ | ✓¹⁶ | ✓ | ✓ | ⚠¹⁷ | ✓ | — | ✓ |
| cursor | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹⁵ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |

**Footnotes (the shared files behind each `⚠`):**
1. **terminal-mux↔custom-builds**: built font family name + custom-icon `code` pins are custom-builds's output, terminal-mux's font chain references them. Safe if custom-builds preserves the contract; risky if either changes the pin set.
2. **clipboard↔system-services**: `services.toml.tmpl` owns the public TCP and trusted-local Unix listeners; clipboard owns their shared frame/opcode contract. Changes to endpoint trust or transport require both silos.
3. **terminal-mux↔shell**: mux auto-attach in `dot_zshrc` (shell) calls into terminal-mux's quick-launch recency seeding; `notify` (shell lib) is called by terminal-mux's `copy-pwd`. Different files, but the *call contract* must stay in sync.
4. **terminal-mux↔preview**: `image-protocol-support.zsh` is owned by terminal-mux, sourced read-only by preview. Safe if preview only *calls* `get_terminal_image_protocol`; collision if preview needs to edit it (→ hand back to terminal-mux).
5. **terminal-mux↔yazi**: `mux-open` (terminal-mux) opens dirs in a Yazi tab (yazi). Contract is the Yazi invocation; different files.
6. **chezmoi↔{terminal-mux,custom-builds,secrets,system,shell}**: the `.chezmoiscripts/run_*` triggers. Each run-script is a distinct file, so **per-file** parallelism is fine; the collision is only if two agents renumber/reorder the prefix sequence. Rule: chezmoi owns ordering; feature silos own the *content* of their own run-script.
7. **utils↔{terminal-mux,hammerspoon,shell}**: `common.zsh` (`notify` primitive) + `platform*.zsh` are shared. Any new shared primitive = serialize.
8. **neovim↔preview/yazi**: nvim's filetype registry is queried by chezmoi's app generator and nvim's `$NVIM` env is read by yazi. Contract-level, different files.
9. **chezmoi↔neovim**: the open-in-neovim generator headlessly queries `vim.filetype.inspect()`. neovim changing filetype mappings changes the generated UTI list — coordinate if both run.
10. **pick↔custom-builds**: the `symbols.db` schema. custom-builds owns the builder, pick owns the reader. Schema change = both must update. **This is the tightest cross-silo contract.**
11. **pick/utils↔shell**: `common.zsh` (stdlib). pick's `pick-common.zsh` and utils/shell all source it.
12. **ai-harnesses↔shell**: `functions.d/widgets.sh` contains both shell's dir-ring/smart-space widgets **and** the ai-harnesses `ai-assist-trigger` widget. **Same file — serialize ai-harnesses and shell, or split the file first.**
13. **secrets↔shell**: `private_secrets.d/` (secrets owns the slot fragments, shell owns the sourcing in `dot_zshrc`); `prompt-common.zsh` (shell owns, secrets sources).
14. **system internal**: system-packages/system-services/system-images/system-update share `system-package-common.zsh` (`pkg::*`). Parallel within system only if no agent edits `pkg::*`; otherwise serialize the lib edit.
15. **ai-harnesses↔pi/cursor**: the `ai-assist-pi`/`ai-commit-pi` (ai-harnesses) and `ai-assist-cursor`/`ai-commit-cursor` (ai-harnesses) wrappers CALL the pi/cursor CLIs whose config pi/cursor own. Disjoint files; the seam is conceptual (the CLI the wrapper invokes is configured by the agent-config silo). Safe to parallelize; preserve the `--probe` contract from the ai-harnesses side.
16. **shell↔pi**: the `pi-local` zsh function lives in `dot_config/zsh/functions.d/commands.sh` (shell) and points `PI_CODING_AGENT_DIR` at `~/.pi/agent-local` (pi's owner area). Disjoint files; pi owns the config the function targets, shell owns the function. Coordinate only if the function's env vars (`PI_CODING_AGENT_DIR`/`PI_CODING_AGENT_SESSION_DIR`) need to change.
17. **chezmoi↔pi**: pi-specific content blocks live inside shared chezmoi-orchestration files — the `[data.pi.devExtensions]` block in `.chezmoi.toml.tmpl`, the pi-cockpit/pi-plannotator-bridge suppression blocks in `.chezmoiignore.tmpl`, the consumer-machine `pi install` blocks in `run_once_after_10-setup-bootstrap-tools.sh.tmpl`, and the `~/.pi/agent-local` prune in `run_after_90-prune-dev-shell-state.sh.tmpl`. **pi owns these pi content blocks; chezmoi owns the chezmoi machinery** (run-script ordering/numbering, `run_once` vs `run_after` mechanics, hash-baking, `.chezmoi*.{tmpl,yaml}` scaffolding) — not the pi content. Per-block parallelism is fine; collision only if chezmoi restructures a shared file or renumbers run-scripts while pi edits its blocks. Adding a brand-new pi run-script = coordinate with chezmoi for the ordering number. (No chezmoi↔cursor hazard: `dot_cursor/` has no run-script or ignore gating — verified.)

## Dispatching cleanly — practical recipe

1. **One worktree per agent**: `git worktree add ../<silo>-work master`. Agents never share a worktree (chezmoi render + edits would interleave).
2. **Brief each agent with**: its silo name, owner-area file list, "out of scope" list, the public contract(s) to preserve, and what it consumes read-only. Pull the relevant section from this doc verbatim.
3. **For `⚠` pairs**: either serialize, or split the shared file first (e.g. move `ai-assist-trigger` out of `widgets.sh` into its own file before parallelizing ai-harnesses and shell).
4. **Verify after**: each agent's diff should be confined to its owner area + (at most) its own run-script in chezmoi. Run `make test` (ShellSpec) for any `lib/` change. A diff touching `common.zsh` or `services.toml.tmpl` from two agents = merge conflict — re-dispatch with the contract restated.
5. **The two examples you gave are clean to parallelize**: system-packages (system packages manager) and custom-builds (custom font build) share no owner files. The only `⚠` is custom-builds↔pick (symbols.db schema) — irrelevant unless the font agent also changes the DB schema. Safe to run concurrently.
