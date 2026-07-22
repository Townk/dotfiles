---
name: code-commit
description: Creates polished git commits using Conventional Commits and project-specific message rules. Use before staging or committing changes, when the user asks to commit, write a commit message, or prepare a commit.
---

# Code Commit

Create a git commit for the requested changes. Do not push unless the user
explicitly asks. Follow repository-specific commit instructions over this
general format.

## Consent and safety

- A request to suggest or write a commit message does not authorize staging or
  committing. Mutate git state only when the user explicitly asks.
- Inspect `git status`, staged and unstaged diffs, and recent commit subjects
  before staging.
- Stage only the intended files. Ask when unrelated or ambiguous changes exist.
- Never bypass hooks unless the user explicitly approves it.
- Never include secrets, private data, or prohibited repository content.
- Do not add AI attribution, `Co-Authored-By`, `Signed-off-by`, or other
  authorship trailers unless local instructions explicitly require one.

## Subject

Use Conventional Commits:

```text
<type>(<scope>): <summary>
```

- `type` is required. Common values include `feat`, `fix`, `docs`, `refactor`,
  `chore`, `test`, and `perf`.
- `scope` is optional and should be a short noun.
- Use an imperative, lowercase summary with no trailing period.
- Keep the subject within the repository's limit; default to 50 characters.

## Body

Scale the body to the change:

- Trivial change: subject only.
- Normal change: add `## Changes Description`.
- Substantial change: also add `## Testing` and `## Related items` when they
  contain useful information.

When multiple sections exist, separate them with `---`. Wrap prose at the
repository's preferred width; default to 72 characters.

### `## Changes Description`

Explain what changed, why, the approach, and notable decisions. Make the commit
understandable without requiring the reader to inspect the diff.

### `## Testing`

Record verification that actually ran. Include commands where useful. Omit the
section if no verification was performed.

### `## Related items`

Reference related work items or commits when relevant. Omit the section when
there are none.

## Procedure

1. Read local commit instructions and hooks.
2. Determine whether the user supplied file paths, globs, or message guidance.
3. Inspect status, diffs, and recent commit conventions.
4. Ask about ambiguous files before staging.
5. Stage only the authorized scope.
6. Review the staged diff, including added lines for sensitive information.
7. Choose a subject and appropriately sized body.
8. Commit using a mechanism that preserves Markdown exactly, such as a
   temporary message file with `git commit -F`.
9. Confirm the commit succeeded and report its short hash and subject.
