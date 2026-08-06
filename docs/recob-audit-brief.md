# RECOB audit brief — performance and security review of the reverse control bridge

## Why this exists

What is still named `clipboard-bridge` is no longer a clipboard bridge. It is a
**RE**mote **CO**ntrol **B**ridge: a general channel that lets a session on a
machine reached over SSH cause effects on the machine whose screen the human is
actually watching. Two of its live opcodes (`W` window actions, `n` notify) have
nothing to do with clipboards, and both were added by extending a protocol that
was designed for something narrower.

The growth has been incremental and mostly unexamined as a whole. This audit
looks at it as its own piece of software: one protocol, two endpoints, three
client implementations, and a per-frame cost that nobody has attributed.

## Mandate and constraints

**Clean slate on the wire.** Compatibility with today's opcode set, framing, and
payload shapes is explicitly NOT required. Redesign for performance, security,
and extensibility without carrying the current format forward.

**One thing the clean slate does not license: version skew.** The two ends of
this bridge live on different machines that are updated by independent `chezmoi
apply` runs, at different times. Skew is not legacy baggage that a rewrite
eliminates — it is a permanent property of the deployment. It has already bitten
in practice: a dev-shell running a stale client against a current receiver
produced a bare exit code with no diagnostic, and the existing
`unknown_opcode_hint` helper in `pbcopy` exists only because that pain was
patched once, per-op, after the fact.

Requirement: **version and capability exchange as part of the connection**, such
that a mismatch produces a precise diagnostic naming which side is behind. A
protocol that cannot detect its own version repeats the current mistake at a new
address.

**Scope is the protocol and both ends, not just the listener.** Two costs
multiply here: how many frames a user action needs, and what each frame pays in
process startup on both endpoints. The measurements below put ~145 ms of every
~236 ms frame in accept-fork-dispatch on the two ends, and a single copy needs
three frames plus a fourth for its notification. An audit that tunes only one of
those two factors leaves most of the latency on the table.

## What exists today

### Endpoints and launch shape

| Endpoint | Address | Trust | Launcher |
| --- | --- | --- | --- |
| public | loopback TCP `2489` (peer reaches it as `2490` through the SSH `RemoteForward`) | none — the tunnel is the only credential | macOS: `socat TCP-LISTEN:2489,bind=127.0.0.1,fork,reuseaddr EXEC:…dispatch`; Linux: systemd `clipboard-bridge.socket` with `Accept=yes` + `clipboard-bridge@` template |
| trusted | Unix socket `~/.local/state/cb.sock`, mode 0600 | same-uid only; SSH never forwards it | macOS: `socat UNIX-LISTEN:…,fork,unlink-early,mode=0600`; Linux: `clipboard-bridge-trusted.socket`, `Accept=yes` |

Both listeners spawn **a fresh `clipboard-bridge-dispatch` process per accepted
connection** — `fork`+`EXEC` under socat, a new transient unit instance under
systemd. Every frame pays a full process startup on both ends.

Framing today: `<1 byte opcode><4 byte BE length><payload>`, reply
`<status byte><BE32 len><payload>` with `O` for success and `E` for error.

### Opcode inventory and current authorization

16 live opcodes, plus `F`/`A` retained as error stubs and `N` removed outright.
Authorization is decided in three different places and is mostly absent:

| Enforcement site | Opcodes |
| --- | --- |
| Endpoint checked in the dispatch `case` | `C` (public restricted to 7 UTIs), `U` (trusted only), `M` (trusted authorizes paths, public gets a pointer row) |
| Endpoint checked inside the handler | `K` (token issued only for a trusted local snapshot) |
| Capability token required | `f`, `a` |
| **No check at all** | `G`, `S`, `R`, `H`, `T`, `P`, `O`, `L`, `W`, `n` |

The single-byte opcode namespace has visibly run out: `n` is lowercase with a
comment explaining that uppercase `N` is retired, and `f`/`a` are lowercase for
similar reasons.

### Three independent client implementations of one wire format

1. `clipbridge::*` in `home/dot_local/lib/clipboard-bridge-client.zsh` —
   `probe`, `send`, `send_unix`, `request`, plus `get`/`get_host`/`get_ts`
   helpers. Used by `pick-clipboard`, `common.zsh`'s `notify`,
   `clipboard-platform-macos.zsh`, and the mux fullscreen scripts.
2. Hand-rolled `send_frame` / `send_frame_unix` in POSIX `sh` inside `pbcopy`
   and `pbpaste`, which cannot source a zsh library.
3. `frame_request` in Lua over libuv inside
   `home/dot_config/nvim/lua/clipboard/universal.lua`.

Each carries its own timeout, retry, and reply-checking semantics. This is why
`pbcopy` delivered plain text over OSC 52 for a long time while nvim's provider
had been using the bridge's `T` op for the same job — the two implementations
made different choices and nothing forced them to agree.

