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
   `module::fn` = a library module (`pkg::*`, `sec::*`, `pick::*`, `zj::*`,
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

| # | Silo | Owner root | Library | Flagship contract |
|---|------|-----------|---------|-------------------|
| S1 | Terminal & mux integration | `dot_config/{wezterm,ghostty}/`, `dot_config/zellij/` | `lib/zellij.zsh`, `lib/image-protocol-support.zsh` | `zj::pick`, `resolve_session`, OSC-52 clipboard, workspace-rename side-channel |
| S2 | NeoVim config | `dot_config/nvim/` | (lua, none in `lib/`) | filetype registry (consumed by S12), chezmoi auto-apply (consumes S13) |
| S3 | Hammerspoon | `dot_config/hammerspoon/` | (lua, in-process) | `hs` CLI `notify`/`notifyAnsi` globals (consumed by S9/S1) |
| S4 | pick framework + symbols pickers | `dot_local/lib/pick-common.zsh`, `pick-symbols-common.zsh`, `libexec/pick-*` | `pick::*`, `pick_symbols::*` | `pick::start` wire format (consumed by S1/S5/S6) |
| S5 | Custom builds | `custom-builds/` | (shell/python builders) | `symbols.db` schema+path (consumed by S4/S3), patched font (consumed by S1/S3) |
| S6 | AI agent harnesses | `dot_local/bin/ai-assist*`, `ai-commit*` | `lib/{assist,commit}-agent-common.zsh` | `request.json` shape, harness `--probe` contract (consumed by S1 pane render) |
| S7 | Secrets & onboarding | `dot_local/bin/system-secrets`, `system-onboard` | `lib/system-secrets-common.zsh` | `sec::*` slot API, `.leak-patterns` audit, `secrets.yaml` manifest |
| S8 | System management | `dot_local/bin/system-{package,service,images,update}*` | `lib/system-package-common.zsh` | `pkg::restart_services_for` → `system-service restart-for` (S8 internal seam), `services.toml.tmpl` |
| S9 | Shell (zsh) bootstrap & widgets | `dot_config/zsh/`, `dot_zshrc`/`dot_zshenv`/`dot_p10k.zsh` | `lib/{common,prompt-common,platform}.zsh` | `environment.sh` (XDG source of truth), ZLE widgets, `notify` primitive |
| S10 | File preview & terminal viewers | `dot_local/bin/{preview,fzf-tab-preview-open}`, `libexec/{ics,sqlite,disk-image}-view` | (uses `image-protocol-support.zsh` from S1) | `preview` as fzf/Yazi `--preview` backend |
| S11 | Yazi | `dot_config/yazi/` | (lua plugins) | Yazi previewer contract (consumes S10), `cd` event plugins |
| S12 | chezmoi orchestration & run-scripts | `.setup.sh`, `.chezmoiscripts/`, `.chezmoi*.{tmpl,yaml}` | — | `run_onchange_*` ordering + hash-baking, `zellij-plugin-path.tmpl` shared resolver |
| S13 | Cross-cutting utilities | `dot_local/bin/{notify,wait-until,chezmoi-reverse,tab-edit}` | `lib/common.zsh` (`notify`), `lib/platform.zsh` | `notify` CLI, `chezmoi-reverse --no-merge`, `tab-edit` launcher |

> **S13 is a coordination silo** — its files are shared deps. Treat
> `common.zsh`, `notify`, `tab-edit`, `chezmoi-reverse` as read-mostly by
> other silos; changes here ripple. Where a "feature" feels like it spans S13
> and another silo, the other silo owns the *consumer* and S13 owns the
> *primitive*.

---

## S1 — Terminal & multiplexer integration

**Owner area (safe to edit):**
- `home/dot_config/wezterm/` (all lua)
- `home/dot_config/ghostty/config`
- `home/dot_config/zellij/config.kdl.tmpl`, `layouts/default.kdl.tmpl`, `quick-launch/`, `scripts/` (quick-launch, zellij-modal, zellij-open, pick-*-zellij, copy-pwd, edit-terminal-config, terminal-toggle-fullscreen, ensure-plugins, nested-session-check, lib/{config,command,dispatch,zellij-session}.zsh)
- `home/dot_local/lib/zellij.zsh` (`zj::*`), `home/dot_local/lib/image-protocol-support.zsh`
- Zellij chezmoiscripts in S12: `run_after_45-grant-zellij-plugin-permissions`, `run_onchange_after_40-install-snaps` (snap is S8's data, the hook wiring is shared — coordinate)

**Out of scope:** the custom wasm plugin *source* (`zj-hud`, `zj-promptjump`, `zj-context-keys`, `vim-navigator`) lives **outside** this repo in `~/Projects/apps/zellij/`. This silo owns only the KDL that *loads* them and the scripts they *invoke*. The patched font/Symbols DB are S5. nvim's SSH-paste consumer is S2. The `clipboard-bridge` launchd *service definition* lives in `services.toml.tmpl` (S8) — S1 owns the nvim→socket protocol, S8 owns the agent plist.

**Public contract (preserve):**
- `zj::pick` — drop-in for `pick::start` (S4). Same argv, floats in a Zellij pane when `$ZELLIJ` set, else inline. Consumed by `ai-assist`/`ai-commit` (S6) and `quick-launch-pick`.
- `resolve_session <client_pid>` / `zellij_wezterm_sessions` in `zellij/scripts/lib/zellij-session.zsh` — unix-socket session resolver. Consumed by `zellij-open`, `tab-edit` (S13), quick-launch.
- **OSC 52 clipboard protocol**: `copy_command` intentionally unset in `config.kdl.tmpl`; copy is origin-relative via re-emitted OSC 52. The SSH paste-back reads `~/.clipboard-bridge.sock` (served by S8's `clipboard-bridge` agent). nvim (S2) implements the client.
- **Workspace-rename side-channel**: `__TOGGLE_FULLSCREEN__` / `__QL_FOCUS__=<id>` workspace names drive WezTerm handlers. `terminal-toggle-fullscreen` (this silo) and quick-launch depend on these exact sentinel strings.
- **Fullscreen-state mirror file**: `~/.local/state/wezterm/fullscreen_state` (atomic write-on-change) — read by the zj-hud bar.
- `get_terminal_image_protocol()` in `image-protocol-support.zsh` — returns Kitty/iTerm2/Sixel capability list constrained through Zellij. Consumed by `preview` (S10).
- `zellij-plugin-path.tmpl` (in this dir, shared with S12) — resolves managed plugin `file:` paths; the permission-grant hook and `ensure-plugins` must agree with `config.kdl`'s loaded paths.

**Consumes from:** S4 (`pick::start`), S5 (patched font + symbols.db for glyph pickers), S9 (`environment.sh` XDG vars, `notify`), S13 (`notify`, `tab-edit`, `platform::`), S8 (`services.toml` clipboard-bridge agent), S12 (chezmoi hooks trigger plugin perms / snaps).

**Entry points to start an investigation:** `wezterm.lua`, `config.kdl.tmpl`, `zellij.zsh`, `zellij-session.zsh`, `scripts/lib/dispatch.zsh`.

**Dispatch example:** *"Review the Zellij quick-launch dispatcher for correctness/performance. You own S1's `dot_config/zellij/scripts/quick-launch*` and `lib/dispatch.zsh`. Preserve `zj::pick`/`resolve_session`/`@window:<id>` contracts. Don't touch the wasm plugin sources (outside repo) or `services.toml` (S8)."*

---

## S2 — NeoVim config

**Owner area:** `home/dot_config/nvim/` — `init.lua`, `lua/config/{options,autocmds,keymaps,lazy}.lua`, `lua/plugins/*.lua`, `lua/lualine/`, `lua/utils/*.lua`, `after/`, `local-plugins/smart-comment-wrap/`, `spell/`, `lazyvim.json`, `lazy-lock.json`, `dot_luarc.json`, `dot_editorconfig`.

**Out of scope:** the `chezmoi-reverse` binary (S13) — nvim *calls* it. The `clipboard-bridge` service (S8) and WezTerm paste path (S1) — nvim *consumes* them. The Finder droplet generator (S12) *queries* nvim's filetype registry headlessly but doesn't modify nvim.

**Public contract (preserve):**
- **Filetype registry**: `vim.filetype.add` patterns (`.json.tmpl`→`json.gotmpl`, etc.) and `vim.filetype.inspect().extension` — the S12 "Open in NeoVim" app generator queries this headlessly to build UTI lists. Adding/removing filetype mappings changes Finder's "Open With" coverage.
- **SSH clipboard client** (`options.lua`): `vim.g.clipboard` custom paste reads `~/.clipboard-bridge.sock` via `nc -U`; copy uses OSC 52. Gated to SSH. The socket path and the `nc -U` read protocol are the seam with S1/S8.
- **Chezmoi auto-apply** (`autocmds.lua`): `BufReadPre` redirect → `chezmoi-reverse --no-merge` (S13); `BufWritePost` debounced `chezmoi apply --force`. Depends on `chezmoi-reverse`'s `needs-merge` exit semantics (S13).
- **Harper shared dictionary**: `spell/en.utf-8.add` is chezmoi `create_`-prefixed (so apply never reverts). The `uv.new_fs_event` watcher + `workspace/didChangeConfiguration` ping to harper-ls.
- **gotmpl treesitter injection**: `after/queries/gotmpl/injections.scm` + custom `inject-inner-ft!` directive.
- **lualine `dynamic-fqn`** uses `lua/utils/path.lua`, also consumed by Snacks `yank_path`.

**Consumes from:** S13 (`chezmoi-reverse`), S1/S8 (clipboard-bridge socket, OSC 52 via WezTerm), S12 (chezmoi apply), external LazyVim/Mason/Harper.

**Entry points:** `lua/config/options.lua`, `lua/config/autocmds.lua`, `lua/plugins/`.

**Dispatch example:** *"Investigate the chezmoi auto-apply debounce in nvim. You own `dot_config/nvim/lua/config/autocmds.lua`. The seam is `chezmoi-reverse --no-merge` (S13, read-only for you) emitting `needs-merge`; preserve the `BufReadPre` redirect + 5s debounced `BufWritePost` apply + `VimLeavePre` flush contract."*

---

## S3 — Hammerspoon

**Owner area:** `home/dot_config/hammerspoon/` — `init.lua`, `modules/{keybindings,streamdeck,osd,system,audio,windows,apps,clipboard,bootstrap,lifecycle}/*.lua`, `Assets/`.

**Out of scope:** the `notify` *caller* in `common.zsh`/`bin/notify` (S9/S13) — Hammerspoon owns the *receiver* (`hs` CLI globals `notify`/`notifyAnsi`); S13 owns the *sender*. The symbols.db (S5) — Hammerspoon's OSD `glyph:` resolver *queries* it read-only. Stream Deck hardware/Elgato app. Raycast/Shottr/ColorSlurp/PixelSnap (external apps, only URL-scheme integration here).

**Public contract (preserve):**
- **`hs` CLI globals `notify` / `notifyAnsi`**: the OSD entry points invoked by `common.zsh`'s `notify` primitive (S9/S13) via `hs -c`. Arg shape: Lua string literals (env vars are invisible inside the running HS process — that's why `notify` serializes env to literals). Icon specs `glyph:<name>` (resolved via symbols.db query), `swatch:#RRGGBB`, SVG name. Sound names. This is the single most important S3 seam.
- **`optimistic_state`** generic (`modules/system/optimistic_state.lua`) — reused by controls + Stream Deck re-render-on-external-change.
- **keybinding tree shape** (`modules/keybindings/init.lua` `kb.setup{...}`) — numeric actions = macOS symbolic hotkeys managed via `system_shortcuts.lua` plist diffing.
- **media-key interception** (`lifecycle.lua` `systemDefined` eventtap) — routes SOUND/BRIGHTNESS to controls.

**Consumes from:** S5 (symbols.db for `glyph:` icons), S9/S13 (`notify` senders), external apps via URL schemes.

**Entry points:** `init.lua`, `modules/keybindings/`, `modules/streamdeck/`, `modules/osd/`.

**Dispatch example:** *"Review the Stream Deck+ engine for performance. You own `dot_config/hammerspoon/modules/streamdeck/`. Preserve the `hs` CLI `notify`/`notifyAnsi` global contract (S13 calls it) and the `onChange` callback that Stream Deck subscribes to from `modules/system/controls.lua` (same silo)."*

---

## S4 — pick framework + symbols pickers

**Owner area:**
- `home/dot_local/lib/pick-common.zsh` (`pick::*`), `pick.jq`
- `home/dot_local/lib/pick-symbols-common.zsh` (`pick_symbols::*`)
- `home/dot_local/libexec/executable_pick-list`, `pick-glyph`, `pick-gitmoji`

**Out of scope:** `zj::pick` (S1 — the Zellij floating adapter, but it's a thin drop-in that *calls* `pick-list`/`pick::start`). The Zellij modal adapters `pick-{glyph,gitmoji}-zellij` (S1). The symbols.db *builder* (S5). Consumers in S6 (`ai-assist`/`ai-commit` pickers) and S1 (`quick-launch-pick`).

**Public contract (preserve — load-bearing for ≥3 silos):**
- **`pick::start [flags] LINES_CACHE_OR_STDIN`** — the core entry. Flags include `--cache-usage` (recency), `--cache-state`/`--resume` (cursor restore), `--selector`/`--selector-shortcuts`/`--selector-nav`, `--key-background` (insert-without-dismiss FIFO broker), `--key-output <key>:<kind>:<field>`, `--multi[=SEP]`, `--copy-only`, `--on-items-picked <cmd>`, `--output`, `--name`. Also `pick::line`, `pick::run`, `pick::feed`, `pick::clipboard`, `pick::record`.
- **Wire format** (shared with `pick.jq`): each line `<visible>\x1f<tail[0]>\x1e<tail[1]>…`. US (`\x1f`) splits ANSI-colored visible display (fzf renders via `--with-nth=1`) from hidden plain-text tail; RS (`\x1e`) splits tail fields. Last tail field = raw glyph by convention (so ANSI never leaks to stdout). `pick.jq` defines canonical Catppuccin SGR sequences + `emit_line`.
- **Recency**: file-based for non-DB pickers (`--cache-usage`), SQLite `last_used` via `--on-items-picked` for DB pickers.
- **`PICK_INJECT_PANE` / `PICK_INJECT_ZELLIJ`** env — the `--key-background` FIFO broker injects into these.
- **`PICK_GLYPH_DB`** env (default `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`) — the DB path contract with S5.

**Consumes from:** S5 (symbols.db at `PICK_GLYPH_DB`), S9 (`common.zsh` stdlib), S1 (`zj::pick` adapter, `zellij-modal --capture` FIFO for floating pickers).

**Entry points:** `pick-common.zsh` (`pick::start` at line ~650), `pick.jq`, `pick-glyph`.

**Dispatch example:** *"Review the `pick::` engine for performance. You own `lib/pick-common.zsh` + `pick.jq` + `libexec/pick-list`. The wire format (`\x1f`/`\x1e`) and the `pick::start` flag set are a public contract consumed by S1 (quick-launch-pick, zj::pick) and S6 (ai-assist/ai-commit pickers) — preserve them. The symbols.db path (`PICK_GLYPH_DB`) is owned by S5; treat the DB as read-only."*

---

## S5 — Custom builds

**Owner area:**
- `custom-builds/nerd-fonts/` — `build-updated-font.sh` (~2740 lines), `recalibrate-fa.sh`, `custom-icons/*.{svg,metadata.json}`, `unicode-donor-glyphs.txt`, `symbols-db/build-symbols-db.py` (~46K) + `README.md`
- `custom-builds/zsh/` — `build-zsh.sh` + `README.md`
- The build-trigger chezmoiscripts in S12: `run_onchange_after_70-symbols-nerd-font`, `run_onchange_after_60-symbols-db`, `run_after_80-symbols-nerd-font-prompt`, `run_onchange_after_50-custom-build-zsh` (the *trigger logic* is S12; the *builder* is S5 — coordinate the hash-baked fingerprints)

**Out of scope:** the font *consumers* (S1 WezTerm/Ghostty font chains, S3 OSD glyph rendering) — they reference the built artifacts by path; S5 only owes them a stable artifact path + format. The pickers (S4) — they read the DB.

**Public contract (preserve):**
- **`symbols.db`** at `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db` — single flat `symbols` table, one row per symbol, faceted columns (primary shortcode by source priority `gitmoji>github>slack>emoticon`, `extra_shortcodes`, `source_keys`, `keywords`, `tags`, `last_used`). Schema is consumed read-only by S4 (`pick-glyph`/`pick-gitmoji`) and S3 (OSD `glyph:` resolver). **Schema changes require coordinating S4.**
- **Renderability probe**: `wezterm ls-fonts --text` oracle (drops `.notdef`), CoreText fallback; verdicts cached under `$XDG_CACHE_HOME/symbols-db/`. Re-running preserves `last_used`.
- **Patched font artifacts**: the Symbols Nerd Font (and the JetBrains-Mono NF for Blink) installed to the user font dir; the Blink CSS (embedded fonts + Noto OT-SVG). S1's WezTerm `font_with_fallback` chain and Ghostty `font-codepoint-map` reference these by family name; the custom-icons `code` pins in `metadata.json` must stay stable (S1/S3 glyph lookups depend on them).
- **Custom `zsh`** at `~/.local/opt/zsh` + symlink `~/.local/bin/zsh`, registered in `/etc/shells` + `chsh`. Built *without* `--enable-unicode9`. macOS work/personal only (template-gated).

**Consumes from:** S12 (chezmoi onchange triggers + the hash-baked fingerprints), upstream zsh/Font-Awesome/Nerd-Fonts patcher, `wezterm ls-fonts` (oracle).

**Entry points:** `custom-builds/nerd-fonts/build-updated-font.sh`, `symbols-db/build-symbols-db.py`, `custom-builds/zsh/build-zsh.sh`.

**Dispatch example (matches your stated need):** *"The custom Nerd Font build is too slow — investigate. You own `custom-builds/nerd-fonts/build-updated-font.sh` + `recalibrate-fa.sh` + `symbols-db/build-symbols-db.py`. The build is triggered by S12's `run_onchange_after_70`/`run_after_80` hooks (read-only for you — the trigger hashes live there). You must preserve the output contract: `symbols.db` schema+path (consumed read-only by S4 pickers and S3 OSD) and the patched font family name + custom-icon `code` pins (consumed by S1 font chains). Don't touch the consumers."*

---

## S6 — AI agent harnesses

**Owner area:**
- `home/dot_local/bin/executable_ai-assist`, `ai-assist-{claude,pi,cursor,test}`
- `home/dot_local/bin/executable_ai-commit`, `ai-commit-{claude,pi,cursor}`
- `home/dot_local/lib/assist-agent-common.zsh` (`assist::*`), `commit-agent-common.zsh` (`cagent::*`)
- `home/dot_local/libexec/ai-assist-{summon,popup,render,input,action-broker}` (the popup is a `zellij-modal --capture` adapter)
- The ZLE widget `ai-assist-trigger` in `home/dot_config/zsh/functions.d/widgets.sh` (shared file with S9 — coordinate) bound to `Ctrl+Shift+/` (kitty `CSI 47;6u`, delivered by S1's `zj-context-keys`)

**Out of scope:** the `zj::pick`/`pick::start` framework (S4) — harnesses *call* it for the harness picker. The Zellij docked-pane spawn (`assist::spawn_pane`) uses S1's `zellij action` API. Atuin and the LLM harness CLIs (claude/cursor/pi) are external.

**Public contract (preserve):**
- **Harness `--probe` contract**: each `ai-assist-*`/`ai-commit-*` worker answers `--probe` with a label iff its CLI is present. The dispatcher discovers workers by globbing `ai-assist-*`/`ai-commit-*` siblings and probing. Adding a harness = add a sibling respecting `--probe`.
- **`request.json` shape** (ai-assist): `{origin:{session,pane,cwd}, last_command, exit, scrollback, user_request, project:{root,branch}}` — consumed by `assist-agent-common.zsh` and the worker.
- **Commit plan JSON** (ai-commit): `{commits:[{files:[...], message}]}` — the worker writes it to a tempfile; `cagent::execute_plan` reads it. **The agent never runs git** — `cagent::*` owns all `git add`/`git commit -F`. Plan cache under `.git`; `--replan` forces refresh.
- **Session pin**: `$XDG_STATE_HOME/ai-assist/sessions/<session>/harness`.
- **Per-project KB**: `$XDG_DATA_HOME/ai-assist/projects/<sha1(root)>/knowledge.md`.

**Consumes from:** S4 (`zj::pick`/`pick::start` for harness + plan pickers), S1 (Zellij docked pane, `zellij-modal` for popup), S9 (`prompt::confirm`, `common.zsh`), S13 (`notify`), external Atuin + LLM CLIs.

**Entry points:** `assist-agent-common.zsh`, `commit-agent-common.zsh`, `bin/ai-assist`, `bin/ai-commit`.

**Dispatch example:** *"Review the `ai-commit` plan-cache + stage/commit loop for robustness. You own `lib/commit-agent-common.zsh` + `bin/ai-commit*`. Preserve the `{commits:[{files,message}]}` plan JSON shape and the 'agent plans, script owns all git' invariant. You consume `zj::pick` (S4) and `prompt::confirm` (S9) — read-only. Don't touch the ZLE widget file (shared with S9)."*

---

## S7 — Secrets & onboarding

**Owner area:**
- `home/dot_local/bin/executable_system-secrets`, `executable_system-onboard`
- `home/dot_local/lib/system-secrets-common.zsh` (`sec::*`, 24K — also sources `prompt-common.zsh`)
- `home/dot_config/zsh/private_secrets.d/private_slot-*.sh.tmpl`
- `home/.chezmoidata/secrets.yaml` (manifest of env-var NAMES + prompts + `requiredFor` profiles — no values)
- `secrets/<slot>.sops.sh` (outside the chezmoi source root), `.sops.yaml`, `.leak-patterns`
- GPG chezmoiscript `run_after_25-setup-gpg-key.sh.tmpl` + the op-daemon reaper `run_before_05-reap-stale-op-daemon.sh.tmpl` (trigger wiring is S12; the *logic* is S7)

**Out of scope:** the 1Password CLI / SOPS / age tools (external). The `op-cache-v1` content-hash cache is S7-internal. The operator map `~/.config/chezmoi/onboard-map.yaml` is loose/unmanaged (not in repo).

**Public contract (preserve):**
- **Opaque slot IDs** `slot-<6hex>` — never alias/hostname/username in committed artifacts. The committed manifest `secrets.yaml` carries NO values, only declarations. This leak-safety boundary is the core invariant.
- **Two materialization paths**: human = `op read "op://..."` in chezmoi templates (cached via `op-cache-v1` content hash, refresh on `CHEZMOI_REFRESH_SECRETS=1`); headless = SOPS+age blobs decrypted to 0600 files. Over SSH, `op` switches to a loose service-account token.
- **`sec::leak_audit`** runs on every commit path against `.leak-patterns` — the leak-patterns file is part of the contract.
- **GPG import** (`run_after_25`): keys as 1Password **Private** vault docs; `env -u OP_SERVICE_ACCOUNT_TOKEN` forces account mode; defers (exit 0, `run_after` not `run_once`) when no tty; completion marker keyed on `expected_key_spec` + keyring stat hash.

**Consumes from:** S9 (`prompt-common.zsh` for prompts, `common.zsh`), S12 (chezmoi template `op read` resolution, run-script ordering), external `op`/SOPS/age.

**Entry points:** `system-secrets-common.zsh`, `bin/system-onboard`, `secrets.yaml`, `.leak-patterns`.

**Dispatch example:** *"Review the secrets leak-audit coverage. You own `lib/system-secrets-common.zsh` + `.leak-patterns` + `bin/system-secrets`. Preserve the opaque-slot-id invariant and the `op-cache-v1` cache semantics. The GPG import hook (`run_after_25`) and op-daemon reaper are yours but live in S12's `.chezmoiscripts/` — coordinate if you touch trigger hashes."*

---

## S8 — System management

**Owner area:**
- `home/dot_local/bin/executable_system-package`, `system-package-{brew,cargo,go,npm,snap,uv}`
- `home/dot_local/bin/executable_system-service`, `system-service-{launchd,brew}`
- `home/dot_local/bin/executable_system-images`, `executable_system-update`
- `home/dot_local/lib/system-package-common.zsh` (`pkg::*` — also backs `system-service` and `system-images` per `bin/README.md`)
- `home/dot_config/packages/{Brewfile,Brewfile.bootstrap,Cargofile,Gofile,Npmfile,Snapfile,Uvfile}.tmpl`, `services.toml.tmpl`, `images.toml.example`

**Sub-silos (independently dispatchable, shared `pkg::*` lib):**
- **S8a packages** — `system-package*` + `pkg::*` + `*file.tmpl` (not `services.toml`/`images.toml`)
- **S8b services** — `system-service*` + `services.toml.tmpl`
- **S8c images** — `system-images` + `images.toml.example`
- **S8d update orchestrator** — `system-update` (orchestrates S8a/S8b + external brew/mise/yazi/nvim/pi)

**Out of scope:** the package ecosystems themselves (brew/cargo/go/npm/snap/uv — external). The services *declared* in `services.toml.tmpl` that belong to other silos: `clipboard-bridge` (S1 protocol, S8 owns the plist), `images-automount` (S8c consumer), `llama-swap`/`local-llm-gateway`/`headroom` (local-LLM stack — treat as S8-internal or split out if an agent will work the LLM gateway; the gateway *binary* is `libexec/local-llm-gateway`, see S13/libexec). mise-managed runtimes are external (mise), but `system-package-brew` guards them.

**Public contract (preserve):**
- **`pkg::restart_services_for <pkg>...`** → calls `system-service restart-for "$@"` (S8 internal seam between S8a and S8b). `pkg::restart_changed <before> <after>` diffs version snapshots and restarts only changed. **This is the seam your "system packages manager" agent must preserve** — `system-service restart-for` maps a package name to services (launchd by key or `cmd[0]` basename, brew by name) and restarts **only if currently running**.
- **Manifest grammar** (`pkg::manifest_read`): comment-stripping, canonical-name tokenizer (`${(z)}`), `<name> -- <spec>` alternate install form for git/local. Shared across all 6 ecosystem workers.
- **`list [-u|--update] [-a|--all]` TSV rows** + `sync` (install declared / uninstall extras, strict where safe). Brew worker merges `Brewfile.bootstrap`+`Brewfile`, guards mise-owned runtimes (`^(go|python|node|...)@?`), tracks taps. Snap worker intentionally does **not** remove undeclared (snapd auto-installs base/platform snaps).
- **`services.toml.tmpl`** schema: TOML sections → launchd user agents rendered to plists (`yq`/`jq`), `~`-expansion + `command -v` resolution of `cmd[0]`, working/log dirs auto-created, bootstrapped into `gui/$(id -u)`. OS-aware cache dir (Library/Caches on macOS, `~/.cache` elsewhere).
- **`system-update`** ordering invariants: `git fetch`+ff-only (no rebase) → `chezmoi apply` → **self re-exec** if source advanced (`SYSTEM_UPDATE_REEXECED`) → `brew update` → `mise install/upgrade/prune` **before** `system-package sync` (so npm globals don't orphan on a node upgrade) → `system-package sync` → `brew cleanup` → `pinentry-touchid -fix` (SSH-skipped) → `system-service sync` → `ya pkg upgrade` → yazi lockfile commit/push (copies `package.toml` into chezmoi source, not `chezmoi re-add`, to avoid the apply lock when invoked from chezmoi's own `run_once`) → `Lazy! sync`/`MasonToolsUpdateSync` → `pi update --extensions` → git-pull zsh plugins. Detects `CHEZMOI=1` re-entrancy.

**Consumes from:** S12 (Snapfile onchange hook `run_onchange_after_40`), S9 (`common.zsh`), external brew/cargo/go/npm/snap/uv/mise.

**Entry points:** `system-package-common.zsh`, `bin/system-package`, `bin/system-service-launchd`, `bin/system-update`, `packages/services.toml.tmpl`.

**Dispatch example (matches your stated need):** *"Review the system-packages manager for performance improvements. You own silo **S8a**: `bin/system-package*` + `lib/system-package-common.zsh` + `packages/{Brewfile,Cargofile,Gofile,Npmfile,Snapfile,Uvfile}.tmpl`. Don't touch `services.toml.tmpl` (S8b) or `system-update` (S8d). The cross-seam contract you must preserve is `pkg::restart_services_for` → `system-service restart-for` (S8b owns the receiver) and the manifest grammar (`<name> -- <spec>`, comment-stripping). Each worker's `list -u` fans out parallel outdated-checks to registries — start there."*

---

## S9 — Shell (zsh) bootstrap & widgets

**Owner area:**
- `home/dot_config/zsh/` — `dot_zshrc` (rendered from `home/dot_zshrc`), `environment.sh`, `completion.sh`, `keybindings.sh`, `functions.d/`, `aliases.d/`
- `home/dot_zshrc`, `home/dot_zshenv`, `home/dot_p10k.zsh` (chezmoi top-level)
- `home/dot_local/lib/common.zsh` (stdlib — **shared, coordinate**), `prompt-common.zsh` (`prompt::*`), `platform.zsh` + `platform-{macos,linux}.zsh` (`platform::*`)

**Out of scope (shared-file hazards):**
- `home/dot_config/zsh/functions.d/widgets.sh` — contains both S9 widgets (dir-ring, smart-space) **and** S6's `ai-assist-trigger` widget. If both an S9 agent and an S6 agent run, this file is a collision point → serialize or split.
- `home/dot_config/zsh/private_secrets.d/` — owned by S7 (S9 owns the dir's sourcing plumbing in `dot_zshrc`).
- `common.zsh` — shared stdlib (S13 coordination).

**Public contract (preserve):**
- **`environment.sh`** — the single source of truth for XDG vars, sourced by both `.zshenv` and the `my.environment.variables` LaunchAgent (`launchctl setenv` to GUI apps). The S12 `run_onchange_after_30-reload-environment-launchagent` hook re-boots that agent when `environment.sh`'s hash changes. Notable: `PIP_REQUIRE_VIRTUALENV=true`, static Homebrew PATH (no `brew shellenv` fork), `MISE_CARGO_HOME`/`RUSTUP_HOME`, `XDG_RUNTIME_DIR` auto-created for the `op` daemon.
- **`notify` primitive** in `common.zsh` — best-effort (returns non-zero quietly on missing `hs`); the `bin/notify` front-end (S13) wraps it with a hard error. Consumed on hot paths (S1 `copy-pwd`). Icon/sound spec shape matches S3's `hs` globals.
- **`prompt::*`** (`prompt-common.zsh`) — `required`/`default`/`secret`/`choice`/`confirm`, read from `/dev/tty`. `prompt::secret` does masked entry via `-echo -icanon` + `read -rk 1`. Consumed by S6 (`cagent`), S7 (`sec`).
- **`platform::*`** — `launch_gui`/`raise_app`; macOS `open -a`+AppleScript, Linux detached exec + hyprctl/swaymsg/wmctrl/xdotool. Consumed by S13 `tab-edit`.
- **ZLE widgets**: dir-navigation ring (`_dir_ring`), `smart-space-expansion`, `super-cd` (aliased to `cd`). Bound to raw CSI sequences (WezTerm/Ghostty Shift+arrows, Shift+Tab=undo, Option+/=redo).
- **Zellij auto-attach** in `dot_zshrc` — "Main" session reuse logic, over-SSH scrollback wipe to suppress pam_motd flash, quick-launch recency seeding (calls into S1).

**Consumes from:** S1 (Zellij auto-attach, quick-launch recency seeding), S4 (pick widget), S10 (fzf wired to `preview`), S13 (`notify`, `wait-until`), external z4h/p10k/zsh-defer/fzf/zoxide/atuin.

**Entry points:** `dot_zshrc`, `environment.sh`, `functions.d/widgets.sh`, `lib/common.zsh`, `lib/prompt-common.zsh`.

**Dispatch example:** *"Review zsh startup time. You own `dot_config/zsh/dot_zshrc` + `environment.sh` + `lib/{common,prompt-common,platform}.zsh`. The `notify` primitive and `environment.sh` XDG vars are public contracts (S1/S6/S7/S13 consume them) — preserve signatures. `functions.d/widgets.sh` is shared with S6's `ai-assist-trigger` — don't remove that widget. The `my.environment.variables` LaunchAgent (S12) watches `environment.sh`'s hash; changing its content triggers a reload."*

---

## S10 — File preview & terminal viewers

**Owner area:**
- `home/dot_local/bin/executable_preview` (15K), `executable_fzf-tab-preview-open`
- `home/dot_local/libexec/executable_ics-view`, `sqlite-view`, `disk-image-view` (Python stdlib)

**Out of scope:** `image-protocol-support.zsh` (S1 — S10 *sources* it read-only). Yazi's previewer *wiring* (S11 — S11 calls `preview`/the libexec viewers). fzf itself (external).

**Public contract (preserve):**
- **`preview` as the universal `--preview` backend** — invoked by fzf (`FZF_DEFAULT_OPTS`) and Yazi. Routing order: pre-guards (empty/dir/missing/zero-byte) → by-extension (`.ipynb` despite json MIME, csv/md/json/yaml/xml/ics/sqlite/archive/pdf) → by-MIME (image via chafa/Kitty graphics, audio/video via mediainfo, disk images) → binary hexdump → `bat`. Lives as a *script* (not a zsh function) so fzf's non-interactive preview subshell finds it via PATH.
- **`stamp-msg()`** figlet banners (custom `phm-minecraft.flf` font, true-footprint measurement, plain-text fallback).
- **libexec viewer contract**: stdin = file path, stdout = rendered card; rounded Unicode box-drawing, Catppuccin Mocha truecolor, Nerd Font icons. Consumed by `preview` and Yazi (S11).

**Consumes from:** S1 (`get_terminal_image_protocol()`), external bat/chafa/mediainfo/ouch/rich/hexyl/figlet.

**Entry points:** `bin/preview`, `libexec/{ics,sqlite,disk-image}-view`.

**Dispatch example:** *"Add a previewer for a new file type. You own `bin/preview` + `libexec/*-view`. Preserve the routing order and the libexec viewer contract (stdin path → stdout card, Catppuccin styling). `image-protocol-support.zsh` (S1) is read-only — call `get_terminal_image_protocol`, don't modify it."*

---

## S11 — Yazi

**Owner area:** `home/dot_config/yazi/` — `init.lua`, `yazi.toml`, `keymap.toml`, `plugins/{folder-rules,parent-arrow}.yazi/`.

**Out of scope:** the `zellij-open` script (S1) that opens dirs in a Yazi tab. The `preview` backend + libexec viewers (S10). The `mactag`/`bypass`/`smart-switch`/`full-border`/`git` plugins (external Yazi plugins — only config here).

**Public contract (preserve):**
- **Previewer wiring** in `yazi.toml`/`init.lua` — prepend_previewers route to `ouch`/`mediainfo`/`rich`/the S10 libexec viewers. The `preview` script (S10) is the backend.
- **`cd` event plugins** (`folder-rules`) — Downloads→mtime reverse, else alphabetical dirs-first.
- **`$NVIM` detection** — auto-toggles min-preview when nested under nvim (cooperates with S2).
- **keymap contract** — `K`/`J` parent-arrow, `H`/`L` bypass, color-tag keys, `qlmanage -p` on Ctrl+Space.

**Consumes from:** S10 (preview + viewers), S1 (zellij-open), S2 (`$NVIM`), external Yazi plugins.

**Entry points:** `init.lua`, `yazi.toml`, `keymap.toml`, `plugins/`.

**Dispatch example:** *"Review Yazi preview performance. You own `dot_config/yazi/{init.lua,yazi.toml}`. The previewer routes to S10's `preview`/libexec viewers — those are read-only for you. Preserve the `$NVIM` min-preview toggle (cooperates with S2)."*

---

## S12 — chezmoi orchestration & run-scripts

**Owner area:**
- `.setup.sh`, `Makefile`, `README.md`, `.chezmoiroot`, `.chezmoiignore.tmpl`, `.chezmoi.toml.tmpl`, `.chezmoidata/*.yaml`, `.shellspec`, `.gitattributes`, `.gitignore`
- `home/.chezmoiscripts/run_*` — **all** the numbered run-scripts
- `home/dot_config/zellij/zellij-plugin-path.tmpl` (shared resolver — also used by S1; coordinate)

**Out of scope:** the *logic* each run-script invokes belongs to its feature silo (S5 builds, S7 GPG/secrets, S8 snaps, S1 zellij perms). S12 owns the **trigger mechanics**: the numeric ordering, the hash-baking into rendered comments (so `run_onchange` re-fires on source change), the `run_after` vs `run_once` vs `run_onchange` choice, and the interactive-prompt gating (TTY + not-CI + `CHEZMOI_NONINTERACTIVE`).

**Public contract (preserve):**
- **Numeric prefix ordering** (`run_*_after_NN-…`): chezmoi runs `after` scripts in alphabetical order, so the prefix fixes execution order. Current map (don't renumber without tracing deps): `05` op-daemon reaper (S7), `10` bootstrap-tools, `15` dev-shell tools, `20` system-settings, `25` GPG key (S7), `30` env LaunchAgent reload, `34` sudo touchid, `35` open-in-neovim app (S1/S2) + dev-shell sudo links, `36` tab-edit desktop (S1/S13), `40` snaps (S8), `45` zellij plugin perms (S1), `50` custom zsh build (S5), `60` symbols-db mark (S5), `70` symbols-nerd-font mark (S5), `80` symbols font/DB prompt (S5), `90` dev-shell prune.
- **Hash-baking**: `run_onchange` scripts bake a SHA256 of their inputs (builder, donor glyphs, custom-SVG `code` pins, manifest content) into rendered comments so chezmoi re-runs on change. Editing a builder (S5) without updating the baked hash logic breaks the trigger.
- **Open-in-NeoVim app generator** (`run_onchange_after_35`): builds the `.app` via `osacompile`, stamps `neovim-hicontrast.icns`, registers `CFBundleDocumentTypes`, and **queries nvim's filetype registry headlessly** (`vim.filetype.inspect().extension` + `mdls`) — this is a hard dependency on S2's filetype map.
- **`.chezmoiignore.tmpl`** — the profile/os gating that makes dev-shell headless (excludes `hammerspoon`/`wezterm`/`ghostty`/`espanso`/`llama-swap` etc. on dev-shell).

**Consumes from:** every feature silo (the run-scripts trigger their builds/imports/permissions).

**Entry points:** `.setup.sh`, `home/.chezmoiscripts/`, `.chezmoiignore.tmpl`.

**Dispatch example:** *"Review the chezmoi run-script ordering for safety. You own `.chezmoiscripts/run_*` + `.chezmoiignore.tmpl`. The hash-baking in the `run_onchange` scripts is the trigger contract with S5 (custom builds) — if you change how hashes are computed, S5's builders must still re-fire. The `run_after_35` open-in-neovim generator depends on S2's `vim.filetype.inspect()` — preserve that headless query."*

---

## S13 — Cross-cutting utilities

**Owner area:**
- `home/dot_local/bin/executable_notify` (front-end), `executable_wait-until` (standalone POSIX sh), `executable_chezmoi-reverse`, `executable_tab-edit`
- `home/dot_local/lib/common.zsh` (`notify` primitive, stdlib) — **shared with S9**
- `home/dot_local/lib/platform.zsh` + `platform-{macos,linux}.zsh` — **shared with S9**
- `home/dot_local/libexec/local-llm-gateway`, `local-llm-bench`, `pinentry-auto` (libexec, reached by absolute path)

**Out of scope:** the `hs` CLI receivers (S3), the Zellij session resolver (S1) that `tab-edit` calls, the chezmoi apply machinery (S12) that `chezmoi-reverse` cooperates with.

**Public contract (preserve):**
- **`notify [--icon SPEC] [--sound NAME] [--ansi] MESSAGE...`** — SPEC = SVG name / `glyph:<nerd-font-name>` / `swatch:#RRGGBB`. The *primitive* in `common.zsh` is best-effort (silent on missing `hs`); the *bin* is a hard-error front-end. Serializes args as Lua string literals to `hs -c`. `gtimeout`-capped. Consumed on hot paths (S1 `copy-pwd`).
- **`chezmoi-reverse [--no-merge] [--] <file>...`** — destination→source propagation. `--no-merge` emits `needs-merge` (per-file tabular status: `clean`/`applied`/`merged`/`needs-merge`/`skipped`/`failed`) instead of interactive `chezmoi merge`. Skips `encrypted_*`/`run_*`/`symlink_*`/`modify_*`. **Consumed by S2's nvim autocmd** — the `needs-merge` exit semantics are the seam.
- **`tab-edit`** — opens files in nvim inside the focused Zellij session (resolves pane TTY → Zellij client → session via S1's `resolve_session`), falls back to bare WezTerm. Tab title + CWD=git root. Engine behind the S12 Finder droplet + Linux desktop handler.
- **`wait-until [--timeout 2s] [--interval 0.1] [--quiet] -- CMD...`** — standalone POSIX sh, polls before first sleep. Any caller can `exec` it.
- **`platform::*`** — see S9.

**Consumes from:** S1 (`resolve_session` for `tab-edit`), S3 (`hs` CLI for `notify`), S5 (symbols.db for `glyph:` icons), chezmoi (for `chezmoi-reverse`).

**Entry points:** `bin/notify`, `bin/chezmoi-reverse`, `bin/tab-edit`, `lib/common.zsh`.

**Dispatch example:** *"Review `chezmoi-reverse` patch robustness. You own `bin/chezmoi-reverse`. Preserve the `--no-merge` → `needs-merge` status contract (S2's nvim `BufReadPre` autocmd depends on it) and the skip list (`encrypted_*`/`run_*`/`symlink_*`/`modify_*`)."*

---

## Concurrency & collision matrix

Which silos can run agents **in parallel** without file collisions. `✓` = safe to
run concurrently; `⚠` = shared file, serialize or pre-agree ownership; `✗` = same
owner area, don't parallelize.

|  | S1 | S2 | S3 | S4 | S5 | S6 | S7 | S8 | S9 | S10 | S11 | S12 | S13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| S1 | — | ✓ | ✓ | ✓ | ⚠¹ | ✓ | ✓ | ⚠² | ⚠³ | ⚠⁴ | ⚠⁵ | ⚠⁶ | ⚠⁷ |
| S2 | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠⁸ | ⚠⁹ | ✓ |
| S3 | ✓ | ✓ | — | ✓ | ⚠¹ | ✓ | ✓ | ✓ | ⚠⁷ | ✓ | ✓ | ✓ | ⚠⁷ |
| S4 | ✓ | ✓ | ✓ | — | ⚠¹⁰ | ✓ | ✓ | ✓ | ⚠¹¹ | ✓ | ✓ | ✓ | ⚠¹¹ |
| S5 | ⚠¹ | ✓ | ⚠¹ | ⚠¹⁰ | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠⁶ | ✓ |
| S6 | ✓ | ✓ | ✓ | ✓ | ✓ | — | ✓ | ✓ | ⚠¹² | ✓ | ✓ | ✓ | ✓ |
| S7 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | ✓ | ⚠¹³ | ✓ | ✓ | ⚠⁶ | ✓ |
| S8 | ⚠² | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | —¹⁴ | ✓ | ✓ | ✓ | ⚠⁶ | ✓ |
| S9 | ⚠³ | ✓ | ⚠⁷ | ⚠¹¹ | ✓ | ⚠¹² | ⚠¹³ | ✓ | — | ✓ | ✓ | ⚠⁶ | ⚠¹¹ |
| S10 | ⚠⁴ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | ⚠⁸ | ✓ | ✓ |
| S11 | ⚠⁵ | ⚠⁸ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠⁸ | — | ✓ | ✓ |
| S12 | ⚠⁶ | ⚠⁹ | ✓ | ✓ | ⚠⁶ | ✓ | ⚠⁶ | ⚠⁶ | ⚠⁶ | ✓ | ✓ | — | ✓ |
| S13 | ⚠⁷ | ✓ | ⚠⁷ | ⚠¹¹ | ✓ | ✓ | ✓ | ✓ | ⚠¹¹ | ✓ | ✓ | ✓ | — |

**Footnotes (the shared files behind each `⚠`):**
1. **S1↔S5**: built font family name + custom-icon `code` pins are S5's output, S1's font chain references them. Safe if S5 preserves the contract; risky if either changes the pin set.
2. **S1↔S8**: `services.toml.tmpl` `clipboard-bridge` section — S8 owns the file, S1 owns the socket protocol the nvim client (S2) uses. Pre-agree: S8 edits the plist fields, S1 edits the `~/.clipboard-bridge.sock` protocol; both touching `[clipboard-bridge]` = collision.
3. **S1↔S9**: Zellij auto-attach in `dot_zshrc` (S9) calls into S1's quick-launch recency seeding; `notify` (S9 lib) is called by S1's `copy-pwd`. Different files, but the *call contract* must stay in sync.
4. **S1↔S10**: `image-protocol-support.zsh` is owned by S1, sourced read-only by S10. Safe if S10 only *calls* `get_terminal_image_protocol`; collision if S10 needs to edit it (→ hand back to S1).
5. **S1↔S11**: `zellij-open` (S1) opens dirs in a Yazi tab (S11). Contract is the Yazi invocation; different files.
6. **S12↔{S1,S5,S7,S8,S9}**: the `.chezmoiscripts/run_*` triggers. Each run-script is a distinct file, so **per-file** parallelism is fine; the collision is only if two agents renumber/reorder the prefix sequence. Rule: S12 owns ordering; feature silos own the *content* of their own run-script.
7. **S13↔{S1,S3,S9}**: `common.zsh` (`notify` primitive) + `platform*.zsh` are shared. Any new shared primitive = serialize.
8. **S2↔S10/S11**: nvim's filetype registry (S2) is queried by S12's app generator and nvim's `$NVIM` env is read by S11. Contract-level, different files.
9. **S12↔S2**: the open-in-neovim generator headlessly queries `vim.filetype.inspect()`. S2 changing filetype mappings changes the generated UTI list — coordinate if both run.
10. **S4↔S5**: the `symbols.db` schema. S5 owns the builder, S4 owns the reader. Schema change = both must update. **This is the tightest cross-silo contract.**
11. **S4/S13↔S9**: `common.zsh` (stdlib). S4's `pick-common.zsh` and S13/S9 all source it.
12. **S6↔S9**: `functions.d/widgets.sh` contains both S9's dir-ring/smart-space widgets **and** S6's `ai-assist-trigger` widget. **Same file — serialize S6 and S9, or split the file first.**
13. **S7↔S9**: `private_secrets.d/` (S7 owns the slot fragments, S9 owns the sourcing in `dot_zshrc`); `prompt-common.zsh` (S9 owns, S7 sources).
14. **S8 internal**: S8a/S8b/S8c/S8d share `system-package-common.zsh` (`pkg::*`). Parallel within S8 only if no agent edits `pkg::*`; otherwise serialize the lib edit.

## Dispatching cleanly — practical recipe

1. **One worktree per agent**: `git worktree add ../<silo>-work master`. Agents never share a worktree (chezmoi render + edits would interleave).
2. **Brief each agent with**: its silo number, owner-area file list, "out of scope" list, the public contract(s) to preserve, and what it consumes read-only. Pull the relevant section from this doc verbatim.
3. **For `⚠` pairs**: either serialize, or split the shared file first (e.g. move `ai-assist-trigger` out of `widgets.sh` into its own file before parallelizing S6 and S9).
4. **Verify after**: each agent's diff should be confined to its owner area + (at most) its own run-script in S12. Run `make test` (ShellSpec) for any `lib/` change. A diff touching `common.zsh` or `services.toml.tmpl` from two agents = merge conflict — re-dispatch with the contract restated.
5. **The two examples you gave are clean to parallelize**: S8a (system packages manager) and S5 (custom font build) share no owner files. The only `⚠` is S5↔S4 (symbols.db schema) — irrelevant unless the font agent also changes the DB schema. Safe to run concurrently.
