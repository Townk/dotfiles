# Pi memory integration: pi-memctx + pi-observational-memory

**Date**: 2026-05-22 **Goal**: Add persistent memory to the Pi coding agent in a
way that is "installed, configured, and out of the way" — no manual recall/save
gestures during normal use.

## Why these two together

They cover different memory layers and don't overlap:

| Extension                 | Scope                         | What it remembers                                                                           | Hook points used                                                                                                |
| ------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `pi-memctx`               | Per-project knowledge         | Decisions, observations, runbooks, action notes — durable project context as Markdown packs | `session_start`, `before_agent_start`, `agent_end`, `tool_result`, `session_before_compact`, `session_shutdown` |
| `pi-observational-memory` | Per-branch session continuity | In-session observations + reflections that survive compaction cycles                        | `turn_end`, `agent_end`, `session_before_compact`                                                               |

Together: memctx builds long-term _project_ knowledge that crosses sessions;
observational-memory keeps the _current_ session coherent through context
compactions. Both are fully hook-driven (no agent tool-calls required for the
read/write loop), which is the stated criterion.

Overlapping hooks (`agent_end`, `session_before_compact`) are additive — Pi's
EventBus supports multiple listeners. memctx writes to packs,
observational-memory writes to its ledger; no shared state.

## Decisions (picks made)

1. **Profile gating**: install under `personal` only, matching where the rest of
   the personal extensions live in `dot_pi/agent/settings.json.tmpl`. Work
   profile gets none of this (different model, different workflow). Can be
   extended later.

2. **`MEMCTX_AUTOSAVE=auto`**: exported from `dot_zshrc` alongside `GPG_TTY` /
   `EDITOR` / `USERNAME` (line ~207-210). Documented as the env var to skip the
   `/memctx-review` manual queue. Picked the env var route over
   `~/.config/pi-memctx/config.json` because it's the canonical surface in the
   README and keeps the chezmoi diff to one line.

3. **qmd**: install `@tobilu/qmd` globally via `Npmfile.tmpl` (personal-only).
   Optional dependency for both memctx and pi-memory, but it materially speeds
   retrieval (BM25 + vectors vs. grep fallback). One-line cost, real benefit.

4. **pi-observational-memory config**: override only `compactAfterTokens` to
   match Kimi K2.6's 256k context window at 80% =
   **`compactAfterTokens: 204800`**. Leave `observeAfterTokens: 10000`,
   `reflectAfterTokens: 20000`, `passive: false`, `agentMaxTurns: 16` at
   their defaults — they fire more frequently relative to the bigger compact
   budget, which means finer-grained memory at the cost of a few more
   background LLM calls per session. Acceptable tradeoff for "just works".
   Memory worker model unset → inherits session model (`kimi-k2.6` on
   `opencode-go`). Config goes under the `observational-memory` key in
   `~/.pi/agent/settings.json`.

5. **First-run per workspace**: NOT needed as a manual step. memctx's
   `autoBootstrap` defaults to `"ask"`, which means on every `session_start`
   in a project-shaped directory without a pack, memctx already calls
   `ctx.ui.confirm("Create memory pack?", ...)` and creates the pack on yes
   (per `index.ts:4751-4775`). Valid values are `"off" | "ask" | "on"` — `"on"`
   currently behaves like `"ask"` (both call `ctx.ui.confirm`), so the
   default is the right pick. **No `autoBootstrap` override needed.**

6. **No new chezmoi templates**: the existing `personal` profile gate in
   `settings.json.tmpl` is sufficient. No `dot_config/pi-memctx/` directory
   needed (env var carries the only override, and `autoBootstrap` default is
   already what we want).

## File changes

### A. `dot_pi/agent/settings.json.tmpl`

Add two entries to the `personal`-gated section of `packages`:

```diff
 {{- if eq .profile "personal" }}
     "npm:pi-web-access",
     "npm:pi-cymbal",
     "npm:pi-lsp",
     "npm:glimpseui",
     "npm:@tintinweb/pi-subagents",
     "npm:@mario-gc/pi-context7",
     "npm:@plannotator/pi-extension",
     "git:github.com/ghoseb/pi-askuserquestion",
+    "npm:pi-memctx",
+    "npm:pi-observational-memory",
 {{- end }}
```

