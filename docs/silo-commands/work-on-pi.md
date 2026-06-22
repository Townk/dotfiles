---
description: Dispatch an agent to the pi coding agent config silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **pi coding agent config** silo of this chezmoi
dotfiles repo.

> pi (AI coding agent CLI) config for BOTH the cloud config home
> (`dot_pi/agent/`) and the local 32K-context config home
> (`dot_pi/agent-local/`). Custom subagents (Architect/Librarian/Reviewer),
> custom skills (code-simplifier, commit), custom theme, a custom
> `pi-rtk-optimizer` extension, dev-extension symlinks, and the declarative
> `modify_settings.json.tmpl` → `pi-settings-merge.tmpl` settings-merge
> contract. `agent-local/` shares extensions/lsp/skills/themes/Librarian
> from `agent/` via symlinks.

## Your scope (owner area — safe to edit)

- `home/dot_pi/agent/` — `AGENTS.md` (cloud baseline behavior file pi
  loads), `README.md`, `lsp.json`, `modify_settings.json.tmpl`,
  `private_models.json.tmpl`
- `home/dot_pi/agent/agents/{Architect,Librarian,Reviewer}.md` — custom
  subagent definitions
- `home/dot_pi/agent/skills/{code-simplifier,commit}/SKILL.md` — custom
  skills
- `home/dot_pi/agent/themes/catppuccin-mocha.json` — custom theme
- `home/dot_pi/agent/extensions/pi-rtk-optimizer/config.json` — CUSTOM
  extension with its own config
- `home/dot_pi/agent/extensions/symlink_pi-{cockpit,plannotator-bridge}.tmpl`
  — dev-extension symlinks resolved from chezmoi data `.pi.devExtensions`
- `home/dot_pi/agent-local/` — `AGENTS.md` (local 32K-context variant:
  "Local Context Budget", "Memory First"), `agents/{Architect,Reviewer}.md`,
  `agents/symlink_Librarian.md.tmpl` (shares Librarian from cloud),
  `modify_settings.json.tmpl`, `private_models.json.tmpl` (local variants),
  `symlink_{extensions,lsp.json,skills,themes}.tmpl` (share from `agent/`)
- `home/dot_pi/web-search.json` — `allowBrowserCookies`, `workflow: none`
- `home/.chezmoitemplates/pi-settings-merge.tmpl` — the FORCE/SEED/KEEP
  settings-merge policy consumed by both `modify_settings.json.tmpl` files
- **pi-specific content blocks in shared chezmoi files** (you own the pi
  content; the **chezmoi** silo owns the machinery — run-script ordering,
  `run_once`/`run_after` mechanics, hash-baking, `.chezmoi*` file
  scaffolding — not your pi blocks):
  - `home/.chezmoi.toml.tmpl` — the `[data.pi.devExtensions]` block
  - `home/.chezmoiignore.tmpl` — the pi-cockpit/pi-plannotator-bridge
    suppression blocks
  - `home/.chezmoiscripts/run_once_after_10-setup-bootstrap-tools.sh.tmpl`
    — the consumer-machine `pi install` blocks
  - `home/.chezmoiscripts/run_after_90-prune-dev-shell-state.sh.tmpl` —
    the `~/.pi/agent-local` dev-shell prune block

⚠ **Dual-config-home sharing:** `agent-local/` shares `extensions/`,
`lsp.json`, `skills/`, `themes/`, and the `Librarian` subagent from
`agent/` via the `symlink_*.tmpl` files. **Editing any shared resource in
`agent/` automatically affects `agent-local/` (and thus `pi-local`).**
Understand the sharing before editing `agent/skills/`, `agent/extensions/`,
`agent/themes/`, `agent/lsp.json`, or `agent/agents/Librarian.md` — a
change there propagates to local-context pi. `agent-local/`'s own-only
files are its `AGENTS.md`, `agents/{Architect,Reviewer}.md`, and its two
`*.tmpl` settings/models variants.

## Out of scope (do not edit — owned by other silos)

- `home/dot_config/zsh/functions.d/commands.sh` `pi-local` function →
  **shell** (S9). That function points `PI_CODING_AGENT_DIR` at
  `~/.pi/agent-local`; you own the *config it targets*, not the function.
  Coordinate with S9 only if the function's env vars
  (`PI_CODING_AGENT_DIR` / `PI_CODING_AGENT_SESSION_DIR`) need to change.
- `home/dot_local/bin/ai-assist-pi`, `ai-commit-pi`,
  `home/dot_local/lib/{assist,commit}-agent-common.zsh` → **AI agent
  harnesses** (S6). S6's wrappers CALL the pi CLI; you own the CLI's
  config. Treat the wrappers as read-only consumers.
