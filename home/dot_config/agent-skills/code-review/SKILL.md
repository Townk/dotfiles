---
name: code-review
description: Routes code review requests to the configured reviewer subagent in isolated context. Use for pull requests, diffs, files, directories, bundled review scopes, or when the user asks for a strict code review.
---

# Code Review

Delegate every code review to the harness's dedicated `reviewer` subagent. The
subagent owns the review discipline, tool selection, and findings format.

## Router behavior

1. Do not review code in the parent conversation or provide a preliminary
   finding.
2. Resolve the requested scope. If it is materially ambiguous, ask the user
   before delegating.
3. Invoke exactly one configured reviewer subagent in isolated context. Harness
   UI may display its name with different capitalization.
4. Give it a complete briefing:

   ```text
   Review scope: <paths, diff, branch, pull request, directory, or bundle>

   Context:
   - <why the review was requested>
   - <relevant constraints or known decisions>

   Delivery:
   - Direct user request: write review-<scope>.md in the working directory and
     return its path plus a one-line severity count.
   - Review requested by another agent: return findings inline.

   Inspect only. Do not modify source files, commit, or push.
   ```

5. Relay the reviewer result without weakening, embellishing, or silently
   dropping findings.

## Failure handling

- If no reviewer subagent is configured, report that configuration error. Do
  not silently perform an inline review.
- If the reviewer asks for clarification, obtain the answer and re-delegate to
  the same reviewer context when the harness supports resuming it.
- Do not launch multiple reviewers for the same scope unless the user requests
  independent passes.
