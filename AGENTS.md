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
