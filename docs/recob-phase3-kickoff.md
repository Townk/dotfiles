# Kickoff prompt — Phases 3 onward

Paste the block below to a fresh agent. It is written for someone with no
context. Delete this file when Phase 8 lands.

---

Continue the RECOB implementation in the chezmoi dotfiles repo at
`~/.local/share/chezmoi`. Phases 1 and 2 are done, verified and pushed; you are
picking up at Phase 3.

**Before anything else**, get the work and confirm what you inherited is sound —
so that a failure you did not cause is never attributed to a change you made:

```sh
git -C ~/.local/share/chezmoi pull --ff-only
cd ~/.local/share/chezmoi
git config core.hooksPath .githooks     # the leak guard; see the handoff
make -C custom-builds/recob test        # must be green before you change anything
```

The build needs a Rust toolchain. If `cargo` is missing, install it before going
further rather than working around it. If that suite is **not** green on a clean
pull, stop and report that — it is a finding about the inherited state, not
something to fix your way past.

**Read first, in this order:**

1. `AGENTS.md` and `.cursor/rules/no-company-info.mdc` — repo rules. This
   repository is **public**: no work identifiers in any committed file *or commit
   message*. After editing anything under `home/`, run `chezmoi apply` scoped to
   the path you touched.
2. `docs/recob-handoff.md` — the state of the work, the decisions already made,
   what is deliberately missing, and the hazards that have already bitten. Read
   this in full before writing anything. **Arm the leak guard as it says, before
   your first commit.**
3. `docs/recob-implementation-plan.md` — the ground rules and your phase's entry.
4. `docs/recob-protocol-spec.md`, the sections your phase names — §14.1, §14.2,
   §14.6 and §14.7 for Phase 3. It is ~2,700 lines; read what your phase names
   and do not skip it.
5. `custom-builds/recob/probes/README.md` before writing any macOS code. The
   working `objc2` call shapes are there and each cost several rounds of compile
   errors to find — including a document-type trap that fails at runtime with an
   unhelpful "Cocoa error 65806" if you pass string literals instead of the
   exported statics.

**What RECOB is:** a replacement for the clipboard bridge's wire protocol and
process model. A single persistent Rust daemon (`recobd`) in place of socat
forking a zsh dispatcher per connection, a named-operation protocol in place of
sixteen exhausted single-letter opcodes, and one connection carrying many
exchanges in place of five connections per user action.

**Phase 3 — the macOS platform layer.** Scope: §14.1 (native pasteboard), §14.2
(the behaviors absorbed from the Hammerspoon watcher), §14.6 (regtype without the
sidecar file), §14.7 (what the Linux build omits).

Build it as a platform module behind an interface, with a Linux implementation
that omits what §14.7 says it omits. Phase 4 sits on top of it, and keeping the
split real is what stops the Linux build from rotting — the suite runs on Linux
today and must keep running there.

**Done when:** the daemon observes real pasteboard changes and writes store rows
itself; `source_app` and `source_bundle_id` are stamped from the frontmost
application; the password-manager deny-list still refuses to capture; and regtype
is tracked internally against `changeCount` with no sidecar file.

**Not yet:** Hammerspoon is still writing too. Retiring it is Phase 7. Expect
duplicate rows in this window and do not "fix" them.

**Do not touch, in any phase:** the store schema, the launchd/systemd service
names, the pickers' read paths, the clipboard mount, or the OSC 52 fallback's
existence.

**The store schema is off-limits but you must write to it correctly.** Read what
the Lua writer does today before writing a row, and reimplement the behaviors
§14.2 lists — the sensitive-UTI refusal, the password-manager deny-list, the 5 MB
image cap, the empty and whitespace-only rejection, dedup by `type_hash`, the
retention sweeps, `file_authorities` for local captures only, and `file_grants`
expiry. A rewrite that quietly drops the password-manager guard is exactly the
regression a wire-protocol document is bad at noticing.

**This is the human's live clipboard.** Test against a uniquely-named private
pasteboard wherever possible, the way `probes/pasteboard.rs` does. Where a test
genuinely must observe the general pasteboard, say so and save and restore it.

**If implementation contradicts the spec, stop and report it.** Do not patch
around it and do not amend the spec on your own. Four of the blocking defects
found during review existed only because a previous fix created them, so a
plausible-looking workaround is the most likely way this goes wrong.

**Every commit leaves `make -C custom-builds/recob test` green.** The history
bisects today; keep it that way.

**Verify before claiming done.** Run the command, show the output. "Should work
now" is not a result.

When Phase 3 lands, continue to Phase 4 — D7 is decided
(`docs/recob-d7-osd-delivery.md`), so `osd.notify` is unblocked — then 5 and 7.
Phase 6 needs nothing you are about to build and can be run in parallel by other
agents, one per spec file; it is the long pole by volume. Phase 8 needs both
machines and cannot be finished from one.