- The **chezmoi** silo (S12) owns the *machinery* of the shared files your
  pi blocks live in: run-script ordering/numbering, the `run_once` vs
  `run_after` choice, hash-baking into rendered comments, and the
  `.chezmoi*.{tmpl,yaml}` file scaffolding. You own the pi *content* within
  those files; coordinate with S12 only if you add a NEW run-script (needs
  an ordering number) or restructure a shared file's skeleton.
- The pi CLI (npm `pi-coding-agent`) and the dev extension source repos
  `pi-cockpit` / `pi-plannotator-bridge` (live outside this repo, referenced
  by symlink) — external.

## Contracts you must preserve

- **agent-local ↔ agent symlink sharing** —
  `agent-local/symlink_{extensions,lsp.json,skills,themes}.tmpl` →
  `~/.pi/agent/{extensions,lsp.json,skills,themes}` and
  `agent-local/agents/symlink_Librarian.md.tmpl` →
  `~/.pi/agent/agents/Librarian.md`. A change to a shared resource in
  `agent/` propagates to `agent-local/` (and `pi-local`). Do not break the
  symlink targets; do not duplicate a shared resource into `agent-local/`
  as a real file (that would shadow the symlink).
- **`modify_settings.json.tmpl` declarative-keys merge contract** — the
  `modify_` script declaratively owns STRUCTURAL keys of
  `~/.pi/agent/settings.json` (theme, `extensions` list, `skills` list,
  `packages` list, defaultProvider/model, thinking level by profile,
  `npmCommand` via mise, observational-memory config). Pi rewrites
  settings.json at runtime. The merge policy lives in
  `home/.chezmoitemplates/pi-settings-merge.tmpl`:
  - **FORCE** — keys in `$forced` (`extensions`, `skills`, `packages`,
    `npmCommand`, `observational-memory`) are always taken from `$desired`
    (declaratively owned).
  - **SEED** — any key in `$desired` absent on disk is written once.
  - **KEEP** — everything else (Pi-owned runtime toggles: model, theme,
    thinking, `lastChangelogVersion`, …) keeps whatever Pi last wrote.
  - If the merged result is byte-identical to on-disk, emit the ORIGINAL
    BYTES verbatim so chezmoi reports no diff regardless of jq vs Pi's
    serializer formatting. Only re-serialize when a forced key actually
    drifted (or on first creation).
  Do not move a key between FORCE and KEEP without understanding the
  consequence; do not break the byte-identical-emit invariant.
- **`.pi.devExtensions` dev-extension symlink resolution** —
  `agent/extensions/symlink_pi-{cockpit,plannotator-bridge}.tmpl` resolve
  from chezmoi data `.pi.devExtensions` (declared in the `[data.pi]` block
  of `.chezmoi.toml.tmpl`, which you own). On dev machines (working tree
  present) the value is a path → the symlink points at the live working
  tree. On consumer machines the value is empty → the symlink template is
  suppressed by your `.chezmoiignore.tmpl` block and your
  `run_once_after_10` block runs `pi install git:…` instead. **Adding or
  removing a dev extension touches FOUR places, all owned by this silo**:
  the `.chezmoi.toml.tmpl` `[data.pi.devExtensions]` block, the
  `.chezmoiignore.tmpl` suppression block, the `run_once_after_10` install
  block, AND a new `symlink_*.tmpl` under `dot_pi/agent/extensions/`. Keep
  all four consistent. (Coordinate with S12 only for the run-script
  ordering if you add a brand-new script file.)
- **Profile gating** — `modify_settings.json.tmpl` and
  `private_models.json.tmpl` are profile-gated (`work` / `dev-shell` /
  personal). Preserve the `{{ if eq .profile "…" }}` guards; don't strip
  them.
- **`packages` / `extensions` / `skills` array pinning** — the `packages`
  array pins pi extension packages (`npm:pi-web-access`, `pi-cymbal`,
  `pi-lsp`, `pi-memctx`, `pi-rtk-optimizer`,
  `git:github.com/ghoseb/pi-askuserquestion`, …); the `extensions` /
  `skills` arrays pin what pi loads. These are FORCE keys (declaratively
  owned). Changing them changes what pi loads on every machine.

## What you consume read-only

- **AI agent harnesses (S6):** `ai-assist-pi` / `ai-commit-pi` wrappers
  (they CALL the pi CLI you configure; treat as read-only consumers).
- **shell (S9):** the `pi-local` function in `commands.sh` (points at your
  `agent-local` config; you own the config, not the function).
