---
description: Dispatch an agent to the universal clipboard silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **universal clipboard** silo of this chezmoi dotfiles
repo.

> One clipboard across machines: a content store with provenance, a framed
> bridge protocol carried over SSH forwards, platform backends for macOS and
> headless Linux, file/rich-media clips, and a FUSE mount that lets Finder
> paste a remote clip as a real file.
>
> This silo exists because the subsystem outgrew its neighbours. Its files sit
> in five other silos' territory (nvim, hammerspoon, systemd units, zellij
> scripts, launchd services) and every one of those is a *consumer* of a
> protocol defined here. The protocol is the product; the callers are not.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_pbcopy`, `executable_pbpaste` — the CLI
  surface, including the SSH branches that reach the peer bridge
- `home/dot_local/libexec/executable_clipboard-bridge-dispatch` — the
  per-connection handler (socat EXECs it once per accepted connection, so a
  code change takes effect on the next request with no restart)
- `home/dot_local/libexec/executable_clipboard-mount` — the FUSE mount that
  materialises a clip as a file
- `home/dot_local/libexec/executable_pick-clipboard` — the history picker
- `home/dot_local/lib/clipboard-store-core.zsh` — the store, the framing
  helpers (`send_frame`/`send_ok`/`send_err`) and every `clip::op_*`
- `home/dot_local/lib/clipboard-bridge-client.zsh` — `clipbridge::*`
- `home/dot_local/lib/clipboard-platform-macos.zsh`,
  `clipboard-platform-linux-headless.zsh` — the `pb::*` backends
- `home/dot_config/systemd/user/clipboard-bridge{,-trusted}{@.service,.socket}`
- `home/.chezmoiscripts/run_onchange_after_37-setup-clipboard-bridge.sh.tmpl`
  (the *logic*; hook ordering and hash triggers are **chezmoi**'s)
- `docs/clipboard-universal-project.md` — the project record, including the
  opcode table. Keep it in step with the code; it is how the next agent
  learns the wire.

## Out of scope (do not edit — owned by other silos)

- `home/dot_config/nvim/lua/clipboard/**` → **neovim**. You own the socket
  protocol its provider speaks; neovim owns the Lua.
- `home/dot_config/hammerspoon/modules/apps/clipboard*.lua` and the picker
  HTML/CSS → **hammerspoon**. Same split: yours is the data, theirs is the UI.
- `home/dot_config/zellij/scripts/executable_pick-clipboard-zellij` →
  **terminal-mux** (a modal adapter, like the other `pick-*-zellij` thins).
- The `clipboard-bridge` agent *definition* in
  `home/dot_config/packages/services.toml.tmpl` → **system-services**. You own
  the socket and the protocol; they own the plist fields.
- `pick::start` and the picker engine → **pick**. `pick-clipboard` is a
  caller.
- The **`W` window opcode's mux half** (`terminal-toggle-fullscreen`,
  `mux-fullscreen-probe`) → **terminal-mux**. You own the opcode and its
  dispatch; they own what it does to a window.

## Contracts you must preserve

- **The wire protocol** — `<1 byte opcode><4 byte BE length><payload>` in,
  `<1 byte status 'O'|'E'><4 byte BE length><payload>` out. Opcodes are
  documented in `docs/clipboard-universal-project.md` §11 and the dispatcher
  header; both must agree. **Adding an opcode is additive; changing one is a
  cross-machine break**, because the two ends update independently.
- **Ports**: `2489` is always *this machine's own* bridge; `2490` is the
  reverse-forwarded *peer*. The peer port listening is also the honest test
  for "am I the remote end of a tunnel".
- **Cross-machine TCP, trusted-local Unix socket** — macOS OpenSSH ignores
  `StreamLocalBindUnlink` for remote Unix-socket forwards, so `2489`/`2490`
  stay TCP. Privileged local `U`/origin-`M` calls use the separate mode-0600
  `~/.local/state/cb.sock`, owned by socat/systemd and never SSH-forwarded.
- **Capability-bound file reads** — `L` is display-only; `K` grants one trusted
  path snapshot; lowercase `f`/`a` accept only its opaque token + item index.
  Raw-path `F`/`A` are retired. Public `M` is pointer-only and may not claim
  this machine's own hostname.
- **Hammerspoon authority seam** — native file captures populate
  `file_authorities`; public-M mount enrichment carries
  `org.chezmoi.clipboard.UntrustedFileURLs`, which the watcher must skip.
- **`clipbridge::probe|send|request`** in `clipboard-bridge-client.zsh`.
  `CLIPBRIDGE_TIMEOUT_S` overrides the 2s wire timeout: 2s is right for a read
  the far end answers from memory, and wrong for an op that makes the origin
  *act* (a window animation, or a first-use macOS Automation consent dialog —
  timing out there reports failure for something that already happened).
- **Legacy bare-connect compatibility** — a client that connects and sends
  nothing gets `pbpaste` output unframed after `LEGACY_GRACE_S`. Old callers
  still exist; keep the grace path.
- **Byte-safety**: requests are assembled in a temp file and read with
  `sysread` loops, never `$(...)` — command substitution truncates at the
  first NUL, and manifests are NUL-joined.
- **`x-file-manifest`** synthetic UTI and `source_host` provenance in the
  store; `clip::self_host` is the identity both the `H` opcode and the store's
  rows answer with.

## What you consume read-only

- **pick**: `pick::start` (the history picker's engine)
- **terminal-mux**: `mux::pick` / popup mechanics for the floating picker
- **utils**: `notify`, `common.zsh`
- **system-services**: the launchd agent that runs the socat listener
- **shell**: `environment.sh` XDG vars

## Where to start

`docs/clipboard-universal-project.md` (the wire and the phases), then
`lib/clipboard-store-core.zsh` (the ops), `libexec/clipboard-bridge-dispatch`
(the connection handler), `bin/pbcopy` (the richest caller).

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
git worktree add -b work-on-clipboard-$suffix "$WT_ROOT/work-on-clipboard-$suffix" "$base"
cd "$WT_ROOT/work-on-clipboard-$suffix"
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
- Reproduce the behavior you changed (don't guess). The bridge is testable
  locally: send a frame to `127.0.0.1:2489` with `clipbridge::request` and read
  the status byte.
- Run the clipboard specs (`clipboard-*_spec.sh`, `pick-clipboard-*_spec.sh`)
  plus `make test` if you touched `lib/*.zsh`.
- **A protocol change needs both ends considered.** The far machine updates on
  its own schedule, so ask what an old peer does with your new frame — an
  unknown opcode must fail loudly as `E`, never hang.
- Your diff stays within the owner area above. If the feature genuinely spans
  silos (a new opcode almost always does), use the `cross-silo` skill rather
  than reaching into a neighbour.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "clipboard" section) and
`docs/clipboard-universal-project.md`.
