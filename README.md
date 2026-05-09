# dotfiles

Personal dotfiles for macOS (Apple Silicon), managed by
[chezmoi](https://www.chezmoi.io). macOS-specific artifacts are gated to
`darwin` via `.chezmoiignore.tmpl` and per-script template guards so the
same source can later coexist with a Linux machine without polluting it.

## What's inside

| Path | Purpose |
| ---- | ------- |
| `.setup.sh` | Top-level fresh-machine bootstrap (Xcode CLT → Homebrew → chezmoi → apply → 1Password/gh auth → `bin`). |
| `dot_zshrc`, `dot_zshenv`, `dot_p10k.zsh` | Zsh + [zsh4humans](https://github.com/romkatv/zsh4humans) + Powerlevel10k. |
| `dot_config/zsh/` | Functions, abbreviations, color/lib helpers. |
| `dot_config/brewfile/` | `Brewfile.bootstrap` (minimal subset `.setup.sh` itself needs) and `Brewfile` (everything else). |
| `dot_config/git/` | Git config, ignore, attributes, message templates, delta integration. |
| `dot_config/wezterm/` | WezTerm config + custom quick-launch and statusbar plugin configs. |
| `dot_config/hammerspoon/` | Stream Deck+ integration, system controls, MOTD overlays. |
| `dot_config/nvim/` | **Not stored here** — cloned from [`Townk/nvim-config`](https://github.com/Townk/nvim-config) by the bootstrap script. |
| `dot_config/yazi/` | Yazi file manager config + plugins. |
| `dot_config/tealdeer/` | tldr client (Catppuccin Mocha theme, templated). |
| `dot_config/atuin/`, `mise/`, `bin/`, `espanso/` | CLI tool configs. |
| `private_dot_ssh/`, `dot_config/private_gnupg/` | SSH and GnuPG configs (chezmoi-private permissions). |
| `dot_local/bin/system-update` | Canonical "bring all tools to latest" script. Used both as a daily command and inside the bootstrap. |
| `dot_local/bin/nvim-wez.sh` | Engine behind the macOS "Open in NeoVim" Shortcuts droplet. |
| `dot_local/share/shortcuts/` | Exported macOS Shortcuts (`.shortcut` files). |
| `Library/private_Application Support/` | macOS symlinks to XDG paths (e.g. tealdeer's config). |
| `run_once_after_setup-bootstrap-tools.sh.tmpl` | Fresh-machine: runtime dir, clone nvim-config, run `system-update`, install `rust@nightly`. |
| `run_once_after_setup-system-settings.sh.tmpl` | macOS `defaults`, Finder, Dock, login items. |
| `run_onchange_after_install-macos-shortcut.sh.tmpl` | Re-imports `Open in NeoVim.shortcut` whenever its content hash changes. |

## Bootstrap on a fresh Mac

```sh
# 1. Clone the source repo into chezmoi's source path.
git clone https://github.com/Townk/dotfiles.git ~/.local/share/chezmoi

# 2. Run the entry-point bootstrap script.
~/.local/share/chezmoi/.setup.sh
```

What `.setup.sh` does, end to end:

1. Creates the XDG directories (`~/.config`, `~/.cache`, `~/.local/{bin,share,state}`).
2. Installs Xcode Command Line Tools.
3. Installs Homebrew.
4. Installs `chezmoi` (via brew).
5. Runs `chezmoi init` + `chezmoi apply`. This deploys every tracked file
   and fires the bootstrap scripts:
   - `setup-bootstrap-tools.sh.tmpl` clones the NeoVim config repo, then
     calls `~/.local/bin/system-update` which installs `Brewfile.bootstrap` +
     `Brewfile`, upgrades all formulas/casks, runs `mise upgrade`, syncs
     Yazi plugins, runs Lazy/Mason for NeoVim, and updates zsh4humans.
     Finally it installs `rust@nightly` via mise.
   - `setup-system-settings.sh.tmpl` writes macOS `defaults` (keyboard,
     trackpad, dock, finder), and registers `Dropbox`/`Hammerspoon`/
     `Raycast`/`SoundSource` as login items.
   - `install-macos-shortcut.sh.tmpl` opens the `Open in NeoVim.shortcut`
     in Shortcuts.app (one-click confirmation needed).
6. Re-installs `Brewfile.bootstrap` directly (idempotent — typically a
   no-op since step 5 already did it).
7. Pauses for manual 1Password CLI integration (you enable it in
   1Password's Developer settings; the script polls `op account list`).
8. Runs `gh auth login`.
9. Downloads and installs [`bin`](https://github.com/marcosnils/bin) via
   `gh release download`.

After it returns, the machine is fully provisioned. **Reboot recommended**
so login items and macOS defaults take effect.

## Day-to-day workflow

```sh
# Bring all installed tools to latest. Same script the bootstrap calls.
system-update

# Pull upstream changes and re-apply.
chezmoi update

# Inspect drift between source and destination.
chezmoi diff

# Edit a tracked dotfile (auto-routes to the source/.tmpl if templated).
chezmoi edit ~/.config/<file>

# Capture live edits on a NON-templated file back into source.
chezmoi re-add ~/.config/<file>

# 3-way merge a TEMPLATED file that's drifted in destination.
chezmoi merge ~/.config/<file>
```

NeoVim is also wired so that opening a chezmoi-managed file with `:e` (or
any other entry point — yazi, fzf-lua, telescope) transparently swaps the
buffer to the source `.tmpl`, and saving runs `chezmoi apply` for you. The
toggle is `<leader>uM`. See `~/.config/nvim/lua/config/autocmds.lua`.

## Conventions used in this repo

- **Templates (`*.tmpl`)** are rendered through chezmoi's Go templates.
  Used here for OS-gating (`{{ if eq .chezmoi.os "darwin" }}`) and for
  `{{ .chezmoi.homeDir }}` so paths stay portable across users.
- **`.chezmoiignore.tmpl`** skips `.local/bin/nvim-wez.sh` and
  `.local/share/shortcuts/` on non-darwin targets — they depend on
  `open -a`, AppleScript, and the WezTerm GUI socket layout.
- **Brewfile split**: `Brewfile.bootstrap` is the strict minimum
  `.setup.sh` itself needs (`gh` + `1password-cli` + `1password/tap`).
  `Brewfile` is everything else. `system-update` concatenates them so
  `--cleanup` operates on their union; running `--cleanup` against
  either alone would treat the other's contents as "extra" and
  uninstall them.
- **`system-update` is the convergence point.** Both the bootstrap path
  (fresh machine) and the user-driven path (running `system-update`
  manually) reach the same end state: everything at latest. This closes
  the gap where bootstrap could otherwise leave pre-existing tools
  stale on a partially-set-up machine.
- **`run_once_*` scripts** fire when their content hash changes. The
  setup scripts are deliberately idempotent so re-running them after a
  content edit is safe.
- **`run_onchange_*` scripts** for situations where you want re-fire on
  any change. The macOS-shortcut script embeds
  `{{ include "<.shortcut>" | sha256sum }}` in a comment so its rendered
  hash also changes when the referenced binary file does.

## Linux portability

This repo targets macOS. macOS-only artifacts are gated either by
`.chezmoiignore.tmpl` or by `{{ if eq .chezmoi.os "darwin" }}` template
blocks. **One known gap**: the `Library/` symlink directory isn't
currently gated, so a first Linux apply would create
`~/Library/Application Support/tealdeer` (harmless but cosmetically
wrong). Trivial to fix when needed by adding `Library` to the ignore
list.

## Layout reminder

- chezmoi's source: `~/.local/share/chezmoi/`
- `chezmoi cd` drops you into a subshell at that path for git operations.