- **chezmoi (S12):** the *machinery* of the shared files your pi blocks
  live in (run-script ordering, `run_once`/`run_after` mechanics,
  hash-baking, `.chezmoi*` scaffolding). You own the pi content blocks;
  S12 owns the mechanics.
- External: the pi CLI (npm `pi-coding-agent`), dev extension source repos
  `pi-cockpit` / `pi-plannotator-bridge` (outside this repo).

## Where to start

`home/dot_pi/agent/AGENTS.md`, `home/dot_pi/agent/modify_settings.json.tmpl`,
`home/.chezmoitemplates/pi-settings-merge.tmpl`,
`home/dot_pi/agent-local/AGENTS.md`.

## Setup — branch from the freshest master tip into an isolated worktree
```sh
# 1. Learn what origin has. Updates origin/master only — does NOT move local
#    master or touch any other worktree. Safe to run anytime.
git fetch origin master

# 2. Find the freshest master tip, wherever it lives.
ahead=$(git rev-list --count master..origin/master)
behind=$(git rev-list --count origin/master..master)
if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
  echo "master and origin/master diverged ($ahead ahead, $behind behind)." >&2
  echo "Reconcile master before dispatching. Stopping." >&2
  exit 1
elif [ "$ahead" -gt 0 ]; then
  base=origin/master
else
  base=master
fi

# 3. Unique-suffixed branch in a fresh worktree, rooted under chezmoi's
#    state dir (XDG-respecting, matches the repo's environment.sh). The
#    suffix lets two agents work this same silo concurrently without
#    colliding on the branch name. Never check out master itself.
WT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees"
mkdir -p "$WT_ROOT"
suffix=$(date +%s)
git worktree add -b work-on-pi-$suffix "$WT_ROOT/work-on-pi-$suffix" "$base"
cd "$WT_ROOT/work-on-pi-$suffix"
```

## TASK

$ARGUMENTS

## Validate & integrate
- **Self-test (logic):** load the `validate` skill (Agent Skill — invoke
  `/skill:validate` in pi, `/validate` in Claude Code, or read its `SKILL.md`)
  and run **Mode A** — sandbox-`$HOME`, parallel, no lock, no clobber of real
  `$HOME`.
- **Human UX validation:** if the work needs eyeball judgment, ask the user
  whether to enter a UX session, then load the `validate` skill and run
  **Mode B** — the session merges your branch to master and you iterate live.
  The human is in the loop, so this is a human-decided integration.
- **Stop here — do not integrate.** A workflow started by `/work-on-<silo>`
  ends only when the human decides. Once your work is self-tested and
  committed on the `work-on-<silo>-<suffix>` branch, **stop** and leave the
  branch parked in its worktree. Do **not** load the `reconcile` skill or
  merge to master yourself. The human closes the session by typing
  **`/end-work`**, which loads the `reconcile` skill and lands the branch on
  `master` (`flock`-gated, ff-only, `make test` under the lock). Report that
  the branch is ready and stop.

## Verify before claiming done
- Reproduce by running `pi` (cloud) **and** `pi-local` (local) against the
  rendered config; confirm `~/.pi/agent/settings.json` merges without a
  spurious chezmoi diff (byte-identical result → original bytes emitted).
- The `agent-local` ↔ `agent` symlinks resolve:
  `ls -L ~/.pi/agent-local/{extensions,lsp.json,skills,themes}` and
  `ls -L ~/.pi/agent-local/agents/Librarian.md` all reach `~/.pi/agent/`.
- A dev-extension add/remove keeps the dev-vs-consumer split consistent:
  the `.chezmoi.toml.tmpl` `[data.pi.devExtensions]` block, the
  `.chezmoiignore.tmpl` suppression block, the `run_once_after_10` install
  block, and the `symlink_*.tmpl` here all agree (all four are yours).
- Profile guards in `modify_settings.json.tmpl` / `private_models.json.tmpl`
  are preserved.
- Your diff stays within `home/dot_pi/` +
  `home/.chezmoitemplates/pi-settings-merge.tmpl` + your pi content blocks
  in `.chezmoi.toml.tmpl` / `.chezmoiignore.tmpl` / `.chezmoiscripts/`
  (plus an S12-coordinated ordering number if you add a brand-new
  run-script).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "pi coding agent config" section — note the
S12↔pi shared-file hazard on `.chezmoi.toml.tmpl` / `.chezmoiignore.tmpl` /
`run_once_after_10` / `run_after_90`: pi owns the content blocks, S12 owns
the machinery).
