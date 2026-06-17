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

## Commit authorship

Do **not** add `Co-Authored-By`, `Signed-off-by`, or any other AI/agent
attribution trailer to commits in this repo — regardless of which agent or
tool authored the change.

The repository owner is the sole author and the sole responsible party for
every change that lands here. A co-author trailer implies shared
responsibility for any problem a change causes, which is not the case: the
owner alone owns the outcome. Generate the commit message (subject + body)
and stop there.
