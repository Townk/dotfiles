# Silo S13 — Cross-cutting utilities

> The shared coordination silo: `notify` (the Hammerspoon-OSD sender),
> `wait-until` (standalone POSIX-sh polling), `chezmoi-reverse`
> (destination→source drift propagation), `tab-edit` (multiplexer-aware
> nvim launcher), and the `common.zsh` stdlib + `platform::*` shared with S9.

## Setup

```sh
git worktree add ../s13-utilities-work master
cd ../s13-utilities-work
```

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_notify` (front-end),
  `executable_wait-until` (standalone POSIX sh),
  `executable_chezmoi-reverse`, `executable_tab-edit`
- `home/dot_local/lib/common.zsh` (`notify` primitive, stdlib) — **shared
  with S9**
- `home/dot_local/lib/platform.zsh` + `platform-{macos,linux}.zsh` —
  **shared with S9**
- `home/dot_local/libexec/local-llm-gateway`, `local-llm-bench`,
  `pinentry-auto` (libexec, reached by absolute path)

## Out of scope (do not edit — owned by other silos)

- The `hs` CLI *receivers* (`notify`/`notifyAnsi` globals) → **S3**.
- The Zellij session resolver (`resolve_session`) that `tab-edit` calls →
  **S1**.
- The chezmoi apply machinery that `chezmoi-reverse` cooperates with →
  **S12**.
- The `symbols.db` that `glyph:` icons resolve against → **S5**.

## Contracts you must preserve

- **`notify [--icon SPEC] [--sound NAME] [--ansi] MESSAGE...`** — SPEC = SVG
  name / `glyph:<nerd-font-name>` / `swatch:#RRGGBB`. The *primitive* in
  `common.zsh` is best-effort (silent on missing `hs`); the *bin* is a
  hard-error front-end. Serializes args as Lua string literals to `hs -c`.
  `gtimeout`-capped. Consumed on hot paths (S1 `copy-pwd`).
- **`chezmoi-reverse [--no-merge] [--] <file>...`** — destination→source
  propagation. `--no-merge` emits `needs-merge` (per-file tabular status:
  `clean`/`applied`/`merged`/`needs-merge`/`skipped`/`failed`) instead of
  interactive `chezmoi merge`. Skips `encrypted_*`/`run_*`/`symlink_*`/
  `modify_*`. **Consumed by S2's nvim autocmd** — the `needs-merge` exit
  semantics are the seam.
- **`tab-edit`** — opens files in nvim inside the focused Zellij session
  (resolves pane TTY → Zellij client → session via S1's `resolve_session`),
  falls back to bare WezTerm. Tab title + CWD=git root. Engine behind the S12
  Finder droplet + Linux desktop handler.
- **`wait-until [--timeout 2s] [--interval 0.1] [--quiet] -- CMD...`** —
  standalone POSIX sh, polls before first sleep. Any caller can `exec` it.
- **`platform::*`** — see S9; shared lib.

## What you consume read-only

- S1: `resolve_session` for `tab-edit`
- S3: `hs` CLI for `notify`
- S5: `symbols.db` for `glyph:` icons
- chezmoi: for `chezmoi-reverse`

## Where to start

`home/dot_local/bin/notify`, `bin/chezmoi-reverse`, `bin/tab-edit`,
`home/dot_local/lib/common.zsh`.

## TASK

> _<describe the assignment — e.g. "Review `chezmoi-reverse` patch
> robustness; unified-diff apply occasionally fails on templated whitespace" >_

**Verify before claiming done:**
- Run `make test` (ShellSpec covers `common.zsh` primitives, `for_each`,
  `wait-until`, `platform::*`; `tests/chezmoi-reverse_spec.sh` needs
  `chezmoi` on PATH).
- `notify`'s `--icon`/`--sound`/`--ansi` contract and the `hs` literal
  serialization unchanged (S1 hot-path `copy-pwd` depends on it).
- `chezmoi-reverse`'s `--no-merge` → `needs-merge` status contract unchanged
  (S2's nvim `BufReadPre` autocmd depends on it).
- `common.zsh` + `platform*.zsh` are shared with S9 — if you add a primitive,
  follow the `bare = stdlib, `::` = module` convention and confirm S9's
  consumers aren't broken.
- Your diff stays within the owner area above.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S13 (S13↔S9
  `common.zsh` sharing, S13↔S2 `chezmoi-reverse` seam).
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #85–#90.
