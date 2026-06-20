# Silo S2 — NeoVim config

> LazyVim-based config with custom autocmds/plugins: chezmoi source-redirect
> + debounced auto-apply, gotmpl compound filetype + treesitter injection,
> SSH clipboard client, Unicode-escape hints, Harper spell integration,
> markdown list-wrap fix, self-authored smart-comment-wrap, custom lualine.

## Setup

```sh
git worktree add ../s02-neovim-work master
cd ../s02-neovim-work
```

## Your scope (owner area — safe to edit)

- `home/dot_config/nvim/` — `init.lua`, `lua/config/{options,autocmds,keymaps,lazy}.lua`,
  `lua/plugins/*.lua`, `lua/lualine/`, `lua/utils/*.lua`, `after/`,
  `local-plugins/smart-comment-wrap/`, `spell/`, `lazyvim.json`,
  `lazy-lock.json`, `dot_luarc.json`, `dot_editorconfig`

## Out of scope (do not edit — owned by other silos)

- `chezmoi-reverse` binary → **S13** (you *call* it via `BufReadPre`).
- The `clipboard-bridge` service + WezTerm OSC 52 paste path → **S1/S8b**
  (you *consume* the socket).
- The "Open in NeoVim" Finder droplet generator → **S12** (it *queries* your
  filetype registry headlessly; it doesn't modify nvim).
- LazyVim/Mason/Harper/blink/etc. are external plugins — you own the *config
  specs*, not the plugins themselves.

## Contracts you must preserve

- **Filetype registry** — `vim.filetype.add` patterns (`.json.tmpl`→
  `json.gotmpl`, `Brewfile.tmpl`→`ruby.gotmpl`, etc.) and
  `vim.filetype.inspect().extension`. The S12 "Open in NeoVim" app generator
  queries this headlessly to build Finder UTI lists. Adding/removing filetype
  mappings changes Finder's "Open With" coverage.
- **SSH clipboard client** (`lua/config/options.lua`): `vim.g.clipboard`
  custom paste reads `~/.clipboard-bridge.sock` via `nc -U`; copy uses OSC 52.
  Gated to SSH. The socket path + `nc -U` read protocol are the seam with
  S1/S8b.
- **Chezmoi auto-apply** (`lua/config/autocmds.lua`): `BufReadPre` redirect →
  `chezmoi-reverse --no-merge` (S13); `BufWritePost` debounced (5s)
  `chezmoi apply --force`; `VimLeavePre` flush. Depends on
  `chezmoi-reverse`'s `needs-merge` exit semantics (S13).
- **Harper shared dictionary**: `spell/en.utf-8.add` is chezmoi
  `create_`-prefixed (apply never reverts). The `uv.new_fs_event` watcher +
  `workspace/didChangeConfiguration` ping to harper-ls.
- **gotmpl treesitter injection**: `after/queries/gotmpl/injections.scm` +
  custom `inject-inner-ft!` directive.
- **lualine `dynamic-fqn`** uses `lua/utils/path.lua`, also consumed by Snacks
  `yank_path` — keep the `utils.path` API stable.

## What you consume read-only

- S13: `chezmoi-reverse --no-merge` (emits `needs-merge`)
- S1/S8b: `~/.clipboard-bridge.sock`, OSC 52 via WezTerm
- S12: `chezmoi apply`
- External: LazyVim, Mason, harper-ls, blink.cmp, opencode.nvim

## Where to start

`lua/config/options.lua`, `lua/config/autocmds.lua`, `lua/plugins/`.

## TASK

> _<describe the assignment — e.g. "Investigate the chezmoi auto-apply
> debounce: AutoSave bursts sometimes cause duplicate applies" >_

**Verify before claiming done:**
- Reproduce in a real nvim session (don't rely on `:checkhealth` alone).
- If you touch filetype mappings, confirm the S12 app generator's headless
  query still works (`vim.filetype.inspect().extension`).
- The SSH clipboard gating must stay local-vs-SSH correct.
- Your diff stays within `home/dot_config/nvim/`.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S2.
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #26–#37.
