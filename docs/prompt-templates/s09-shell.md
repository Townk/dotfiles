# Silo S9 — Shell (zsh) bootstrap & widgets

> Framework-free, XDG-hardened zsh bootstrap with Zellij auto-attach; custom
> ZLE widgets (dir-navigation ring, smart-space, `super-cd`); the shared
> `common.zsh` stdlib, `prompt::*`, and `platform::*`.

## Setup

```sh
git worktree add ../s09-shell-work master
cd ../s09-shell-work
```

## Your scope (owner area — safe to edit)

- `home/dot_config/zsh/` — `dot_zshrc` (rendered from `home/dot_zshrc`),
  `environment.sh`, `completion.sh`, `keybindings.sh`, `functions.d/`,
  `aliases.d/`
- `home/dot_zshrc`, `home/dot_zshenv`, `home/dot_p10k.zsh` (chezmoi
  top-level)
- `home/dot_local/lib/common.zsh` (stdlib — **shared, coordinate**),
  `prompt-common.zsh` (`prompt::*`), `platform.zsh` +
  `platform-{macos,linux}.zsh` (`platform::*`)

## Out of scope (do not edit — owned by other silos)

⚠ **Shared-file hazards:**
- `home/dot_config/zsh/functions.d/widgets.sh` — contains **both** S9 widgets
  (dir-ring, smart-space) **and** S6's `ai-assist-trigger` widget. If an S6
  agent is running concurrently, **serialize** S6↔S9 or split the file first.
- `home/dot_local/lib/common.zsh` + `platform*.zsh` — shared with S13 and
  sourced by S4/S6/S7. Any new shared primitive = a merge point; prefer a
  silo-local helper unless ≥2 silos need it.
- `home/dot_config/zsh/private_secrets.d/` → **S7** (you own only the
  sourcing plumbing in `dot_zshrc`).

## Contracts you must preserve

- **`environment.sh`** — the single source of truth for XDG vars, sourced by
  both `.zshenv` and the `my.environment.variables` LaunchAgent
  (`launchctl setenv` to GUI apps). The S12
  `run_onchange_after_30-reload-environment-launchagent` hook re-boots that
  agent when `environment.sh`'s hash changes. Notable:
  `PIP_REQUIRE_VIRTUALENV=true`, static Homebrew PATH (no `brew shellenv`
  fork), `MISE_CARGO_HOME`/`RUSTUP_HOME`, `XDG_RUNTIME_DIR` auto-created for
  the `op` daemon.
- **`notify` primitive** in `common.zsh` — best-effort (returns non-zero
  quietly on missing `hs`); the `bin/notify` front-end (S13) wraps it with a
  hard error. Consumed on hot paths (S1 `copy-pwd`). Icon/sound spec shape
  matches S3's `hs` globals.
- **`prompt::*`** (`prompt-common.zsh`) — `required`/`default`/`secret`/
  `choice`/`confirm`, read from `/dev/tty`. `prompt::secret` does masked
  entry via `-echo -icanon` + `read -rk 1`. Consumed by S6 (`cagent`), S7
  (`sec`).
- **`platform::*`** — `launch_gui`/`raise_app`; macOS `open -a`+AppleScript,
  Linux detached exec + hyprctl/swaymsg/wmctrl/xdotool. Consumed by S13
  `tab-edit`.
- **ZLE widgets**: dir-navigation ring (`_dir_ring`), `smart-space-expansion`,
  `super-cd` (aliased to `cd`). Bound to raw CSI sequences (WezTerm/Ghostty
  Shift+arrows, Shift+Tab=undo, Option+/=redo).
- **Zellij auto-attach** in `dot_zshrc` — "Main" session reuse logic,
  over-SSH scrollback wipe to suppress pam_motd flash, quick-launch recency
  seeding (calls into S1).

## What you consume read-only

- S1: Zellij auto-attach, quick-launch recency seeding
- S4: pick widget
- S10: fzf wired to `preview`
- S13: `notify`, `wait-until`
- External: z4h/p10k/zsh-defer/fzf/zoxide/atuin

## Where to start

`home/dot_config/zsh/dot_zshrc`, `environment.sh`, `functions.d/widgets.sh`,
`home/dot_local/lib/common.zsh`, `prompt-common.zsh`.

## TASK

> _<describe the assignment — e.g. "Review zsh startup time; instant prompt
> sometimes flashes" >_

**Verify before claiming done:**
- Run `make test` (ShellSpec covers `common.zsh` primitives, `platform::*`,
  `for_each`).
- Reproduce in a fresh interactive zsh (`zsh -i`).
- The `notify` primitive and `environment.sh` XDG vars are public contracts
  (S1/S6/S7/S13 consume them) — signatures unchanged.
- `functions.d/widgets.sh`: don't remove S6's `ai-assist-trigger` widget.
- The `my.environment.variables` LaunchAgent (S12) watches `environment.sh`'s
  hash; if you change its content, note that a reload is triggered.
- Your diff stays within the owner area above.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S9 (S9↔S6
  `widgets.sh` hazard, S9↔S13 `common.zsh` sharing).
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #64–#69.
