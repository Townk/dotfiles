# Bare-metal recovery — Terminal Time Machine (`system-backup`)

How to come back from `rm -rf ~` (or a dead disk) using the tiered encrypted
restic backups. This page is deliberately self-contained: every step up to §5
works on a **fresh machine with nothing installed** except Homebrew, because
the tool that automates all of this is itself inside the backup.

The division of labor to keep in mind:

- **This backup holds the *unmanaged* half of `$HOME`** — private keys, live
  app state, loose config — plus, for every git project, its working tree and
  a bundle of *unpushed* history.
- **chezmoi reproduces the *managed* half** (`~/.zshenv`, `~/.config/**`,
  `~/.local/bin` scripts, plists) from its source repo — which this backup
  also protects, dirty + unpushed edits included.

No managed file is stored twice, yet everything comes back.

## 0. What you need

- The **restic repo passphrase**, in 1Password as the `backup-repo` secret
  (1Password syncs independently of this machine — that is the point).
- One backup repo: the external SSD (`/Volumes/…/terminal-backup`), the
  OneDrive folder, or — if the machine is alive and only `$HOME` is hurt —
  the local staging repo at `~/.local/state/terminal-backup/repo`.

## 1. Get restic

```sh
brew install restic
```

## 2. Point restic at the deepest surviving repo

```sh
export RESTIC_REPOSITORY=/Volumes/BackupSSD/terminal-backup   # or the OneDrive path
restic snapshots        # enter the passphrase from 1Password; pick the latest good one
```

Prefer the target with `role = "master"` — it never prunes, so it is the
deepest archive.

## 3. Restore the unmanaged half

```sh
restic restore latest --target ~
```

This brings back `~/.ssh` private keys, `~/.config/gnupg/private-keys-v1.d`,
the Atuin history DB + encryption key, unmanaged app config and live state,
project working trees, and `~/.local/state/terminal-backup/wip/` — the git
sidecar directory the next step needs. Partial restores work too
(`--include ~/.ssh`, etc.).

> The chezmoi **age/GPG decryption identity** is part of this restore (or in
> 1Password): the key that unlocks chezmoi's managed encrypted secrets never
> lives only in chezmoi.

## 4. Reconstruct the chezmoi source repo — dirty edits included

The chezmoi source's git remote is its system of record, but the remote does
not have your uncommitted/unpushed work. The sidecar does:

```sh
sh ~/.local/share/chezmoi/.setup.sh   # or your usual chezmoi bootstrap, then:
system-backup restore-project ~/.local/share/chezmoi
```

(If `system-backup` isn't on PATH yet, the restored
`~/.local/bin/system-backup` — or the repo copy under
`home/dot_local/bin/` with `BKP_LIB` pointed at `home/dot_local/lib` — runs
directly.) `restore-project` re-inits the repo, fetches origin, fetches the
unpushed-history bundle from the sidecar, re-aligns HEAD/branch/index around
the restored working tree, and re-registers the stash.

## 5. Reproduce the managed half

```sh
chezmoi apply   # FROM the restored source — uncommitted chezmoi work included
```

`~/.zshenv`, `~/.config/**`, `~/.local/bin` scripts, managed plists — all
reappear, none were ever stored in the backup.

## 6. Reconstruct the other projects

```sh
system-backup restore-project ~/Projects/<repo>   # per project
```

Working tree files are already on disk from step 3; this rebuilds each
`.git` (origin + unpushed branches/commits + stash).

## 7. Re-onboard and resume the schedule

```sh
system-onboard                       # secret slots (incl. backup-repo)
cp ~/.config/backup/config.toml.example ~/.config/backup/config.toml
$EDITOR ~/.config/backup/config.toml # staging path + [[target]]s for THIS machine
system-service sync                  # boots backup-capture / -reconcile / -prune
system-backup status                 # ● targets, fresh snapshot within 30 min
```

## Day-to-day reference

| Task | Command |
|---|---|
| Browse this dir's history | `tm` (or `system-backup browse [path]`) |
| Scrub one file's versions | `tm <file>` |
| Recover deleted files here | `tm --deleted` |
| Restore paths in place | `system-backup restore --snapshot <id> [--force] <path>…` |
| Revert a bad restore | `system-backup undo` |
| Force a capture now | `system-backup now` |
| Health check | `system-backup verify` / `system-backup status` |

Restores are undoable by construction: any `--force` overwrite first snapshots
the live state (tag `bkp-undo`), and `undo` peels it back.
