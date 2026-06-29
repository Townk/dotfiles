# `~/.local/bin` — personal scripts

Hand-rolled command-line tools, deployed by chezmoi from
`home/dot_local/bin/`. This file is reference material and is **not** deployed
to `~/.local/bin` (see the `.chezmoiignore.tmpl` entry).

The scripts are thin front-ends over a small set of **sourced libraries** in
`~/.local/lib`. The goal: no primitive is implemented twice, and each script is
mostly its own unique logic.

Backend helpers that are invoked by *other programs* (never typed by the user,
never on `PATH`) live in `~/.local/libexec/` instead. Each is reached by an
absolute path from its caller, so it never needs to be on `PATH`:

- `pinentry-auto` — gpg-agent's `pinentry-program` (set in `gpg-agent.conf`);
- `pick-glyph`, `pick-gitmoji` — the fzf symbol pickers, driven by the zellij
  `pick-{glyph,gitmoji}-zellij` adapters (`Ctrl+Shift+u` / `Ctrl+Shift+g`);
  backed by `pick-symbols-common.zsh` → `pick-common.zsh`.
- `pick-list` — a generic standalone front-end to `pick::start`, used by
  `zj::pick` (in `zellij.zsh`) to run a picker inside a Zellij floating pane.
- `ics-view`, `sqlite-view`, `disk-image-view` — rich file preview renderers
  driven by `preview` and Yazi; they are implementation details, not general
  shell commands.
- The AI terminal assistant is now the single `ai-playbook` Go binary
  (`~/Projects/langs/go/ai-playbook`, manually `go install`ed), which subsumes the
  former `ai-assist-*` shell stack (popup/input/shell/run/ask/remember/triage/
  render/pager/harness wrappers). It is launched by the `ai-assist-trigger` ZLE
  widget (bound to `Ctrl+Shift+/`, delivered as kitty `CSI 47;6u` by
  `zj-context-keys`), which just runs `ai-playbook troubleshoot`.

## Library layering

Everything bottoms out at one base library; all of it is zsh.

```
common.zsh ............. base "stdlib": C_* palette, log_info/log_ok/log_warn/
                        log_error/die, is_help, args_contain_help, require_cmd,
                        have_tty, for_each
   ├── prompt-common.zsh ......... prompt::required/default/secret/choice/confirm
   ├── pick-common.zsh ........... pick::*  (the fzf picker engine)
   │     ├── pick-symbols-common.zsh   pick_symbols::*  (glyph/gitmoji shared bits)
   │     └── zellij.zsh ............ zj::*  (zj::pick: drop-in for pick::start
   │                                 that floats the picker when zellij is present)
   ├── system-package-common.zsh .. pkg::*  (manifest parsing, version diff,
   │                              restart hook, outdated rows, table print)
   ├── system-secrets-common.zsh .. sec::*  (slots, SOPS/age, 1Password, leak audit)
   │     └── (also sources prompt-common.zsh)
   ├── platform.zsh ............... platform::*  (OS shim → platform-macos.zsh /
   │                              platform-linux.zsh: launch GUI app, raise window)
   ├── commit-agent-common.zsh ... cagent::*  (spinner, plan summary/dry-run,
                                    stage/commit loop)
   └── assist-agent-common.zsh ... assist::*  (session pin, request parsing,
                                    KB paths, system prompt, docked-pane spawn,
                                    worker engine)
```

Every library is zsh; the ShellSpec suite sources them under zsh.
`platform.zsh` dispatches on `$PLATFORM_OS` (default `uname -s`, overridable in
tests) and only the active OS's implementation is deployed (see
`.chezmoiignore.tmpl`).

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
| AI-driven git commits | `ai-commit` + `ai-commit-{pi,cursor}` | `commit-agent-common.zsh`, `zellij.zsh` |
| AI terminal assistant | `ai-playbook` (Go binary; not a script here) | — |
| File preview (fzf/yazi) | `preview` | — |
| Editor/terminal glue | `tab-edit`² | `platform.zsh` (tab-edit) |
| chezmoi tooling | `chezmoi-reverse` | — |
| Package management | `system-package` + `system-package-{brew,cargo,go,npm,snap,uv}` | `system-package-common.zsh` |
| Service management | `system-service`, `system-service-{launchd,brew}` | `system-package-common.zsh` |
| Disk images | `system-images`¹ | `system-package-common.zsh` |
| Secrets & onboarding | `system-secrets`, `system-onboard` | `system-secrets-common.zsh` |
| Orchestration | `system-update` | — |
| Notifications | `notify` | `common.zsh` (the `notify` primitive) |
| Utility | `wait-until` | — (standalone POSIX `sh`) |

¹ macOS-only; excluded from other hosts via `.chezmoiignore.tmpl`.
² macOS + graphical Linux; excluded from the headless dev-shell and other
non-GUI hosts via `.chezmoiignore.tmpl`. On Linux a `run_onchange` generates a
`tab-edit.desktop` handler (see `.chezmoiscripts/`).

## `notify`

Our replacement for `terminal-notifier` (whose cross-app posting and custom
icons broke on recent macOS). It shows a transient notification through the
running Hammerspoon's custom OSD:

```sh
notify [--icon SPEC] [--sound NAME] [--ansi] MESSAGE...
```

The actual work lives in the `notify` primitive in `common.zsh`, so any script
that already sources the library can call `notify …` directly — no extra
process between it and Hammerspoon's `hs` CLI. The bin is the standalone
front-end (help text, argument handling, and a hard error when Hammerspoon
isn't running). The library function is best-effort instead: it returns
non-zero quietly so hot paths (e.g. the zellij `copy-pwd` helper) can ignore a
missing OSD.

## `wait-until`

A standalone POSIX-`sh` helper used to replace fixed `sleep`s:

```sh
wait-until [--timeout 2s] [--interval 0.1] [--quiet] -- CMD [ARG...]
```

Runs `CMD` until it exits 0 or the timeout elapses, checking once before the
first sleep (so an already-true condition returns immediately). It's a
standalone bin kept in POSIX `sh` on purpose: a dependency-free polling
primitive any caller can `exec`, regardless of the caller's shell.

## Tests

[ShellSpec](https://shellspec.info/) suites live in `tests/` at the repo root
(not deployed) and run under zsh (`.shellspec` pins `--shell zsh`):

```sh
make test     # or: shellspec
```

They source the libraries directly from the repo path under zsh, so they cover
the base primitives, `for_each`, `wait-until`, `platform::*`, and the
package-domain helpers. `tests/chezmoi-reverse_spec.sh` additionally needs
`chezmoi` on PATH.
