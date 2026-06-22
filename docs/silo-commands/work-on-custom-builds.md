---
description: Dispatch an agent to the custom builds silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **custom builds** silo of this chezmoi dotfiles repo.

> The custom Symbols Nerd Font builder (~2740 lines), the `symbols.db`
> generator (~46K Python), and the non-unicode9 zsh build. Exists to fix
> terminal rendering bugs the upstreams won't (FA version lag, post-2016
> emoji widths).

## Your scope (owner area — safe to edit)

- `custom-builds/nerd-fonts/` — `build-updated-font.sh`, `recalibrate-fa.sh`,
  `custom-icons/*.{svg,metadata.json}`, `unicode-donor-glyphs.txt`,
  `symbols-db/build-symbols-db.py` + `README.md`
- `custom-builds/zsh/` — `build-zsh.sh` + `README.md`

The **build-trigger chezmoiscripts** live in the **chezmoi** silo
(`run_onchange_after_70-symbols-nerd-font`, `run_onchange_after_60-symbols-db`,
`run_after_80-symbols-nerd-font-prompt`, `run_onchange_after_50-custom-build-zsh`).
The *trigger logic* (hash-baked fingerprints) is **chezmoi**; the *builder*
is this silo. If you need to change what inputs trigger a rebuild, coordinate
with **chezmoi**.

## Out of scope (do not edit — owned by other silos)

- Font *consumers*: **terminal-mux**'s WezTerm `font_with_fallback` chain +
  Ghostty `font-codepoint-map`, **hammerspoon**'s OSD glyph rendering — they
  reference built artifacts by family name/path; you only owe them a stable
  artifact path + format.
- The pickers (**pick**) read `symbols.db` — you owe them a stable schema.
- chezmoi run-scripts under `home/.chezmoiscripts/` → **chezmoi**.

## Contracts you must preserve

- **`symbols.db`** at `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`
  — single flat `symbols` table, one row per symbol, faceted columns (primary
  shortcode by source priority `gitmoji>github>slack>emoticon`,
  `extra_shortcodes`, `source_keys`, `keywords`, `tags`, `last_used`). Schema
  is consumed read-only by **pick** (`pick-glyph`/`pick-gitmoji`) and
  **hammerspoon** (OSD `glyph:` resolver). **Schema changes require
  coordinating pick.**
- **Renderability probe**: `wezterm ls-fonts --text` oracle (drops `.notdef`),
  CoreText fallback; verdicts cached under `$XDG_CACHE_HOME/symbols-db/`.
  Re-running preserves `last_used`.
- **Patched font artifacts**: the Symbols Nerd Font (and the JetBrains-Mono
  NF for Blink) installed to the user font dir; the Blink CSS (embedded fonts
  + Noto OT-SVG). **terminal-mux**'s font chains reference these by family
  name; the custom-icons `code` pins in `metadata.json` must stay stable
  (**terminal-mux**/**hammerspoon** glyph lookups depend on them).
- **Custom `zsh`** at `~/.local/opt/zsh` + symlink `~/.local/bin/zsh`,
  registered in `/etc/shells` + `chsh`. Built *without* `--enable-unicode9`.
  macOS work/personal only (template-gated).

## What you consume read-only

- **chezmoi**: chezmoi `run_onchange` triggers + the hash-baked fingerprints
- Upstream: zsh source, Font Awesome, Nerd-Fonts patcher, `wezterm ls-fonts`
  (oracle)

## Where to start

`custom-builds/nerd-fonts/build-updated-font.sh`,
`custom-builds/nerd-fonts/symbols-db/build-symbols-db.py`,
`custom-builds/zsh/build-zsh.sh`.

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
git worktree add -b work-on-custom-builds-$suffix "$WT_ROOT/work-on-custom-builds-$suffix" "$base"
cd "$WT_ROOT/work-on-custom-builds-$suffix"
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
- Actually run the build end-to-end and time it (`chezmoi apply` with the
  font/DB markers triggered, or invoke the builder directly).
- Confirm the output contract: `symbols.db` still opens and its schema is
  unchanged (**pick** pickers still work); the patched font family name +
  custom-icon `code` pins are unchanged (**terminal-mux** font chain still
  resolves glyphs).
- Don't commit built artifacts (they're gitignored / outside the repo).
- Your diff stays within `custom-builds/` (coordinate **chezmoi** if a
  trigger hash must change).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "custom builds" section — custom-builds↔pick
schema contract, custom-builds↔terminal-mux font-pin contract).
