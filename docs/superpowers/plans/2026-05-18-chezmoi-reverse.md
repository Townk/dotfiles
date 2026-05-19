# chezmoi-reverse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `chezmoi-reverse`, a bash CLI that propagates edits made to a chezmoi-managed destination file back into its source `.tmpl`, auto-patching when safe and falling back to `chezmoi merge` when not.

**Architecture:** Single bash script invoked as `chezmoi-reverse <file>...`. For each file: resolve the source via `chezmoi source-path`, classify by source filename, then either (a) `chezmoi re-add` for non-templates, (b) render → `diff` → `patch --fuzz=0` for templates (with restore + `chezmoi merge` on rejection), or (c) `chezmoi merge` directly for encrypted files. Tested via bats with an isolated `$HOME` and a stub merge tool.

**Tech Stack:** bash 5, `chezmoi`, `diff`, `patch`, `bats` 1.x.

**Spec:** `docs/superpowers/specs/2026-05-18-chezmoi-reverse-design.md`

---

## File Structure

- **Create** `dot_local/bin/executable_chezmoi-reverse` — the script. The `executable_` prefix tells chezmoi to set the executable bit at apply time; no `.tmpl` because the script has no per-host variation.
- **Create** `tests/chezmoi-reverse.bats` — bats tests. Sets up an isolated `$HOME` + a stub merge tool per test, then invokes the script by absolute path.

No shared helper library: the test setup is small enough to inline. The script itself is self-contained.

---

### Task 1: Skeleton script and usage-error test

**Files:**
- Create: `dot_local/bin/executable_chezmoi-reverse`
- Create: `tests/chezmoi-reverse.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/chezmoi-reverse.bats`:

```bash
#!/usr/bin/env bats

setup() {
  TEST_TMP=$(mktemp -d)
  export HOME="$TEST_TMP/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME CHEZMOI_CONFIG_FILE
  mkdir -p "$HOME" "$HOME/.config/chezmoi" "$TEST_TMP/src"

  # Stub merge tool that records its arguments to a sentinel file.
  cat > "$TEST_TMP/stub-merge" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMP/merge-invoked"
EOF
  chmod +x "$TEST_TMP/stub-merge"

  # chezmoi config: point source at our temp dir, route merges to the stub,
  # provide a data value so templates can render.
  cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$TEST_TMP/src"

[merge]
  command = "$TEST_TMP/stub-merge"
  args = ["{{ .Destination }}", "{{ .Source }}", "{{ .Target }}"]

[data]
  role = "engineer"
EOF

  SCRIPT="$BATS_TEST_DIRNAME/../dot_local/bin/executable_chezmoi-reverse"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "usage: no args exits 2 with usage line on stderr" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage: chezmoi-reverse"* ]] || [[ "$output" == *"usage: chezmoi-reverse"* ]]
}
```

Note: bats `run` captures stdout into `$output` by default; the `||` fallback handles both bats configurations (with or without `--separate-stderr`).

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/chezmoi-reverse.bats`
Expected: FAIL — script does not exist yet.

- [ ] **Step 3: Create the script skeleton**

Create `dot_local/bin/executable_chezmoi-reverse`:

```bash
#!/usr/bin/env bash
# chezmoi-reverse: propagate destination edits back to chezmoi source templates.
# Usage: chezmoi-reverse <file> [<file>...]
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "usage: chezmoi-reverse <file> [<file>...]" >&2
  exit 2
fi

echo "not yet implemented" >&2
exit 1
```

Set executable bit (chezmoi will do this on apply, but the source file must be executable too so tests can run it directly):

```bash
chmod +x dot_local/bin/executable_chezmoi-reverse
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/chezmoi-reverse.bats`
Expected: PASS — one test passing.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_chezmoi-reverse tests/chezmoi-reverse.bats
git commit -m "feat(chezmoi-reverse): add script skeleton with usage error"
```

---

