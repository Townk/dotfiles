# Silo Prompt Templates

Ready-to-use prompts for dispatching an agent to work on one bounded area
("silo") of this dotfiles repo without stepping on other agents working in
parallel.

## How to use

1. **Make a fresh worktree per agent** (never share worktrees — chezmoi renders
   and edits would interleave):
   ```sh
   git worktree add ../<silo-name>-work master
   ```
2. **Open the silo file you need** (e.g. `s08-system-management.md`), copy its
   contents, fill in the **TASK** section, and hand it to an agent. The prompt
   is self-contained — a cold agent that hasn't seen your conversation gets
   enough context to work safely.
3. **For the two example use cases**:
   - "Review the system packages manager for performance improvements" →
     `s08-system-management.md` (it scopes you to sub-silo **S8a**).
   - "The font custom build is too slow, investigate" →
     `s05-custom-builds.md`.
4. **Verify after**: an agent's diff should be confined to its owner area + (at
   most) its own run-script in `.chezmoiscripts/`. Run `make test` (ShellSpec)
   for any `home/dot_local/lib/` change.

## What each prompt contains

Every template carries, inline, so the agent doesn't *have* to read the
reference docs to start safely:

- **Setup** — repo path, worktree command, branch.
- **Your scope (owner area)** — the exact files/globs the agent may edit.
- **Out of scope (do not edit)** — files that belong to other silos.
- **Contracts you must preserve** — the load-bearing seams other silos depend
  on. Breaking these silently breaks other agents' work.
- **What you consume read-only** — deps the agent may call but not modify.
- **Where to start** — the best entry-point files for an investigation.
- **TASK** — a placeholder for the specific assignment, plus how to verify.
- **Reference** — pointers to the full detail in the two reference docs.

## Silo index

| File | Silo | One-line purpose |
|------|------|------------------|
| `s01-terminal-mux.md` | S1 | WezTerm/Ghostty/Zellij integration & cross-tool bridges |
| `s02-neovim.md` | S2 | LazyVim config + custom autocmds/plugins |
| `s03-hammerspoon.md` | S3 | macOS automation: keybindings, Stream Deck, OSD, controls |
| `s04-pick-framework.md` | S4 | `pick::` fzf picker engine + symbols pickers |
| `s05-custom-builds.md` | S5 | Custom Nerd Font, symbols.db, non-unicode9 zsh builds |
| `s06-ai-harnesses.md` | S6 | `ai-assist` / `ai-commit` multi-harness agent dispatchers |
| `s07-secrets.md` | S7 | Leak-safe slot-based secrets + machine onboarding |
| `s08-system-management.md` | S8 | package/service/image sync + update orchestrator (sub-silos S8a–S8d) |
| `s09-shell.md` | S9 | zsh bootstrap, ZLE widgets, `common.zsh`/`prompt::*`/`platform::*` |
| `s10-preview-viewers.md` | S10 | `preview` engine + terminal "card" viewers |
| `s11-yazi.md` | S11 | Yazi config + custom plugins |
| `s12-chezmoi-orchestration.md` | S12 | `.setup.sh`, `.chezmoiscripts/`, run-script ordering & hash triggers |
| `s13-utilities.md` | S13 | `notify`, `wait-until`, `chezmoi-reverse`, `tab-edit`, `common.zsh` |

## Parallel safety

Before running two agents concurrently, check the collision matrix in
[`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) ("Concurrency & collision
matrix"). The headline hazards:

- **`home/dot_config/zsh/functions.d/widgets.sh`** is shared by S6 and S9
  (both have widgets there) — serialize S6↔S9, or split the file first.
- **`home/dot_local/lib/common.zsh`** and
  **`home/dot_config/packages/services.toml.tmpl`** are shared coordination
  points — any new shared primitive or service entry is a merge point.
- **S8a and S5** (the two example dispatches) share no owner files and are
  safe to run concurrently.

## Reference docs

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — full silo &
  integration-point map, contracts, and the concurrency/collision matrix.
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — the
  90-feature evidence catalog the silos were derived from.
