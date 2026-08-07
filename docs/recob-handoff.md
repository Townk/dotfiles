# RECOB handoff — state after Phase 2

For an agent picking this up cold. Phases 1 and 2 of
`docs/recob-implementation-plan.md` are done, verified and pushed. Phases 3–8
remain. This document is what the plan and the spec do not say: what actually
exists, what was decided along the way and why, what is deliberately missing, and
which hazards have already bitten.

Delete it when Phase 8 lands. The spec and the plan are the durable artifacts.

## Read these, in this order

1. `AGENTS.md` and `.cursor/rules/no-company-info.mdc`. **This repo is public.**
   Work identifiers — employer, product and codenames, work hostnames, corporate
   usernames, work home paths, internal tool names — must never reach a committed
   file **or a commit message**. This has already been violated once and scrubbed
   (`c3f15fd`); the guard that should have caught it had silently stopped working.
2. `docs/recob-protocol-spec.md`, the sections your phase names. It is ~2,700
   lines and converged over ten review rounds; do not read it end to end, and do
   not skip the sections your phase does name.
3. `docs/recob-implementation-plan.md` — the ground rules and your phase's entry.
   **Read the ground rules even if you skim the rest.**
4. `custom-builds/recob/README.md`, `probes/README.md`, `bench/README.md`.
5. This document.

## What exists

`custom-builds/recob/` builds `recobd`: the wire codec (§4), the connection
lifecycle (§5), both endpoints with the launch shape and socket permissions of
§3.1–§3.4, the recording seam (§11.1), mutual authentication (§9.2), the policy
table and its single call site (§9.1, §9.3, §9.4), pre-auth limits (§3.5),
per-endpoint rate buckets (§9.5) and subtractive exposure (§9.6).

```sh
make -C custom-builds/recob build     # → target/release/recobd
make -C custom-builds/recob test      # fmt --check, clippy -D warnings, 131 tests
```

Verified beyond the suite: the §4.4 worked example round-trips byte-exact against
`bench/verify-worked-example.zsh` (which is authoritative over any figure you
compute); socket activation and the handshake work under real systemd on Linux
(`bench/verify-activation-systemd.sh`, 16 checks, run 2026-08-06); and both the
wire and the handshake have been driven by throwaway clients written from the
spec alone, which is the check worth repeating whenever you add an operation.

The operation registry holds **`host.identity` only**. That is not an oversight —
see "deliberately missing" below.

## Decisions already made

Do not re-litigate these. Each was a place the spec did not say and the reasoning
had to come from what the section was protecting; each is commented at its site.

| Decision | Why |
| --- | --- |
| The policy row lives **on** the registry row — one table, not two | §9.3 requires the registry derived from the policy; it also makes §9.4's first assertion structural, since a row cannot exist without a tier |
| `auth`/`cnonce` on the trusted socket are **refused**, not ignored | Silently accepting a credential field on an endpoint that checks none is the shape P6 forbids |
| `cnonce` is **required** on the public endpoint | Without it the server cannot prove itself, and skipping the mutual half quietly is the "looks like protection" failure §9.2 is written against |
| The token is re-read per connection, regenerated **only at startup** | Rewriting it while serving invalidates every remote's pushed copy at once, with no push to repair them |
| An unreadable token answers `bad-credential` | §11.4's "rejected as if absent" describes the file, not the caller |
| §3.5's accept caps are **per endpoint** | §9.5 says so for rate buckets and gives the reasoning; the identical argument applies to the accept caps, or a public flood locks the trusted socket out. **This one is an inference, not a quotation** |
| The recorder logs the client hello as op `hello` | Otherwise Phase 2's "the token never appears in a recorded exchange" passes vacuously, since the token travels in the hello |
| **D7: option 1**, spawn `hs` per notification | `docs/recob-d7-osd-delivery.md`, measured. This unblocks `osd.notify` in Phase 4 |

## Deliberately missing, and why

**Thirteen of §9.3's fourteen policy rows.** They arrive in Phase 4 *with* their
handlers. `caps` advertises what this build can dispatch (§5.1) and §7.1's skew
diagnostic rests on `caps` being true, so a policy row without a handler would put
a lie in it. Add the row and the handler in the same change.

