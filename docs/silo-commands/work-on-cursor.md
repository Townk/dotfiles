---
description: Dispatch an agent to the Cursor coding agent config silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **Cursor coding agent config** silo of this chezmoi
dotfiles repo.

> Cursor (AI coding agent) config: custom subagents
> (architect/librarian/reviewer), shared-skill adapters, and a global
> `alwaysApply` MDC baseline rule
> ("Verify, don't assume"). The parallel of `dot_pi/` for Cursor.

## Your scope (owner area — safe to edit)

- `home/dot_cursor/agents/{architect,librarian,reviewer}.md` — custom
  subagent definitions
- `home/dot_cursor/skills/*/symlink_SKILL.md.tmpl` — adapters to portable
  skills canonically stored under `home/dot_config/agent-skills/`
- `home/dot_cursor/rules/baseline.mdc` — global baseline behavior rule
  (Cursor `.cursor/rules` MDC format: markdown body + YAML frontmatter
  `description` / `alwaysApply: true`)

## Out of scope (do not edit — owned by other silos)

- `home/dot_local/bin/ai-assist-cursor`, `ai-commit-cursor`,
  `home/dot_local/lib/{assist,commit}-agent-common.zsh` → **AI agent
  harnesses**. Its wrappers CALL cursor; you own the agent's own
  config. Treat the wrappers as read-only consumers.
- The Cursor app/CLI itself — external.

## Contracts you must preserve

- **MDC rule format** — `rules/baseline.mdc` uses Cursor's `.cursor/rules`
  MDC format: a markdown body carrying the baseline behavior ("Verify,
  don't assume", be direct, read-before-edit, try-before-asking, follow
  project conventions, subagents/skills) with YAML frontmatter
  (`description`, `alwaysApply: true`). **`alwaysApply: true` means the
  rule is injected into every Cursor session's context.** Preserve the
  frontmatter schema and the `alwaysApply` semantics; don't break the
  injection by changing the frontmatter keys.
- **agents/skills parallel structure** — `agents/{architect,librarian,reviewer}.md`
  and `skills/*/SKILL.md` mirror `dot_pi/agent/`'s structure (custom
  subagent definitions + custom skills). The subagent names
  (`architect`/"Dave", `librarian`, `reviewer`) and the `SKILL.md`
  frontmatter (`name` / `description`) are the contract Cursor's
  agent/skill discovery depends on. Keep the structure consistent with
  `dot_pi/` where the two configs should agree on behavior.

## What you consume read-only

- **AI agent harnesses:** `ai-assist-cursor` / `ai-commit-cursor`
  wrappers (CALL cursor; read-only consumers).
- External: the Cursor app/CLI.

## Where to start

`home/dot_cursor/rules/baseline.mdc`, `home/dot_cursor/agents/`,
`home/dot_cursor/skills/`.

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
git worktree add -b work-on-cursor-$suffix "$WT_ROOT/work-on-cursor-$suffix" "$base"
cd "$WT_ROOT/work-on-cursor-$suffix"
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
  The human is in the loop, so this is a human-decided integration.
- **Stop here — do not integrate.** A workflow started by `/work-on-<silo>`
  ends only when the human decides. Once your work is self-tested and
  committed on the `work-on-<silo>-<suffix>` branch, **stop** and leave the
  branch parked in its worktree. Do **not** load the `reconcile` skill or
  merge to master yourself. The human closes the session by typing
  **`/end-work`**, which loads the `reconcile` skill and lands the branch on
  `master` (`flock`-gated, ff-only, `make test` under the lock). Report that
  the branch is ready and stop.

## Verify before claiming done
- Reproduce by opening Cursor and confirming the `baseline.mdc` rule is
  attached (`alwaysApply: true`) and the custom agents (`architect`,
  `librarian`, `reviewer`) and skills (`code-commit`, `code-review`,
  `code-simplifier`, `handoff`) are discovered.
- The MDC frontmatter schema is intact (`description` + `alwaysApply`).
- Your diff stays within `home/dot_cursor/`.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "Cursor coding agent config" section).
