# RECOB benchmark and feasibility scripts

The evidence behind §1 and §3 of `docs/recob-protocol-spec.md`, and the
starting point for the tracked harness §12 requires.

These are throwaway-grade zsh, written to answer one question each. They are
kept because the design rests on the numbers they produce, and a number nobody
can reproduce is an assertion.

## Launch shape: `run.zsh`

The A/B behind the central bet. It isolates exactly one variable — what the
listener does per accepted connection — by running the identical client and
identical per-connection work against two ports: socat with `fork` (an
accept + fork + **exec** per connection, today's shape) versus a persistent
zsh listener that binds once and forks an already-warm handler.

Both arms run in one session and in both orders, per the audit brief's warning
that arms measured minutes apart drift by around 20 ms. It also runs an
`nc`-versus-`ztcp` client comparison against the same warm listener, which is
what corrected the brief's client-transport figure from ~30 ms to ~5 ms — the
original number had been measured through a forking listener and was
attributing the listener's cost to the client.

```sh
./run.zsh          # needs hyperfine and socat
./run2.zsh         # the cold-dispatcher arm, measured separately
```

Reproduced 2026-08-05: socat fork+exec 28.2 / 27.6 ms, warm listener 13.6 /
13.8 ms, client floor 9.5 ms, cold dispatcher 44.3 / 45.7 ms, `nc` 18.9 / 19.1
against `ztcp` 13.4 / 13.5. Every figure inside its original sigma.

Arms: `responder.zsh` (socat side), `warm-listener.zsh` (persistent side),
`client-ztcp.zsh` and `client-nc.zsh` (the two client transports),
`dispatch-direct.zsh` (the real dispatcher, spawned per frame),
`floor.zsh` (the client's own cost, subtracted from everything else).

## Listener feasibility: `listener-feasibility.zsh`

Three questions about what a zsh listener can actually do. Two of the answers
shaped the spec and remain requirements even though the daemon is now Rust:

- **Q2 fails**: `ztcp -a` refuses a descriptor the process did not create with
  `ztcp -l` — `fd 8 is not registered as a tcp connection`. This is what ruled
  out systemd socket activation with `Accept=no` for a shell listener, and
  therefore one of the reasons the daemon is compiled (§3.2: a Rust daemon
  honours `LISTEN_FDS` trivially, so activation comes back).
- **Q3**: `zsocket -l` creates the Unix socket **mode 755**, not 0600. The
  trusted endpoint's whole security model is same-uid-only, so the listener
  must establish it itself — `umask 077` before bind, explicit `chmod` after,
  0700 parent directory, all three (§3.3). This applies to the Rust daemon
  unchanged.

## Worked example: `verify-worked-example.zsh`

Encodes §4.4's frame from the spec's own field grammar and prints the bytes, so
the hex in the document is checked rather than trusted. It caught a
hand-computed body length of 0x3a where the grammar yields 0x3d.
