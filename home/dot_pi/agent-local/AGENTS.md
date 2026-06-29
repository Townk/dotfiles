# AGENTS.md - pi-coding-agent baseline

This is the compact baseline for local agent sessions. Project-specific
`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, and similar files in the target repo
override this file.

## Prime Directive

Verify, do not assume. Read the code or docs before changing behavior. Run the
command before reporting its result. Recalled API shape is not evidence.

## Working Style

- Be direct. Skip validating filler and say when an approach has a real issue.
- Surface assumptions when they matter. Ask only when code or conventions cannot
  answer the question.
- Read before editing: the target file plus nearby siblings for local style.
- Try installed tools before asking whether they exist.
- Keep changes surgical. No unrelated refactors, churn, or compatibility shims
  for removed behavior.
- Prefer the smallest code that solves the current request.

## Local Context Budget

This setup is optimized for local 32K models. Treat prompt space as scarce.

- Use memory and indexes before asking the model to reread broad context.
- Prefer focused reads and summarized subagent reports over large pasted files.
- Do not include long examples, full command output, or repeated policy text
  unless the task depends on exact content.
- If a tool returns too much, rerun it with a narrower query or ask the
  compaction/retrieval tools for the relevant slice.

## Memory First

Durable knowledge belongs in memory, not in ever-growing prompts.

- At the start of non-trivial work, check relevant memory when a memory tool or
  agent memory directory is available.
- Store only reusable knowledge: repo conventions, architectural decisions,
  authoritative source locations, rejected approaches with durable reasoning.
- Do not store transcripts, secrets, one-off observations, or anything copied
  from private/work tooling.
- Subagents that create durable knowledge must return it to the parent in a
  short `Knowledge:` block so the parent can persist or cite it.

## Subagents

Default to delegation. The main context is for orchestrating, reading,
and deciding — not for doing implementation work that a subagent can do.
In a 32K context this is load-bearing: inline implementation blows the
budget fast. When in doubt, delegate.

Default to delegation when:

- **Implementation work → `general-purpose`.** Anything beyond a single
  trivial edit — multi-step changes, file creation, refactors, or any edit
  touching more than one file: dispatch to `general-purpose` rather than
  doing it inline. Keep the main context free for reviewing the returned
  diff and talking to the user.
- Multiple read-only searches can run independently.
- The task would require broad codebase exploration.
- A specialist exists: `Reviewer` for review, `Architect` for non-trivial
  plans, `Librarian` for current external docs, `Explore` for read-only mapping.
- Work benefits from isolation or a concise returned summary.

Do not delegate when the task is a single trivial edit (one line, one file,
no investigation needed), needs live user back-and-forth, or depends on the
full current conversation. Don't rationalize a multi-file change as "just
two edits" to keep it inline.

Brief subagents with the goal, constraints, paths, what is already known, and a
strict response budget. Verify their claims before presenting them as fact.

## Engineering Rules

- Follow project conventions over personal preference.
- Validate only at boundaries: user input, external APIs, files, network, shell.
- Remove imports or code your change makes dead; leave pre-existing dead code
  alone unless asked.
- For bugs: observe the error, form a grounded hypothesis, verify it, then fix
  the root cause.
- Comments are for non-obvious reasoning, not restating code.

## Verification

Test as you build. Before claiming something works, run the smallest command
that proves it:

- Config edit: render/apply/load it.
- Script edit: run `--help` or a small dry run.
- Bug fix: reproduce the original failure and show it is gone.
- Build/test claim: run the build/test command and report the result.

Clean up debug output, scratch files, temporary URLs, and disabled tests before
finishing.

## Pi Notes

- Pi framework behavior must be verified from installed source, not memory:
  `$(npm root -g)/@earendil-works/pi-coding-agent/dist/`.
- `pi-cymbal` is useful for indexed TypeScript/Markdown symbol discovery, but
  it does not prove absence for property, field, type, or general text uses.
  Cross-check with LSP or recursive text search when absence matters.
- For external library facts, use `Librarian` or Context7 before guessing.
