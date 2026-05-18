---
name: commit
description: You MUST use the read tool to read this file before performing ANY git commits or staging changes. It contains mandatory project-specific commit formats.
---

# Code Commit

Create a git commit for the current changes using Conventional Commits format
with a **polished, highly descriptive** message and a **Markdown body**. If
there are commit hooks, do not skip them — it's your responsibility to leave
things better than they were.

## Subject Format

`<type>(<scope>): <summary>`

- `type` REQUIRED. Use `feat` for new features, `fix` for bug fixes. Other
  common types: `docs`, `refactor`, `chore`, `test`, `perf`.
- `scope` OPTIONAL. Short noun in parentheses for the affected area (e.g.,
  `api`, `parser`, `ui`).
- `summary` REQUIRED. Short, imperative, **lowercase**, no trailing period.

**NOTE**: The entire subject line must not exceed 50 characters.

## Body Format

The body is written in **Markdown**. Because git's default `core.commentChar` is
`#`, which would strip `#`/`##` heading lines, the comment character must be `;`
for the body to render correctly. See "Comment character preflight" below.

Scale the body to the size of the change:

- **Trivial change** (typo, one-line fix): subject only, no body.
- **Normal change**: subject + `## Changes Description` section.
- **Substantial change**: subject + `## Changes Description`, plus `## Testing`
  and/or `## Related items` when they have real content.

When multiple sections are present, separate them with a `---` horizontal rule,
matching the project's commit-message template.

### `## Changes Description`

- Wrap lines at 72 characters.
- Explain **what** changed, **why**, the approach taken, and any notable
  decisions. A reader of `git log` should understand the change without looking
  at the diff.
- Do not assume the reviewer understands the original problem — state it.
- Do not assume the code is self-explanatory.
- Use `-` for itemized lists; each item ends with `;`.
- For list items longer than 72 characters, wrap the text and use a trailing
  (dangling) space on the previous line to indicate continuation.

### `## Testing`

- Describe the manual steps taken to verify the change does not break the
  system.
- List any requirements needed to validate the change.
- List the commands used to test, when appropriate.
- Omit this section if no verification was performed.

### `## Related items`

- Itemized list referencing related artifacts. Examples:
  - `- Fix JIRA-1234;`
  - `- Is dependency for JIRA-1234;`
  - `- Depend on commit <short sha>;`
- Omit this section entirely if there are no related artifacts.

## Comment character preflight

Before writing the commit message, ensure markdown headings will survive:

1. Run `git config --get core.commentChar`.
2. If the output is empty or `#`, set it locally for this repo:
   `git config --local core.commentChar ';'`.
3. This change is scoped to the current repo and is reversible
   (`git config --local --unset core.commentChar`).

## General notes

- Do NOT include breaking-change markers or footers.
- Do NOT add sign-offs (no `Signed-off-by`).
- Only commit; do NOT push.
- If it is unclear whether a file should be included, ask the user which files
  to commit.
- Treat any caller-provided arguments as additional commit guidance:
  - Free-form instructions should influence scope, summary, and body.
  - File paths or globs should limit which files to commit. If files are
    specified, only stage/commit those unless the user explicitly asks
    otherwise.
  - If arguments combine files and instructions, honor both.

## Steps

1. Infer from the prompt whether the user provided specific file paths/globs
   and/or additional instructions.
2. Run the comment-character preflight above.
3. Review `git status` and `git diff` to understand the current changes (limit
   to argument-specified files if provided).
4. (Optional) Run `git log -n 50 --pretty=format:%s` to see commonly used
   scopes.
5. If there are ambiguous extra files, ask the user for clarification before
   committing.
6. Stage only the intended files (all changes if no files specified).
7. Decide the body scope (trivial / normal / substantial) based on the diff.
8. Write the commit message to a temp file: subject on line 1, blank line, then
   the Markdown body. Commit with `git commit -F <tmpfile>` (using `-F`
   preserves the Markdown structure and avoids `-m` quoting pitfalls).
9. Remove the temp file when done.
