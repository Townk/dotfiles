# chezmoi-reverse design

**Date:** 2026-05-18
**Status:** Approved (design)

## Problem

A chezmoi template at the source (e.g. `dot_foo.tmpl`) is rendered to a destination file at `~/.foo`. An external process (or the user) modifies `~/.foo`. We want a single command that propagates that change back into the source template, automatically when safe and via interactive merge when not.

`chezmoi re-add` explicitly refuses to overwrite templates. `chezmoi merge` performs a three-way merge but is always manual. `chezmoi add --autotemplate --force` would replace the existing template with one generated from the destination, destroying any non-trivial template logic (conditionals, loops, custom funcs). None of these alone solves the workflow.

## Goal

Provide `chezmoi-reverse <file> [<file>...]` that, for each destination file:

- Auto-applies the change to the source template when the diff lies entirely in literal (non-templated) regions.
- Falls back to `chezmoi merge` when the change would touch a `{{ ... }}` directive or any region whose template form differs from its rendered form.
- Never silently corrupts a template.

## Non-goals

- Directory recursion (single-file only).
- Files that have been renamed or relocated relative to their chezmoi-managed path.
- One-source-to-many-destinations templates.
- Reverting paths excluded by `.chezmoiignore`.
- Unattended/non-interactive use. The merge fallback uses `merge.command` (default `vimdiff`), which is interactive. Callers that need full automation must accept that some diffs will require manual intervention or restrict edits to literal regions.

## Algorithm (per file)

1. **Resolve the source.** `src=$(chezmoi source-path "$file")`. If the call fails, report `failed` and continue to the next file.
2. **Categorize by source filename** (chezmoi's attribute prefixes and suffixes encode the file's nature):
   - No `.tmpl` suffix → plain file, no templating concern. Run `chezmoi re-add "$file"` and report `applied`.
   - `encrypted_` prefix → skip the patch path entirely; the rendered form requires decryption and the source is ciphertext. Go straight to `chezmoi merge "$file"` and report `merged`.
   - `run_*.tmpl` (script template) → no destination state to read; report `skipped` with a message.
   - Otherwise (regular `.tmpl`) → continue.
3. **Render** the current template: `chezmoi cat "$file" > "$rendered"`.
4. **Diff** the rendered output against the current destination: `diff -u "$rendered" "$file" > "$patch"`. If empty, report `clean` and continue.
5. **Back up** the source: `cp "$src" "$src.bak"`.
6. **Attempt patch** on the source: `patch --fuzz=0 --no-backup-if-mismatch "$src" < "$patch"`.
7. **Verify.** If `patch` exited 0 **and** `$src.rej` does not exist → remove `$src.bak`, report `applied`.
8. **Fallback.** Otherwise: restore source from `$src.bak`, remove any `$src.rej` / `$src.orig` that `patch` left behind, then run `chezmoi merge "$file"` and report `merged`.

Note on diff/patch wiring: `diff -u "$rendered" "$file"` produces headers referencing those paths, but the patch is applied to `$src` because `$src` is given explicitly on `patch`'s command line. The headers are advisory only in this mode.

## Why `--fuzz=0` is load-bearing

The patch's context lines are taken from the rendered output. The source template is identical to the rendered output **on literal lines** and different **on templated lines** (`{{ .name }}` in the template renders to `thiago` in the output, for example).

With `--fuzz=0`:

- A hunk that touches only literal lines has literal context, which matches the template exactly, so the hunk applies.
- A hunk whose context or changed region falls on a templated line cannot match the template (which still contains `{{ ... }}`), so `patch` rejects the hunk into a `.rej` file. We detect this and fall back to merge.

With the default `--fuzz=2`, `patch` may match a different region with two non-matching context lines, silently writing the change to the wrong place in the template. That is the failure mode we are designed to prevent. Fuzz=0 turns the "fail loudly and fall back" property into a hard guarantee for single-line edits and a very strong heuristic for multi-line edits.

## Output and exit codes

Per file, the script prints one line to stdout: `<status>\t<file>` where `status ∈ {clean, applied, merged, skipped, failed}`.

Exit code:
- `0` if every file ended in `clean`, `applied`, or `merged`.
- Non-zero if any file ended in `skipped` or `failed`.

## Location

A static (non-template) bash script at `dot_local/bin/executable_chezmoi-reverse` in the chezmoi source tree. chezmoi will install it to `~/.local/bin/chezmoi-reverse` with the executable bit set. No `.tmpl` because the script has no per-host variation.

## Testing

A `bats` test file colocated under `tests/`. Each test creates a throwaway home directory and a throwaway chezmoi source directory, populates them, then invokes the script. Three core scenarios:

1. **Literal-only change.** Template `name = thiago\nrole = {{ .role }}`. Edit the destination's first line. Expect `applied`. Verify the source `.tmpl` now reflects the edit and the templated line is untouched.
2. **Templated-region change.** Same template. Edit the destination's second line (the rendered form of `{{ .role }}`). Expect `merged` and that the merge command is invoked (use a stub merge tool that records its arguments). Verify the source `.tmpl` is unchanged after the auto-patch attempt — i.e., the backup-and-restore worked.
3. **No change.** Destination equals rendered output. Expect `clean`. Verify no writes to the source.

Stub `merge.command` to a script that records its arguments and exits 0, so tests are non-interactive.

## Edge cases noted, deferred

- **Source is a symlink template** (`symlink_*.tmpl`): the destination is a symlink, so "modifying it" means changing the target. The patch path would diff symlink-target strings, which is well-defined but unusual. Initial version: skip with a message.
- **Source contains template errors** (`chezmoi cat` fails): report `failed` with the chezmoi error.
- **Destination doesn't exist**: report `failed`.
- **Source is a directory template** (`exact_`, `dot_*` directory): out of scope; this tool is for files.

## Open questions

None blocking. Bats-vs-shell-test framework choice is left to implementation.