### Task 2: Clean case (no diff between rendered and destination)

**Files:**
- Modify: `dot_local/bin/executable_chezmoi-reverse`
- Modify: `tests/chezmoi-reverse.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/chezmoi-reverse.bats`:

```bash
@test "clean: unchanged destination reports clean and exits 0" {
  printf 'name = thiago\n' > "$TEST_TMP/src/dot_foo.tmpl"
  chezmoi apply
  run "$SCRIPT" "$HOME/.foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [[ "$output" == *".foo"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/chezmoi-reverse.bats -f clean`
Expected: FAIL — script exits 1 with "not yet implemented".

- [ ] **Step 3: Implement the clean path**

Replace the body of `dot_local/bin/executable_chezmoi-reverse` (keep the usage check):

```bash
#!/usr/bin/env bash
# chezmoi-reverse: propagate destination edits back to chezmoi source templates.
# Usage: chezmoi-reverse <file> [<file>...]
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "usage: chezmoi-reverse <file> [<file>...]" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

emit() { printf '%s\t%s\n' "$1" "$2"; }

reverse_one() {
  local file="$1" src rendered patch
  if ! src=$(chezmoi source-path "$file" 2>/dev/null); then
    emit failed "$file"; return 1
  fi
  rendered="$work/rendered"; patch="$work/patch"
  if ! chezmoi cat "$file" > "$rendered" 2>/dev/null; then
    emit failed "$file"; return 1
  fi
  if diff -u "$rendered" "$file" > "$patch"; then
    emit clean "$file"; return 0
  fi
  emit failed "$file"; return 1   # placeholder; later tasks add patch + merge paths
}

rc=0
for f in "$@"; do
  reverse_one "$f" || rc=1
done
exit "$rc"
```

- [ ] **Step 4: Run tests to verify both pass**