Two consequences you will meet: no row is `local` and none has a rate bucket, so
the table-generated enforcement loops in `registry.rs` are empty today. They are
written to cover each new row the moment it has an entry — do not replace them
with hand-written per-operation tests. The enforcement logic itself is
additionally proven against a constructed operation, which is why those tests pass
despite the empty loops.

**§9.2's token push.** `ssh-prepare-connection` does not yet push
`tunnel-tokens/<owner-host>`, so no remote holds a credential and the public
endpoint is unusable by a real client. Phase 5, with the clients that need it.
§9.2 "Distribution, with the mode fixed" gives the exact shell, `umask` before the
write and `chmod` after.

**On-demand token rotation** has no affordance; today it is delete the file and
restart. Document it in Phase 8's migration note rather than adding a flag, unless
asked.

**§7.3's pre-RECOB shim** — a non-RECOB peer is logged and closed. Phase 5.

**Client-side §11.4 coverage**: the client refusing an unproven server, refusing
an `R` before `proof`, and the OSC 52 fail-open test §11.4 calls the most
important one. Phase 5/6. The recorder already ships `deny-auth`, `no-proof` and
`bad-proof` so you can drive them without hand-rolling a handshake.

**§9.4 assertion 3 in the spec suite.** The daemon has the table-driven version;
§9.4 also wants one driving real connections from the shellspec side. Phase 6.

## Hazards that have already bitten

**The leak guard does not exist on a fresh clone until you arm it.** The hook is
tracked at `.githooks/pre-commit`, but `core.hooksPath` is local config and
`.leak-patterns` is gitignored and holds the real identifiers. Until both are in
place the hook warns and passes. Do this before your first commit:

```sh
git config core.hooksPath .githooks
$EDITOR .leak-patterns     # see README.md § the leak-safe boundary
```

A pre-commit hook **cannot see the commit message**, and the policy covers
messages. Check your own message before committing; that is how the one leak in
this repo's history happened, and how it nearly happened a second time.

**A committed verification artifact can go stale silently.** Phase 2 broke
`bench/verify-activation-systemd.sh` — its client did not authenticate, so the
public endpoint refused it — and nothing failed until a human ran it. If your
phase changes the wire, the handshake or the launch shape, re-run the bench
scripts and fix them in the same change.

**This is the clipboard the human uses every few minutes.** Phase 3 deliberately
leaves Hammerspoon writing too, so duplicate rows are expected until Phase 7 — do
not "fix" them. Phases 3, 5 and 7 progressively take over the live path; the
repo's `/validate` skill exists for the eyeball checks, and its Mode B is the
serialized UX session for exactly this.

**`mkdir -p -m` sets the mode on the final component only.** Intermediate
directories silently take the umask. This produced a 0775 directory that the
daemon then correctly refused, and cost a debugging round on Linux.

**`bind()` masks a Unix socket from 0777**, so §3.3's `umask(0o077)` yields 0700,
not 0600 — the explicit `chmod` is what lands 0600. Both steps are load-bearing;
the section reads as though either would do.

**`chezmoi apply` runs pending scripts.** Scope it (`chezmoi apply <path>`) unless
you intend to run GPG-key setup and the rest.

## Working rules that are not in the plan

- Every commit must leave `make test` green. The history bisects today; keep it
  that way. Verify a split by checking each commit out in a worktree and running
  the suite, not by assuming.
- No `Co-Authored-By` or agent-attribution trailers (`AGENTS.md`).
- Commit messages in this repo carry a `## Changes Description` and, when
  verification ran, a `## Testing`. Explain *why*, not what the diff shows.
- The store schema, the launchd/systemd service names, the pickers' read paths,
  the clipboard mount and the OSC 52 fallback's existence are all off-limits
  (plan, ground rules).
- When implementation contradicts the spec: **stop and report**. Do not patch
  around it and do not amend the spec unilaterally. Four of the blocking defects
  found in review existed only because a previous fix created them.

## Sequencing

