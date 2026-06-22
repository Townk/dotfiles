---
description: Dispatch an agent to the pick framework + symbols pickers silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **pick framework + symbols pickers** silo of this
chezmoi dotfiles repo.

> The from-scratch fzf picker engine (`pick::*`) that standardizes every
> fuzzy picker, plus the symbols.db-backed glyph/gitmoji pickers. The single
> largest custom subsystem; consumed by terminal-mux and ai-harnesses.

## Your scope (owner area — safe to edit)

- `home/dot_local/lib/pick-common.zsh` (`pick::*`), `pick.jq`
- `home/dot_local/lib/pick-symbols-common.zsh` (`pick_symbols::*`)
- `home/dot_local/libexec/executable_pick-list`, `pick-glyph`, `pick-gitmoji`

## Out of scope (do not edit — owned by other silos)

- `zj::pick` (the Zellij floating adapter) → **terminal-mux** (it's a thin
  drop-in that *calls* `pick-list`/`pick::start`).
- The Zellij modal adapters `pick-{glyph,gitmoji}-zellij` → **terminal-mux**.
- The `symbols.db` *builder* → **custom-builds**. You read the DB; you don't
  build it.
- Consumers in **ai-harnesses** (`ai-assist`/`ai-commit` pickers) and
  **terminal-mux** (`quick-launch-pick`) — they call
  `pick::start`/`zj::pick`.
- `home/dot_local/lib/common.zsh` → **shell**/**utils** (you source it
  read-only for `require_cmd`/`die`).

## Contracts you must preserve

These are load-bearing for ≥3 silos (**terminal-mux**, **ai-harnesses**, and
the glyph/gitmoji pickers):

- **`pick::start [flags] LINES_CACHE_OR_STDIN`** — the core entry. Flags
  include `--cache-usage` (recency), `--cache-state`/`--resume` (cursor
  restore), `--selector`/`--selector-shortcuts`/`--selector-nav`,
  `--key-background` (insert-without-dismiss FIFO broker),
  `--key-output <key>:<kind>:<field>`, `--multi[=SEP]`, `--copy-only`,
  `--on-items-picked <cmd>`, `--output`, `--name`. Also `pick::line`,
  `pick::run`, `pick::feed`, `pick::clipboard`, `pick::record`.
- **Wire format** (shared with `pick.jq`): each line
  `<visible>\x1f<tail[0]>\x1e<tail[1]>…`. US (`\x1f`) splits the ANSI-colored
  visible display (fzf renders via `--with-nth=1`) from the hidden plain-text
  tail; RS (`\x1e`) splits tail fields. Last tail field = raw glyph by
  convention (so ANSI never leaks to stdout). `pick.jq` defines the canonical
  Catppuccin SGR sequences + `emit_line`.
- **Recency**: file-based for non-DB pickers (`--cache-usage`), SQLite
  `last_used` via `--on-items-picked` for DB pickers.
- **`PICK_INJECT_PANE` / `PICK_INJECT_ZELLIJ`** env — the `--key-background`
  FIFO broker injects into these.
- **`PICK_GLYPH_DB`** env (default
  `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`) — the DB
  path contract with **custom-builds**.

## What you consume read-only

- **custom-builds**: `symbols.db` at `PICK_GLYPH_DB` (schema owned by
  custom-builds — if you need new columns, coordinate with custom-builds)
- **shell**: `common.zsh` stdlib
- **terminal-mux**: `zj::pick` adapter, `zellij-modal --capture` FIFO for
  floating pickers

## Where to start

`pick-common.zsh` (`pick::start` at ~line 650), `pick.jq`, `libexec/pick-glyph`.

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
git worktree add -b work-on-pick-$suffix "$WT_ROOT/work-on-pick-$suffix" "$base"
cd "$WT_ROOT/work-on-pick-$suffix"
```

## TASK

$ARGUMENTS

## Validate & integrate
- **Self-test (logic):** sandbox-`$HOME` per `docs/silo-commands/validate.md`
  (Mode A) — parallel, no lock, no clobber of real `$HOME`.
- **Human UX validation:** if the work needs eyeball judgment, ask the user
  whether to enter a UX session, then follow `docs/silo-commands/validate.md`
  (Mode B) — the session merges your branch to master and you iterate live.
- **Integrate (non-UX work):** follow `docs/silo-commands/reconcile.md` —
  `flock`-gated, on-demand `master-work`, ff-only automated / divergence
  human-gated, `make test` under the lock.

## Verify before claiming done
- Run the relevant ShellSpec: `make test` (covers the `lib/` primitives).
- Reproduce with a real picker (e.g. `Ctrl+Shift+u` glyph picker in Zellij,
  or `pick-list` standalone).
- The wire format (`\x1f`/`\x1e`) and `pick::start` flag set are a public
  contract — confirm **terminal-mux**'s `quick-launch-pick` and
  **ai-harnesses**' `ai-assist`/`ai-commit` pickers still work unchanged.
- Your diff stays within the owner area above.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "pick framework + symbols pickers" section —
note the pick↔custom-builds symbols.db schema contract, the tightest
cross-silo seam).
