# RECOB implementation plan

Sequencing for building what `docs/recob-protocol-spec.md` specifies. The spec
is the source of truth for *what*; this document is only the order, the gates
between phases, and what "done" means for each.

Written because the work is far too large for one agent context. Each phase
below is sized to be startable cold by someone who has read the spec and
nothing else, and to end at a state that can be verified without the next phase
existing.

## Ground rules for every phase

**The spec outranks this plan, and reality outranks the spec.** If
implementation contradicts the specification — an API that does not behave as
§14 claims, a measurement that does not reproduce, a rule that cannot be
enforced where §9.4 says to enforce it — **stop and report it**. Do not work
around it silently and do not amend the spec unilaterally. Ten review rounds
found four blocking defects that each existed only because the previous round's
fix created them; the failure mode of this project is a plausible-looking
patch, not a missing feature.

**No phase lands with a red test.** The daemon replaces a path the human uses
every few minutes; a broken intermediate state is not academic.

**Do not touch, in any phase:** the store schema (§16), the launchd/systemd
service names (D3 — protocol renamed, service not), the pickers' read paths, the
clipboard mount, or the OSC 52 fallback's existence.

**Repo conventions:** compiled artifacts live in `custom-builds/<name>/` with a
Makefile exposing `build`, `install` and `test`, a `.gitignore` for the binary,
and a `run_onchange_after_*` hook in `home/.chezmoiscripts/`. `tm-timeline` is
the model to copy. `custom-builds/recob/` already exists and holds the probes
and benchmarks the design was derived from — read both READMEs before writing
macOS code, because the working `objc2` call shapes are there and cost several
rounds of compile errors each to find.

**Commit authorship:** no `Co-Authored-By` or agent-attribution trailers
(`AGENTS.md`).

---

## Phase 1 — Wire codec, daemon skeleton, recording seam

**Why first:** it is platform-neutral, it validates the wire format before
anything depends on it, and the recorder it produces is a prerequisite for all
test conversion. Nothing else can start cold.

Scope: §4 (preamble, frames, named fields, the §4.4 worked example), §5
(connection lifecycle, hello, timeouts), §3.1–§3.4 (endpoints, launch shape,
socket permissions, concurrency), §11.1 (`recobd --record`).

Registry content is deliberately out of scope: implement `host.identity` only,
as a proof that dispatch works.

**Done when:**
- `custom-builds/recob/` builds a `recobd` via `make build`, and `make test`
  passes.
- The §4.4 worked example round-trips byte-exact. `bench/verify-worked-example.zsh`
  prints the reference bytes; the codec must produce those bytes and parse them
  back. Body length is `0x3d`.
- The trusted socket is mode 0600 with a 0700 parent, established by the daemon
  itself — `umask` before bind *and* explicit `chmod` after, both, because
  `bench/listener-feasibility.zsh` Q3 shows the default is 755.
- `LISTEN_FDS` is honoured on Linux (§3.2). This is the capability that was
  impossible in zsh and is half the reason the daemon is compiled; if it does
  not work, that is a report-worthy finding.
- `recobd --record` decodes with the production decoder and writes the log
  format §11.1 specifies.

**Gate:** the recorder must be usable by a human before Phase 6 is briefed.

---

## Phase 2 — Authentication, authorization, limits

Scope: §9.2 (mutual challenge-response), §9.1/§9.3 (tiers, policy table, single
call site), §9.4 (the enforcement test), §3.5 (pre-auth limits), §9.5 (rate
limits), §9.6 (subtractive exposure).

**Read §9.2 in full before writing any of it.** It is the most-revised section
in the document and several obvious-looking simplifications are defects that
earlier rounds already found and closed: the token must never cross the wire,
nonces must come from the OS CSPRNG, comparison must be constant-time, a client
must not parse `R` before verifying `proof`, and frame kind `C` exists
specifically because the proof-bearing frame could not borrow `H` or `R`.

**Done when:**
- §9.4's structural assertions pass, including the one that fails when an
  operation exists with no policy entry. That assertion is the mechanism that
  keeps future additions from being silently ungated; it is not a formality.
- The §11.4 authentication tests pass — the token never appears in a full
  recorded exchange, nonces are unique per connection in both directions, a
  response before `proof` is refused, and a refused connection still writes
  `RECOB` + `busy` before closing.
- Rate limits are per-endpoint in-memory counters, and exhausting one endpoint
  demonstrably does not throttle the other.

---

## Phase 3 — macOS platform layer

Scope: §14.1 (native pasteboard), §14.2 (behaviors absorbed from the watcher),
§14.6 (regtype without the sidecar file), §14.7 (what the Linux build omits).

Build this as a platform module behind an interface, with a Linux
implementation that omits what §14.7 says it omits. Phase 4 sits on top of it.
Keeping the split real is what stops the Linux build from rotting.

