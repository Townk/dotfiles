# shell-color-scripts (user-owned install)

A self-built install of [shell-color-scripts](https://gitlab.com/dwt1/shell-color-scripts)
(Derek Taylor) — a collection of terminal color scripts — placed entirely
under `~/.local/opt` with no `sudo`, and a symlink on `$PATH`.

## The problem

The NeoVim dashboard renders a colorscript on startup:

```lua
-- ~/.config/nvim/lua/plugins/core.lua
cmd = "colorscript -e square",
```

The upstream `Makefile` installs with `sudo` into `/usr/local/bin` and
`/opt/shell-color-scripts`, and the CLI hardcodes the `/opt` data dir. On
Apple Silicon `/usr/local/bin` is the Intel-Homebrew path and is **not** on
`$PATH` (native Homebrew lives in `/opt/homebrew`), so the binary lands
installed-but-uncallable and nvim prints
`zsh:1: command not found: colorscript`.

mise can't manage this project: its `aqua`/`github`/`gitlab` backends all
fetch *release assets attached to tagged releases*, and this one has no tags
and no releases — it's a shell script + a data directory distributed by
`make install`.

## What this does

`build-colorscripts.sh` clones the upstream repo into `./build` (gitignored),
copies the CLI + the `colorscripts/` data dir into `~/.local/opt/colorscripts/`,
patches the hardcoded data path to the user install, and symlinks
`~/.local/bin/colorscript` → the installed binary. `~/.local/bin` is already
on `$PATH`, and the only thing it receives is a symlink — the real script
content lives in the clone and the prefix, both user-owned.

Install layout:

```
~/.local/opt/colorscripts/
├── bin/colorscript          # CLI (patched, executable)
├── share/colorscripts/      # colorscript data scripts
└── .source-commit           # stamp of the cloned commit (fast-path check)
~/.local/bin/colorscript     # symlink -> ~/.local/opt/colorscripts/bin/colorscript
```

## Usage

The chezmoi hook `run_onchange_after_55-custom-build-colorscripts.sh.tmpl`
runs this automatically on `chezmoi apply` whenever the builder changes. To
pull upstream and rebuild by hand:

```bash
COLORSCRIPTS_UPDATE=1 bash ~/.local/share/chezmoi/custom-builds/colorscripts/build-colorscripts.sh
```

Force a clean reinstall:

```bash
rm -rf ~/.local/opt/colorscripts && chezmoi apply
```

## Overrides

Export before running, or pass as `KEY=val ./build-colorscripts.sh`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `COLORSCRIPTS_BUILD_ROOT` | `<script-dir>/build` | Where the shallow clone lives |
| `COLORSCRIPTS_URL` | `https://gitlab.com/dwt1/shell-color-scripts.git` | Upstream URL |
| `COLORSCRIPTS_REF` | `master` | Git ref to track (no release tags exist) |
| `COLORSCRIPTS_PREFIX` | `~/.local/opt/colorscripts` | Install prefix |
| `COLORSCRIPTS_BINLINK` | `~/.local/bin/colorscript` | `$PATH` symlink |
| `COLORSCRIPTS_UPDATE` | unset | Set to `1` to fetch + reset the clone before installing |

## Caveats

- **No versioning.** Upstream has no tags/releases, so this tracks `master`
  with git as the trust anchor (same model as `custom-builds/zsh`). Pin
  `COLORSCRIPTS_REF` to a specific commit SHA for reproducibility.
- **The `-b`/`-u` blacklist subcommands** still call `sudo mv` upstream. With
  a user-owned data dir the `sudo` is unnecessary and would chown files to
  root; this build doesn't patch that path (out of scope — the nvim dashboard
  only uses `-e`). Avoid `-b`/`-u`, or patch them out if you need them.
