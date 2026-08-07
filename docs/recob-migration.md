# RECOB migration

For the operator, not the designer. Its audience is a human at 2 a.m. whose
copy stopped working: what to apply, in what order, how to recognize each way
it can be half-applied *from the message alone*, and how to get back.

The design lives in `docs/recob-protocol-spec.md`; the sequencing in
`docs/recob-implementation-plan.md`. Neither is required reading to run this.

## What changes on a machine

| Before | After |
| --- | --- |
| `socat` forks a zsh dispatcher per connection | one persistent `recobd` |
| sixteen single-letter opcodes | fourteen named operations |
| five connections for `copy-pwd` | four, one on the critical path |
| the public port is open to anyone who can reach it | it requires a credential |
| Hammerspoon's watcher writes the store | the daemon does, as sole writer |
| `pbcopy` falls back to OSC 52 on any failure | only when nothing is listening |

The launchd and systemd identities do **not** change: the services are still
`clipboard-bridge` and `clipboard-bridge-trusted` (spec D3 — only the protocol
was renamed). If you are looking for something called `recob` in `launchctl`,
that is why you cannot find it.

## Apply order

**One machine at a time, deliberately.** A machine is entirely on one protocol
or the other the moment it is applied — the listener and the client library
ship in the same change, so there is no intra-machine mixed state. What *is*
mixed, between the first apply and the second, is the pair.

```sh
chezmoi apply                 # builds recobd + system-clip, swaps the services
```

The build hook is part of the cutover, not a detail after it. It fails loudly
when `cargo` is missing rather than skipping: without `recobd` there is no
bridge at all, and a machine left on the old implementation is a working
machine, while a machine with neither is not. If it fails:

```sh
mise use -g rust              # or: rustup default stable
chezmoi apply
```

Cold builds take about 11 seconds (`rusqlite` bundles SQLite); a source change
takes under a second.

## The skew window: reading the failure from the message

Between the first machine's apply and the second's, cross-machine operations
degrade. Every row here is a *transient* state that ends when the other machine
is applied. Nothing below indicates a broken install.

| What you see | What it means | What to do |
| --- | --- | --- |
| `this endpoint now speaks RECOB v1; the client that called it is behind` | you are on an **old** machine calling a **new** one | apply on the machine you are sitting at |
| `not a RECOB endpoint` / a copy that fails after ~500 ms | you are on a **new** machine calling an **old** one | apply on the machine named in the message |
| `unauthorized` with `reason=no-credential` | the token has not reached this machine yet | reconnect the SSH session; the push runs at connect |
| `unauthorized` with `reason=bad-credential` | this machine holds a **stale** token | reconnect; the push overwrites it |
| `busy` | the listener is at its connection cap | retry; it is a real overload, not a fault |
| local operations behaving normally | expected | nothing — local never degrades |

**A plain-text copy over the tunnel to a machine that is not yet applied fails
loudly instead of falling back to OSC 52.** This is deliberate and it is the
one place where rollout convenience and failing closed genuinely conflict. The
old listener *accepts* the connection and then stalls, which is byte-for-byte
what an attacker stalling a connection looks like; an exception carved out for
skew is an exception an attacker can trigger at will. The cost is bounded — it
lasts from the first apply until the second, on machines you control, with a
message naming the one to fix.

`pbcopy <path>` over SSH still records locally and only warns about the peer;
nvim's paste still falls back to its per-process cache. Neither of those is a
less trusted transport, so neither is a downgrade.

## The credential

Each machine generates its own at startup — 32 random bytes, hex, mode 0600
under a 0700 directory:

```
~/.local/state/clipboard/accepted-token
```

There is no provisioning step. A daemon that cannot read or create one refuses
to serve the public endpoint rather than serving it unauthenticated.

Remotes receive a copy at connect time, pushed by `ssh-prepare-connection`,
keyed by the owning machine:

```
~/.local/state/clipboard/tunnel-tokens/<owner-hostname>     # on the remote
```

Keyed by owner because two machines pushing to one shared remote would
otherwise invalidate each other, and because a token lifted from one remote is
useless against any other machine. **The token itself never crosses the wire** —
only digests of a per-connection challenge do, in both directions.

### Rotation

There is no rotation command. Delete and restart:

```sh
rm ~/.local/state/clipboard/accepted-token
launchctl kickstart -k gui/$(id -u)/clipboard-bridge      # macOS
systemctl --user restart clipboard-bridge.service         # Linux
```

Every remote still holding the old value gets `unauthorized` with
`reason=bad-credential` until its next connect, which overwrites it. That
self-heals; nothing needs to be cleaned up by hand.

### When a remote will not authenticate

In order, cheapest first:

```sh
ls -l ~/.local/state/clipboard/tunnel-tokens/       # on the remote: is it there, is it 0600?
```

