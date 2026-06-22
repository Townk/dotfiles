# Silo slash-commands

`/work-on-<silo>` slash commands for dispatching an agent to work on one
bounded area ("silo") of this dotfiles repo without stepping on other agents
working in parallel. Each command is a self-contained brief a cold agent can
work from — scope, contracts to preserve, read-only deps, entry points, and a
verify checklist are all inline.

The same files serve both **pi** and **Claude Code** via symlinks (see
[Sharing mechanism](#sharing-mechanism) below). No silo codes (`S01`, `S8a`,
etc.) appear in the templates — the command name is the only identifier.

## How to use

1. **Type `/work-on-<silo> <task>`** in pi or Claude Code (run from this repo's
   root). The template expands to the full silo brief with your `<task>`
   dropped into the TASK section via `$ARGUMENTS`.
2. **The Setup block runs first** — it fetches origin, picks the freshest
   master tip, and creates an isolated, uniquely-suffixed worktree under
   `$WT_ROOT` (see below). Never share worktrees; never check out `master`
   directly in a working agent tree.
3. **Validate & integrate** per the template's pointers:
   - **Self-test (logic):** sandbox-`$HOME` per [`validate.md`](validate.md)
     (Mode A) — parallel, no lock, no clobber of real `$HOME`.
   - **Human UX validation:** if the work needs eyeball judgment, the agent
     asks whether to enter a UX session, then follows [`validate.md`](validate.md)
     (Mode B) — the session merges your branch to master and you iterate live.
   - **Integrate (non-UX work):** follow [`reconcile.md`](reconcile.md) —
     `flock`-gated, on-demand `master-work`, ff-only automated / divergence
     human-gated, `make test` under the lock.
4. **Verify after**: an agent's diff should be confined to its owner area + (at
   most) its own run-script in `.chezmoiscripts/`. Run `make test` (ShellSpec)
   for any `home/dot_local/lib/` change.

## What each command contains

Every template carries, inline, so the agent doesn't *have* to read the
reference docs to start safely:

- **Setup** — fetch origin, pick freshest master, create a uniquely-suffixed
  worktree under `$WT_ROOT`.
- **Your scope (owner area)** — the exact files/globs the agent may edit.
- **Out of scope (do not edit)** — files that belong to other silos.
- **Contracts you must preserve** — the load-bearing seams other silos depend
  on. Breaking these silently breaks other agents' work.
- **What you consume read-only** — deps the agent may call but not modify.
- **Where to start** — the best entry-point files for an investigation.
- **TASK** — `$ARGUMENTS` (your task description, interpolated by the slash
  command).
- **Validate & integrate** — one-line pointers to `validate.md` / `reconcile.md`.
- **Verify before claiming done** — the per-silo verification checklist.
- **Reference** — pointers to the full detail in the two reference docs.

## Command index

| Command | Domain | One-line purpose |
|---------|--------|------------------|
| `/work-on-terminal-mux` | terminal & multiplexer integration | WezTerm/Ghostty/Zellij integration & cross-tool bridges |
| `/work-on-neovim` | NeoVim config | LazyVim config + custom autocmds/plugins |
| `/work-on-hammerspoon` | Hammerspoon | macOS automation: keybindings, Stream Deck, OSD, controls |
| `/work-on-pick` | pick framework + symbols pickers | `pick::` fzf picker engine + symbols pickers |
| `/work-on-custom-builds` | custom builds | Custom Nerd Font, symbols.db, non-unicode9 zsh builds |
| `/work-on-ai-harnesses` | AI agent harnesses | `ai-assist` / `ai-commit` multi-harness agent dispatchers |
| `/work-on-secrets` | secrets & onboarding | Leak-safe slot-based secrets + machine onboarding |
| `/work-on-system-packages` | system packages | package sync (brew/cargo/go/npm/snap/uv) |
| `/work-on-system-services` | system services | launchd+brew service manager, `services.toml` |
| `/work-on-system-images` | system disk images | APFS sparse disk-image manager |
| `/work-on-system-update` | system update orchestrator | "everything at latest" update orchestrator |
| `/work-on-shell` | shell (zsh) bootstrap & widgets | zsh bootstrap, ZLE widgets, `common.zsh`/`prompt::*`/`platform::*` |
| `/work-on-preview` | file preview & terminal viewers | `preview` engine + terminal "card" viewers |
| `/work-on-yazi` | Yazi | Yazi config + custom plugins |
| `/work-on-chezmoi` | chezmoi orchestration & run-scripts | `.setup.sh`, `.chezmoiscripts/`, run-script ordering & hash triggers |
| `/work-on-utils` | cross-cutting utilities | `notify`, `wait-until`, `chezmoi-reverse`, `tab-edit`, `common.zsh` |

The four `/work-on-system-*` commands are sub-silos of the system management
area. There is intentionally no `/work-on-system` umbrella — always dispatch
via the specific sub-silo.

## Worktree root

