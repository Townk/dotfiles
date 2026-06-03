---
name: code-commit
description: Create polished git commits using Conventional Commits and project-specific Markdown body rules. Use before staging or committing changes, when the user asks to commit, write a commit message, or prepare a commit.
---

# Code Commit

Create a git commit for the current changes using Conventional Commits format with a polished, highly descriptive message and a Markdown body when the change merits one. If there are commit hooks, do not skip them. Only commit; do not push unless the user explicitly asks.

## Subject Format

Use:

```text
<type>(<scope>): <summary>
```

- `type` is required. Use `feat` for new features and `fix` for bug fixes. Other common types: `docs`, `refactor`, `chore`, `test`, `perf`.
- `scope` is optional. Use a short noun for the affected area, such as `api`, `parser`, or `ui`.
- `summary` is required. Use short, imperative, lowercase phrasing with no trailing period.
- Keep the entire subject line at or below 50 characters.

## Body Format

The body is Markdown. Scale it to the size of the change:

- Trivial change: subject only, no body.
- Normal change: subject plus `## Changes Description`.
- Substantial change: subject plus `## Changes Description`, and add `## Testing` and/or `## Related items` when they have real content.

When multiple sections are present, separate them with a `---` horizontal rule.

### `## Changes Description`

- Wrap lines at 72 characters.
- Explain what changed, why, the approach taken, and any notable decisions.
- Make `git log` useful without requiring the reader to inspect the diff.
- Do not assume the reviewer understands the original problem.
- Use `-` for itemized lists; each item ends with `;`.
- For list items longer than 72 characters, wrap the text and use a trailing dangling space on the previous line to indicate continuation.

### `## Testing`

- Describe manual steps taken to verify the change does not break the system.
- List any requirements needed to validate the change.
- List test commands when appropriate.
- Omit this section if no verification was performed.

### `## Related items`

Use an itemized list for related artifacts, for example:

```md
- Fix JIRA-1234;
- Is dependency for JIRA-1234;
- Depend on commit <short sha>;
```

Omit this section entirely if there are no related artifacts.

## Cursor Safety Notes

- Do not update git config to preserve Markdown headings. Use the active Cursor commit protocol for passing multi-line messages, such as a HEREDOC-backed `git commit -m`, or a temp file with `--cleanup=verbatim` when that is allowed by the environment.
- Do not include breaking-change markers or footers.
- Do not add sign-offs, including `Signed-off-by`.
- If it is unclear whether a file should be included, ask which files to commit.
- Treat caller-provided arguments as additional commit guidance:
  - Free-form instructions should influence scope, summary, and body.
  - File paths or globs should limit which files to commit.
  - If arguments combine files and instructions, honor both.

## Steps

1. Infer whether the user provided specific file paths, globs, or additional instructions.
2. Review `git status`, staged changes, unstaged changes, and recent commit subjects.
3. If there are ambiguous extra files, ask before committing.
4. Stage only the intended files; if no files were specified, stage all relevant changes while avoiding secrets and unrelated work.
5. Decide whether the body should be omitted, normal, or substantial based on the diff.
6. Commit with the formatted message while preserving Markdown structure.
7. Remove any temporary commit-message file if one was used.