Critical path is 3 → 4 → 5 → 8. **Phase 6 needs only Phase 2 and can start now**;
it is the long pole by volume (~245 examples across eight spec files) and is the
main way this project ends up waiting on itself. It parallelizes cleanly, one
agent per spec file. Phase 7 needs only Phase 4.

Phase 8 cannot be finished by one machine: it needs `chezmoi apply` on both, and
§12's benchmark must measure the **authenticated public endpoint** on both, or it
will report a win the human does not experience (§9.2's closing note).

---

## Update — after Phases 3, 4, 5, 7 and part of 8

Phases 3, 4, 5 and 7 are complete; Phase 8 has its build hook and its
migration guide. **Phase 6 is the only thing standing between the tree and the
cutover**, and it is the one piece a fresh agent can start on immediately.

### What exists now, beyond what this document described

`custom-builds/recob/` is a two-crate workspace. `recob-wire` holds the codec,
the credential primitives and the §8 client contract, and **links no platform
framework** — that boundary is what lets the clients obey §8's no-AppKit rule,
and `wire/tests/no_appkit.rs` asserts it with `otool -L` rather than trusting
it. `recobd` depends on that crate and adds the store, the platform layer and
the registry.

The client binary is **`system-clip`**, with `copy`, `paste` and `restore`
subcommands and no argv[0] dispatch (operator's decision, 2026-08-07: RECOB is
the bridge, not the feature, and a compiled binary must not hardcode the names
of the shims that call it). At cutover, `executable_pbcopy` and
`executable_pbpaste` become two-line `exec` trampolines — not aliases, which
non-shell callers never see, and not symlinks, which re-couple the names.

`clients/` holds two **staged** files that Phase 8 installs over their `home/`
counterparts: `universal.lua` (the nvim provider on RECOB) and
`clipboard-history.lua` (the read-only module Phase 7 leaves behind). They are
staged rather than applied because either one, applied before the daemon
exists, breaks the live clipboard until the daemon is installed.

### The gate, precisely

Phase 6 must convert or retire roughly 256 examples across eight spec files.
The blocking subset is the 107 in `pbcopy_spec.sh`, `pbcopy-files_spec.sh` and
`pbpaste-files_spec.sh` that drive the shims directly, plus the 65 in
`clipboard-bridge_spec.sh` and `clipboard-files-ops_spec.sh` that drive the zsh
dispatcher. Until those are converted, swapping the shims and the services
turns the repo suite red — which is why the cutover commit does not exist yet.

### Decisions taken since, which should not be re-litigated

| Decision | Why |
| --- | --- |
| The daemon captures the pasteboard **iff `--capture`** | §6.5's synchronous capture in `files.list`/`files.grant` is the same act of observation the poll loop performs. They shared no switch, so a daemon started without `--capture` still read the general pasteboard — a test daemon read the live clipboard. One switch now gates both |
| A direct write's row comes from a **post-write pasteboard snapshot**, not from the request fields | The pasteboard advertises synonym types beyond what was written, and a later observation of an identical physical copy hashes the full advertised set. Building the row from the request alone made the same bytes stop deduping |
| The `--files` engine takes an explicit `Context` | Reading `SSH_*`, the mount helper and `CLIP_FILE_MAX` from the environment inside made the local/mounted/streamed decision untestable, and leaked a cap between parallel tests |
| Behaviors the old implementation has and the spec omits are **ported, and reported** | Operator's ruling, 2026-08-06, after the M path's mount enrichment was found missing from the spec. Do not drop one silently |

### Hazards found the hard way, since

**`system-clip copy` on a local Mac never reaches the daemon.** It delegates to
`/usr/bin/pbcopy`, by design and unchanged since before this project. A local
rehearsal therefore writes the real clipboard, reads it back, prints what you
expected, and proves nothing — the row appears later, written by the capture
loop observing the general pasteboard. `PBCOPY_DARWIN_BIN=/nonexistent` forces
the bridge path. `docs/recob-migration.md` says so; this cost a confused
debugging round and one overwrite of the human's real clipboard.

**`vim.fn.sha256` is NUL-safe.** §8 depends on it for the challenge response
and nonces are raw CSPRNG bytes, so roughly one in eight contains a NUL. It was
verified against `shasum`, not assumed. Do not "fix" this with hex encoding —
it would break the digest the daemon computes.

**The nonce-uniqueness test in `tests/auth.rs` flakes.** Seen four times across
this work, always on a cold or heavily-parallel full run, never in isolation,
and it predates all of it. It deserves its own diagnosis; treat a single red
run of that one example as the known flake rather than as a regression, but
confirm by re-running.

**Linux is unverified.** No cross toolchain, no container and no dev-shell
access existed on the machine this was built on. Every platform-specific path
is `cfg`-gated and the shared code is std-only, but the suite has not been run
there. Do that first on the next Linux touchpoint.

## Update — Phase 6 complete (2026-08-07, `recob-cutover`)

Phase 6 is **done**. Every spec file that drives the shims, the dispatcher or
the third client is converted to the recorder harness — ten files, 315
examples, 0 failures, 1 deliberate macOS skip — and the three client bugs the
conversion surfaced are fixed. All of it lives on `recob-cutover` (unpushed);
`master` is untouched.

### What exists now, beyond the update above

**`system-bridge`**, the generic op invoker (operator's decisions, 2026-08-07:
generic invoker over `system-clip` subcommands; installed to
`~/.local/libexec` — it is plumbing the zsh wrapper execs, and `system-clip`
stays the only PATH-visible RECOB binary). `call` sends any §6.1 operation
(`name=value` fields, one `--stdin` field, `--peer` for the tunnel endpoint,
`--action` for the long §5.2 deadline, replies as `name=<hex>` lines or one
`--raw` field); `probe` is §6.1's ruling that reachability is the §5.2
connect result. Design record:
`docs/superpowers/specs/2026-08-07-recob-generic-invoker-design.md`
(gitignored, local).

**`clipboard-bridge-client.zsh` is op wrappers now** — no opcode, frame byte
or payload layout survives in shell — and all four callers are rewired:
`notify` puts the `style` enum on the wire (P5; the Lua-global mapping
survives only on the local `hs` route), the mux scripts speak
`window.fullscreen.*`, and `pick-clipboard`'s eight opcodes became six op
wrappers (the `id:` prefix and the LOCAL_PORT plumbing died; a new
`RECOB_ACTION_TIMEOUT_S` knob carries `MUX_BRIDGE_TIMEOUT_S`'s meaning).

**§8 rule 7 is implemented.** `Session::exchange`/`fetch` pre-flight the op
against `caps` and render §7.1's three message shapes, side named from the
address dialed; the wire crate carries its own registry copy
(`recob_wire::registry`), pinned to the daemon's table by a test beside that
table. The endpoint/credential plumbing both binaries share moved to
`recob_wire::cli`.

**The auth-nonce flake is dead, not dodged.** It was the test racing §3.5's
8-slot unauthenticated cap: `join()` proves client-side completion, but the
slots are released by the server's teardown. The test now honors
`busy`/`retry_after` exactly as §5.2 tells a real client to. Retract this
document's earlier "deserves its own diagnosis" — it got one.

### Hazards found the hard way, since

**A workspace `cargo build --release` does not relink `recob-wire`'s bins.**
A stale `target/release/system-clip` silently fails spec assertions that the
library fix provably satisfies. Build with `--workspace` (what `make build`
does) or `-p recob-wire --bins`.

**`make test | grep …; echo $?` reports grep's exit, not make's.** A
`cargo fmt --check` failure printed nothing the grep matched and five commits
claimed green suites that were fmt-red. The branch history was repaired by
autosquash and every commit re-verified in a worktree with real exit codes;
capture `$?` from `make`, never from a pipe tail.

### What remains, in order

1. **Phase 8, the services swap** — still not written, still the single edit
   that can leave a machine with no bridge at all. Write it and validate it
   Mode B **with the operator present**; service names must not change (D3).
   `tests/clipboard-window-op_spec.sh` is deleted with the dispatcher in that
   same commit, and `docs/notify-over-bridge.md` needs its dead-wire sections
   refreshed then too.
2. **The Linux dev-shell run** — now covers the five newly-converted files
   too; still the first execution for every `cfg!`-gated branch.
3. Push, once the cutover lands.
