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