## Measured baseline

Two rounds of measurement exist. The first (`$EPOCHREALTIME` loops on the Linux
dev-shell) established that a frame costs ~125 ms locally and ~250 ms across the
tunnel, but could not say *why*. The second round attributed it with hyperfine on
both machines and is the one to build on. Its harness traps are documented under
[How to measure](#how-to-measure) — two of them produced confidently wrong
answers before being caught.

### End to end, from a remote session

hyperfine on the dev-shell, talking to the Mac through the live tunnel:

| Measurement | Cost |
| --- | --- |
| Sourcing `common.zsh` + `mux-bootstrap.zsh` | 18.9 ms ± 0.9 |
| Sourcing + one `n` frame to the sit-at machine | 272.3 ms ± 6.4 |
| `pbcopy` over the bridge (`O` + `T`, `P` backgrounded) | 472.2 ms ± 31.8 |
| Whole `copy-pwd` with two-phase feedback | 471.2 ms ± 45.6 |

The whole script costs what the copy alone costs, because the announcement toast
now overlaps it. The shell side of a keypress — interpreter, every library, the
`tmux` remoteness probe — is ~20 ms of the ~470 ms. **There is nothing left to
win outside the frames themselves.**

### Where one frame goes

The same `n` frame costs 240.7 ms ± 18.0 on the Mac over loopback and
272.3 ms ± 6.4 from the dev-shell across the tunnel. Decomposed:

| Stage | Cost | How it was measured |
| --- | --- | --- |
| client-side frame assembly (before `7790c3a`) | ~50 ms | the two implementations A/B'd, spaced, in both orders |
| `socat` accept + fork of a fresh dispatcher | ~54 ms | bare `printf \| nc` (91 ms) minus dispatcher-direct (37 ms) |
| dispatcher startup until it answers | ~37 ms | a frame piped straight into `clipboard-bridge-dispatch` |
| `hs -c` into the already-running Hammerspoon | 11 ms | `hs -c "1+1"` |
| SSH tunnel round trip | ~30 ms | remote total minus loopback total |

**The network is ~30 ms and Hammerspoon is 11 ms. Everything else is process
startup on the two endpoints.** That is the ~115 ms the first round could not
place, and it aims the redesign at the launch shape rather than at the wire
format. A persistent listener that does not fork per connection is worth more
than any framing change available.

Transport floor for the same exchange: `nc` is 78–91 ms, `ztcp` (a zsh builtin,
`zmodload zsh/net/tcp`) is 60 ms. So `nc` is ~30 ms of pure overhead — but it is
also the seam five spec files use to watch the wire (a fake `nc` on `PATH`
recording frames, 138 examples). It is kept for that reason alone. **A
replacement transport must ship an equivalent observation seam**, or that
coverage silently stops testing anything.

### What has already been removed

`7790c3a` rewrote `clipbridge::send` to build frames with builtins (`zstat`,
arithmetic expansion for the BE header, a `sysread` loop) instead of eleven
processes: **139.8 → 90.2 ms per frame**, and a whole `notify` 261.6 → 209.5 ms.

Still carrying the old assembly: `clipbridge::request`, `clipbridge::send_unix`,
and the POSIX `sh` `send_frame` inside `pbcopy`/`pbpaste`. The last one is why a
copy still costs 472 ms for its two frames, and it is the largest single piece of
client-side waste left.

### The path a single user action takes

One "copy the working directory" keypress from a remote session costs five
frames. Three of them are on the critical path (`O` → `T` → the completion `n`,
~680 ms); the announcement `n` overlaps the copy and `P` is backgrounded:

1. `O` declare-origin to the peer, which must precede the clipboard set so the
   receiver's watcher tags provenance correctly.
2. `T` set text + regtype to the peer. Together with `O`: 472 ms measured.
3. `P` persist a local row to this machine's own bridge — now backgrounded, so
   the caller no longer pays for it.
4. `n` notify to the peer to raise the OSD (~210 ms), plus a second `n` for the
   announcement toast, which overlaps the copy rather than adding to it.

`O` immediately precedes `T` and exists only to attribute the change that `T` is
about to make. Collapsing that pair into one frame is the obvious candidate, and
it generalizes into a design principle worth applying across the whole protocol:
**one frame per logical operation, with provenance travelling in the payload.**
At 200–240 ms per frame today, each frame removed is worth more than any
micro-optimization inside one.

## How to measure

hyperfine is provisioned on both machines already (`Brewfile.tmpl`, and the mise
`dev-shell` profile), so use it rather than hand-rolled loops. Rules that came
out of getting this wrong:

- **Decompose into separately benchmarkable commands**, then subtract. Bench the
  library sourcing, one frame, the copy, and the whole script as four commands;
  the differences attribute the cost. A single end-to-end number explains
  nothing.
- **Never interleave two implementations in one loop.** Because the listener
  forks a dispatcher per connection, a frame sent immediately after another
  competes with the previous dispatcher, and *both* inflate. An interleaved A/B
  of the old and new client showed 132 vs 133 ms — a false null result. Spaced
  runs of the same code showed 139.8 vs 90.2 ms.
- **Do not compare across time windows.** The same unchanged code measured
  240.7 ms and 259.7 ms minutes apart. Run both arms in one session, in both
  orders, and report the pair.
- **Wall time is not perceived latency.** The toast paints on the *other*
  machine, and no shell benchmark can see that pixel. Measure the far end's
  handling locally over loopback and subtract, rather than comparing clocks
  across two hosts.
- **Prefer read-only opcodes.** An `H` (get-host) frame exercises accept, spawn,
  dispatch and reply without touching the store. Reserve `T`/`P` for the few
  cases that must prove byte-exactness — and when a benchmark does write, save
  and restore the clipboard around it and silence the OSD sound, because a
  20-run benchmark otherwise means 20 toasts and 20 history rows.
- **On a managed machine, put probe code in a script file.** Endpoint security
  can silently kill an inline one-liner that opens a socket — exit 0, no output,
  a few milliseconds — which reads exactly like a shell bug. The same code in a
  file runs fine.
- **Verify byte-exactness separately from speed.** A payload crossing NUL bytes
  and one larger than a single `sysread` block are distinct cases; both belong in
  any transport rewrite's tests.

## Security findings

The trust model is "whoever can open a loopback socket." On a shared, multi-user
development host, that is not only the intended human. Everything on the public
endpoint is unauthenticated.

- **Authorization is scattered.** Three enforcement sites, ten opcodes with no
  check. Replace with a declarative op → required-capability table, and add a
  test that fails when a new opcode appears with no policy entry, so "ungated"
  becomes a deliberate, reviewable choice instead of an omission.
- **Read ops are exfiltration.** `G` hands the receiving machine's clipboard to
  anything that can connect on the remote box; `L` enumerates file paths.
- **`T` is an injection path.** Poisoning a clipboard that a human will later
  paste into a shell prompt is code execution with extra steps.
- **`n` carries a callable name.** Its payload names a Lua global to invoke,
  guarded by a two-entry allow-list. The allow-list is the right mitigation for
  that shape, but a wire protocol should carry an enum, not a function name.
- **No rate limiting.** `W` and `n` are annoyance vectors; nothing throttles
  them.
- **Authentication is available cheaply.** `ssh-prepare-connection` already
  pushes per-connection state to the remote at connect time (the `self-name`
  file), which is a natural hook for a per-tunnel pre-shared token.

## Required deliverables

1. **A spec document first, no code.** Wire format, opcode/capability model,
   version negotiation, authorization table, error taxonomy. Reviewed before
   anything is implemented.
2. **A benchmark harness** committed alongside it, driving hyperfine per the
   rules in [How to measure](#how-to-measure), so performance claims are
   measured rather than asserted. The per-frame attribution is already done —
   the harness exists to keep it honest as the design changes, and to prove the
   persistent-listener win rather than assume it.
3. **The authorization policy as data plus its enforcement test**, per the
   finding above.
4. **A migration note covering skew**, including what a mismatched pair does and
   what the human sees.

## Rollout safety

This bridge is on the hot path of every copy on both machines, plus the nvim
provider, the clipboard picker, and the yazi integration. Keep the current
implementation serving until the replacement passes the existing
`tests/clipboard-bridge_spec.sh` (and whatever the new spec adds), then cut over
atomically. This is rollout safety, not backwards compatibility — the clean-slate
mandate does not override it.

## Out of scope / already landed

Client-side latency work on the `copy-pwd` path was handled separately and does
not touch the wire protocol. It is already in `master`:

- `054c991` — `-b` on the tmux binds (the command queue was held for the whole
  script), a two-phase OSD whose completion toast repaints the announcement in
  place, and the `P` frame backgrounded.
- `7790c3a` — builtin frame assembly in `clipbridge::send` (see above).

A further item — a merged opcode collapsing `O`+`T` — was deliberately
**dropped** from that work and handed to this audit, because it is a protocol
decision that should be made once, as a principle, rather than bolted on next to
the ops it replaces.

Left for whoever takes this on, because both are the same problem this audit
exists to solve: `pbcopy`/`pbpaste`'s POSIX `sh` `send_frame` still spawns per
frame the way the zsh client used to, and `clipbridge::request` /
`clipbridge::send_unix` still assemble frames the old way. Fixing them
one-by-one is exactly the incremental drift that produced three divergent client
implementations; a single client contract is the better answer.