A token file is treated as **absent** — never partially matched — if it is not
exactly 64 lowercase hex characters on a single line, if anything follows that
line, or if its mode grants any bit to group or other. A file that looks
present but fails one of those checks produces exactly the same
`reason=no-credential` as no file at all. That is deliberate; it is also the
most confusing failure here, so check the mode before anything else.

## Verifying a machine is on RECOB

```sh
launchctl list | grep clipboard-bridge                    # macOS: is it running
systemctl --user status clipboard-bridge.socket           # Linux
tail -n 5 ~/.cache/clipboard-bridge/listener.log
```

A running daemon logs one line at startup naming the wire version, the protocol
version, the build and the host:

```
recobd: wire 1 proto 1 impl <hash> host <name>
```

If that line is absent and the service is running, you are still on the old
implementation. The other quick check is behavioral: the old bridge answers a
bare connect with your clipboard text, the new one answers with `RECOB`.

```sh
printf '' | nc 127.0.0.1 2489 | head -c 5                 # "RECOB" once applied
```

## Rollback

The old implementation is still in the tree until the conversion completes, so
rollback is a checkout and an apply:

```sh
cd ~/.local/share/chezmoi
git log --oneline -- home/dot_config/packages/services.toml.tmpl
git revert <the cutover commit>
chezmoi apply
```

Nothing in the store needs to be undone: **the schema did not change.** Both
implementations read and write the same `clips`, `clip_types`,
`file_authorities` and `file_grants` tables, so history written by the daemon
is readable by the old pickers and vice versa. The only artifacts the new
implementation stops writing are `~/.local/state/pick-clipboard/current-origin`
and `current-regtype`, which the old one recreates on its next copy.

## Rehearsing before cutover

The daemon can be exercised end to end **without touching the live services**,
which is the right way to gain confidence before applying. Nothing below binds
the real port or the real socket, and nothing writes the real store:

**Read this paragraph before running the commands, because the obvious
rehearsal does not test what it appears to.** On a Mac, sitting locally,
`system-clip copy` delegates straight to `/usr/bin/pbcopy` — that is the
shim's oldest and most deliberate behavior, and it means a local copy never
reaches the daemon at all. Its row appears later, written by the *capture
loop* observing the general pasteboard. So a naive local rehearsal writes your
real clipboard, reads it back through `/usr/bin/pbpaste`, prints exactly what
you expected, and proves nothing about the bridge. `PBCOPY_DARWIN_BIN`, the
seam the suite already uses, is what forces the client down the bridge path.

```sh
cd ~/.local/share/chezmoi/custom-builds/recob
make build

# A scratch everything: its own store, its own state, its own socket, and a
# PRIVATE pasteboard, so the real clipboard is neither read nor written.
scratch=$(mktemp -d)
XDG_DATA_HOME="$scratch/data" XDG_STATE_HOME="$scratch/state" \
RECOB_CAPTURE_PASTEBOARD=org.chezmoi.recob.rehearsal \
  ./target/release/recobd --capture --no-public --socket "$scratch/cb.sock" &

# Drive it with the real client. PBCOPY_DARWIN_BIN sends it to the bridge
# instead of /usr/bin/pbcopy; clearing SSH_* keeps it on the trusted socket
# even when you are rehearsing from inside an SSH session.
run() { env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
  PBCOPY_DARWIN_BIN=/nonexistent PBPASTE_DARWIN_BIN=/nonexistent \
  CLIPBOARD_BRIDGE_LOCAL_SOCKET="$scratch/cb.sock" ./target/release/system-clip "$@"; }

printf 'hello from the rehearsal' | run copy
run paste

# One row, written by the daemon in the same operation as the pasteboard write:
sqlite3 "$scratch/data/pick-clipboard/history.db" \
  'SELECT id, type_kind, source_host, substr(text_plain,1,40) FROM clips;'

kill %1; rm -rf "$scratch"
```

If the row count is 0 and the paste still printed your text, you are looking at
the trap above: the client delegated locally and the daemon was never
involved.

To rehearse the public endpoint as well, drop `--no-public`, add
`--port 24890`, and point the client at it with `CLIPBOARD_BRIDGE_PORT=24890`
after copying the daemon's `accepted-token` into
`$scratch/state/clipboard/tunnel-tokens/$(scutil --get LocalHostName)` at mode
0600 — which is exactly what `ssh-prepare-connection` does at connect.

## What is deliberately still true after the cutover

- **OSC 52 still exists.** It is the fallback for a machine with no tunnel at
  all, which is the common case for an iPad session, and it is unchanged there.
- **The GUI picker and `pick-clipboard` still read the store directly.**
  Concurrent readers are what WAL is for. What they no longer do is write it.
- **The OSD, the fullscreen toggle and the peer mount stay where they are.**
  The daemon authorizes and forwards them; it does not reimplement them.
