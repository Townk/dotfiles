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

## Socket activation, for real: `verify-activation-systemd.sh`

The other half of the Q2 finding above. Q2 says a zsh listener *cannot* accept
on a descriptor it did not create; this checks that `recobd` can, against real
systemd rather than against a stand-in.

The daemon's own suite reproduces systemd's contract by hand — descriptors from
fd 3 up, `LISTEN_PID` set to the daemon's pid — so the check runs on macOS too.
That is a model of systemd, written by the same person as the code it tests.
This script needs a Linux box with a systemd user session and is the thing that
actually settles §3.2.

```sh
./verify-activation-systemd.sh          # scratch units, removed on exit
./verify-activation-systemd.sh --keep   # leave them up to poke at
```

It also checks the refusal path, because the first manual run of this hit it by
accident: `DirectoryMode=` applies only to a directory systemd *creates*, so a
pre-existing 0775 one arrives at the daemon untouched and is refused. That is
the empirical reason §3.3 has the daemon assert the mode it was handed rather
than trust the unit.

Output is redacted — home path, hostname, username — so it is safe to paste.

Phase 2 extended it: the embedded client now completes §9.2's mutual handshake —
it answers the banner's challenge and recomputes the endpoint's `proof` from the
challenge it chose itself — so the run also confirms authentication works under
real systemd. A client that did not authenticate would now be refused, which is
how this script came to be updated.

Verified 2026-08-06 on Linux under a systemd user session: 13 checks passed.
Both listeners adopted from `LISTEN_FDS`, neither bound by the daemon, each
identified by address family rather than by fd order, socket 0600 under a 0700
parent, and a 0775 parent refused. The full test suite passes on that machine
too, so §3.3's `bind()`-masks-from-0777 behavior — the reason `umask 077` yields
0700 and the explicit chmod is what lands 0600 — holds on both platforms.

## Worked example: `verify-worked-example.zsh`

Encodes §4.4's frame from the spec's own field grammar and prints the bytes, so
the hex in the document is checked rather than trusted. It caught a
hand-computed body length of 0x3a where the grammar yields 0x3d.
