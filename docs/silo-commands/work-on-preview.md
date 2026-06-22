---
description: Dispatch an agent to the file preview & terminal viewers silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **file preview & terminal viewers** silo of this
chezmoi dotfiles repo.

> The universal `preview` backend for fzf/Yazi, plus the stdlib-Python "card"
> viewers for iCalendar / SQLite / macOS disk images.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_preview` (15K),
  `executable_fzf-tab-preview-open`
- `home/dot_local/libexec/executable_ics-view`, `sqlite-view`,
  `disk-image-view` (Python stdlib)

## Out of scope (do not edit — owned by other silos)

- `home/dot_local/lib/image-protocol-support.zsh` → **terminal-mux** (you
  *source* it read-only and call `get_terminal_image_protocol()`). If you
  need a new protocol capability, hand that request to **terminal-mux** —
  don't edit it here.
- Yazi's previewer *wiring* → **yazi** (**yazi** calls `preview`/the libexec
  viewers; you own the viewers themselves).
- fzf, bat, chafa, mediainfo, ouch, rich, hexyl, figlet (external).

## Contracts you must preserve

- **`preview` as the universal `--preview` backend** — invoked by fzf
  (`FZF_DEFAULT_OPTS`) and Yazi. Routing order: pre-guards
  (empty/dir/missing/zero-byte) → by-extension (`.ipynb` despite json MIME,
  csv/md/json/yaml/xml/ics/sqlite/archive/pdf) → by-MIME (image via
  chafa/Kitty graphics, audio/video via mediainfo, disk images) → binary
  hexdump → `bat`. Lives as a *script* (not a zsh function) so fzf's
  non-interactive preview subshell finds it via PATH.
- **`stamp-msg()`** figlet banners (custom `phm-minecraft.flf` font,
  true-footprint measurement, plain-text fallback on overflow).
- **libexec viewer contract**: stdin = file path, stdout = rendered card;
  rounded Unicode box-drawing, Catppuccin Mocha truecolor, Nerd Font icons.
  Consumed by `preview` and Yazi (**yazi**).

## What you consume read-only

- **terminal-mux**: `get_terminal_image_protocol()` (Kitty/iTerm2/Sixel
  constrained through Zellij)
- External: bat/chafa/mediainfo/ouch/rich/hexyl/figlet

## Where to start

`home/dot_local/bin/executable_preview`, `libexec/{ics,sqlite,disk-image}-view`.

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
git worktree add -b work-on-preview-$suffix "$WT_ROOT/work-on-preview-$suffix" "$base"
cd "$WT_ROOT/work-on-preview-$suffix"
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
- Reproduce with a real `preview <file>` invocation and via fzf's `--preview`.
- If you add a viewer, follow the libexec viewer contract (stdin path →
  stdout card, Catppuccin styling) so Yazi (**yazi**) picks it up unchanged.
- `image-protocol-support.zsh` (**terminal-mux**) is read-only — call
  `get_terminal_image_protocol`, don't modify it.
- Your diff stays within the owner area above.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "file preview & terminal viewers" section).
