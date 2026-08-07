# D7 — how the daemon raises the OSD

Closing the one decision `docs/recob-protocol-spec.md` §15 left open. It gates
`osd.notify`, and therefore Phase 4 of `docs/recob-implementation-plan.md`.

**Recommendation: option 1, spawn `hs` per notification.** Which is what the
spec already recommends; what follows is the measurement that was missing, and
one finding that strengthens the case rather than merely confirming it.

## The options, restated

1. **Spawn `hs` per notification, as today.** No new mechanism, no new failure
   mode, and the only option that needs nothing new to work.
2. **A persistent subscription.** Hammerspoon holds a connection to the trusted
   socket and the daemon streams notifications as `D` frames — the streaming
   shape §6.4 already specifies, so not new protocol. It removes the last
   significant spawn and inverts the dependency, so the daemon never has to know
   how to launch Hammerspoon. It introduces a reconnect contract, a behavior when
   nothing is subscribed, and a queue-or-drop policy.

Option 2's saving is exactly option 1's cost, so measuring option 1 decides it.

## Measured

`bench/d7-osd-delivery.zsh`, on the sit-at Mac, both arms in one session and in
both orders. The script each arm runs is `return 1`, not a toast: drawing the
toast happens inside Hammerspoon either way and is common to both options, so
what is measured is the *delivery* mechanism alone.

| Arm | Mean | Reversed order |
| --- | --- | --- |
| `hs <file>` round trip | 12.6 ms ± 1.7 | 11.8 ms ± 2.4 |
| process-spawn floor (`/usr/bin/true`) | 4.7 ms ± 1.9 | 3.7 ms ± 2.4 |
| `hs -c` | 17.8 ms ± 2.4 | 20.7 ms ± 2.7 (earlier run) |

So delivery costs about **12 ms**, of which about 4 ms is the platform's own
process-spawn floor; the Hammerspoon round trip itself is roughly 8 ms. Every
figure repeated inside its own σ across two runs, which is the stability rule §1
applies to itself.

This is lower than §1.1's 17.9 ms for an `hs` spawn, and does not contradict it:
that figure is a spawn that then *does* something — generated Lua writing the
pasteboard — where this one returns immediately. Same order, different work.

## Why the cost does not matter here

Two independent reasons, and either alone would be sufficient.

**The caller already backgrounds it.** `mux/scripts/executable_copy-pwd:155`
fires `notify` with `&` and keeps the pid. The 12 ms is not on the path the human
waits for; it never was.

**The daemon does not serialize on it.** §3.4 gives every connection its own
task, so a handler that blocks 12 ms in `hs` blocks exactly the connection that
asked for a toast. Nothing else queues behind it — not the accept loop, not a
paste on another connection, not the trusted socket. This is a property the
process-per-connection design had too, so nothing regresses.

Option 2 would therefore spend a reconnect contract, a no-subscriber policy and a
queue-or-drop decision to remove a delay that is already off the critical path
and already isolated to one task. Three new failure modes for a cost nobody can
perceive.

## The finding that strengthens it

The obvious optimization inside option 1 — `hs -c 'code'`, avoiding the temporary
script file — is **slower**, at 17.8–20.7 ms against 12–13 ms. It is also already
recorded as unreliable: `clipboard-platform-macos.zsh:27` notes it was "observed
to hang even on trivial code" and that `hs <file>` is the confirmed-reliable form.

That is worth writing down because it is the change a future reader will propose.
It costs a temp file, looks tidier, and is worse on both axes.

## What this does not close

Option 2 remains the right shape if the premises change. The trigger is either of
these, and neither is true today:

- a notification path that is **not** backgrounded by its caller, so the delay
  becomes visible; or
- a notification rate high enough that one spawn per toast is a real load, which
  §9.5's `osd` bucket caps at 20 per 10 s and therefore bounds by construction.

Until then the subscription is a follow-up, noted in the spec and not built.
