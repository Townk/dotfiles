# Full zsh consolidation plan

**Goal:** Make the user's scripts zsh-bound end to end —
`~/.local/{bin,lib,libexec}` and `~/.config/zellij/scripts/*` — removing the
accidental bash layer, with a single zsh-native test suite. Two deliberate
POSIX `#!/bin/sh` exceptions remain (documented).

**Why a bash layer existed (all incidental, none fundamental):**

- `tab-edit` + `copy-pwd` were bash and sourced `common.sh` / `platform.sh`,
  forcing those dual-shell.
- The `bats` suite sourced base libs *into bash*.
- One real bash word-split dependency: `zellij-session.sh` `for e in $external`
  (also a latent bug for its existing zsh callers).

**Tech stack:** zsh 5.9 (custom build at `~/.local/bin/zsh`, resolved via
`/usr/bin/env zsh`), ShellSpec 0.28.1 (run with `--shell zsh`).

---

## End-state conventions

- **Shebang:** every executable script → `#!/usr/bin/env zsh` (picks the custom
  build via PATH; `#!/bin/zsh` would pin the system zsh).
- **Extensions:** sourced libs → `.zsh` (they are all zsh-only after this).
- **No dual-shell scaffolding** anywhere (`if [ -n "${BASH_SOURCE:-}" ] … %x`
  blocks deleted; replaced by the plain zsh `${(%):-%x}` self-path line).
- **POSIX exceptions (keep `#!/bin/sh`, add a one-line "why"):**
  `~/.local/bin/wait-until`, `~/.local/libexec/pinentry-auto`.
- **Spawned-command shell:** zellij `dispatch.sh` launches via `$SHELL -c`
  (was `/bin/bash -c`).

---

## Phase 1 — Test framework: bats → ShellSpec (under zsh)

Foundation: gets tests running under zsh so the dual-shell scaffolding can be
removed safely. Specs reference *current* paths/names (renames come later).

- Add `.shellspec` (`--shell zsh`, `--default-path tests`).
- Translate `tests/*.bats` → `tests/*_spec.sh`:
  `common`, `system-package-common`, `platform` (Include the lib, `When call`),
  `chezmoi-reverse`, `wait-until` (`When run command "$SCRIPT"`).
- `Makefile`: `test:` → `shellspec`.
- Remove `tests/*.bats`. Add `shellspec` to `home/dot_config/packages/Brewfile.tmpl`.
- **Verify:** `make test` green under `~/.local/bin/zsh`.

## Phase 2 — Shebang standardization (dot_local)

- `executable_preview`, `executable_system-update`: `#!/bin/zsh` → `#!/usr/bin/env zsh`.
- **Verify:** both run (`--help`/dry paths).

## Phase 3 — Convert remaining bash scripts to zsh

dot_local:
- `executable_chezmoi-reverse`, `executable_tab-edit`: shebang → `env zsh`
  (bodies already zsh-safe; tab-edit's only barrier was zellij-session.sh).

zellij subsystem (`~/.config/zellij/scripts`):
- Shebang flip on the 10 bash scripts.
- `${BASH_SOURCE[0]}` → `${0:A:h}` (executables) / `${(%):-%x}` (sourced libs):
  `quick-launch`, `quick-launch-zellij`, `zellij-open`, `lib/dispatch.sh` (×2).
- `BASH_REMATCH[1|2]` → `match[1|2]`: `lib/command.sh` (size parser).
- `lib/zellij-session.sh`: add `#!/usr/bin/env zsh` header note; fix
  `for e in $external` → portable `printf '%s\n' "$external" | while IFS= read -r e`.
- `lib/dispatch.sh`: `/bin/bash -c "$cmd"` → `$SHELL -c "$cmd"` (×2).
- **Verify:** `make test` green; smoke each entrypoint that's safe to run.

## Phase 4 — Remove dual-shell scaffolding from libs

All consumers are now zsh, so the `BASH_SOURCE` branches are dead.

- dot_local/lib: `platform.sh`, `system-package-common.sh`,
  `system-secrets-common.sh` (×2), `prompt-common.zsh`, `commit-agent-common.zsh`,
  `zellij.zsh`, `pick-symbols-common.zsh`, `pick-common.zsh` — collapse each
  `if/else` self-path block to the single `${(%):-%x}` line. Update `common.sh`'s
  "works under bash" header comment.
- **Verify:** `make test` green.

## Phase 5 — Rename `.sh` → `.zsh` + fix all references

dot_local/lib: `common`, `platform`, `platform-linux`, `platform-macos`,
`system-package-common`, `system-secrets-common`, `image-protocol-support`.
zellij lib: `command`, `config`, `dispatch`, `zellij-session`.

Reference sites to update (chezmoi source rename + every sourcer):
- All `source "$HOME/.local/lib/<name>.sh"` in dot_local/bin + zellij `copy-pwd`.
- Relative `source "$(dirname …)/…sh"` and `${0:A:h}/lib/…sh` in libs + zellij.
- `platform.sh`'s `source "$_platform_dir/platform-$os.sh"` dispatch.
- `home/.chezmoiignore.tmpl` (platform-linux/macos entries).
- `.setup.sh:142` (system-secrets-common).
- `tests/*_spec.sh` Include paths.
- READMEs (prose).

Then `chezmoi apply`, then **remove orphaned old targets**
(`rm ~/.local/lib/*.sh` that were renamed; same for zellij lib).
- **Verify:** `make test` green; smoke key scripts.

## Phase 6 — Docs + cleanup

- `home/dot_local/bin/README.md`: rewrite the dual-shell rationale → pure-zsh
  with the two documented sh exceptions.
- `README.md`: fix any `*.sh` lib references.
- Add the one-line "why sh" comment to `wait-until` and `pinentry-auto`.
- **Verify:** final `make test` + targeted smoke runs.

---

## Notes / risks

- chezmoi renames don't delete old targets — Phase 5 must `rm` orphans or stale
  `~/.local/lib/*.sh` could be sourced.
- Keep every phase green: scripts convert before libs lose dual-shell; renames
  happen last with refs updated in the same batch.
- `zellij-session.sh` word-split fix is portable and also corrects existing zsh
  callers (`nested-session-check`, `quick-launch-window`, `quick-launch-pick`).
