# Silo S6 — AI agent harnesses

> Multi-harness (claude/cursor/pi) AI terminal assistant + atomic commit
> planner. `ai-assist` captures Atuin + Zellij context and renders replies in
> a docked pane; `ai-commit` has the LLM emit a JSON commit plan and owns all
> git operations itself.

## Setup

```sh
git worktree add ../s06-ai-harnesses-work master
cd ../s06-ai-harnesses-work
```

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_ai-assist`, `ai-assist-{claude,pi,cursor,test}`
- `home/dot_local/bin/executable_ai-commit`, `ai-commit-{claude,pi,cursor}`
- `home/dot_local/lib/assist-agent-common.zsh` (`assist::*`),
  `commit-agent-common.zsh` (`cagent::*`)
- `home/dot_local/libexec/ai-assist-{summon,popup,render,input,action-broker}`
  (the popup is a `zellij-modal --capture` adapter)

⚠ **Shared file hazard:** the ZLE widget `ai-assist-trigger` lives in
`home/dot_config/zsh/functions.d/widgets.sh`, which also contains **S9**'s
dir-ring/smart-space widgets. If an S9 agent is running concurrently,
**serialize** or split the file first. You own only the `ai-assist-trigger`
widget within that file; do not remove S9's widgets.

## Out of scope (do not edit — owned by other silos)

- `zj::pick` / `pick::start` framework → **S4** (you *call* it for the harness
  picker).
- The Zellij docked-pane spawn (`assist::spawn_pane`) uses S1's
  `zellij action` API; `ai-assist-popup` uses S1's `zellij-modal`.
- Atuin and the LLM harness CLIs (claude/cursor/pi) are external.
- `home/dot_config/zsh/functions.d/widgets.sh` beyond the `ai-assist-trigger`
  widget → **S9**.

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

- S4: `zj::pick` / `pick::start` (harness + plan pickers)
- S1: Zellij docked pane, `zellij-modal` for the popup
- S9: `prompt::confirm`, `common.zsh` stdlib
- S13: `notify`
- External: Atuin, LLM CLIs (claude/cursor/pi)

## Where to start

`home/dot_local/lib/assist-agent-common.zsh`,
`home/dot_local/lib/commit-agent-common.zsh`,
`home/dot_local/bin/ai-assist`, `home/dot_local/bin/ai-commit`.

## TASK

> _<describe the assignment — e.g. "Review the `ai-commit` plan-cache +
> stage/commit loop for robustness; on abort it sometimes leaves files
> staged" >_

**Verify before claiming done:**
- Reproduce the scenario with a real harness (or `ai-commit-test`/
  `ai-assist-test` no-agent path).
- The "agent plans, script owns all git" invariant must hold — no `git` call
  moves into a worker.
- The `request.json` / commit-plan JSON shapes are unchanged.
- Your diff stays within the owner area above (plus, if needed, only the
  `ai-assist-trigger` widget in the shared `widgets.sh`).

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S6 (note the S6↔S9
  `widgets.sh` shared-file hazard).
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #53–#54.
