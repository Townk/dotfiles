# dotfiles

Personal dotfiles for macOS (Apple Silicon), managed by
[chezmoi](https://www.chezmoi.io). macOS-specific artifacts are gated to
`darwin` via `.chezmoiignore.tmpl` and per-script template guards so the same
source can later coexist with a Linux machine without polluting it.

## What's inside

| Path | Purpose |
| ---- | ------- |
| `.setup.sh` | Top-level fresh-machine bootstrap (Xcode CLT → Homebrew → chezmoi → init → bootstrap Brewfile → `bin` → 1Password/gh auth → apply). |
| `dot_zshrc`, `dot_zshenv`, `dot_p10k.zsh` | Zsh + [zsh4humans](https://github.com/romkatv/zsh4humans) + Powerlevel10k. |
| `dot_config/zsh/` | Functions, abbreviations, color/lib helpers. |
| `dot_config/packages/` | `Brewfile.bootstrap` (tools needed before `chezmoi apply` runs: `chezmoi`, `mise`, `gh`, `1password-cli`) and `Brewfile` (everything else). |
| `dot_config/git/` | Git config, ignore, attributes, message templates, delta integration. |
| `dot_config/wezterm/` | WezTerm config + custom quick-launch and statusbar plugin configs. |
| `dot_config/hammerspoon/` | Stream Deck+ integration, system controls, MOTD overlays. |
| `dot_config/nvim/` | LazyVim-based NeoVim config (`init.lua`, plugins, snippets, spell, lockfile). |
| `dot_config/yazi/` | Yazi file manager config + plugins. |
| `dot_config/tealdeer/` | tldr client (Catppuccin Mocha theme, templated). |
| `dot_config/atuin/`, `mise/`, `bin/`, `espanso/` | CLI tool configs. |
| `dot_config/zsh/environment.sh` | Shared shell/GUI environment source, including XDG paths and `GNUPGHOME`. |
| `private_dot_ssh/`, `dot_config/private_gnupg/` | SSH and GnuPG configs (chezmoi-private permissions). |
| `dot_local/bin/system-update` | Canonical "bring all tools to latest" script. Used both as a daily command and inside the bootstrap. |
| `dot_local/bin/nvim-wez.sh` | Engine behind the macOS "Open in NeoVim" Shortcuts droplet. |
| `dot_local/share/shortcuts/` | Exported macOS Shortcuts (`.shortcut` files). |
| `Library/private_Application Support/` | macOS symlinks to XDG paths (e.g. tealdeer's config). |
| `run_once_after_setup-bootstrap-tools.sh.tmpl` | Fresh-machine: runtime dir, `mise install`, install `rust@nightly`, then run `system-update`. |
| `run_once_after_setup-gpg-key.sh.tmpl` | Imports OpenPGP keys from 1Password if they are missing locally. |
| `run_once_after_setup-system-settings.sh.tmpl` | macOS `defaults`, Finder, Dock, login items. |
| `run_onchange_after_reload-environment-launchagent.sh.tmpl` | Reloads the GUI environment LaunchAgent when env definitions change. |
| `run_onchange_after_install-macos-shortcut.sh.tmpl` | Re-imports `Open in NeoVim.shortcut` whenever its content hash changes. |

## Bootstrap on a fresh Mac

Prereqs: `curl` and `bash` — both ship with macOS by default. That's it.

```sh
# Personal Mac (default; chezmoi will prompt if no flag and a TTY is available)
curl -fsSL https://raw.githubusercontent.com/Townk/dotfiles/master/.setup.sh | bash

# Work Mac (skip the App Store apps and personal-only packages)
curl -fsSL https://raw.githubusercontent.com/Townk/dotfiles/master/.setup.sh | bash -s -- --work

# Explicit personal
curl -fsSL https://raw.githubusercontent.com/Townk/dotfiles/master/.setup.sh | bash -s -- --personal
```

`.setup.sh` is self-bootstrapping: it installs Xcode Command Line Tools,
Homebrew, and chezmoi; uses `chezmoi init Townk` to clone this repo into
`~/.local/share/chezmoi/`; clears the 1Password / GitHub auth gates that need
a human; then runs `chezmoi apply`.

### Profile

This repo uses a single `profile` data value (`personal` or `work`) to gate
profile-specific entries. The `.chezmoi.toml.tmpl` init template reads the
profile from the `CHEZMOI_PROFILE` env var; `.setup.sh` sets it based on the
`--work` / `--personal` flag. When no flag is given and a TTY is available,
chezmoi prompts. When no flag is given and there's no TTY (e.g. `curl | bash`
without args), the script defaults to `personal`.

To change profile on an already-bootstrapped machine, re-run setup.sh with the
opposite flag, then `chezmoi apply`. Templates that branch on profile look like:

```
{{ if eq .profile "personal" -}}
mas "DaisyDisk", id: 411643860
{{- end }}
```

Currently the App Store (`mas`) entries are gated to `personal`. Brews, casks,
and the bootstrap Brewfile are shared.

End to end, the script:

1. Creates the XDG directories (`~/.config`, `~/.cache`, `~/.local/{bin,share,state}`).
2. Installs Xcode Command Line Tools (gates on `xcode-select --install`).
3. Installs Homebrew (curl-piped from `Homebrew/install`).
4. Installs `chezmoi` (via brew) so the repo can be cloned.
5. Runs `chezmoi init Townk` to clone the repo into chezmoi's source path
   (no `apply` yet).
6. Installs `Brewfile.bootstrap` — `chezmoi`, `mise`, `gh`, `1password-cli`,
   `1password/tap`. These are the tools needed before `chezmoi apply` can
   safely fire.
7. Installs [`bin`](https://github.com/marcosnils/bin) by fetching the
   latest darwin release asset via the anonymous GitHub releases API
   (no `gh auth` required at this point).
8. Pauses for manual 1Password CLI integration (enable it in 1Password's
   Developer settings; the script polls `op account list`).
9. Runs `gh auth login` if GitHub isn't yet authenticated.
10. Finally runs `chezmoi apply`, which deploys every tracked file and
    fires the bootstrap scripts:
    - `setup-bootstrap-tools.sh.tmpl` runs `mise install` (now that
      `~/.config/mise/config.toml` is on disk) to provision
      Python/Node/Go/Rust/uv, installs `rust@nightly`, then calls
      `~/.local/bin/system-update` to converge everything else.
    - `setup-gpg-key.sh.tmpl` imports OpenPGP keys from 1Password Documents
      when they are not already present in `~/.config/gnupg`, then applies
      each document's configured ownertrust and enabled/disabled state.
    - `setup-system-settings.sh.tmpl` writes macOS `defaults` (keyboard,
      trackpad, dock, finder), and registers `Dropbox` / `Hammerspoon` /
      `Raycast` / `SoundSource` as login items.
    - `install-macos-shortcut.sh.tmpl` opens `Open in NeoVim.shortcut` in
      Shortcuts.app (one-click confirmation needed).

The interactive gates (1Password, `gh auth`) are deliberately front-loaded
so the user clears them while their attention is on the install. After
that, `chezmoi apply` can run unattended.

Before bootstrapping a new machine, make sure the `rapinialves` 1Password
account has these Documents in the `Private` vault:

```text
Personal - Thiago Alves (CA995D91)
Personal - Thiago Alves (F403C88D)
```

The import hook reads them with `op document get --account rapinialves --vault
Private`. Each document declares its ownertrust level and whether the imported
keys should be left enabled or marked disabled, which keeps legacy keys
available for decrypting old mail without making them active for new use.

After it returns, the machine is fully provisioned. **Reboot recommended**
so login items and macOS defaults take effect.

`chezmoi init` clones via HTTPS. To switch to SSH afterwards (once your
1Password SSH agent is configured):

```sh
git -C ~/.local/share/chezmoi remote set-url origin git@github.com:Townk/dotfiles.git
```

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

## `chezmoi-reverse`

Propagate edits made to a chezmoi-managed destination file back into its
source template.

```sh
chezmoi-reverse ~/.foo
```

For each file it prints one of `clean`, `applied`, `merged`, `skipped`, or
`failed`. Changes that fall entirely on literal lines are auto-patched into
the `.tmpl` source. Changes that touch a `{{ ... }}` directive route through
`chezmoi merge` for manual three-way merging — make sure `merge.command` is
configured in your chezmoi config.

## Conventions used in this repo

- **Templates (`*.tmpl`)** are rendered through chezmoi's Go templates.
  Used here for OS-gating (`{{ if eq .chezmoi.os "darwin" }}`) and for
  `{{ .chezmoi.homeDir }}` so paths stay portable across users.
- **`.chezmoiignore.tmpl`** skips `.local/bin/nvim-wez.sh` and
  `.local/share/shortcuts/` on non-darwin targets — they depend on
  `open -a`, AppleScript, and the WezTerm GUI socket layout.
- **Brewfile split**: `Brewfile.bootstrap` holds everything that must
  exist before `chezmoi apply` fires (`chezmoi` + `mise` + `gh` +
  `1password-cli` + `1password/tap`). `Brewfile` is everything else.
  `system-update` concatenates them so `--cleanup` operates on their
  union; running `--cleanup` against either alone would treat the
  other's contents as "extra" and uninstall them.
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