All worktree checkouts live under:
```
${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees/
```
This co-locates git worktrees inside chezmoi's *state* dir (not the *source*
dir); safe because chezmoi only stores its own state files (`.sig`/hash/bolt
files) there and never scans a `worktrees/` subdir. Worktree checkout paths
are machine-local and never committed. Each template's Setup block defines
`WT_ROOT` and `mkdir -p`s it.

## Parallel safety

Before running two agents concurrently, check the collision matrix in
[`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) ("Concurrency & collision
matrix"). The headline hazards (using command names, not codes):

- **`home/dot_config/zsh/functions.d/widgets.sh`** is shared by
  `/work-on-ai-harnesses` and `/work-on-shell` (both have widgets there) —
  serialize them, or split the file first.
- **`home/dot_local/lib/common.zsh`** and
  **`home/dot_config/packages/services.toml.tmpl`** are shared coordination
  points — any new shared primitive or service entry is a merge point.
- The `/work-on-system-*` sub-silos share `system-package-common.zsh`
  (`pkg::*`). Parallel within system-management only if no agent edits
  `pkg::*`; otherwise serialize the lib edit.
- `/work-on-system-packages` and `/work-on-custom-builds` share no owner
  files and are safe to run concurrently.

## Concurrency model — the two `flock` lockfiles

- **`silo-integration.lock`** — held by the [`reconcile.md`](reconcile.md)
  procedure; spans create `master-work` → merge → `make test` → rollback-or-
  cleanup → remove `master-work`.
- **`silo-ux-session.lock`** — held by a UX session
  ([`validate.md`](validate.md) Mode B); spans session-start merge → live
  iteration → done cleanup.

Each procedure non-block-attempts the *other* lock before proceeding and
fails-and-reports if held (no silent multi-hour blocking). `flock` is provided
by Homebrew's `util-linux` (keg-only on macOS — the procedures resolve its
path via `command -v flock || brew --prefix util-linux`). The lockfiles live
under the chezmoi state dir at
`${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/locks/` (machine-local runtime
locks, not repo content) and are never unlinked — unlinking a flock lockfile
breaks mutual exclusion under concurrency.

## Sharing mechanism — pi + Claude Code

Each canonical template lives once in this `docs/silo-commands/` directory and
is symlinked into both tools' prompt directories:

```
docs/silo-commands/work-on-<silo>.md            ← canonical source (committed)
.pi/prompts/work-on-<silo>.md                   → ../../docs/silo-commands/work-on-<silo>.md
.claude/commands/work-on-<silo>.md              → ../../docs/silo-commands/work-on-<silo>.md
```

Relative symlink targets keep them valid inside any `git worktree` checkout.
Both `.pi/prompts/` and `.claude/commands/` are gitignored-free, so the
symlinks commit normally; chezmoi ignores dot-prefixed dirs, so no
`chezmoi apply` is needed for the symlinks themselves. The templates use only
the pi/Claude-Code **compatibility subset** (`description` + `argument-hint`
frontmatter, `$ARGUMENTS`, markdown body) — no tool-specific features.

### Skills sharing mechanism — pi + Claude Code

`reconcile` and `validate` are **Agent Skills** (a directory with a
`SKILL.md` carrying `name` + `description` frontmatter), not slash-command
prompt templates. Each canonical skill directory lives once in
`docs/silo-commands/` and is symlinked into both tools' skill directories so
pi auto-discovers it under `.pi/skills/` and Claude Code auto-discovers it
under `.claude/skills/` (where it also exposes a `/reconcile` / `/validate`
command):

```
docs/silo-commands/reconcile/SKILL.md          ← canonical skill (committed)
docs/silo-commands/validate/SKILL.md            ← canonical skill (committed)
.pi/skills/reconcile      → ../../docs/silo-commands/reconcile
.pi/skills/validate       → ../../docs/silo-commands/validate
.claude/skills/reconcile  → ../../docs/silo-commands/reconcile
.claude/skills/validate   → ../../docs/silo-commands/validate
```

A compat symlink at each old path —
`docs/silo-commands/reconcile.md → reconcile/SKILL.md` (and `validate.md`)
— keeps the `follow docs/silo-commands/<name>.md` references in the
`work-on-<silo>.md` templates (and the links in this README) resolving to the
canonical skill content, so the templates didn't need editing. The skill
directory name matches the `name` frontmatter field, as the Agent Skills
standard (and Claude Code) requires; pi is lenient about that but the match
is kept for portability. `tests/silo-skills_spec.sh` pins this contract.

## Reference docs

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — full silo &
  integration-point map, contracts, and the concurrency/collision matrix.
  (Still keyed by `SNN` codes internally — a follow-up will purge those once
  the `/work-on-*` names are established as the canonical IDs.)
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — the
  90-feature evidence catalog the silos were derived from.
- [`reconcile.md`](reconcile.md) — the `flock`-gated integration procedure
  (now an Agent Skill: `reconcile/SKILL.md`; `reconcile.md` is a compat
  symlink).
- [`validate.md`](validate.md) — sandbox self-test (Mode A) + agent-initiated
  UX session (Mode B) (now an Agent Skill: `validate/SKILL.md`; `validate.md`
  is a compat symlink).
