# Silo S12 — chezmoi orchestration & run-scripts

> The chezmoi bootstrap, run-script ordering, hash-baked change triggers,
> profile/os gating, and the Open-in-NeoVim Finder droplet generator.

## Setup

```sh
git worktree add ../s12-chezmoi-work master
cd ../s12-chezmoi-work
```

## Your scope (owner area — safe to edit)

- `.setup.sh`, `Makefile`, `README.md`, `.chezmoiroot`, `.chezmoiignore.tmpl`,
  `.chezmoi.toml.tmpl`, `.chezmoidata/*.yaml`, `.shellspec`, `.gitattributes`,
  `.gitignore`
- `home/.chezmoiscripts/run_*` — **all** the numbered run-scripts
- `home/dot_config/zellij/zellij-plugin-path.tmpl` (shared resolver — also
  used by S1; coordinate if you change the path resolution logic)

## Out of scope (do not edit — owned by other silos)

- The *logic* each run-script invokes belongs to its feature silo:
  - S5 owns the custom-build *builders* (`custom-builds/`)
  - S7 owns the GPG/secrets logic
  - S8 owns the snap sync content
  - S1 owns the zellij plugin-perm *protocol*
- You own the **trigger mechanics**: the numeric ordering, the hash-baking
  into rendered comments (so `run_onchange` re-fires on source change), the
  `run_after` vs `run_once` vs `run_onchange` choice, and the
  interactive-prompt gating (TTY + not-CI + `CHEZMOI_NONINTERACTIVE`).

## Contracts you must preserve

- **Numeric prefix ordering** (`run_*_after_NN-…`): chezmoi runs `after`
  scripts in alphabetical order, so the prefix fixes execution order.
  Current map (don't renumber without tracing deps):
  `05` op-daemon reaper (S7), `10` bootstrap-tools, `15` dev-shell tools,
  `20` system-settings, `25` GPG key (S7), `30` env LaunchAgent reload,
  `34` sudo touchid, `35` open-in-neovim app (S1/S2) + dev-shell sudo links,
  `36` tab-edit desktop (S1/S13), `40` snaps (S8), `45` zellij plugin perms
  (S1), `50` custom zsh build (S5), `60` symbols-db mark (S5), `70`
  symbols-nerd-font mark (S5), `80` symbols font/DB prompt (S5), `90`
  dev-shell prune.
- **Hash-baking**: `run_onchange` scripts bake a SHA256 of their inputs
  (builder, donor glyphs, custom-SVG `code` pins, manifest content) into
  rendered comments so chezmoi re-runs on change. Editing a builder (S5)
  without updating the baked hash logic breaks the trigger.
- **Open-in-NeoVim app generator** (`run_onchange_after_35`): builds the
  `.app` via `osacompile`, stamps `neovim-hicontrast.icns`, registers
  `CFBundleDocumentTypes`, and **queries nvim's filetype registry headlessly**
  (`vim.filetype.inspect().extension` + `mdls`) — a hard dependency on S2's
  filetype map.
- **`.chezmoiignore.tmpl`** — the profile/os gating that makes dev-shell
  headless (excludes `hammerspoon`/`wezterm`/`ghostty`/`espanso`/
  `llama-swap` etc. on dev-shell).

## What you consume read-only

- Every feature silo (the run-scripts trigger their builds/imports/
  permissions). S2's `vim.filetype.inspect()` for the app generator.

## Where to start

`.setup.sh`, `home/.chezmoiscripts/`, `.chezmoiignore.tmpl`, `.chezmoidata/`.

## TASK

> _<describe the assignment — e.g. "Review the chezmoi run-script ordering
> for safety after the new S8 snap hook was added" >_

**Verify before claiming done:**
- Run `chezmoi apply --dry-run` (or a real apply in the worktree) and confirm
  the run-script ordering is as intended.
- The hash-baking in `run_onchange` scripts is the trigger contract with S5
  (custom builds) — if you change how hashes are computed, S5's builders must
  still re-fire on real input changes (and not fire spuriously).
- The `run_after_35` open-in-neovim generator still depends on S2's
  `vim.filetype.inspect()` — preserve that headless query.
- `.chezmoiignore.tmpl` profile/os gating must keep dev-shell headless.
- Your diff stays within the owner area above (a feature silo's run-script
  *content* is jointly owned with that silo — coordinate if you edit the
  logic, not just the trigger).

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S12 (the run-script
  → feature-silo ownership map).
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #76–#84.
