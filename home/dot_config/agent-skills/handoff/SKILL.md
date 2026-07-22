---
name: handoff
description: Compacts the current conversation into a handoff document for another agent to continue. Use when the user asks to hand off, preserve context for a new session, or prepare work for another agent.
---

# Handoff

Write a concise handoff document so a fresh agent can continue the current
work. Save it in the operating system's temporary directory, not in the current
workspace.

## Include

- The user's current goal and authorized scope.
- Work completed, with verification evidence.
- Current repository and working-tree state.
- Important decisions, constraints, and rejected approaches.
- Remaining tasks and the safest next action.
- Relevant paths, commands, errors, plans, issues, or URLs.
- A short `Suggested skills` section naming useful skills for the next agent.

## Rules

- Prefer references to existing plans, diffs, issues, and documentation over
  duplicating their contents.
- Distinguish verified facts from assumptions and unresolved questions.
- Do not claim work passed verification unless the command was run.
- Redact secrets, credentials, sensitive internal information, and unnecessary
  personal data.
- Do not modify project files while producing the handoff.
- If the user supplied arguments, treat them as the intended focus of the next
  session.

Reply with the handoff file path and a one-sentence summary.
