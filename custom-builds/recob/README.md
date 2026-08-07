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

Cross-platform dependencies: `sha2` and `subtle` (both required by §9.2 and
pinned by `probes/` first) and `rusqlite` with bundled SQLite (the store,
§14.2). On macOS only, the `objc2` crates carry the platform layer (§14.1);
their feature lists were likewise pinned by `probes/`. Everything else is std:
threads are the per-connection task boundary (§3.4), socket timeouts are §5.2's,
`FromRawFd` is all §3.2's socket activation needs, and `/dev/urandom` is the
CSPRNG §9.2 names. The one libc call made by hand is `umask`, in `listen.rs`.

The credential lives at `$XDG_STATE_HOME/clipboard/accepted-token`, created at
startup if absent or invalid, mode 0600 under a 0700 directory. A daemon serving
the public endpoint refuses to start without one rather than serving
unauthenticated; a `--no-trusted`-only daemon needs none, because the trusted
socket's uid boundary is its credential.

`$XDG_CONFIG_HOME/clipboard/exposure` withdraws operations per endpoint, one
`<endpoint> <operation>` per line. It can only subtract, never restore what the
policy table denies, and it never changes the advertised `caps`.

## What is built, and what deliberately is not

Phase 1 — the wire format (§4) including the §4.4 worked example byte-exact, the
connection lifecycle (§5) with banner, capabilities frame and timeouts, both
endpoints with the launch shape, concurrency and socket permissions of §3.1–§3.4,
and `recobd --record` (§11.1).

Phase 2 — mutual challenge-response authentication (§9.2: the credential never
crosses the wire, nonces come from the OS CSPRNG, comparison is constant-time),
the tier and policy table with a single enforcement call site (§9.1, §9.3, §9.4),
pre-authentication limits (§3.5), per-endpoint rate buckets (§9.5), and
subtractive exposure (§9.6).

Phase 3 — the platform layer (§14): the native pasteboard behind
`src/platform/` (macOS only, §14.7 — the Linux build compiles it out and keeps
the store, the sockets, the codec and the policy table), the capture pipeline
absorbed from the Hammerspoon watcher (§14.2: the sensitive-UTI refusal, the
password-manager deny-list, the empty/whitespace rejection, the 5 MB image cap,
classification, `type_hash` dedup), the store writer with the Lua writer's
retention sweeps and `file_authorities`/`file_grants` rules, and §14.6's
register-type tracking against `changeCount` with no sidecar file. Capture is
**opt-in** (`recobd --capture`) so a test daemon can never touch the live
store; the production unit passes the flag at cutover. Until Phase 7 retires
the Lua writer, both writers capture — §14.4 expects the duplicate rows.

Phase 4 — the full §6.1 registry: all fourteen operations dispatch, each §9.3
policy row on the registry row itself (an operation cannot exist without a
tier), every field §6.6-validated, `files.fetch` streaming per §6.4 with the
explicit empty-`D` terminator and mid-stream `E`, §6.5's no-race `files.list`
(synchronous capture instead of the 0.3 s sleep) and per-operation caps
(128 MiB for `clip.set.rich`, `file-too-large`), and §14.5's `clip.restore`
with all four `plain_only` branches. The clip writes record themselves on the
§14.6 tracker, which is what makes §11.4's "one copy, one row" hold. Two
carried-across behaviors are worth naming: the M path's mount enrichment
(Finder-native paste — absent from the RECOB spec, preserved rather than
silently dropped) and the `W` scripts' environment surgery.

Not implemented, by phase rather than by omission — where a later phase's field
or check belongs, the code says so rather than stubbing it:

| Absent | Lands in |
| --- | --- |
| `pbcopy` / `pbpaste`, proof verification client-side, and the §7.3 old-client shim | Phase 5 |
| retiring the Lua writer (until then two writers capture, §14.4) | Phase 7 |
| the `run_onchange` build hook and the unit changes | Phase 8 |

The thirteen remaining policy rows wait for Phase 4 because they arrive *with*
their handlers: `caps` advertises what this build can dispatch (§5.1), and a
policy row without a handler would put a lie in it — which §7.1's skew diagnostic
is built on not happening.

## Running it

```sh
recobd                              # bind 127.0.0.1:2489 and ~/.local/state/cb.sock
recobd --no-public --socket /tmp/s  # one endpoint, somewhere else
LISTEN_FDS=2 LISTEN_PID=… recobd    # adopt listeners on fds 3 and 4, binding
                                    # nothing — what systemd's Accept=no passes
                                    # (§3.2); tests/activation.rs sets this up
recobd --record                     # the observation seam (§11.1)
recobd --capture                    # also observe the pasteboard and write
                                    # history rows (§14.2, macOS only)
```

`--capture` polls `changeCount` every 500 ms (`RECOB_CAPTURE_POLL_MS`) and can
be pointed at a named pasteboard instead of the general one with
`RECOB_CAPTURE_PASTEBOARD` — the seam `tests/capture_macos.rs` uses so the
suite never touches the live clipboard. One further live check exists behind
`cargo test --test capture_macos -- --ignored`; it observes the general
pasteboard, and saves and restores it.

`--record` reads `RECOB_RECORD_LOG`, `RECOB_RECORD_SCRIPT` and
`RECOB_RECORD_ENDPOINT`. It decodes with the production decoder, so a client
that emits a subtly wrong frame fails rather than being recorded as wrong; a
spent or absent script means the daemon answers from its own registry.

Note on naming: the service keeps its `clipboard-bridge` launchd and systemd
identity for this change — only the protocol is renamed (spec D3). The daemon
binary is `recobd`.
