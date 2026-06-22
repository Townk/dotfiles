---
description: Dispatch an agent to the cross-cutting utilities silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **cross-cutting utilities** silo of this chezmoi
dotfiles repo.

> The shared coordination silo: `notify` (the Hammerspoon-OSD sender),
> `wait-until` (standalone POSIX-sh polling), `chezmoi-reverse`
> (destination→source drift propagation), `tab-edit` (multiplexer-aware
> nvim launcher), and the `common.zsh` stdlib + `platform::*` shared with
> shell.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_notify` (front-end),
  `executable_wait-until` (standalone POSIX sh),
  `executable_chezmoi-reverse`, `executable_tab-edit`
- `home/dot_local/lib/common.zsh` (`notify` primitive, stdlib) — **shared
  with shell**
- `home/dot_local/lib/platform.zsh` + `platform-{macos,linux}.zsh` —
  **shared with shell**
- `home/dot_local/libexec/local-llm-gateway`, `local-llm-bench`,
  `pinentry-auto` (libexec, reached by absolute path)

## Out of scope (do not edit — owned by other silos)

- The `hs` CLI *receivers* (`notify`/`notifyAnsi` globals) → **hammerspoon**.
- The Zellij session resolver (`resolve_session`) that `tab-edit` calls →
  **terminal-mux**.
- The chezmoi apply machinery that `chezmoi-reverse` cooperates with →
  **chezmoi**.
- The `symbols.db` that `glyph:` icons resolve against → **custom-builds**.

## Contracts you must preserve

- **`notify [--icon SPEC] [--sound NAME] [--ansi] MESSAGE...`** — SPEC = SVG
  name / `glyph:<nerd-font-name>` / `swatch:#RRGGBB`. The *primitive* in
  `common.zsh` is best-effort (silent on missing `hs`); the *bin* is a
  hard-error front-end. Serializes args as Lua string literals to `hs -c`.
  `gtimeout`-capped. Consumed on hot paths (**terminal-mux** `copy-pwd`).
- **`chezmoi-reverse [--no-merge] [--] <file>...`** — destination→source
  propagation. `--no-merge` emits `needs-merge` (per-file tabular status:
  `clean`/`applied`/`merged`/`needs-merge`/`skipped`/`failed`) instead of
  interactive `chezmoi merge`. Skips `encrypted_*`/`run_*`/`symlink_*`/
  `modify_*`. **Consumed by neovim's nvim autocmd** — the `needs-merge` exit
  semantics are the seam.
- **`tab-edit`** — opens files in nvim inside the focused Zellij session
  (resolves pane TTY → Zellij client → session via **terminal-mux**'s
  `resolve_session`), falls back to bare WezTerm. Tab title + CWD=git root.
  Engine behind the **chezmoi** Finder droplet + Linux desktop handler.
- **`wait-until [--timeout 2s] [--interval 0.1] [--quiet] -- CMD...`** —
  standalone POSIX sh, polls before first sleep. Any caller can `exec` it.
- **`platform::*`** — see **shell**; shared lib.

## What you consume read-only

- **terminal-mux**: `resolve_session` for `tab-edit`
- **hammerspoon**: `hs` CLI for `notify`
- **custom-builds**: `symbols.db` for `glyph:` icons
- chezmoi: for `chezmoi-reverse`

## Where to start

`home/dot_local/bin/notify`, `bin/chezmoi-reverse`, `bin/tab-edit`,
`home/dot_local/lib/common.zsh`.

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
git worktree add -b work-on-utils-$suffix "$WT_ROOT/work-on-utils-$suffix" "$base"
cd "$WT_ROOT/work-on-utils-$suffix"
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
- Run `make test` (ShellSpec covers `common.zsh` primitives, `for_each`,
  `wait-until`, `platform::*`; `tests/chezmoi-reverse_spec.sh` needs
  `chezmoi` on PATH).
- `notify`'s `--icon`/`--sound`/`--ansi` contract and the `hs` literal
  serialization unchanged (**terminal-mux** hot-path `copy-pwd` depends on
  it).
- `chezmoi-reverse`'s `--no-merge` → `needs-merge` status contract unchanged
  (**neovim**'s nvim `BufReadPre` autocmd depends on it).
- `common.zsh` + `platform*.zsh` are shared with **shell** — if you add a
  primitive, follow the `bare = stdlib, `::` = module` convention and confirm
  **shell**'s consumers aren't broken.
- Your diff stays within the owner area above.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "cross-cutting utilities" section —
utils↔shell `common.zsh` sharing, utils↔neovim `chezmoi-reverse` seam).
