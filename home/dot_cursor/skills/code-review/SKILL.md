---
name: code-review
description: >-
  Routes code review requests to the Kevin/reviewer subagent in isolated context.
  Use when reviewing pull requests, diffs, files, directories, bundled review
  scopes, or when the user asks for a code review, @code-review, or
  Kevin/reviewer-style review.
---

# Code Review (delegate to reviewer)

This skill does **not** perform the review. It always delegates to the `reviewer`
subagent at `~/.cursor/agents/reviewer.md`, which holds the full discipline,
tooling, and output contract.

## What you must do

1. **Do not review code in this conversation.** No findings, no partial review,
   no "quick take" before delegating.
2. **Invoke the `reviewer` subagent immediately** with a complete briefing.
3. **Relay the subagent's result** to the user when it finishes — do not rewrite
   findings in your own words unless the user asked for a summary on top.

## Delegation prompt template

Use the `reviewer` subagent (or equivalent subagent invocation) with a prompt
like:

```
Review scope: <paths, diff, PR, directory, or bundled scope file>

Context:
- <why the review was requested, branch/PR link, constraints>

Delivery:
- Direct user request → write review-<short-scope-slug>.md in the current
  working directory; reply with file path + one-line severity count.
- Otherwise → return findings inline per reviewer output contract.

Do not modify source files. Read-only inspection only.
```

Fill in `Review scope` and `Context` from the user's message. If scope is unclear,
ask the user **before** delegating — do not guess.

## After the subagent returns

- If it wrote a report file: give the user the path and severity summary.
- If it returned inline findings: pass them through.
- If it asked for clarification: surface that to the user and re-delegate after
  they answer.

## Do not

- Duplicate reviewer rules here or improvise a lighter review.
- Edit, commit, or fix code unless the user changes the task after the review.
- Spawn multiple reviewer subagents for the same scope unless the user asks for
  a second pass.
