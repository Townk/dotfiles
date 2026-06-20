# Silo S1 — Terminal & multiplexer integration

> WezTerm + Ghostty + Zellij cooperation: clipboard bridges, link dispatch,
> fullscreen/status side-channels, plugin loading, floating modal pickers,
> nested-session passthrough, image-protocol negotiation.

## Setup

The repo is at `/Users/thiago/.local/share/chezmoi` (live tree on
`feat/ai-assist-phase-c1` — **do not work there**). Create an isolated
worktree from `master`:

```sh
git worktree add ../s01-terminal-mux-work master
cd ../s01-terminal-mux-work
```

All paths below are relative to the worktree root.

## Your scope (owner area — safe to edit)

- `home/dot_config/wezterm/` (all lua)
- `home/dot_config/ghostty/config`
- `home/dot_config/zellij/config.kdl.tmpl`, `layouts/default.kdl.tmpl`,
  `quick-launch/` (incl. `default.yaml.tmpl`, `launch.d/`),
  `scripts/` (quick-launch, zellij-modal, zellij-open, pick-*-zellij,
  copy-pwd, edit-terminal-config, terminal-toggle-fullscreen, ensure-plugins,
  nested-session-check, `lib/{config,command,dispatch,zellij-session}.zsh`)
- `home/dot_local/lib/zellij.zsh` (`zj::*`)
- `home/dot_local/lib/image-protocol-support.zsh`
- `home/dot_config/zellij/zellij-plugin-path.tmpl` (shared resolver —
  coordinate with S12 if you change the path resolution logic)

## Out of scope (do not edit — owned by other silos)

- The custom Zellij wasm plugin **sources** (`zj-hud`, `zj-promptjump`,
  `zj-context-keys`, `vim-navigator`) live **outside this repo** under
  `~/Projects/apps/zellij/`. You own only the KDL that *loads* them and the
  scripts they *invoke*.
- The patched font + `symbols.db` → **S5**. You reference built artifacts by
  family name / DB path only.
- nvim's SSH-paste *client* → **S2**. You own the socket protocol the client
  reads.
- The `clipboard-bridge` launchd *service definition* in
  `home/dot_config/packages/services.toml.tmpl` → **S8b**. You own the
  `~/.clipboard-bridge.sock` protocol; S8b owns the plist fields.
- The `pick::` engine and `pick-glyph`/`pick-gitmoji` libexec → **S4**. You
  own the `zj::pick` adapter and the `pick-*-zellij` modal adapters that call
  them.
- chezmoi run-scripts under `home/.chezmoiscripts/` → **S12** (the
  `run_after_45-grant-zellij-plugin-permissions` and
  `run_onchange_after_40-install-snaps` triggers).

## Contracts you must preserve

- **`zj::pick`** — drop-in for `pick::start` (S4). Same argv; floats in a
  Zellij pane when `$ZELLIJ` set, else inline. Consumed by `ai-assist`/
  `ai-commit` (S6) and `quick-launch-pick`.
- **`resolve_session <client_pid>`** / **`zellij_wezterm_sessions`** in
  `zellij/scripts/lib/zellij-session.zsh` — unix-socket session resolver.
  Consumed by `zellij-open`, `tab-edit` (S13), quick-launch.
- **OSC 52 clipboard protocol**: `copy_command` intentionally unset in
  `config.kdl.tmpl`; copy is origin-relative via re-emitted OSC 52. The SSH
  paste-back reads `~/.clipboard-bridge.sock` (served by S8b's
  `clipboard-bridge` agent); nvim (S2) implements the client.
- **Workspace-rename side-channel**: `__TOGGLE_FULLSCREEN__` /
  `__QL_FOCUS__=<id>` workspace names drive WezTerm handlers. Your
  `terminal-toggle-fullscreen` and quick-launch depend on these exact
  sentinel strings.
- **Fullscreen-state mirror file**:
  `~/.local/state/wezterm/fullscreen_state` (atomic write-on-change) — read
  by the zj-hud bar.
- **`get_terminal_image_protocol()`** in `image-protocol-support.zsh` —
  returns Kitty/iTerm2/Sixel capability list constrained through Zellij.
  Consumed by `preview` (S10).
- **`zellij-plugin-path.tmpl`** — resolves managed plugin `file:` paths; the
  S12 permission-grant hook and your `ensure-plugins` must agree with
  `config.kdl`'s loaded paths.

## What you consume read-only

- S4: `pick::start`, `pick-glyph`, `pick-gitmoji`, `pick-list`
- S5: patched font (family name), `symbols.db` at
  `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`
- S9: `environment.sh` XDG vars, the `notify` primitive in `common.zsh`
- S13: `notify` bin, `platform::*`, `tab-edit`
- S8b: `services.toml` `clipboard-bridge` agent
- S12: chezmoi hooks that trigger plugin perms / snaps

## Where to start

`wezterm.lua`, `config.kdl.tmpl`, `zellij.zsh`, `zellij/scripts/lib/dispatch.zsh`,
`zellij/scripts/lib/zellij-session.zsh`.

## TASK

> _<describe the specific assignment here — e.g. "Review the quick-launch
> dispatcher for correctness and performance" or "Investigate why
> `resolve_session` occasionally returns the wrong session after a
> switch" >_

**Verify before claiming done:**
- Reproduce the behavior you changed (don't guess).
- If you touched `lib/zellij.zsh` or `zellij/scripts/lib/*.zsh`, run
  `make test` (ShellSpec, pinned `--shell zsh`).
- Confirm `zj::pick`/`resolve_session`/`@window:<id>`/sentinel-string
  contracts still hold.
- Your diff stays within the owner area above.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S1 full contract +
  cross-silo detail.
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #1–#25 (the terminal/mux stack).
