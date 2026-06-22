# Validate — agent self-test & human UX session

Two validation modes. **Mode A** is the default for logic/self-test work
(parallel, no lock). **Mode B** is for changes that need human eyeball
judgment (serialized by a session lock; the session **is** the integration).

## Resolve `flock` (util-linux is keg-only on macOS)

```sh
FLOCK="$(command -v flock || echo "$(brew --prefix util-linux 2>/dev/null || echo /opt/homebrew/opt/util-linux)/bin/flock")"
[ -x "$FLOCK" ] || { echo "flock not found — brew install util-linux" >&2; exit 1; }
```

## Worktree root

```sh
WT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees"
mkdir -p "$WT_ROOT"
```

---

## Mode A — sandbox self-test (agent, parallel, no lock)

Render the agent's worktree into a throwaway `$HOME` and run the code there.
No clobber of real `$HOME`, fully parallel with other agents.

```sh
sandbox=$(mktemp -d)
chezmoi apply --source "$PWD" --destination "$sandbox"
HOME="$sandbox" ./home/dot_local/bin/<script-under-test>
# ...run whatever the agent needs to self-test...
rm -rf "$sandbox"
```

**Honest limit:** real OS integration surfaces (sockets like
`~/.clipboard-bridge.sock`, launchd agents, mise-managed runtimes at their
real install dirs) are **absent** in a sandbox. Logic tests pass; integration
tests don't run at all. Anything touching those needs Mode B.

**chezmoi-state caution:** pointing chezmoi at a different `--source` then
back at the canonical source *may* disturb the global chezmoi state file. If
your pilot check (see the silo-commands README) found this, use an isolated
config: `chezmoi apply --config <mktemp-config> --source "$PWD" --destination
"$sandbox"`.

---

## Mode B — agent-initiated UX session (agent + human, serialized)

Use this when the work needs eyeball judgment — neovim UX, a new zsh widget,
a zellij layout, a picker's feel. The session merges your branch to `master`
and you iterate live; **the session IS the integration** for human-validated
work (no separate `reconcile.md` step after).

### Start (agent asks, human approves)

1. Ask the user whether to enter a UX session. On approval:
2. **Mutual lock check** — refuse if an integration is active (don't block).
   Probe the lock STATE, not the lockfile's existence: `flock` does not remove
   the lockfile on release, so `[ -e ]` would false-positive on a stale file
   left by a crashed run and block all future sessions. `flock -n` returns
   non-zero immediately if the lock is held; it succeeds on a free lock
   (including a stale-but-unlocked file). Release the probe fd right after.
   ```sh
   INT_LOCK="$(git rev-parse --git-common-dir)/silo-integration.lock"
   exec 8>"$INT_LOCK"
   if ! "$FLOCK" -n 8; then
     echo "Integration in progress. Wait for it to end." >&2
     exit 1
   fi
   exec 8>&-
   ```
3. **Acquire the session lock** (blocking — wait for any other session to end):
   ```sh
   SESSION_LOCK="$(git rev-parse --git-common-dir)/silo-ux-session.lock"
   exec 7>"$SESSION_LOCK"
   "$FLOCK" 7 || { echo "could not acquire session lock" >&2; exit 1; }
   ```
4. **Merge your branch to master** using the same ff/divergence logic as
   `reconcile.md`. If master diverged, the human resolves it **in the live
   tree** (they're present for UX). Never auto-rebase, never `--force`.
5. **`chezmoi apply` from the live tree** (`~/.local/share/chezmoi`) — render
   `$HOME` from `master`. **Never** `--source <worktree>` → no orphaned files,
   no chezmoi-state confusion.
6. **Leave the agent's worktree parked** at
   `$WT_ROOT/work-on-<silo>-<suffix>` for the session's duration — do **not**
   delete the branch (you'll resume on it if re-work is needed, or clean it up
   at done). The branch is merged to master; the worktree is just a parked
   checkout.

### During the session

Human and agent edit the live chezmoi source on `master` directly:

```sh
cd ~/.local/share/chezmoi     # the live tree, on master
$EDITOR <file>                # edit the chezmoi source directly
chezmoi apply                 # re-render into $HOME
make test                     # run on EVERY tweak — see below
git commit -am "ux: <tweak>"  # commit straight to master, no worktree
# ...repeat all day...
```

**`make test` runs on every tweak.** Fixing/adjusting tests is part of every
change, and is the discipline that makes direct-to-master safe. This is also
the signal for the re-work decision (below): if a "tweak" needs new tests or
breaks existing ones in ways that aren't trivial adjustments, that's a sign
it's structural, not a tweak.

### Re-work transition (agent judgment)

When a change is structural rather than a tweak, the agent tells the user it's
closing the session, then:

1. Release the session lock:
   ```sh
   exec 7>&-
   ```
2. `cd "$WT_ROOT/work-on-<silo>-<suffix>"` and fast-forward the agent branch to
   absorb the session commits:
   ```sh
   git merge --ff-only master
   ```
   This is clean because the session lock guaranteed no other integration
   touched `master` during the session.
3. Continue on the branch. `$HOME` stays rendered from `master` (session
   tweaks are good, just incomplete).
4. Later, re-enter a session → repeat from Start.

**Re-work threshold — judgment call with a tightening note:** deciding tweak
vs. re-work is the agent's judgment. The rule of thumb to *tighten if judgment
fails too much*: a **tweak** is ≤3 lines in a single file with no new symbols;
anything larger is **re-work** and must close the session. If the agent finds
itself misclassifying (e.g. repeatedly calling structural changes "tweaks" to
avoid closing the session), apply this rule literally.

### Done (human + agent agree)

1. Run `make test` (final gate).
2. Clean up the agent's worktree:
   ```sh
   git worktree remove "$WT_ROOT/work-on-<silo>-<suffix>"
   git branch -d work-on-<silo>-<suffix>   # -d refuses if unmerged; safety net
   ```
3. Release the session lock: `exec 7>&-`.

`$HOME` already tracks `master` with the final work — nothing to restore.
