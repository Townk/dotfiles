# AGENTS.md — chezmoi dotfiles repo

## Post-edit requirement

This repository is a [chezmoi](https://www.chezmoi.io) source directory.
Files here are **not** the live config — they are templates/sources that
chezmoi renders into `$HOME`.

After every file write or edit in this repo, run:

```bash
chezmoi apply
```

This propagates your changes to the live system. Without it, edits remain
in the source tree only and the running config stays stale.

## Clearing untracked files for a git operation — never `rm -rf` a parent

Git collisions during rebase/checkout/merge are **per-file**, not per-
directory. A directory blocking an operation often contains a *gitignored*
sibling that is invisible to `git ls-files --others --exclude-standard` (so
it won't appear in a collision analysis) but is fully visible to `rm -rf`.
This repo has one: `docs/superpowers/` (`.gitignore:36`, "agent working
notes, kept on disk only"). It was lost forever on 2026-06-21 to a careless
`rm -rf docs/` meant to clear only 16 colliding tracked files — the
rebase restored the tracked files but could not restore the gitignored dir
(never tracked, no Time Machine, no snapshots, `rm` bypasses Trash).

**Rules when an untracked path blocks a git operation:**

1. **Enumerate before deleting.** `ls -la <dir>` AND `git check-ignore <dir>/*`
   to see gitignored entries — they are the precious-but-unversioned ones.
2. **Remove only the specific colliding paths**, never the parent directory:
   `rm -f docs/file1 docs/file2 ...` over an explicit list. A gitignored
   sibling survives automatically.
3. **If the colliding set is large**, move the whole dir aside first, then
   rebase, then move the gitignored bits back:
   `mv docs docs.bak` → rebase → `mkdir docs && mv docs.bak/superpowers docs/ && rm -rf docs.bak`.
4. **Never run `rm -rf <parent>/` to clear a git collision.** Treat any `rm`
   near a gitignored path as a data-loss operation requiring explicit
   confirmation of the directory's contents first.

## Commit authorship

Do **not** add `Co-Authored-By`, `Signed-off-by`, or any other AI/agent
attribution trailer to commits in this repo — regardless of which agent or
tool authored the change.

The repository owner is the sole author and the sole responsible party for
every change that lands here. A co-author trailer implies shared
responsibility for any problem a change causes, which is not the case: the
owner alone owns the outcome. Generate the commit message (subject + body)
and stop there.
