# Silo S8 — System management

> Multi-ecosystem package sync (brew/cargo/go/npm/snap/uv), unified
> launchd+brew service manager, APFS sparse disk image manager, and the
> "everything at latest" update orchestrator.

This silo has **four independently-dispatchable sub-silos** sharing
`pkg::*`. Pick the one that matches the task; the boundaries below say which
files each owns.

## Setup

```sh
git worktree add ../s08-system-work master
cd ../s08-system-work
```

## Sub-silos

### S8a — Packages  *(the "system packages manager")*
- **Owns:** `home/dot_local/bin/executable_system-package`,
  `system-package-{brew,cargo,go,npm,snap,uv}`;
  `home/dot_local/lib/system-package-common.zsh` (`pkg::*`);
  `home/dot_config/packages/{Brewfile,Brewfile.bootstrap,Cargofile,Gofile,Npmfile,Snapfile,Uvfile}.tmpl`
- **Does NOT own:** `services.toml.tmpl` (S8b), `system-update` (S8d),
  `images.toml` (S8c).
- **Cross-seam contract:** `pkg::restart_services_for <pkg>...` → calls
  `system-service restart-for "$@"` (**S8b** owns the receiver). It restarts
  only services whose backing package was upgraded, only if currently
  running. `pkg::restart_changed <before> <after>` diffs version snapshots
  and restarts only changed. **Preserve this seam.**
- **Manifest grammar** (`pkg::manifest_read`): comment-stripping,
  canonical-name tokenizer (`${(z)}`), `<name> -- <spec>` alternate install
  form for git/local. Shared across all 6 ecosystem workers.
- **Worker contract:** `list [-u|--update] [-a|--all]` TSV rows + `sync`
  (install declared / uninstall extras, strict where safe). Brew worker
  merges `Brewfile.bootstrap`+`Brewfile`, guards mise-owned runtimes
  (`^(go|python|node|...)@?`), tracks taps. Snap worker intentionally does
  **not** remove undeclared (snapd auto-installs base/platform snaps).
- **Where to start:** `system-package-common.zsh`, `bin/system-package`,
  `bin/system-package-brew`. Each worker's `list -u` fans out parallel
  outdated-checks to registries — a good performance starting point.

### S8b — Services
- **Owns:** `home/dot_local/bin/executable_system-service`,
  `system-service-{launchd,brew}`;
  `home/dot_config/packages/services.toml.tmpl`
- **Does NOT own:** the package workers (S8a); `system-update` (S8d).
- **Contract:** `services.toml.tmpl` schema — TOML sections → launchd user
  agents rendered to plists (`yq`/`jq`), `~`-expansion + `command -v`
  resolution of `cmd[0]`, working/log dirs auto-created, bootstrapped into
  `gui/$(id -u)`. OS-aware cache dir (Library/Caches on macOS, `~/.cache`
  elsewhere). `restart-for <pkg>...` maps a package name to services (launchd
  by key or `cmd[0]` basename, brew by name) and restarts **only if currently
  running** — this is the receiver of S8a's `pkg::restart_services_for`.
- **Note:** `services.toml.tmpl` declares agents owned by *other* silos:
  `clipboard-bridge` (S1 protocol, S8b plist), `images-automount` (S8c
  consumer), `llama-sswap`/`local-llm-gateway`/`headroom` (local-LLM stack).
  Editing the plist fields for these is S8b's job; changing the *protocol*
  they expose is the other silo's. Pre-agree if both touch the same section.
- **Where to start:** `bin/system-service-launchd`, `services.toml.tmpl`.

### S8c — Disk images
- **Owns:** `home/dot_local/bin/executable_system-images`;
  `home/dot_config/packages/images.toml.example` (loose/local-only,
  chezmoiignored).
- macOS-only. Each TOML section key is the source of truth for image file /
  `-volname` / mount dir. `sync` is create-missing + automount, **never
  deletes**; `remove` is the separate destructive path. Login automount via
  the `[images-automount]` launchd agent in `services.toml` (S8b owns the
  plist).
- **Where to start:** `bin/system-images`.

### S8d — Update orchestrator
- **Owns:** `home/dot_local/bin/executable_system-update` (383 lines).
- Orchestrates S8a/S8b + external brew/mise/yazi/nvim/pi. **Ordering
  invariants** (preserve): `git fetch`+ff-only (no rebase) → `chezmoi apply`
  → **self re-exec** if source advanced (`SYSTEM_UPDATE_REEXECED`) →
  `brew update` → `mise install/upgrade/prune` **before** `system-package
  sync` (so npm globals don't orphan on a node upgrade) → `system-package
  sync` → `brew cleanup` → `pinentry-touchid -fix` (SSH-skipped) →
  `system-service sync` → `ya pkg upgrade` → yazi lockfile commit/push
  (copies `package.toml` into chezmoi source, not `chezmoi re-add`, to avoid
  the apply lock when invoked from chezmoi's own `run_once`) → `Lazy!
  sync`/`MasonToolsUpdateSync` → `pi update --extensions` → git-pull zsh
  plugins. Detects `CHEZMOI=1` re-entrancy.
- **Where to start:** `bin/system-update`.

## Shared across all S8 sub-silos

- **Shared lib:** `home/dot_local/lib/system-package-common.zsh` (`pkg::*`).
  Per `bin/README.md`, this lib also backs `system-service` and
  `system-images`. **If two S8 sub-silos run concurrently and either edits
  `pkg::*`, serialize that edit.**
- **Out of scope:** the package ecosystems themselves (brew/cargo/go/npm/
  snap/uv — external); mise-managed runtimes (external, but the brew worker
  guards them); chezmoi run-scripts → **S12** (the Snapfile onchange hook
  `run_onchange_after_40` is S12's trigger, S8a owns the Snapfile content);
  `common.zsh` → **S9/S13**.
- **Consumes read-only:** S9 (`common.zsh`), S12 (Snapfile hook), external
  brew/cargo/go/npm/snap/uv/mise.

## TASK

> _<describe the assignment and which sub-silo — e.g. "Review the system
> packages manager (S8a) for performance improvements" >_

**Verify before claiming done:**
- Run `make test` (ShellSpec covers `pkg::*` and the package-domain helpers).
- Reproduce the behavior with a real `system-package <eco> list -u` / `sync`
  (or `system-service list` / `system-update --dry-run` if S8b/S8d).
- The `pkg::restart_services_for` → `system-service restart-for` seam still
  holds (only running services restart).
- Your diff stays within your sub-silo's owner files (don't touch the other
  S8 sub-silos' files unless you've pre-agreed).

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S8 (incl. the S8a↔S8b
  `restart-for` seam and the S8↔S1 `services.toml` shared sections).
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #56–#60.
