# quick-launch targets schema

The targets file (`~/.config/zellij/quick-launch-targets.yaml` by default,
overridable via `$QUICK_LAUNCH_TARGETS`) has three top-level lists plus an
optional `tools` table. YAML is the default; `.json` and `.toml` files are
also accepted (parsed via `yq`).

## Top level

| key          | type     | description                                  |
| ------------ | -------- | -------------------------------------------- |
| `tools`      | table    | absolute paths to binaries (see below)       |
| `workspaces` | list     | session-level targets                        |
| `tabs`       | list     | tab-level targets                            |
| `panes`      | list     | pane-level targets (split the current tab)   |

### `tools`

| key      | type   | fallback                         |
| -------- | ------ | -------------------------------- |
| `editor` | string | `$EDITOR`, then `nvim`           |
| `mise`   | string | `mise` on `PATH` (else disabled) |

## Common element fields

Every workspace / tab / pane shares:

| key    | type   | description                                              |
| ------ | ------ | -------------------------------------------------------- |
| `id`   | string | stable key; `quick-launch open <kind> <id>` and dedup    |
| `name` | string | display label + Zellij tab/session name (default: `id`)  |
| `icon` | string | menu glyph; falls back to the action-type icon when omitted |

## `action`

Panes always have an `action`; tabs/workspaces may have one (used when they
have no child panes).

| key                        | type             | description                                           |
| -------------------------- | ---------------- | ----------------------------------------------------- |
| `type`                     | enum             | `Shell` \| `Edit` \| `Run` \| `Remote`                |
| `cwd`                      | string           | working directory (`~` expanded)                      |
| `args`                     | list of strings  | meaning depends on `type` (see below)                 |
| `label`                    | string           | overrides `name` in the fuzzy menu                    |
| `set_environment_variables`| map              | reserved (not yet applied)                            |
| `python_venv`              | `auto` \| path   | activate a venv before the command                    |
| `mise_env`                 | `auto` \| path   | `eval "$(mise env [--config <path>])"` before command |

### `type` semantics

- `Shell` — interactive shell in `cwd`. `args` ignored. `cwd`/venv/mise apply via the pane's working directory only.
- `Edit` — `<editor> <args...>`, with relative `args` resolved against `cwd`.
- `Run` — `args` joined with `&&`.
- `Remote` — `ssh <args...>` (note: no `cd`/venv/mise prefix, matching the original plugin).

The command prefix is assembled as `cd <cwd>; <python_venv>; <mise_env>; <command>`.

When opened as a **tab**, the target inherits the default `new_tab_template`
(so the zj-hud bar and floating which-key/search panes are present). A command
target (`Edit`/`Run`/`Remote`) runs as the tab's initial command and the tab
closes when that command exits; a `Shell` tab is a plain interactive shell.

## Pane-only fields

| key         | type                         | description                                  |
| ----------- | ---------------------------- | -------------------------------------------- |
| `direction` | `down`\|`up`\|`left`\|`right` | split direction off the previous pane         |
| `size`      | string (e.g. `30%`)          | size of this pane (layouts only)             |
| `moveFocus` | bool                         | reserved (not yet applied)                   |
| `optional`  | bool                         | when true, not auto-opened with its tab/workspace; stays launchable from the pane menu, offered there only while its parent workspace/tab is active |

## Nesting

- A `tab` may contain `panes` (a split chain).
- A `workspace` may contain `tabs` (each becomes a session tab) and/or `panes` (appended to the first tab).

## CLI

```
quick-launch menu   pane|tab|workspace        # fuzzy-pick, then open
quick-launch open   pane|tab|workspace ID     # open directly (focus-or-create)
quick-launch layout pane|tab|workspace ID     # print generated KDL / command
quick-launch list  [pane|tab|workspace]       # list defined targets
```
