# Silo S7 — Secrets & onboarding

> Leak-safe, slot-based secrets system for a **public** repo: dual
> 1Password (human) / SOPS+age (headless) backends, opaque slot IDs, leak
> auditing, and full machine onboarding.

## Setup

```sh
git worktree add ../s07-secrets-work master
cd ../s07-secrets-work
```

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
  reaper `run_before_05-reap-stale-op-daemon.sh.tmpl` (trigger wiring is S12;
  the *logic* is S7)

## Out of scope (do not edit — owned by other silos)

- The 1Password CLI / SOPS / age tools (external).
- The `op-cache-v1` content-hash cache is S7-internal (yours).
- The operator map `~/.config/chezmoi/onboard-map.yaml` is loose/unmanaged
  (not in repo).
- `home/dot_local/lib/prompt-common.zsh` → **S9** (you source it read-only).
- chezmoi run-script *ordering* → **S12** (you own the *content* of your own
  run-scripts; S12 owns the numeric prefix sequence).

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

- S9: `prompt-common.zsh` (`prompt::*`), `common.zsh`
- S12: chezmoi template `op read` resolution, run-script ordering
- External: `op`, SOPS, age, gpg

## Where to start

`home/dot_local/lib/system-secrets-common.zsh`,
`home/dot_local/bin/system-onboard`, `home/.chezmoidata/secrets.yaml`,
`.leak-patterns`.

## TASK

> _<describe the assignment — e.g. "Review the secrets leak-audit coverage;
> `.leak-patterns` may be missing patterns for the new slot format" >_

**Verify before claiming done:**
- Run `sec::leak_audit` against a synthetic fixture containing a known secret
  pattern and confirm it catches it.
- The opaque-slot-id invariant holds — no real alias/hostname/username lands
  in a committed file.
- `op-cache-v1` cache semantics unchanged (re-resolution only on
  `CHEZMOI_REFRESH_SECRETS=1` or content-hash change).
- Your diff stays within the owner area above (coordinate S12 if a trigger
  hash in a run-script must change).

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S7.
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — feature
  #55, #76–#77.
