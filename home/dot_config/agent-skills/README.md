# Shared agent skills

This directory is the canonical source for harness-neutral personal Agent
Skills. Chezmoi deploys it to `~/.config/agent-skills/`; each harness receives a
managed `SKILL.md` symlink:

- Cursor: `~/.cursor/skills/<name>/SKILL.md`
- Pi: `~/.pi/agent/skills/<name>/SKILL.md`
- Claude Code: `~/.claude/skills/<name>/SKILL.md`

Keep only portable behavior here. Harness-specific subagent definitions, tool
allowlists, models, and invocation metadata remain under each harness's own
configuration directory.

The shared skills are:

- `code-commit`
- `code-review`
- `code-simplifier`
- `confluence-acli`
- `handoff`
- `jira-acli`
