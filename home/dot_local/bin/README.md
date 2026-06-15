# `~/.local/bin` — personal scripts

Hand-rolled command-line tools, deployed by chezmoi from
`home/dot_local/bin/`. This file is reference material and is **not** deployed
to `~/.local/bin` (see the `.chezmoiignore.tmpl` entry).

The scripts are thin front-ends over a small set of **sourced libraries** in
`~/.local/lib`. The goal: no primitive is implemented twice, and each script is
mostly its own unique logic.

## Library layering

Everything bottoms out at one bash-and-zsh-compatible base; the rest are
zsh-only modules that source it.

```
common.sh ............. base "stdlib": C_* palette, log_info/log_ok/log_warn/
   (bash + zsh)         log_error/die, is_help, args_contain_help, require_cmd,
                        have_tty, for_each
   ├── prompt-common.zsh ......... prompt::required/default/secret/choice/confirm
   ├── pick-common.zsh ........... pick::*  (the fzf picker engine)
   │     └── pick-symbols-common.zsh   pick_symbols::*  (glyph/gitmoji shared bits)
   ├── system-package-common.sh .. pkg::*  (manifest parsing, version diff,
   │     (bash + zsh)              restart hook, outdated rows, table print)
   ├── system-secrets-common.sh .. sec::*  (slots, SOPS/age, 1Password, leak audit)
   │     └── (also sources prompt-common.zsh)
   ├── platform.sh ............... platform::*  (OS shim → platform-macos.sh /
   │     (bash + zsh)              platform-linux.sh: launch GUI app, raise window)
   └── commit-agent-common.zsh ... cagent::*  (spinner, plan summary/dry-run,
                                    stage/commit loop)
```

`common.sh`, `system-package-common.sh`, and the `platform*.sh` files stay
bash-sourceable (the bats suite — and nvim-wez.sh — source them under bash);
the `*.zsh` modules are zsh-only. `platform.sh` dispatches on `$PLATFORM_OS`
(default `uname -s`, overridable in tests) and only the active OS's
implementation is deployed (see `.chezmoiignore.tmpl`).

## Naming conventions

- **bare names** (`die`, `log_info`, `for_each`) = the base/stdlib, used everywhere.
- **`module::fn`** (`pkg::manifest_read`, `sec::rebuild_slot`, `pick::start`) =
  a function owned by a specific library module.
- **`MODULE_UPPER`** (`PKG_DIR`, `LAUNCH_AGENTS`) = module constants — shell
  variable names can't contain `::`, so only functions are namespaced.

The rule reads as: *bare = stdlib, `::` = a library module.*

## Scripts by category

| Category | Scripts | Backing library |
|---|---|---|
| AI-driven git commits | `commit-ai`, `commit-cursor` | `commit-agent-common.zsh` |
| Symbol pickers (fzf) | `pick-glyph`, `pick-gitmoji` | `pick-symbols-common.zsh` → `pick-common.zsh` |
| File preview (fzf/yazi) | `preview` | — |
| Editor/terminal glue | `nvim-wez.sh`¹, `pinentry-auto`¹ | `platform.sh` (nvim-wez) |
| chezmoi tooling | `chezmoi-reverse` | — |
| Package management | `system-package` + `system-package-{brew,cargo,go,npm,snap,uv}` | `system-package-common.sh` |
| Service management | `system-service`, `system-service-{launchd,brew}` | `system-package-common.sh` |
| Secrets & onboarding | `system-secrets`, `system-onboard` | `system-secrets-common.sh` |
| Orchestration | `system-update` | — |
| Utility | `wait-until` | — (standalone POSIX `sh`) |

¹ macOS-only; excluded from other hosts via `.chezmoiignore.tmpl`.

## `wait-until`

A standalone POSIX-`sh` helper used to replace fixed `sleep`s:

```sh
wait-until [--timeout 2s] [--interval 0.1] [--quiet] -- CMD [ARG...]
```

Runs `CMD` until it exits 0 or the timeout elapses, checking once before the
first sleep (so an already-true condition returns immediately). It's a bin (not
a sourced function) so `sh`/`bash`/`zsh` callers can all share it.

## Tests

`bats` suites live in `tests/` at the repo root (not deployed):

```sh
bats tests/common.bats tests/wait-until.bats tests/system-package-common.bats
```

They source the libraries directly from the repo path under bash, so they cover
the base primitives, `for_each`, `wait-until`, and the package-domain helpers.
`tests/chezmoi-reverse.bats` additionally needs `chezmoi` on PATH.