`probes/` is the reference: `pasteboard.rs` for atomic multi-UTI writes,
`NSFilenamesPboardType` plists and plist parsing; `gui-context.rs` for
`frontmostApplication` and the `changeCount` poll; `attrstr.rs` for HTML/RTF
conversion, including the document-type-statics trap that produces a runtime
"Cocoa error 65806" if you pass string literals instead.

**Done when:** the daemon observes real pasteboard changes and writes store
rows itself; `source_app` and `source_bundle_id` are stamped from the frontmost
application; the password-manager deny-list still refuses to capture; regtype
is tracked internally against `changeCount` with no sidecar file.

**Not yet:** Hammerspoon is still writing too. Retiring it is Phase 7. Expect
duplicate rows in this window and do not "fix" them here.

---

## Phase 4 — The operation registry

Scope: §6.1 (all fourteen operations), §6.4 (streaming responses), §6.5
(behavior that must carry across), §6.6 (field validation), §14.5
(`clip.restore`).

**Gate: D7 must be decided before `osd.notify` is implemented** — spawning `hs`
at 17.9 ms per notification, or a persistent channel to Hammerspoon. It is the
largest spawn left in the design and the only decision still open.

**Done when:** every operation in the §6.1 registry dispatches, every field
validates per §6.6, streaming terminates with an explicit zero-length chunk so
truncation is detectable, and the §11.4 behavior tests pass — including
`clip.restore` across every clip kind, and `files.list` not racing the capture.

---

## Phase 5 — Clients

Scope: §8 (client contract), §5.2 (timeouts and the fallback rule).

`pbcopy` and `pbpaste` become Rust binaries (D2/D6). The Lua client in
`home/dot_config/nvim/lua/clipboard/universal.lua` is updated in place.

**The clients must not link AppKit** — it costs about 2.6 ms of startup and
they have no reason to touch the pasteboard, which is the daemon's job. This is
a hard rule in §8, not an optimization.

**The OSC 52 fallback is permitted on `ECONNREFUSED` and nothing else.** Not on
timeout, not on a protocol error, not on `unauthorized`. A timeout is
indistinguishable from an attacker stalling the connection, and §13.1 row 4
accepts a loud failure during the skew window rather than reopen that path.

---

## Phase 6 — Test suite conversion

Can start as soon as Phase 2 lands; does not need Phases 3–5.

Roughly 245 examples across the eight spec files §11.3 enumerates, moving from
a fake `nc` to the real recorder. Mechanical but large, and §11.3 says which
file changes how. Two of them are affected only by the `W` →
`window.fullscreen.*` rename rather than by the transport.

**Done when:** every example passes against the recorder. This is a hard gate
on cutover.

---

## Phase 7 — Retire the Lua writer

Scope: §14.4, §14.5.

`clipboard-history.lua` stops starting the watcher and stops inserting; it
opens the store read-only. The GUI picker's in-process `restore_by_id` becomes
a `clip.restore` call over the trusted socket, because sole-writer means
sole-writer.

**Done when:** exactly one writer exists on macOS, and one copy produces exactly
one row (§11.4).

---

## Phase 8 — Build, launch, cutover

Scope: §13 (rollout), §13.2 (`docs/recob-migration.md`), the `run_onchange`
build hook, launchd and systemd unit changes.

The build hook is part of the cutover and has a real cost — `rusqlite` with
`bundled` measured 11.4 s cold. It must fail loudly if the toolchain is
missing rather than silently leaving the old path in place.

`docs/recob-migration.md` is the brief's fourth deliverable and is
operator-facing, not design-facing: apply order, how to recognize each row of
§13.1 from the message alone, token bootstrap and rotation, how to verify a
machine is on RECOB, and rollback. Its audience is a human at 2 a.m. whose copy
stopped working.

**Done when:** a clean `chezmoi apply` on both machines produces a working
bridge, and §12's benchmark harness shows the daemon beating the numbers in §1
that justified building it.

---

## Order and parallelism

Critical path is 1 → 2 → 3 → 4 → 5 → 8. Phase 6 can run alongside 3–5 once 2
lands, and Phase 7 needs only 4. Phase 6 is the long pole by volume and should
start as early as it can.

| Phase | Needs | Blocks |
| --- | --- | --- |
| 1 codec, skeleton, recorder | — | everything |
| 2 auth and policy | 1 | 3, 6 |
| 3 macOS platform | 2 | 4 |
| 4 registry | 3, **D7** | 5, 7 |
| 5 clients | 4 | 8 |
| 6 test conversion | 2 | 8 |
| 7 retire Lua writer | 4 | 8 |
| 8 build and cutover | 5, 6, 7 | — |
