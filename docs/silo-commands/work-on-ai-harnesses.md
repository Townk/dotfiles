---
description: Dispatch an agent to the AI agent harnesses silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **AI agent harnesses** silo of this chezmoi dotfiles
repo.

> Multi-harness (claude/cursor/pi) AI terminal assistant + atomic commit
> planner. `ai-assist` captures Atuin + Zellij context and renders replies in
> a docked pane; `ai-commit` has the LLM emit a JSON commit plan and owns all
> git operations itself.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_ai-assist`, `ai-assist-{claude,pi,cursor,test}`
- `home/dot_local/bin/executable_ai-commit`, `ai-commit-{claude,pi,cursor}`
- `home/dot_local/lib/assist-agent-common.zsh` (`assist::*`),
  `commit-agent-common.zsh` (`cagent::*`)
- `home/dot_local/libexec/ai-assist-{summon,popup,render,input,action-broker}`
  (the popup is a `zellij-modal --capture` adapter)

⚠ **Shared file hazard:** the ZLE widget `ai-assist-trigger` lives in
`home/dot_config/zsh/functions.d/widgets.sh`, which also contains the
**shell** silo's dir-ring/smart-space widgets. If a **shell** agent is running
concurrently, **serialize** or split the file first. You own only the
`ai-assist-trigger` widget within that file; do not remove **shell**'s
widgets.

## Out of scope (do not edit — owned by other silos)

- `zj::pick` / `pick::start` framework → **pick** (you *call* it for the
  harness picker).
- The Zellij docked-pane spawn (`assist::spawn_pane`) uses **terminal-mux**'s
  `zellij action` API; `ai-assist-popup` uses **terminal-mux**'s
  `zellij-modal`.
- Atuin and the LLM harness CLIs (claude/cursor/pi) are external.
- `home/dot_config/zsh/functions.d/widgets.sh` beyond the `ai-assist-trigger`
  widget → **shell**.

## Contracts you must preserve

- **Harness `--probe` contract**: each `ai-assist-*`/`ai-commit-*` worker
  answers `--probe` with a label iff its CLI is present. The dispatcher
  discovers workers by globbing `ai-assist-*`/`ai-commit-*` siblings and
  probing. Adding a harness = add a sibling respecting `--probe`.
- **`request.json` shape** (ai-assist):
  `{origin:{session,pane,cwd}, last_command, exit, scrollback, user_request,
  project:{root,branch}}` — consumed by `assist-agent-common.zsh` and the
  worker.
- **Commit plan JSON** (ai-commit): `{commits:[{files:[...], message}]}` —
  the worker writes it to a tempfile; `cagent::execute_plan` reads it. **The
  agent never runs git** — `cagent::*` owns all `git add`/`git commit -F`.
  Plan cache under `.git`; `--replan` forces refresh.
- **Session pin**: `$XDG_STATE_HOME/ai-assist/sessions/<session>/harness`.
- **Per-project KB**: `$XDG_DATA_HOME/ai-assist/projects/<sha1(root)>/knowledge.md`.

## What you consume read-only

- **pick**: `zj::pick` / `pick::start` (harness + plan pickers)
- **terminal-mux**: Zellij docked pane, `zellij-modal` for the popup
- **shell**: `prompt::confirm`, `common.zsh` stdlib
- **utils**: `notify`
- External: Atuin, LLM CLIs (claude/cursor/pi)

## Where to start

`home/dot_local/lib/assist-agent-common.zsh`,
`home/dot_local/lib/commit-agent-common.zsh`,
`home/dot_local/bin/ai-assist`, `home/dot_local/bin/ai-commit`.

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
git worktree add -b work-on-ai-harnesses-$suffix "$WT_ROOT/work-on-ai-harnesses-$suffix" "$base"
cd "$WT_ROOT/work-on-ai-harnesses-$suffix"
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
- Reproduce the scenario with a real harness (or `ai-commit-test`/
  `ai-assist-test` no-agent path).
- The "agent plans, script owns all git" invariant must hold — no `git` call
  moves into a worker.
- The `request.json` / commit-plan JSON shapes are unchanged.
- Your diff stays within the owner area above (plus, if needed, only the
  `ai-assist-trigger` widget in the shared `widgets.sh`).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "AI agent harnesses" section — note the
ai-harnesses↔shell `widgets.sh` shared-file hazard).
