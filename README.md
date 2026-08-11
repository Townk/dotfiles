# dotfiles

Personal dotfiles for macOS (Apple Silicon), managed by
[chezmoi](https://www.chezmoi.io). macOS-specific artifacts are gated to
`darwin` via `.chezmoiignore.tmpl` and per-script otherword guards so the same
source can later coexist with a Linux machine without polluting it.
## What's inside

| Path | Purpose |
| ---- | ------- |
| `.setup.sh` | Top-level fresh-machine bootstrap (Xcode CLT → Homebrew → chezmoi → init → bootstrap Brewfile → 1Password/gh auth → apply). |
| `dot_zshrc`, `dot_zshenv`, `dot_p10k.zsh` | Zsh + [zsh4humans](https://github.com/romkatv/zsh4humans) + Powerlevel10k. |
| `dot_config/zsh/` | Functions, abbreviations, color/lib helpers. |
| `dot_config/packages/` | `Brewfile.bootstrap` (tools needed before `chezmoi apply` runs: `chezmoi`, `mise`, `gh`, `1password-cli`) and `Brewfile` (everything else). |
| `dot_config/git/` | Git config, ignore, attributes, message templates, delta integration. |
| `dot_config/wezterm/` | WezTerm config + custom quick-launch and statusbar plugin configs. |
| `dot_config/hammerspoon/` | Stream Deck+ integration, system controls, MOTD overlays. |
| `dot_config/nvim/` | LazyVim-based NeoVim config (`init.lua`, plugins, snippets, spell, lockfile). |
| `dot_config/yazi/` | Yazi file manager config + plugins. |
| `dot_config/tealdeer/` | tldr client (Catppuccin Mocha theme, templated). |
| `dot_config/atuin/`, `mise/`, `espanso/` | CLI tool configs. |
| `dot_config/zsh/environment.sh` | Shared shell/GUI environment source, including XDG paths and `GNUPGHOME`. |
| `private_dot_ssh/`, `dot_config/private_gnupg/` | SSH and GnuPG configs (chezmoi-private permissions). |
| `dot_local/bin/system-update` | Canonical "bring all tools to latest" script. Used both as a daily command and inside the bootstrap. |
| `dot_local/libexec/tab-edit` | Opens file(s) in a new WezTerm/Zellij tab. Engine behind the macOS "Open in NeoVim" Finder droplet and the Linux `tab-edit.desktop` handler (both call it by absolute path). |
| `../assets/open-in-neovim/` | Icons used by the generated "Open in NeoVim" Finder app. |
| `Library/private_Application Support/` | macOS symlinks to XDG paths (e.g. tealdeer's config). |
| `home/.chezmoiscripts/` | Chezmoi run scripts, kept out of `$HOME` while still participating in script ordering. |
| `home/.chezmoiscripts/run_once_after_10-setup-bootstrap-tools.sh.tmpl` | Fresh-machine: runtime dir, `mise install` (Rust nightly included, pinned in `config.toml`), then run `system-update`. |
| `home/.chezmoiscripts/run_once_after_15-setup-dev-shell-tools.sh.tmpl` | Linux dev-shell: mise toolbox, apt libraries, runtime dir, and convergence. |
| `home/.chezmoiscripts/run_once_after_20-setup-system-settings.sh.tmpl` | macOS `defaults`, Finder, Dock, login items. |
| `home/.chezmoiscripts/run_after_25-setup-gpg-key.sh.tmpl` | Imports OpenPGP keys from 1Password if they are missing locally; exits from a local completion marker on steady-state applies. |
| `home/.chezmoiscripts/run_onchange_after_30-reload-environment-launchagent.sh.tmpl` | Reloads the GUI environment LaunchAgent when env definitions change. |
| `home/.chezmoiscripts/run_after_34-enable-sudo-touchid.sh.tmpl` | Enables Touch ID for `sudo` via `/etc/pam.d/sudo_local`. |
| `home/.chezmoiscripts/run_onchange_after_35-generate-open-in-neovim-app.sh.tmpl` | Generates and registers the `Open in NeoVim.app` Finder droplet. |
| `home/.chezmoiscripts/run_after_35-install-dev-shell-sudo-tool-links.sh.tmpl` | Linux dev-shell: exposes selected mise binaries through `/usr/local/bin` for `sudo`. |
| `home/.chezmoiscripts/run_onchange_after_40-install-snaps.sh.tmpl` | Linux dev-shell: syncs snaps declared in `Snapfile`. |
| `home/.chezmoiscripts/run_after_45-grant-zellij-plugin-permissions.sh.tmpl` | Pre-grants Zellij plugin permissions for managed plugin paths. |
| `home/.chezmoiscripts/run_onchange_after_50-custom-build-zsh.sh.tmpl` | Builds the non-unicode9 zsh from source (macOS work/personal) and sets it as the login shell. |
| `home/.chezmoiscripts/run_onchange_after_60-symbols-db.sh.tmpl` | Marks symbols database rebuilds when static DB inputs change. |
| `home/.chezmoiscripts/run_onchange_after_70-symbols-nerd-font.sh.tmpl` | Marks Symbols Nerd Font rebuilds when static font inputs change. |
| `home/.chezmoiscripts/run_after_80-symbols-nerd-font-prompt.sh.tmpl` | Prompts for pending font/DB rebuilds on interactive applies. |

The numeric prefix on `run_*` hooks fixes their execution order: chezmoi runs
`after` scripts in alphabetical order of name, so the prefix makes ordering
explicit (e.g. the zsh build at `50` must run after bootstrap at `10`, which
installs its `autoconf`/`pcre2` deps).

## Bootstrap on a fresh Mac

Prereqs: `curl` and `bash` — both ship with macOS by default. That's it.

```sh
# Personal Mac (default; chezmoi will prompt if no flag and a TTY is available)
curl -fsSL https://raw.githubusercontent.com/Townk/dotfiles/master/.setup.sh | bash

# Work Mac (skip the personal-only App Store apps and packages)
curl -fsSL https://raw.githubusercontent.com/Townk/dotfiles/master/.setup.sh | bash -s -- --work

# Explicit personal
curl -fsSL https://raw.githubusercontent.com/Townk/dotfiles/master/.setup.sh | bash -s -- --personal
```

`.setup.sh` is self-bootstrapping: it installs Xcode Command Line Tools,
Homebrew, and chezmoi; uses `chezmoi init Townk` to clone this repo into
`~/.local/share/chezmoi/`; clears the 1Password / GitHub auth gates that need
a human; then runs `chezmoi apply`.

### Profile

This repo uses a single `profile` data value (`personal`, `work`,
`dev-shell`, or `server`) to gate profile-specific entries. The `.chezmoi.toml.tmpl` init
template reads the `CHEZMOI_PROFILE` env var; `.setup.sh` sets it based on the
`--work` / `--personal` flag for Macs. When no flag is given and a TTY is
available, chezmoi prompts. When no flag is given and there's no TTY (e.g.
`curl | bash` without args), the script defaults to `personal`.

To change profile on an already-bootstrapped machine, re-run setup.sh with the
opposite flag, then `chezmoi apply`. Templates that branch on profile look like:

```
{{ if eq .profile "personal" -}}
mas "DaisyDisk", id: 411643860
{{- end }}
```

The App Store (`mas`) entries are split in two blocks: one shared by `personal`
and `work`, one personal-only. Brews, casks, and the bootstrap Brewfile are
shared.

The `dev-shell` profile is for headless Linux dev shells, not `.setup.sh`.
Initialize it with `CHEZMOI_PROFILE=dev-shell` or an equivalent chezmoi config,
then run `chezmoi apply` on the Linux host. The dev-shell bootstrap script
installs the mise toolbox, apt libraries, Rust nightly, creates
`XDG_RUNTIME_DIR`, then calls the Homebrew-less `system-update` path to sync
package manifests and Neovim plugins.

The `server` profile is for headless, long-lived Linux hosts (hypervisor/NAS class machines). Like `dev-shell` it is onboarded by an operator via `system-onboard --profile server` (kind defaults to `headless`), never through `.setup.sh`. Profile→trait gating (headless/ephemeral) lives in `home/.chezmoitemplates/profile-traits.tmpl`, which fails the render on any unknown profile.

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
7. Pauses for manual 1Password CLI integration (enable it in 1Password's
   Developer settings; the script polls `op account list`).
8. Runs `gh auth login` if GitHub isn't yet authenticated.
9. Finally runs `chezmoi apply`, which deploys every tracked file and
    fires the bootstrap scripts:
    - `setup-bootstrap-tools.sh.tmpl` runs `mise install` (now that
      `~/.config/mise/config.toml` is on disk) to provision
      Python/Node/Go/Rust (nightly included)/uv, then calls
      `~/.local/bin/system-update` to converge everything else.
    - `setup-gpg-key.sh.tmpl` imports OpenPGP keys from 1Password Documents
      when they are not already present in `~/.config/gnupg`, then applies
      each document's configured ownertrust and enabled/disabled state. After
      a successful check/import, later applies use a local completion marker
      unless the expected key spec or keyring metadata changes.
    - `setup-system-settings.sh.tmpl` writes macOS `defaults` (keyboard,
      trackpad, dock, finder), and registers `Dropbox` / `Hammerspoon` /
      `Raycast` / `SoundSource` as login items.
    - `generate-open-in-neovim-app.sh.tmpl` generates and registers
      `~/Applications/Open in NeoVim.app`.

The interactive gates (1Password, `gh auth`) are deliberately front-loaded
so the user clears them while their attention is on the install. After
that, `chezmoi apply` can run unattended.

Before bootstrapping a new machine, make sure the `rapinialves` 1Password
account has these Documents in the `Private` vault:

```text
Personal - Thiago Alves (CA995D91)
Personal - Thiago Alves (F403C88D)
Personal - Thiago Alves (D36D4260)
```

The import hook reads them with `op document get --account rapinialves --vault
Private`. Each document declares its ownertrust level and whether the imported
keys should be left enabled or marked disabled, which keeps legacy keys
available for decrypting old mail without making them active for new use. The
disabled legacy documents are best-effort; the active `CA995D91` document is
required.

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

For each file it prints one of `clean`, `applied`, `merged`, `needs-merge`,
`skipped`, or `failed`. Changes that fall entirely on literal lines are
auto-patched into the `.tmpl` source. Changes that touch a `{{ ... }}`
directive route through `chezmoi merge` for manual three-way merging — make
sure `merge.command` is configured in your chezmoi config. `skipped` is
emitted when there is no destination to read back from — chezmoi run-scripts
(`run_*.tmpl`) and symlink templates (`symlink_*.tmpl`).

Pass `--no-merge` (e.g. from editor hooks or other non-interactive callers)
to suppress the merge fallback: rejected hunks emit `needs-merge` instead
of invoking the merge tool, leaving the source byte-identical to before.

## Conventions used in this repo

- **Templates (`*.tmpl`)** are rendered through chezmoi's Go templates.
  Used here for OS-gating (`{{ if eq .chezmoi.os "darwin" }}`) and for
  `{{ .chezmoi.homeDir }}` so paths stay portable across users.
- **`.chezmoiignore.tmpl`** ships `.local/libexec/tab-edit` on macOS and graphical
  Linux, but skips it on the headless dev-shell and other non-GUI hosts — it
  needs a GUI WezTerm and a file manager to be useful. The OS-specific launch
  logic lives behind the `platform::` module.
- **Brewfile split**: `Brewfile.bootstrap` holds everything that must
  exist before `chezmoi apply` fires (`chezmoi` + `mise` + `gh` +
  `1password-cli` + `1password/tap`). `Brewfile` is everything else.
  `system-package brew sync` reconciles the concatenated union; cleaning
  against either file alone would treat the other's contents as "extra"
  and uninstall them.
- **`system-update` is the convergence point.** Both the bootstrap path
  (fresh machine) and the user-driven path (running `system-update`
  manually) reach the same end state: everything at latest. This closes
  the gap where bootstrap could otherwise leave pre-existing tools
  stale on a partially-set-up machine.
- **`run_once_*` scripts** fire when their content hash changes. The
  setup scripts are deliberately idempotent so re-running them after a
  content edit is safe.
- **Run scripts live in `home/.chezmoiscripts/`**, which is chezmoi's
  special script directory under this repo's source root (`home/`). They
  execute normally but do not create target files in `$HOME`.
- **`run_onchange_*` scripts** are used for static input fingerprints.
  Static repo files are hashed into the rendered script; slow host/runtime
  checks write state under `~/.local/state/chezmoi` from `run_after_*`
  scripts instead of running during every template render.

## Secrets (API keys, tokens)

Secret env vars are declared once in the manifest
`home/.chezmoidata/secrets.yaml` (env var **names**, prompts, and which
profiles need them — never values) and materialized per-machine by two
backends, chosen by machine kind:

- **Human machines** (`personal`/`work` Macs): the committed fragment holds only
  `op://…` references, resolved by direct `op read` via the `output` template
  (not `onepasswordRead`) only when the live fragment is missing, the committed
  reference set changes, or `CHEZMOI_REFRESH_SECRETS=1` is set. Steady-state
  applies reuse the already-rendered 0600 fragment, so normal `chezmoi apply`
  does not ask Touch ID just to compare secrets. When a refresh is needed, `op`
  picks its mode from the environment: **local refresh → account mode
  (Touch ID)**, **SSH refresh → service-account token** (exported only over SSH
  by `environment.sh`). Each variable is a single 1Password item; the
  per-machine value is a concealed field labeled with the slot hash, so refs are
  deterministic: `op://<vault>/<NAME>/<slot-hash>` (per-machine values +
  per-machine rotation, one item per variable).
- **Headless machines** (`dev-shell`): **SOPS + age**. There is no interactive
  `op signin`, so values are encrypted at rest to the box's own age recipient
  and decrypted **once at apply** by the `output "sops" "--decrypt"` template.

Either way the per-machine fragment lands at `~/.config/zsh/secrets.d/<slot>.sh`
(mode 0600) and is sourced by the non-secret loader `~/.config/zsh/secrets.sh`
→ `environment.sh` → `~/.zshenv`, so every shell and every subprocess spawned
from one sees the env var.

### The leak-safe boundary (this repo is PUBLIC)

Committed artifacts identify a machine only by an **opaque slot id** (e.g.
`slot-7f3a9c`) — never an alias, hostname, username, or work tool name. Real
endpoints and the alias↔slot map live only in the loose, unmanaged layer. See
`.cursor/rules/no-company-info.mdc` and the `pre-commit` leak guard.

**On a fresh clone, arm the guard — it is inert until you do.** The hook lives
in `.githooks/pre-commit` (tracked, holds no identifiers) but reads its patterns
from `.leak-patterns` (gitignored, holds the real ones), and `core.hooksPath` is
local config:

```sh
git config core.hooksPath .githooks     # otherwise git never runs the hook
$EDITOR .leak-patterns                  # otherwise the hook warns and passes
```

Both were once missing at the same time, which let a work account path reach a
public commit and stay there for five weeks. The hook now says so loudly when
the pattern list is absent, rather than passing in silence.

| Fact | Lives in |
| ---- | -------- |
| Real SSH endpoint | `~/.ssh/config.d/<alias>.conf` (loose, never committed) |
| alias ↔ slot ↔ host map | `~/.config/chezmoi/onboard-map.yaml` (loose, never committed) |
| Which slot is *this host's* | `~/.config/chezmoi/chezmoi.toml` `[data].secretsSlot` (generated at init, local) |
| slot id → age recipient | `.sops.yaml` (committed — opaque slot + age **public** key only) |
| Encrypted values | `secrets/<slot>/<NAME>.sops.sh` (committed — one ciphertext blob per secret, opaque names; outside the chezmoi source root) |
| Env var names + prompts | `home/.chezmoidata/secrets.yaml` (committed — no values) |
| 1Password service-account token | `~/.local/share/op/service-account` (loose, 0600, never committed; exported by `environment.sh` only over SSH, so local sessions stay in account mode / Touch ID) |

### Onboarding a machine

The **slot** is the only shared (committed) identity. An **alias** is just an
operator-local SSH/map name (loose, never committed); the same machine can be
dialed under different aliases from different operators while everyone agrees on
its slot. There are two onboarding paths:

**Self (this Mac).** A human Mac onboards itself — this is what `.setup.sh` runs
during bootstrap, and you can rerun it anytime:

```sh
system-onboard --local [--alias <friendly-name>] [--profile <profile>]
# human only; alias defaults to this host's short name; profile defaults to the
# machine's configured chezmoi profile
```

It assigns the machine's own slot, builds its 1Password fragment, sets
`secretsSlot`, applies, and stores the 1Password **service-account token** loose
at `~/.local/share/op/service-account` — so **every Mac is also an operator**
and can drive `op` non-interactively for its own `system-secrets`/onboarding.
The token is fetched from a 1Password item via the desktop app (it remembers the
`op://` ref at `…/service-account.ref`) or pasted once.

**Operator-driven (remote).** From a trusted operator host (this repo + push
access) that can already SSH to the target:

```sh
system-onboard --alias <ssh-alias> --hostname <ssh-host> --profile <profile>
# kind is inferred: dev-shell → headless, else human
```

It reconciles SSH access (loose), the remote `chezmoi init`, an opaque secrets
slot, the encrypted/1Password-backed fragment, the commit (opaque only), and the
remote apply. If a **human target has already self-onboarded** (it has its own
`secretsSlot`), the operator detects that over SSH, records `alias → slot`, and
only reconciles connectivity + brings it current — it never mints or rebuilds
that machine's secrets. Headless boxes can't self-onboard and stay fully
operator-driven. Idempotent — safe to rerun.

### Managing secrets

```sh
system-secrets list                            # manifest + known slots
system-secrets add <NAME>                       # declare (if new) + set NAME on this machine
system-secrets rotate <NAME> [--slot S | --all] # re-collect NAME (default: this machine)
system-secrets rotate [--slot S | --all]        # rebuild a slot's whole secret set
```

`add` is the one-step path for the machine you're on: it declares the secret if
new, **auto-adds this machine's profile** to its `requiredFor` if missing (so the
value can materialize here), then stores this machine's value. `rotate <NAME>`
re-collects one secret — on this machine by default, on `--slot S`, or across the
fleet with `--all`; with no NAME it rebuilds a slot's whole set. Both commands
share `~/.local/lib/system-secrets-common.zsh` with onboarding so the paths can't
drift.

Values are stored per-secret: one 1Password field per machine (human), or one
`secrets/<slot>/<NAME>.sops.sh` blob (headless), so adding or rotating a single
secret never disturbs the others. A headless blob is encrypted only to its box's
recipient (per-machine isolation — a compromised box can't read peers' secrets),
and the operator holds only the public key. A slot still on the pre-split
monolithic blob can't be decrypted operator-side to patch, so its first
per-secret edit re-collects the slot's set once to migrate it.

### Key custody

- **Headless:** the age **private** identity lives only on the box at
  `~/.local/state/chezmoi/secrets/key.txt` (0600), off git. chezmoi's `[env]`
  exports `SOPS_AGE_KEY_FILE` to it so `output sops` decrypts at apply.
- **Human:** no age key — 1Password resolves references at apply.

GPG/commit-signing is independent of all of this: chezmoi's `encryption = "gpg"`
remains for any `encrypted_` files, while SOPS runs via the `output` template
function. The two do not interact and there is no migration.

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
