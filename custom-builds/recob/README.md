# recob

Build home for the RECOB daemon and clients, specified in
`docs/recob-protocol-spec.md`.

RECOB replaces the clipboard bridge's wire protocol and process model: a single
persistent Rust daemon (`recobd`) in place of socat forking a zsh dispatcher per
connection, a named-operation protocol in place of sixteen single-letter
opcodes, and one connection carrying many exchanges in place of five
connections per user action.

| | |
| --- | --- |
| `src/` | `recobd` — Phase 1 of `docs/recob-implementation-plan.md`: the wire codec, the connection lifecycle, both endpoints and the recording seam |
| `tests/` | Integration coverage: the §4.4 worked example, the lifecycle, socket activation, the self-bound launch shape, the recorder |
| `probes/` | Verified feasibility probes — what a non-GUI Rust process can do to the macOS pasteboard, and the measurements that chose the language |
| `bench/` | The A/B harness behind the launch-shape decision, plus the two listener findings that became requirements |

`probes/` and `bench/` carry a README explaining what each program settles. They
are kept tracked rather than discarded because the spec cites their results, and
a cited measurement nobody can re-run is an assertion.

```sh
make build     # cargo build --release  → target/release/recobd
make test      # cargo fmt --check, clippy -D warnings, cargo test
make install   # → ~/.local/libexec/recobd
```

The daemon takes no dependencies. Threads are the per-connection task boundary
(§3.4), socket timeouts are §5.2's, and `FromRawFd` is all §3.2's socket
activation needs; the one libc call made by hand is `umask`, in `listen.rs`.

## What Phase 1 builds, and what it deliberately does not

Implemented: the wire format (§4) including the §4.4 worked example byte-exact,
the connection lifecycle (§5) with banner, capabilities frame and timeouts, both
endpoints with the launch shape, concurrency and socket permissions of §3.1–§3.4,
and `recobd --record` (§11.1). The operation registry holds `host.identity` and
nothing else, as proof that named dispatch works.

Not implemented, by phase rather than by omission — where a later phase's field
or check belongs, the code says so rather than stubbing it:

| Absent | Lands in |
| --- | --- |
| `auth`, `nonce`, `cnonce`, `proof`; the policy table; §3.5's pre-auth limits | Phase 2 |
| the pasteboard, the store, the absorbed watcher | Phase 3 |
| the other thirteen operations, streaming, per-field validation | Phase 4 |
| `pbcopy` / `pbpaste` and the §7.3 old-client shim | Phase 5 |
| the `run_onchange` build hook and the unit changes | Phase 8 |

## Running it

```sh
recobd                              # bind 127.0.0.1:2489 and ~/.local/state/cb.sock
recobd --no-public --socket /tmp/s  # one endpoint, somewhere else
LISTEN_FDS=2 LISTEN_PID=… recobd    # adopt listeners on fds 3 and 4, binding
                                    # nothing — what systemd's Accept=no passes
                                    # (§3.2); tests/activation.rs sets this up
recobd --record                     # the observation seam (§11.1)
```

`--record` reads `RECOB_RECORD_LOG`, `RECOB_RECORD_SCRIPT` and
`RECOB_RECORD_ENDPOINT`. It decodes with the production decoder, so a client
that emits a subtly wrong frame fails rather than being recorded as wrong; a
spent or absent script means the daemon answers from its own registry.

Note on naming: the service keeps its `clipboard-bridge` launchd and systemd
identity for this change — only the protocol is renamed (spec D3). The daemon
binary is `recobd`.