No `extensions` array change needed — packages are auto-discovered under
`~/.pi/agent/extensions/<name>/` after `pi install`.

Also add the `observational-memory` config block at the top level of the
settings object (inside the `personal` profile gate, since the package itself
is personal-only):

```diff
   "quietStartup": true,
   "terminal": {
     "showTerminalProgress": true
-  }
+  },
+{{- if eq .profile "personal" }}
+  "observational-memory": {
+    "compactAfterTokens": 204800
+  }
+{{- end }}
 }
```

The 204800 value is `256000 * 0.8`, matching the user's Kimi K2.6 context
window at 80%. All other observational-memory settings inherit defaults.

### B. `dot_zshrc`

Add a single export near the existing env-var block (line ~207-210):

```diff
 export GPG_TTY=$TTY
 export EDITOR=nvim
 export USERNAME='Thiago Alves'
+
+# pi-memctx: auto-persist durable memory candidates without /memctx-review
+export MEMCTX_AUTOSAVE=auto
```

### C. `dot_config/packages/Npmfile.tmpl`

Add qmd inside the `personal` profile block, near the existing personal-only
entry:

```diff
 {{ if eq .profile "personal" -}}
 @anthropic-ai/claude-code
+@tobilu/qmd
 {{- end }}
```

## What `chezmoi apply` will do

1. Rewrite `~/.pi/agent/settings.json` from the template (now lists both memory
   packages).
2. Rewrite `~/.zshrc` (adds the env export).
3. Rewrite `~/.config/packages/Npmfile` (adds qmd).
4. The existing `run_once_after_setup-bootstrap-tools.sh.tmpl` already triggers
   `pi install` in consumer mode and `system-package npm sync` — those will pick
   up the new packages on next bootstrap.

If `run_once_*` doesn't re-fire (already-run hash), the manual follow-ups are:

```sh
system-package npm sync   # installs qmd globally
pi install                # pulls pi-memctx + pi-observational-memory
```

## Per-workspace setup — fully automatic

memctx prompts you to bootstrap on first `pi` invocation in any
project-shaped directory (it looks for git/package markers). You'll see:

> `Create memory pack?  [Y/n]`

Say yes once per workspace and the pack is created at
`~/.pi/agent/memory-vault/packs/<workspace-slug>/`. From then on, the
gateway runs automatically on every prompt.

If you want to opt-out for a specific workspace, run `pi` once and answer
`n`. To disable the prompt globally: `export MEMCTX_AUTO_BOOTSTRAP=off`
(don't do this unless you have a reason).

`pi-observational-memory` needs no per-workspace setup — its ledger lives
under `~/.pi/agent/` and scopes itself per-branch.

### Why not a custom "bootstrap-check" extension?

I considered building a small extension that detects an uninitialized
workspace and prompts to run `/memctx-init`. **Not needed:** memctx's own
`session_start` hook (`index.ts:4751-4775`) already does exactly this via
`ctx.ui.confirm`. The default `autoBootstrap: "ask"` is the same UX you
described. Building a sibling extension would duplicate built-in behavior.

## Verification after apply

```sh
# Settings actually contain the new packages
jq '.packages' ~/.pi/agent/settings.json

# Extensions present on disk
ls ~/.pi/agent/extensions/ | grep -E 'memctx|observational'

# qmd binary on PATH
command -v qmd && qmd --version

# Env var in current shell (need fresh shell or `source ~/.zshrc`)
echo $MEMCTX_AUTOSAVE   # expect: auto
```

## Rollback

```sh
chezmoi apply --reverse <each touched file>
# or remove the three diffs above and re-apply
pi uninstall pi-memctx pi-observational-memory
npm uninstall -g @tobilu/qmd
```

No data is destructive: memctx packs stay in each workspace's `packs/` dir,
observational-memory's ledger stays under `~/.pi/agent/`. You can re-enable
later without losing memory.

## Resolved questions

1. **Profile scope**: personal-only (confirmed).
2. **qmd**: yes (confirmed).
3. **observational-memory tunables**: `compactAfterTokens: 204800`
   (256k * 0.8 for Kimi K2.6), others at default (confirmed).
4. **memctx bootstrap auto-prompt**: built into memctx already
   (`autoBootstrap: "ask"` default). No extra extension needed.