Run: `bats tests/chezmoi-reverse.bats`
Expected: 2 of 2 passing.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_chezmoi-reverse tests/chezmoi-reverse.bats
git commit -m "feat(chezmoi-reverse): handle the clean (no-diff) case"
```

---

### Task 3: Literal-only change is auto-patched

**Files:**
- Modify: `dot_local/bin/executable_chezmoi-reverse`
- Modify: `tests/chezmoi-reverse.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/chezmoi-reverse.bats`:

```bash
@test "applied: change to a literal line is patched into the template" {
  cat > "$TEST_TMP/src/dot_foo.tmpl" <<'EOF'
name = thiago
role = {{ .role }}
EOF
  chezmoi apply
  # Edit only the literal first line in the destination.
  sed -i.bak 's/^name = thiago$/name = alice/' "$HOME/.foo"; rm "$HOME/.foo.bak"

  run "$SCRIPT" "$HOME/.foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied"* ]]

  # The templated line must still be in template form, the literal line updated.
  run cat "$TEST_TMP/src/dot_foo.tmpl"
  [[ "$output" == *"name = alice"* ]]
  [[ "$output" == *"role = {{ .role }}"* ]]
  [ ! -e "$TEST_TMP/merge-invoked" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/chezmoi-reverse.bats -f applied`
Expected: FAIL — current code emits `failed` for any non-clean file.

- [ ] **Step 3: Implement the patch path**

Replace the `reverse_one` function in `dot_local/bin/executable_chezmoi-reverse`:

```bash
reverse_one() {
  local file="$1" src rendered patch
  if ! src=$(chezmoi source-path "$file" 2>/dev/null); then
    emit failed "$file"; return 1
  fi
  rendered="$work/rendered"; patch="$work/patch"
  if ! chezmoi cat "$file" > "$rendered" 2>/dev/null; then
    emit failed "$file"; return 1
  fi
  if diff -u "$rendered" "$file" > "$patch"; then
    emit clean "$file"; return 0
  fi
  cp "$src" "$src.bak"
  if patch --fuzz=0 --no-backup-if-mismatch "$src" < "$patch" >/dev/null 2>&1 \
     && [ ! -e "$src.rej" ]; then
    rm -f "$src.bak"
    emit applied "$file"
    return 0
  fi
  # Restore and fall through to merge in the next task.
  cp "$src.bak" "$src"
  rm -f "$src.bak" "$src.rej" "$src.orig"
  emit failed "$file"; return 1
}
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `bats tests/chezmoi-reverse.bats`
Expected: 3 of 3 passing.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_chezmoi-reverse tests/chezmoi-reverse.bats
git commit -m "feat(chezmoi-reverse): auto-patch literal-region changes with fuzz=0"
```

---

### Task 4: Templated-region change falls back to `chezmoi merge`

**Files:**
- Modify: `dot_local/bin/executable_chezmoi-reverse`
- Modify: `tests/chezmoi-reverse.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/chezmoi-reverse.bats`:

```bash
@test "merged: change to a templated line restores template and invokes merge" {
  cat > "$TEST_TMP/src/dot_foo.tmpl" <<'EOF'
name = thiago
role = {{ .role }}
EOF
  chezmoi apply
  # Capture template byte-for-byte before the edit.
  cp "$TEST_TMP/src/dot_foo.tmpl" "$TEST_TMP/template-before"

  # Edit the rendered form of the templated line in the destination.
  sed -i.bak 's/^role = engineer$/role = manager/' "$HOME/.foo"; rm "$HOME/.foo.bak"

  run "$SCRIPT" "$HOME/.foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged"* ]]

  # Merge stub must have been invoked.
  [ -f "$TEST_TMP/merge-invoked" ]

  # Template must be byte-identical to its pre-run state (the merge stub is a
  # no-op; we only verify our backup-and-restore worked).
  run diff "$TEST_TMP/template-before" "$TEST_TMP/src/dot_foo.tmpl"
  [ "$status" -eq 0 ]

  # No stray reject or backup files left behind in the source dir.
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.rej" ]
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.orig" ]
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.bak" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/chezmoi-reverse.bats -f merged`
Expected: FAIL — patch path rejects the hunk (good) but current code emits `failed` instead of invoking merge.

- [ ] **Step 3: Implement the merge fallback**

In `dot_local/bin/executable_chezmoi-reverse`, replace the final two lines of `reverse_one` (the `emit failed` after the restore) with:

```bash
  chezmoi merge "$file" || true
  emit merged "$file"
  return 0
}
```

So the tail of `reverse_one` now reads:

```bash
  cp "$src" "$src.bak"
  if patch --fuzz=0 --no-backup-if-mismatch "$src" < "$patch" >/dev/null 2>&1 \
     && [ ! -e "$src.rej" ]; then
    rm -f "$src.bak"
    emit applied "$file"
    return 0
  fi
  cp "$src.bak" "$src"
  rm -f "$src.bak" "$src.rej" "$src.orig"
  chezmoi merge "$file" || true
  emit merged "$file"
  return 0
}
```

`|| true` is intentional: `chezmoi merge`'s exit code reflects the merge tool's exit, which the user may legitimately use to signal "I bailed out." We still report `merged` so the user sees the file was routed correctly; if they want to know whether they completed the merge, they look at the source dir.

- [ ] **Step 4: Run tests to verify all pass**

