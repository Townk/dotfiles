---
description: Dispatch an agent to the secrets & onboarding silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **secrets & onboarding** silo of this chezmoi dotfiles
repo.

> Leak-safe, slot-based secrets system for a **public** repo: dual
> 1Password (human) / SOPS+age (headless) backends, opaque slot IDs, leak
> auditing, and full machine onboarding.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_system-secrets`, `executable_system-onboard`
- `home/dot_local/lib/system-secrets-common.zsh` (`sec::*`, 24K — also sources
  `prompt-common.zsh`)
- `home/dot_config/zsh/private_secrets.d/private_slot-*.sh.tmpl`
- `home/.chezmoidata/secrets.yaml` (manifest of env-var NAMES + prompts +
  `requiredFor` profiles — **no values**)
- `secrets/<slot>.sops.sh` (outside the chezmoi source root), `.sops.yaml`,
  `.leak-patterns`
- GPG chezmoiscript `run_after_25-setup-gpg-key.sh.tmpl` + the op-daemon
  reaper `run_before_05-reap-stale-op-daemon.sh.tmpl` (trigger wiring is
  **chezmoi**; the *logic* is this silo)

## Out of scope (do not edit — owned by other silos)

- The 1Password CLI / SOPS / age tools (external).
- The `op-cache-v1` content-hash cache is this silo's own (yours).
- The operator map `~/.config/chezmoi/onboard-map.yaml` is loose/unmanaged
  (not in repo).
- `home/dot_local/lib/prompt-common.zsh` → **shell** (you source it
  read-only).
- chezmoi run-script *ordering* → **chezmoi** (you own the *content* of your
  own run-scripts; **chezmoi** owns the numeric prefix sequence).

## Contracts you must preserve

- **Opaque slot IDs** `slot-<6hex>` — never alias/hostname/username in
  committed artifacts. The committed manifest `secrets.yaml` carries NO
  values, only declarations. **This leak-safety boundary is the core
  invariant.**
- **Two materialization paths**: human = `op read "op://..."` in chezmoi
  templates (cached via `op-cache-v1` content hash, refresh on
  `CHEZMOI_REFRESH_SECRETS=1`); headless = SOPS+age blobs decrypted to 0600
  files. Over SSH, `op` switches to a loose service-account token.
- **`sec::leak_audit`** runs on every commit path against `.leak-patterns` —
  the leak-patterns file is part of the contract.
- **GPG import** (`run_after_25`): keys as 1Password **Private** vault docs;
  `env -u OP_SERVICE_ACCOUNT_TOKEN` forces account mode; defers (exit 0,
  `run_after` not `run_once`) when no tty; completion marker keyed on
  `expected_key_spec` + keyring stat hash.

## What you consume read-only

- **shell**: `prompt-common.zsh` (`prompt::*`), `common.zsh`
- **chezmoi**: chezmoi template `op read` resolution, run-script ordering
- External: `op`, SOPS, age, gpg

## Where to start

`home/dot_local/lib/system-secrets-common.zsh`,
`home/dot_local/bin/system-onboard`, `home/.chezmoidata/secrets.yaml`,
`.leak-patterns`.

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
git worktree add -b work-on-secrets-$suffix "$WT_ROOT/work-on-secrets-$suffix" "$base"
cd "$WT_ROOT/work-on-secrets-$suffix"
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
- **Integrate (non-UX work):** load the `reconcile` skill and follow it —
  `flock`-gated, on-demand `master-work`, ff-only automated / divergence
  human-gated, `make test` under the lock.

## Verify before claiming done
- Run `sec::leak_audit` against a synthetic fixture containing a known secret
  pattern and confirm it catches it.
- The opaque-slot-id invariant holds — no real alias/hostname/username lands
  in a committed file.
- `op-cache-v1` cache semantics unchanged (re-resolution only on
  `CHEZMOI_REFRESH_SECRETS=1` or content-hash change).
- Your diff stays within the owner area above (coordinate **chezmoi** if a
  trigger hash in a run-script must change).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "secrets & onboarding" section).
