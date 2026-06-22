---
description: Dispatch an agent to the NeoVim config silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **NeoVim config** silo of this chezmoi dotfiles repo.

> LazyVim-based config with custom autocmds/plugins: chezmoi source-redirect
> + debounced auto-apply, gotmpl compound filetype + treesitter injection,
> SSH clipboard client, Unicode-escape hints, Harper spell integration,
> markdown list-wrap fix, self-authored smart-comment-wrap, custom lualine.

## Your scope (owner area — safe to edit)

- `home/dot_config/nvim/` — `init.lua`, `lua/config/{options,autocmds,keymaps,lazy}.lua`,
  `lua/plugins/*.lua`, `lua/lualine/`, `lua/utils/*.lua`, `after/`,
  `local-plugins/smart-comment-wrap/`, `spell/`, `lazyvim.json`,
  `lazy-lock.json`, `dot_luarc.json`, `dot_editorconfig`

## Out of scope (do not edit — owned by other silos)

- `chezmoi-reverse` binary → **utils** silo (you *call* it via `BufReadPre`).
- The `clipboard-bridge` service + WezTerm OSC 52 paste path → **terminal-mux**
  / **system-services** silos (you *consume* the socket).
- The "Open in NeoVim" Finder droplet generator → **chezmoi** silo (it *queries*
  your filetype registry headlessly; it doesn't modify nvim).
- LazyVim/Mason/Harper/blink/etc. are external plugins — you own the *config
  specs*, not the plugins themselves.

## Contracts you must preserve

- **Filetype registry** — `vim.filetype.add` patterns (`.json.tmpl`→
  `json.gotmpl`, `Brewfile.tmpl`→`ruby.gotmpl`, etc.) and
  `vim.filetype.inspect().extension`. The **chezmoi** silo's "Open in NeoVim"
  app generator queries this headlessly to build Finder UTI lists.
  Adding/removing filetype mappings changes Finder's "Open With" coverage.
- **SSH clipboard client** (`lua/config/options.lua`): `vim.g.clipboard`
  custom paste reads `~/.clipboard-bridge.sock` via `nc -U`; copy uses OSC 52.
  Gated to SSH. The socket path + `nc -U` read protocol are the seam with
  **terminal-mux** / **system-services**.
- **Chezmoi auto-apply** (`lua/config/autocmds.lua`): `BufReadPre` redirect →
  `chezmoi-reverse --no-merge` (**utils**); `BufWritePost` debounced (5s)
  `chezmoi apply --force`; `VimLeavePre` flush. Depends on
  `chezmoi-reverse`'s `needs-merge` exit semantics (**utils**).
- **Harper shared dictionary**: `spell/en.utf-8.add` is chezmoi
  `create_`-prefixed (apply never reverts). The `uv.new_fs_event` watcher +
  `workspace/didChangeConfiguration` ping to harper-ls.
- **gotmpl treesitter injection**: `after/queries/gotmpl/injections.scm` +
  custom `inject-inner-ft!` directive.
- **lualine `dynamic-fqn`** uses `lua/utils/path.lua`, also consumed by Snacks
  `yank_path` — keep the `utils.path` API stable.

## What you consume read-only

- **utils**: `chezmoi-reverse --no-merge` (emits `needs-merge`)
- **terminal-mux** / **system-services**: `~/.clipboard-bridge.sock`, OSC 52
  via WezTerm
- **chezmoi**: `chezmoi apply`
- External: LazyVim, Mason, harper-ls, blink.cmp, opencode.nvim

## Where to start

`lua/config/options.lua`, `lua/config/autocmds.lua`, `lua/plugins/`.

## Setup — branch from the freshest master tip into an isolated worktree
```sh
# 1. Learn what origin has. Updates origin/master only — does NOT move local
#    master or touch any other worktree. Safe to run anytime.
git fetch origin master

# 2. Find the freshest master tip, wherever it lives.
ahead=$(git rev-list --count master..origin/master)
behind=$(git rev-list --count origin/master..master)
if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
  echo "master and origin/master diverged ($ahead ahead, $behind behind)." >&2
  echo "Reconcile master before dispatching. Stopping." >&2
  exit 1
elif [ "$ahead" -gt 0 ]; then
  base=origin/master
else
  base=master
fi

# 3. Unique-suffixed branch in a fresh worktree, rooted under chezmoi's
#    state dir (XDG-respecting, matches the repo's environment.sh). The
#    suffix lets two agents work this same silo concurrently without
#    colliding on the branch name. Never check out master itself.
WT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees"
mkdir -p "$WT_ROOT"
suffix=$(date +%s)
git worktree add -b work-on-neovim-$suffix "$WT_ROOT/work-on-neovim-$suffix" "$base"
cd "$WT_ROOT/work-on-neovim-$suffix"
```

## TASK

$ARGUMENTS

## Validate & integrate
- **Self-test (logic):** load the `validate` skill (Agent Skill — invoke
  `/skill:validate` in pi, `/validate` in Claude Code, or read its `SKILL.md`)
  and run **Mode A** — sandbox-`$HOME`, parallel, no lock, no clobber of real
  `$HOME`.
- **Human UX validation:** if the work needs eyeball judgment, ask the user
  whether to enter a UX session, then load the `validate` skill and run
  **Mode B** — the session merges your branch to master and you iterate live.
- **Integrate (non-UX work):** load the `reconcile` skill and follow it —
  `flock`-gated, on-demand `master-work`, ff-only automated / divergence
  human-gated, `make test` under the lock.

## Verify before claiming done
- Reproduce in a real nvim session (don't rely on `:checkhealth` alone).
- If you touch filetype mappings, confirm the **chezmoi** silo's app
  generator headless query still works (`vim.filetype.inspect().extension`).
- The SSH clipboard gating must stay local-vs-SSH correct.
- Your diff stays within `home/dot_config/nvim/`.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "NeoVim config" section).