Run: `bats tests/chezmoi-reverse.bats`
Expected: 4 of 4 passing.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_chezmoi-reverse tests/chezmoi-reverse.bats
git commit -m "feat(chezmoi-reverse): fall back to chezmoi merge on patch rejection"
```

---

### Task 5: Non-template files use `chezmoi re-add`

**Files:**
- Modify: `dot_local/bin/executable_chezmoi-reverse`
- Modify: `tests/chezmoi-reverse.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/chezmoi-reverse.bats`:

```bash
@test "applied: non-template file is re-added via chezmoi re-add" {
  printf 'literal one\nliteral two\n' > "$TEST_TMP/src/dot_bar"
  chezmoi apply
  printf 'literal one\nliteral CHANGED\n' > "$HOME/.bar"

  run "$SCRIPT" "$HOME/.bar"
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied"* ]]

  run cat "$TEST_TMP/src/dot_bar"
  [[ "$output" == *"literal CHANGED"* ]]
  [ ! -f "$TEST_TMP/merge-invoked" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/chezmoi-reverse.bats -f "non-template"`
Expected: FAIL — current code treats every file as a template; `chezmoi cat` works for a non-template (returns its content), `diff` shows the change, patch path runs, and since the source has no `.tmpl` directives the patch will (incorrectly) succeed. We want explicit handling so the contract is `applied` via `re-add`, not coincidence.

- [ ] **Step 3: Add the non-template branch**

In `reverse_one`, immediately after the `source-path` resolution, before the rendering step, insert:

```bash
  local base
  base=$(basename "$src")
  case "$base" in
    encrypted_*)
      chezmoi merge "$file" || true
      emit merged "$file"
      return 0
      ;;
    run_*.tmpl)
      emit skipped "$file"
      return 1
      ;;
  esac
  if [[ "$base" != *.tmpl ]]; then
    if chezmoi re-add "$file" >/dev/null 2>&1; then
      emit applied "$file"; return 0
    fi
    emit failed "$file"; return 1
  fi
```

So the full `reverse_one` now reads:

```bash
reverse_one() {
  local file="$1" src rendered patch base
  if ! src=$(chezmoi source-path "$file" 2>/dev/null); then
    emit failed "$file"; return 1
  fi
  base=$(basename "$src")
  case "$base" in
    encrypted_*)
      chezmoi merge "$file" || true
      emit merged "$file"
      return 0
      ;;
    run_*.tmpl)
      emit skipped "$file"
      return 1
      ;;
  esac
  if [[ "$base" != *.tmpl ]]; then
    if chezmoi re-add "$file" >/dev/null 2>&1; then
      emit applied "$file"; return 0
    fi
    emit failed "$file"; return 1
  fi
  rendered="$work/rendered"; patch="$work/patch"
  if ! chezmoi cat "$file" > "$rendered" 2>/dev/null; then
    emit failed "$file"; return 1
  fi
  if diff -u "$rendered" "$file" > "$patch"; then
    emit clean "$file"; return 0
  fi
  cp "$src" "$src.bak"
  if patch --fuzz=0 --no-backup-if-mismatch "$src" < "$patch" >/dev/null 2>&1 \
     && [ ! -e "$src.rej" ]; then
    rm -f "$src.bak"
    emit applied "$file"
    return 0
  fi
  cp "$src.bak" "$src"
  rm -f "$src.bak" "$src.rej" "$src.orig"
  chezmoi merge "$file" || true
  emit merged "$file"
  return 0
}
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `bats tests/chezmoi-reverse.bats`
Expected: 5 of 5 passing.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_chezmoi-reverse tests/chezmoi-reverse.bats
git commit -m "feat(chezmoi-reverse): route plain files through chezmoi re-add"
```

---

### Task 6: Multi-file invocation and aggregate exit code

**Files:**
- Modify: `tests/chezmoi-reverse.bats`

The loop and exit-code aggregation are already implemented (Task 2). This task adds explicit test coverage so the contract is enforced going forward.

- [ ] **Step 1: Write the failing test**

Append to `tests/chezmoi-reverse.bats`:

```bash
@test "multi: clean + applied across two files exits 0 with both statuses" {
  printf 'unchanged\n' > "$TEST_TMP/src/dot_a.tmpl"
  printf 'before\n' > "$TEST_TMP/src/dot_b.tmpl"
  chezmoi apply
  printf 'after\n' > "$HOME/.b"

  run "$SCRIPT" "$HOME/.a" "$HOME/.b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [[ "$output" == *"applied"* ]]
  [[ "$output" == *".a"* ]]
  [[ "$output" == *".b"* ]]
}

