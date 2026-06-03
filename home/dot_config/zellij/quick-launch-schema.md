# Quick-Launch Targets Schema

The targets file (`~/.config/zellij/quick-launch-targets.yaml` by default,
override via `$QUICK_LAUNCH_TARGETS`) has three top-level lists plus an
optional `tools` table. YAML is the default; `.json` and `.toml` files are also
accepted (parsed via `yq`).

## Top Level

| key          | type  | description                                |
| ------------ | ----- | ------------------------------------------ |
| `tools`      | table | Absolute paths to binaries (see below)     |
| `workspaces` | list  | Session-level targets                      |
| `tabs`       | list  | Tab-level targets                          |
| `panes`      | list  | Pane-level targets (split the current tab) |

### `tools`

| key      | type   | fallback                         |
| -------- | ------ | -------------------------------- |
| `editor` | string | `$EDITOR`, then `nvim`           |
| `mise`   | string | `mise` on `PATH` (else disabled) |

## Common Element Fields

Every workspace / tab / pane shares:

| key    | type   | description                                                 |
| ------ | ------ | ----------------------------------------------------------- |
| `id`   | string | Stable key; `quick-launch open <kind> <id>` and dedup       |
| `name` | string | Display label + Zellij tab/session name (default: `id`)     |
| `icon` | string | Menu glyph; falls back to the action-type icon when omitted |

## `action`

Panes always have an `action`; tabs/workspaces may have one (used when they have
no child panes).

| key                         | type            | description                                           |
| --------------------------- | --------------- | ----------------------------------------------------- |
| `type`                      | enum            | `Shell` \| `Edit` \| `Run` \| `Remote` \| `External`  |
| `cwd`                       | string          | Working directory (`~` expanded)                      |
| `args`                      | list of strings | Meaning depends on `type` (see below)                 |
| `label`                     | string          | Overrides `name` in the fuzzy menu                    |
| `set_environment_variables` | map             | Reserved (not yet applied)                            |
| `python_venv`               | `auto` \| path  | Activate a `venv` before the command                  |
| `mise_env`                  | `auto` \| path  | `eval "$(mise env [--config <path>])"` before command |

### `type` Semantics

- `Shell` — interactive shell in `cwd`. `args` ignored. `cwd`/`venv`/`mise` apply
  via the pane's working directory only.
- `Edit` — `<editor> <args...>`, with relative `args` resolved against `cwd`.
- `Run` — `args` joined with `&&`.
- `Remote` — `ssh <args...>` (note: no `cd`/`venv`/`mise` prefix, matching the
  original plugin).
- `External` — execute `args` directly as a local command array outside Zellij.
  This is for targets that must not be wrapped in a local tab/pane/session.

The command prefix is assembled as
`cd <cwd>; <python_venv>; <mise_env>; <command>`.

When opened as a **tab**, the target inherits the default `new_tab_template` (so
the `zj-hud` bar and floating which-key/search panes are present). A command
target (`Edit`/`Run`/`Remote`) runs as the tab's initial command and the tab
closes when that command exits; a `Shell` tab is a plain interactive shell. An
`External` target bypasses local Zellij creation entirely.

## Pane-Only Fields

| key         | type                          | description                                                                                                                                         |
| ----------- | ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `direction` | `down`\|`up`\|`left`\|`right` | Split direction off the previous pane                                                                                                               |
| `size`      | string (e.g. `30%`)           | Size of this pane (layouts only)                                                                                                                    |
| `moveFocus` | bool                          | Reserved (not yet applied)                                                                                                                          |
| `optional`  | bool                          | When true, not auto-opened with its tab/workspace; stays launchable from the pane menu, offered there only while its parent workspace/tab is active |

## Nesting

- A `tab` may contain `panes` (a split chain).
- A `workspace` may contain `tabs` (each becomes a session tab) and/or `panes`
  (appended to the first tab).

## CLI

```
quick-launch menu   pane|tab|workspace        # fuzzy-pick, then open
quick-launch open   pane|tab|workspace ID     # open directly (focus-or-create)
quick-launch layout pane|tab|workspace ID     # print generated KDL / command
quick-launch list  [pane|tab|workspace]       # list defined targets
```