@test "multi: unmanaged file causes non-zero exit but other files still process" {
  printf 'x\n' > "$TEST_TMP/src/dot_a.tmpl"
  chezmoi apply

  run "$SCRIPT" "$HOME/does-not-exist" "$HOME/.a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]]
  [[ "$output" == *"clean"* ]]
}
```

- [ ] **Step 2: Run tests to verify both pass**

Run: `bats tests/chezmoi-reverse.bats`
Expected: 7 of 7 passing. (Both new tests should already pass with the current implementation; they exist to lock the behavior in.)

If either fails, the loop or exit-code logic in `main` regressed at some point — re-inspect the `for f in "$@"; do reverse_one "$f" || rc=1; done; exit "$rc"` block at the bottom of the script.

- [ ] **Step 3: Commit**

```bash
git add tests/chezmoi-reverse.bats
git commit -m "test(chezmoi-reverse): lock multi-file invocation and exit-code contract"
```

---

### Task 7: README note for end users

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README**

Run: `cat README.md`

Identify a natural section to extend (likely a "Tools" or "Scripts" section). If no such section exists, add a new top-level section near the bottom.

- [ ] **Step 2: Add a short blurb**

Append (or insert into an existing scripts section):

```markdown
## `chezmoi-reverse`

Propagate edits made to a chezmoi-managed destination file back into its
source template.

```sh
chezmoi-reverse ~/.foo
```

For each file it prints one of `clean`, `applied`, `merged`, `skipped`, or
`failed`. Changes that fall entirely on literal lines are auto-patched into
the `.tmpl` source. Changes that touch a `{{ ... }}` directive route through
`chezmoi merge` for manual three-way merging — make sure `merge.command` is
configured in your chezmoi config.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document chezmoi-reverse"
```

---

### Task 8: End-to-end sanity check in the live environment

**Files:** none modified.

This is a smoke test against the real user environment, not a unit test.

- [ ] **Step 1: Apply chezmoi so the script lands on $PATH**

Run: `chezmoi apply ~/.local/bin/chezmoi-reverse`
Expected: file appears at `~/.local/bin/chezmoi-reverse` with executable bit set.

Verify: `ls -l ~/.local/bin/chezmoi-reverse` shows `x` bits.

- [ ] **Step 2: Pick a low-stakes managed file and dry-run**

Pick any small managed file you can mentally diff, e.g. a config file with at least one literal line. Make a no-op invocation:

Run: `chezmoi-reverse <that-file>`
Expected: `clean<TAB><file>` and exit 0. No source files changed.

Verify: `git -C ~/.local/share/chezmoi status --short` shows no new changes from the script.

- [ ] **Step 3: Done**

No commit. If anything in Steps 1–2 misbehaves, the relevant failure mode should be reproducible as a bats test — add it and loop back through the affected task.

---

## Self-Review Notes

- **Spec coverage:** Tasks 1–4 cover the spec's core algorithm (clean / applied / merged paths). Task 5 covers the non-template branch. The `encrypted_*` and `run_*.tmpl` branches are implemented in Task 5's code drop but not test-covered, matching the spec's "edge cases noted, deferred" section. Task 6 locks the multi-file contract. Task 7 is the README mention. Task 8 is the live smoke test.

- **Placeholder scan:** Every code block contains complete, runnable code. No "TBD" / "TODO" / "handle edge cases" placeholders.

- **Type consistency:** Function names (`emit`, `reverse_one`), variable names (`work`, `src`, `rendered`, `patch`, `base`), and the status vocabulary (`clean`, `applied`, `merged`, `skipped`, `failed`) are identical across all tasks.

- **Known coverage gap:** No automated test exercises the `encrypted_*` or `run_*.tmpl` branches. Both are simple filename-prefix dispatches and visible on inspection. If a future change makes that dispatch non-trivial, add tests at that point.
