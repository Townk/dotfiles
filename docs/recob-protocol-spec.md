# RECOB v1 — wire protocol and endpoint specification

> **Status: proposed, awaiting review. No implementation code exists or should
> be written against this document until it is approved.** This is deliverable
> 1 of `docs/recob-audit-brief.md#required-deliverables`; the benchmark
> harness, the implementation, the authorization-enforcement test and the
> migration note follow it, in that order.
>
> Revision 2 replaces the persistent zsh listener of revision 1 with a native
> Rust daemon that also absorbs the pasteboard watcher. The wire is unchanged
> by that; [§1.1](#11-the-costs-a-shell-implementation-cannot-remove),
> [§3](#3-endpoints-and-launch-shape), [§6.2](#62-the-four-collapses),
> [§9](#9-authorization), [§14](#14-the-macos-integration-surface) and
> [D6](#d6-implementation-language) carry the change.

This document specifies the replacement for the framing protocol currently
served by `clipboard-bridge-dispatch`, and the shape of the process that serves
it. It assumes [`docs/recob-audit-brief.md`](recob-audit-brief.md) has been
read: the mandate, the current-state inventory, the measured baseline and the
security findings live there and are not repeated. Where this document
contradicts `docs/clipboard-universal-project.md` §11/§22/§23, this document
wins for the wire and for the capture path; the fzf picker is unchanged.

**Clean slate.** No opcode, framing byte, payload layout or error string from
today's protocol survives. The single exception to "clean slate" is version
skew, which is a permanent property of the deployment and is specified in
[§7](#7-version-skew-and-the-diagnostic-contract).

**A native daemon, not a shell listener.** The service is a single Rust binary,
`recobd`, that owns the pasteboard, the store and the sockets in one process
([§3](#3-endpoints-and-launch-shape), [§14](#14-the-macos-integration-surface)).
Earlier drafts of this document specified a persistent *zsh* listener; that
decision was reversed on measured evidence and the reasoning is recorded in
[§15](#15-decisions) as D3. The wire format, the operation registry, version
negotiation, the authorization table and the error taxonomy are unchanged by
that reversal — they were designed to be language-agnostic and they survived
it intact. What changed is everything about how the service is *built*, and
several constraints simply disappeared.

---

## 1. What the redesign is aimed at

The brief attributes ~145 ms of every ~236 ms frame to accept-fork-dispatch
process startup on the two endpoints, against ~30 ms of network and 11 ms of
Hammerspoon. Two independent multipliers follow from that:

1. **What a connection costs.** Today every connection pays a `fork`+`EXEC`
   under socat (or a fresh transient unit under systemd) *and* a fresh zsh
   interpreter that sources ~1,700 lines of library before it can answer.
2. **How many connections a user action needs.** Today one frame is one
   connection, and one "copy the working directory" keypress needs five.

This specification attacks both, and deliberately does not attack the framing
bytes. Three measurements taken while writing it, on the Mac over loopback, in
one session, both orders, with an identical client and identical
per-connection work on both arms — only the listener differs:

| Arm | Mean | Repeat (reversed order) |
| --- | --- | --- |
| socat `fork` + `EXEC` of a trivial responder | 27.4 ms ± 2.4 | 27.0 ms ± 2.6 |
| persistent listener, `fork` of an already-warm handler | 13.4 ms ± 1.5 | 13.2 ms ± 1.7 |
| client-side floor (interpreter + modules, no socket) | 9.4 ms ± 1.5 | — |

and, separately, the real dispatcher spawned per frame the way socat spawns it
today — an `H` (get-host) frame piped straight in, which is read-only and
touches neither the store nor the pasteboard:

| Measurement | Mean | Repeat |
| --- | --- | --- |
| `clipboard-bridge-dispatch`, one frame, cold process | 45.3 ms ± 3.6 | 44.1 ms ± 4.0 |

Subtracting the 9.4 ms client floor, a persistent listener removes ~14 ms of
listener fork/exec **and** ~36 ms of interpreter-plus-library startup from
every connection, on this machine, over loopback, with a trivial handler.
These are isolation figures for one variable, not an end-to-end claim: the
end-to-end number is the benchmark harness's job ([§12](#12-benchmark-harness))
and no performance win is reported until it produces a same-session A/B in
both orders on both machines.

The client transport matters too, but less than the brief's earlier figure
suggested. Against the same warm listener, `nc` measured 18.2 / 18.7 ms and
`ztcp` 13.1 / 13.2 ms — about 5 ms per exchange for spawning the transport
binary, not the ~30 ms measured earlier through a forking listener.

Every figure above was re-run in a later session before this document was
declared finished, and every one landed inside its own σ: 28.2 / 27.6 against
13.6 / 13.8, a 9.5 ms floor, a 44.3 / 45.7 ms cold dispatcher, and 18.9 / 19.1
against 13.4 / 13.5 for the transport. The gaps the design rests on are
therefore session-stable, which is the property the brief's warning about
~20 ms drift on identical code exists to make you check.

### 1.1 The costs a shell implementation cannot remove

Everything above measures *connection* overhead, which is what the brief aimed
at. Scoping the implementation language surfaced a second class of cost that no
amount of listener redesign touches, because it is paid **inside** the handler:
every primitive the shell does not have is a subprocess.

| What the handler needs | Today | Native | Where it is paid |
| --- | --- | --- | --- |
| SHA256 | `shasum` spawn, **14.82 ms** (it is a Perl script on macOS) | 0.000282 ms | twice per side of every authenticated handshake ([§9.2](#92-connection-authentication)) |
| rich / file pasteboard write | `mktemp -d`, side files, generated Lua, `hs <script>` spawn, **17.9 ms** floor | direct `NSPasteboard` call | every rich copy, file copy, notification, `changeCount` read |
| store query | `sqlite3` CLI spawn, **7.02 ms** | in-process | every store operation |
| `changeCount` | one `hs` spawn, **17.9 ms** | **0.56 µs** | every capture poll and every enrichment guard |

The authentication figure is the one that forced the reversal. Two digests per
side is ~30 ms of subprocess spawning added to every authenticated connection —
**more than the entire ~50 ms per-connection saving the persistent listener was
designed to deliver.** Seven review rounds did not catch it because every round
audited the design and none audited what the primitives cost.

Every figure in this table was re-measured in a later session before this
revision was declared finished, under the same rule §1 applies to itself:
`shasum` 15.14 ms, `sqlite3` 7.71 ms, `hs` 18.0 ms ± 2.0, in-process SHA256
0.000222 ms. Each landed inside its own noise, so the gaps the language
decision rests on are session-stable and not an artifact of one measurement.

### 1.2 What a compiled client is actually worth

Less than intuition suggests, and the honest number changes an architectural
rule rather than a headline:

| | Startup |
| --- | --- |
| macOS process-spawn floor (`/usr/bin/true`) | 4.7 ms ± 1.0 |
| Rust binary, no AppKit linked | 5.5 ms ± 1.1 |
| Rust binary, linking AppKit | 8.1 ms ± 1.1 |
| zsh + modules, today's client floor | 9.4 ms ± 1.6 |

The platform floor is 4.7 ms, so a compiled `pbcopy` saves ~3.9 ms per
invocation, not the ~8 ms a naive reading of the zsh floor suggests. Linking
AppKit costs 2.6 ms of dynamic-linking time on top. Hence a rule with teeth in
[§8](#8-client-contract): **the clients must not link AppKit.** They speak to
the daemon and have no business touching the pasteboard, so a shared crate that
quietly pulls AppKit into the client binary would consume most of the
client-side win without anyone noticing.

**Design consequence.** The connection is the expensive unit on the wire, and
the subprocess is the expensive unit inside the handler. The first drives §2,
§4 and §6; the second drives §3 and §14.

---

## 2. Design principles

These are the decisions the brief asked to be made as principles rather than
as bolt-ons. Everything in the rest of the document follows from them.

### P1. The service is one persistent process and spawns nothing per request

`recobd` binds both endpoints once and then accepts in a loop, serving each
connection on its own task. `socat` disappears from the macOS service
definition and the `Accept=yes` templates disappear from the Linux one.

"Spawns nothing" is the half of this principle that revision 1 could not state.
A shell listener avoids the per-connection `fork`+`EXEC` and then pays a
subprocess for every primitive it lacks — a digest, a store query, a pasteboard
write — which [§1.1](#11-the-costs-a-shell-implementation-cannot-remove)
measures at more than the fork it eliminated. A process that is warm but has to
shell out to do its job has moved the cost rather than removed it.

### P2. The connection is the unit of cost; amortize it

A connection carries **any number of request/response exchanges**. A client
that needs three things from one endpoint opens one connection and issues
three requests, pipelined. This is the general answer to "fewer frames per
user action", and it is why no operation in this specification exists purely
to be merged with another.

### P3. Provenance travels inside the operation it describes

The `O` (declare-origin) opcode exists only to attribute the change that the
`T` immediately following it is about to make. It is replaced by a field on
`clip.set`, not by a merged opcode. **A declaration sent as a separate
operation is a race; a field is not.**

Generalized: **no operation may depend on state a previous operation deposited
within a time window.** Anything an operation needs is in its payload or in a
bearer capability it presents.

Earlier drafts had to qualify this principle heavily, because it governed the
wire but could not reach the Hammerspoon watcher — a separate process that
observed the pasteboard asynchronously and could not be handed a field. The
qualification is gone: the daemon observes the pasteboard itself
([§6.2](#62-the-four-collapses)), so the writer and the observer are the same
process and provenance is never serialized into a marker for a stranger to
find. The principle now holds without exception, which is the shape a principle
should be in. When a principle needs an exception clause naming a specific
other process, that is usually the architecture asking to be changed rather
than the principle asking to be weakened.

### P4. Operations are named, not numbered

The single-byte opcode namespace has visibly run out (`n` is lowercase because
`N` is retired; `f`/`a` for similar reasons). Operations are dotted ASCII names
(`clip.set`, `osd.notify`, `files.fetch`). The capability set exchanged at
connect is a set of these names, which is what makes the skew diagnostic
precise rather than a bare "unknown opcode". Framing bytes are explicitly not
the thing being optimized.

### P5. The wire carries data, never a callable

`n`'s payload names a Lua global to invoke, guarded by a two-entry allow-list.
The allow-list is the right mitigation for that shape, but the shape is wrong.
Fields that select behavior are closed enums validated against a table; they
are never interpolated into a script, a shell word, or a symbol lookup.

### P6. Fail closed and loud, never silently

An unknown field is an error, not something to ignore. An unparseable frame is
an error, not a fallback. A truncated stream is detectable
([§6.4](#64-streaming-responses)). Silently ignoring an input is how an
authorization bypass and a "it copied, but without provenance" bug both hide.

### P7. Authorization is a table, checked in one place

One declarative op → requirement table, consulted by one call site, with a
test that fails when an operation exists without an entry
([§9](#9-authorization)). Three enforcement sites and ten unchecked opcodes is
the current state and is the finding this closes.

### P8. Reach is bounded locally, never named by the caller

This daemon exists to give a remote host **deliberately granted, mediated
access to the machine the human is sitting at**. Growth is expected — the
retired opcode letters are what the last round of it looked like — so the
question of what may be added needs an answer that is not "whatever seemed
reasonable at the time."

The test is **who determines the operation's reach**:

> Can the sit-at machine determine, from its own configuration and state, the
> complete set of effects this operation can have — with the wire only
> *selecting* among them, never *naming* them?

This is P5 and P9 turned on reach rather than on behavior. P5 keeps the wire
from naming a callable; P8 keeps it from naming a target. An operation whose
reach is fixed before any peer connects is bounded no matter what it touches;
an operation whose reach arrives in a field is unbounded no matter how narrow
it looks in the example that motivated it.

| Operation | Reach determined by | |
| --- | --- | --- |
| `clip.set` | there is exactly one pasteboard | admitted |
| `osd.notify` | `style`, a closed enum ([§6.6](#66-field-validation)) | admitted |
| `window.fullscreen.toggle` | `terminal`, a closed enum | admitted |
| `files.fetch` | a `grant` issued locally, scoped to one clip id and expiring | admitted |
| a write to a device or destination the daemon was configured with | a slot naming an entry in a local table | admitted |
| `file.write{path, bytes}` | the caller's `path` | **refused** |
| `exec.run{cmd}` | the caller's `cmd` | **refused** |

**"Reach" means what the daemon acts *on*, not what it is handed.** A field
carrying content, or selecting among rows this machine already holds, is not
reach: `clip.set.files` takes `paths`, but they are the clipboard's *contents*
in exactly the way `text` is for `clip.set`, and `clip.restore` takes a
`clip_id` that selects a row from the local store. Neither field extends what
the operation can touch — the pasteboard is the pasteboard either way. Read the
test as asking what the daemon will open, write, execute or mount, and it sorts
these correctly; read it as "does any field come from the caller" and it
refuses most of the registry. The two cases where a caller-supplied path
becomes real authority are guarded elsewhere and not by this principle:
`clip.set.files` and `clip.restore` are `local` tier, so no tunnel peer reaches
them at all, and `store.persist.files` is why `mints_authority: local` exists in
[§9.3](#93-per-operation-policy-fields).

**`files.fetch` is the row that makes the test honest.** It is a file read —
policy `authed`, `fs-read`, streaming bytes off this machine to a peer across
the tunnel — and it touches neither pasteboard nor GUI at the moment it runs.
It belongs, and it belongs *because of the grant*: `files.grant` issues the
token here, from a clip this machine already holds, scoped and expiring. Take
the grant away and leave the same bytes reachable by a caller-supplied path,
and the operation becomes one this principle refuses, having changed nothing
about what it can read on a good day. The boundedness is the whole of the
safety, which is why it is the thing the test asks about.

The corollary is the useful half: **an operation is not disqualified for being
unglamorous.** Pushing a built firmware image to a keyboard in bootloader mode
from the machine you are developing on is a legitimate thing to want from this
daemon — no pasteboard, no window, no screen — and it is admissible exactly
when the destination comes from a local table rather than from the wire.
`files.grant` is the template already in the document for "a peer reads local
data under a locally issued, scoped, expiring token"; the write direction is
its mirror.

Two traps this principle is watching for, both of which look like the admitted
rows until read closely. A local destination table holding **paths or device
nodes** is data parameterizing a fixed operation, which
[§9.6](#96-configurable-exposure) classifies as safe backend substitution; the
same table holding **commands** is the additive configuration §9.6 refuses,
and it arrives disguised as a convenience. And an enum whose values are
resolved by string interpolation rather than by table lookup is a
caller-named target wearing a closed set's clothing.

A weaker rule survives alongside this one, as a design pressure rather than a
gate. RECOB's credential is a pushed token file
([§9.2](#92-connection-authentication)) — a real boundary, but a narrower and
newer one than the key infrastructure already carrying the same link, audited
by this document and a policy table rather than by decades of scrutiny. So an
operation as general as an SSH session is a bad trade: it reproduces something
that already exists, over a weaker credential, and gains nothing. It does
**not** follow that anything SSH *could* do belongs in SSH. A bounded
operation over a weak credential is frequently the safer choice, because the
alternative — letting a shared multi-user host hold a key to a shell here —
grants far more than the operation ever would. Prefer the narrowest credential
that accomplishes the task, which sometimes means building the narrow
operation instead of reaching for the general one.

### P9. The daemon mediates a capability; it need not implement it

Delegating to another process is **the intended architecture, not a
concession**. The daemon's job is to define a capability precisely, authorize
it, bound it, and then cause it to happen — by whatever local means suits it,
including handing the work to Hammerspoon or an external script.

This is P5 seen from the other side. P5 forbids the *wire* from naming a
callable; P9 says the handler naming one is exactly right. `osd.notify`
carries `style=ansi`, a closed enum, and a table inside the handler maps that
to the Lua function that draws the toast
([§6.6](#66-field-validation)). The remote asked for a *kind of
notification*; it did not ask to run anything. That indirection — a fixed,
named, authorized capability on one side and a substitutable local
implementation on the other — is what makes it safe to expose GUI actions to a
network at all, and it is the seam every future operation should be built on.

Two consequences worth stating, because they are the difference between this
principle and an open door. The capability's contract is fixed at build time
and is the security boundary. The local implementation behind it is not part of
that boundary, and may be substituted freely ([§9.6](#96-configurable-exposure)).

---

## 3. Endpoints and launch shape

Two endpoints, unchanged in purpose, changed in how they are launched.

| Endpoint | Address | Reached by | Trust |
| --- | --- | --- | --- |
| `public` | loopback TCP `2489` (a peer reaches it as `2490` through the SSH `RemoteForward`) | anything that can open the port | see [§9](#9-authorization) |
| `trusted` | Unix socket `~/.local/state/cb.sock` | same-uid only; never forwarded | highest |

**One process serves both.** `recobd` binds the TCP listener and the Unix
socket and accepts on both. Endpoint identity is a property of *which listener
accepted the connection*, established at bind time and never derived from
request data. This replaces `CLIPBOARD_BRIDGE_ENDPOINT`, which existed only
because socat spawned a separate process per endpoint and had to tell it which
one it was; a variable that carries a security-relevant identity into a process
is a thing to remove when the reason for it goes away.

### 3.1 macOS

`services.toml.tmpl`'s two `socat` entries collapse to one entry running
`recobd`, keeping `keep_alive = true` and `run_at_load = true`. No socat.

### 3.2 Linux

Socket activation returns. Rust honors `LISTEN_FDS`, so `clipboard-bridge.socket`
and `clipboard-bridge-trusted.socket` are kept and their `@.service` templates
are replaced by a single `recobd.service` with `Accept=no`. systemd owns both
listening sockets and passes them as fds 3 and 4; `recobd` adopts them when
`LISTEN_FDS` is set and binds them itself when it is not, so the same binary
runs under systemd, under launchd, and from a terminal during testing.

This reverses the finding an earlier draft recorded. Under a zsh listener the
`Accept=no` design was impossible — `ztcp -a` accepts only on a descriptor the
same process created with `ztcp -l`, and refused an inherited one with
`fd 8 is not registered as a tcp connection`. That constraint was a property of
the implementation language, not of the design, and it left the deployment
without lazy activation for no reason a reader of the finished system could
have reconstructed. It is recorded here because the reverse mistake — carrying
a workaround forward past the constraint that caused it — is the more common
one.

Knock-on edits: `services.toml.tmpl`'s adopted `unit =` names, and the
`systemctl --user start clipboard-bridge.socket` self-heal calls in the
clients.

### 3.3 Trusted socket permissions

The trusted endpoint's entire security model is "mode 0600, same-uid only",
which socat provides today via `mode=0600`. A bound socket does not get that
for free in any language — the mode comes from the umask at bind time — so the
daemon establishes it itself, with no window in which the socket is bound and
world-connectable:

1. `umask(0o077)` **before** bind, so the socket is never created permissive;
2. an explicit `chmod` immediately after bind, as belt and braces;
3. the socket's parent directory at mode 0700, so the socket is unreachable
   even on a platform that ignores socket permission bits.

All three, not one of them. This is a test case, not a comment. When systemd
supplies the socket, the unit's `SocketMode=0600` and `DirectoryMode=0700`
carry the same requirement, and the daemon asserts the mode it was handed
rather than assuming it.

### 3.4 Concurrency and supervision

- **A task per connection, not a process.** The daemon handles each connection
  on its own task; a panic is caught at the task boundary and closes that
  connection only. A handler cannot take the daemon with it, a 20-second
  first-use macOS Automation consent dialog on `window.fullscreen.toggle`
  cannot block a paste, and no handler state leaks between connections because
  none is shared except through explicit, locked structures.
- **No fork, therefore no reaping, no descriptor inheritance, and no zombie
  accounting.** Three hazards an earlier draft had to specify defenses for do
  not arise. The daemon still spawns helper processes for the few operations
  that need them ([§14.3](#143-what-the-daemon-delegates)), and reaps
  those.
- **The accept loop survives a handler error, a malformed frame and a
  connection reset**, and logs each with the endpoint and operation.
- **State that other processes can change is read, not cached.** The
  self-name file is rewritten by `ssh-prepare-connection` at connect time
  while the daemon is running, so a value read once at start would be wrong
  for the rest of the daemon's life. The daemon watches the file, or re-reads
  it per connection; it does not cache it at startup. Each such value gets a
  test that mutates the source and asserts the next connection sees the new
  value. This hazard is created by long life, not by language, and it is the
  one hazard from the earlier draft that survives unchanged.

### 3.5 Pre-authentication limits

A long-lived daemon changes the blast radius of a flood. Today each connection
is an independent `socat` child, and the operating system's own limits are the
backstop. Tomorrow one process owns the accept loop for every client, so a peer
that opens connections and then stalls can starve every legitimate user of the
endpoint. Authorization ([§9](#9-authorization)) does not help here — it is
evaluated per operation, long after the descriptor is spent and the connection
is being served.

The limits are split by where they are enforced, and the specification is
precise about which is which — a limit described as being applied at accept
when it is really applied mid-handler is a limit that does not bound what it
claims to.

**At accept, before the connection is dispatched:**

| Limit | Default | On breach |
| --- | --- | --- |
| concurrent live connections | 32 | `busy`, close |
| unauthenticated connections in flight | 8 | `busy`, close |
| new connections, per 10 s | 30 | `busy`, close |

A connection occupies an **unauthenticated in-flight** slot from accept until it
either authenticates or closes. Releasing the slot at dispatch would make the
counter meaningless — the whole point is to bound peers that connect and then
stall. With one process this is a counter behind a mutex and a guard that
decrements on drop, so the slot is released on every exit path including a
panic; the earlier draft needed a cross-process marker reaped alongside `CHLD`
handling for the same guarantee, which is the kind of accounting that is easy
to get subtly wrong and hard to test.

**In the connection handler, bounding the pre-auth phase:**

| Limit | Default | On breach |
| --- | --- | --- |
| preamble + hello read | 1 s | `E{code=bad-request}`, exit |
| declared frame length, pre-auth | 4 KiB | `E{code=too-large}`, exit |
| total bytes read before authentication | 8 KiB | `E{code=too-large}`, exit |

The pre-auth byte and length caps cover **everything read before the credential
validates**, including `Q` frames the client pipelined ahead of its hello
([§5](#5-connection-lifecycle)). A client may pipeline; it may not pipeline
8 KiB of anything. The **pre-auth frame length cap** is separate from, and far
smaller than, the caps of [§6.5](#65-behavior-the-registry-must-carry-across):
an unauthenticated peer must never be able to make the listener allocate a
large buffer by asserting a large length, and no legitimate hello approaches
4 KiB. The **unauthenticated-in-flight limit** is what makes a slowloris
ineffective — a peer that connects and says nothing occupies one of eight slots
for at most one second, rather than one of thirty-two handler slots
indefinitely.

#### A refused connection must still identify itself

This is the sharpest edge in the whole specification, and the first draft of
this section got it wrong in a way that inverted the fix in
[§5.2](#52-timeouts).

Refusing a connection by closing it silently is not safe here, because §5.2
tells the client that a connection closed without a `RECOB` preamble means *no
bridge is present*, which is the one condition under which `pbcopy` may fall
back to unauthenticated OSC 52. So a local attacker who merely opens eight idle
connections could push every one of the victim's copies onto an unauthenticated
transport — **the limits meant to protect the listener would become the
authentication bypass.** Two defensive additions combining into a hole is
exactly the failure mode a second review round exists to catch.

Therefore: **every accepted connection receives the six preamble bytes and an
`E{code=busy, retry_after=…}` before it is closed, including every connection
refused by a limit above.** A refusal writes the preamble and that error only —
never the banner of [§5.1](#51-hello-fields), since there is no nonce to issue
for a connection that will not be authenticated.

The write is unconditionally non-blocking; if it would block, the socket is
closed and the descriptor reclaimed, because a listener that can be made to
block on a write to a hostile peer is worse than one that occasionally drops a
diagnostic. **A dropped or truncated `busy` is therefore a normal outcome, not
an error path**, and §5.2's fallback rule is keyed on the connect result rather
than on bytes received precisely so that a client which receives four bytes and
a close behaves identically to one that receives all of them. The cost is a few
dozen bytes on a path that is by definition already rejecting work.

Clients back off on `busy` rather than failing instantly: three retries at 50,
150 and 400 ms. If they still fail, the operation fails **loudly**, which is
the intended outcome. An attacker who can sustain that flood can deny the
bridge — that is unavoidable for any local-uid attacker on a shared box, and it
is the correct trade. Denial of service is recoverable and visible; a silent
downgrade to an unauthenticated transport is neither.

---

## 4. Wire format

All integers are big-endian and unsigned. All lengths are byte counts. Values
are arbitrary bytes, including NUL; nothing is escaped, encoded or
length-guessed anywhere.

### 4.1 Connection preamble

Each side, on connect, writes:

```
"RECOB" <1 byte wire_version>        6 bytes, fixed
<hello frame>                        see §4.3 and §5.1
```

The server writes its six bytes and banner immediately on accept, never waiting
for the client. The client's own timing depends on the endpoint: on the trusted
socket it writes everything at once and pipelines its first request behind its
hello, while on the authenticated public endpoint it must read the banner's
challenge before it can compose a hello at all
([§5](#5-connection-lifecycle), [§9.2](#92-connection-authentication)). The
preamble bytes themselves are written immediately either way, so a peer always
learns straight away that it is talking to RECOB.

The server's hello here is a deliberately thin **banner** — enough to diagnose
skew and to carry the challenge, and nothing else. What it must *not* contain,
and why, is [§5.1](#51-hello-fields).

`wire_version` is `0x01` and governs *this section only* — the framing. It is
bumped only if frame or field encoding changes, which is expected never. A
mismatch is unrecoverable, because nothing past the preamble can be parsed
safely.

### 4.2 Frames

```
frame := <1 byte kind> <4 bytes BE32 length> <length bytes body>
```

| Kind | Byte | Direction | Meaning |
| --- | --- | --- | --- |
| Hello | `H` | both | preamble hello, exactly once per side, first frame |
| Capabilities | `C` | server → client | sent once, immediately after the credential validates ([§5.1](#51-hello-fields)) |
| Request | `Q` | client → server | one operation |
| Response | `R` | server → client | success |
| Error | `E` | server → client | failure, terminates this exchange |
| Data | `D` | server → client | one chunk of a streaming response |

A zero-length `D` frame terminates a stream. There is no separate end frame
and no "read until the peer closes".

**Capabilities is its own kind, and that is load-bearing rather than tidy.**
It cannot be a second `H`, because a client must be able to tell the pre-auth
banner from the post-auth frame by kind alone rather than by counting. It
cannot be an `R` either, because §9.2 forbids parsing any `R` before the
client has verified `proof` — and `proof` arrives *in* this frame, so
overloading `R` makes the rule circular and an implementer must either
special-case the first `R` or refuse the frame that unlocks the connection.
A distinct byte removes the choice: `C` is the only frame a client parses
before `proof` is verified, because it is the one that carries it.

Maximum body length is 64 MiB by default; a declared length above the limit
that applies is a protocol error answered with `too-large` and the connection
is closed. This bounds the memory a single malformed frame can ask a handler to
allocate. The limit is **per operation, not global** — one operation raises it
and the pre-auth phase lowers it sharply; see
[§6.5](#65-behavior-the-registry-must-carry-across) and
[§3.5](#35-pre-authentication-limits). A decoder therefore takes its cap from
the operation's registry entry rather than hardcoding 64 MiB.

### 4.3 Bodies: named fields

Every body — hello, request, response and error alike — is a sequence of named
fields, read until the body's declared length is consumed:

```
field := <1 byte name_len> <name_len bytes name>
         <4 bytes BE32 value_len> <value_len bytes value>
```

- **Names** are `[a-z][a-z0-9_.]*`, at most 32 bytes. A name outside that
  shape is a protocol error.
- **Values** are arbitrary bytes. A field may be empty (`value_len` 0); empty
  and absent are distinct and each operation says which it accepts.
- **Order is not significant.**
- **A duplicate field name is a protocol error** (`bad-field`).
- **An unrecognized field name is a protocol error** (`unknown-field`), per
  P6. This is deliberate and it is also the precise skew diagnostic: a newer
  client sending a field an older endpoint has never heard of gets told
  exactly which field and exactly which build lacks it, instead of having the
  field silently dropped and the operation half-performed.
- **List-valued fields are NUL-joined** — one convention everywhere, including
  the hello's capability set. Real filesystem paths cannot contain NUL, which
  is why today's manifest already joins them this way.

Named fields are chosen over positional ones because optional blocks
(provenance on `clip.set`) become natural, and because the current
US/RS-delimited positional layout has already failed once: `US` (0x1f) is legal
in a filename, so `pbpaste`'s `manifest_parse` carries an `awk` scanner that
counts only the first N separator offsets to avoid corrupting the path tail.
Length-prefixing removes the entire class.

### 4.4 Worked example

`clip.set` of the four bytes `hi\n\0` with regtype `l`, originating on a host
recorded as `boxA`, is one `Q` frame with four fields:

```
51                      'Q'
00 00 00 3d             body length 61
  02 6f 70              "op"          (name_len 2)
  00 00 00 08 63 6c 69 70 2e 73 65 74      "clip.set"
  04 74 65 78 74        "text"
  00 00 00 04 68 69 0a 00                  "hi\n\0"
  07 72 65 67 74 79 70 65                  "regtype"
  00 00 00 01 6c                           "l"
  0b 6f 72 69 67 69 6e 5f 68 6f 73 74      "origin_host"
  00 00 00 04 62 6f 78 41                  "boxA"
```

Note the NUL inside `text` and the absence of any delimiter that could collide
with it.

---

## 5. Connection lifecycle

1. Client connects. The server writes its preamble and pre-auth banner
   immediately ([§5.1](#51-hello-fields)).
2. On the **trusted socket**, the client writes its preamble, hello and first
   `Q` frames immediately, without waiting. On the **public endpoint** it waits
   for the banner's `nonce`, then writes its hello; it may pipeline only the
   four payload-free requests behind it, and holds everything else until the
   server has proved itself ([§9.2](#92-connection-authentication)).
3. Server reads the client hello and authenticates the connection
   ([§9.2](#92-connection-authentication)). On success it writes its
   capabilities frame (`C`) — carrying `proof` on the public endpoint — then processes
   `Q` frames in order, answering each with exactly one `R`, one `E`, or one `R`
   followed by a `D` stream. On failure it writes `E{code=unauthorized}` and
   closes, having dispatched nothing and disclosed nothing beyond the banner.
4. Client verifies `proof` before sending any request that carries user data,
   and before acting on any response. A peer that cannot prove itself is
   treated as hostile, not merely broken.
5. Either side may close after any complete exchange. Neither side is required
   to send a goodbye.
6. An `E` frame terminates the exchange it answers. It does not terminate the
   connection unless the error is a connection-level one
   ([§10](#10-error-taxonomy)).

**Responses are strictly ordered.** The Nth `R`/`E` answers the Nth `Q`. There
are no request identifiers, because there is no out-of-order completion; a
handler is single-threaded per connection. This is the cheapest thing that
supports P2, and adding request ids later is a `proto` bump, not a `wire` one.

### 5.1 Hello fields

The server's disclosure is **split in two**. An unauthenticated peer that
merely completes a TCP handshake must not learn the build identity and the
complete operation inventory of the machine — that is a free reconnaissance
map, handed to precisely the local attacker §9.2 exists to stop. But the
opposite extreme is worse: a peer that cannot authenticate must still be able
to learn *why*, or a skewed pair reports `unauthorized` when the truth is "you
are three versions behind."

So the pre-auth banner carries exactly what is needed to produce a correct
diagnostic and to choose a credential, and everything else waits.

**Server banner — written on connect, before authentication:**

| Field | Meaning |
| --- | --- |
| `proto` | decimal integer, the semantic protocol version |
| `host` | this machine's `clip::self_host` value — diagnostics only, and **not** trustworthy, since the banner is unauthenticated ([§9.2](#92-connection-authentication)) |
| `nonce` | 32 random bytes, fresh per connection, on the public endpoint only |

**Client hello:**

| Field | Meaning |
| --- | --- |
| `proto` | decimal integer, the semantic protocol version |
| `impl` | free-form build identity, diagnostics only, never compared programmatically |
| `auth` | challenge response, when the endpoint requires one ([§9.2](#92-connection-authentication)) |
| `cnonce` | 32 random bytes, the client's own challenge, public endpoint only |

On the trusted socket the client hello is written immediately, pipelined with
its first requests. On the public endpoint it necessarily waits for `nonce`;
§9.2 explains why that round trip cannot be optimized away without handing the
credential to whatever happens to be listening.

**Server capabilities (frame kind `C`) — written only after the credential
validates:**

| Field | Meaning |
| --- | --- |
| `impl` | build identity |
| `endpoint` | `public` or `trusted` |
| `caps` | NUL-joined operation names this build can dispatch |
| `proof` | the server's answer to `cnonce`, public endpoint only ([§9.2](#92-connection-authentication)) |

`proto` starts at `1` and increments whenever the operation registry, a field
set, or an authorization requirement changes. `impl` is the chezmoi source
hash prefix of the listener, which distinguishes two builds that share a
`proto` — the case where "which side is behind" is otherwise unanswerable.

`host` is already disclosed unconditionally today: `H` (`clip::op_host`) has no
authorization check at all, so publishing it pre-auth concedes nothing that is
not already public to anyone who can reach the port. `impl` and `caps` are not
in that position, which is why they moved.

`endpoint` lets a client assert it reached what it intended. `pbcopy`'s
`clip.set.files` must go to the trusted socket; if it somehow reaches the
public endpoint, that is a configuration fault worth failing loudly on rather
than discovering as an `unauthorized` several steps later. It arrives after
authentication, which is early enough — the assertion guards against
misconfiguration, not against an adversary.

**The split itself costs no round trip.** The capabilities frame (`C`) rides back in
front of the first response rather than being asked for. The one round trip on
the public endpoint is bought by the challenge in §9.2, not by withholding
`caps` — withholding is free, and would remain worth doing even if the
credential were not.

### 5.2 Timeouts

| Timeout | Default | Override | Applies to |
| --- | --- | --- | --- |
| preamble read | 500 ms | `RECOB_HELLO_TIMEOUT_MS` | client waiting for the server's `RECOB` bytes |
| exchange | 2 s | `RECOB_TIMEOUT_S` | a request that answers from memory |
| action | 20 s | per call site | an operation that makes the far machine *do* something |

The preamble timeout is short on purpose: a warm listener writes its preamble
within single-digit milliseconds of accept, so a 500 ms cap turns a
pre-RECOB peer into a fast, precise diagnostic instead of a multi-second stall
([§7](#7-version-skew-and-the-diagnostic-contract)). The action timeout keeps
today's hard-won behavior — a `window.fullscreen.toggle` can legitimately block
on a first-use macOS Automation consent dialog until a human clicks it, and
reporting "refused" for an action that actually happened is worse than waiting.

#### A timeout must never become a downgrade

That short preamble timeout has a sharp edge, and P6 (fail closed) is the thing
it threatens. `pbcopy` treats *any* unsuccessful bridge attempt as license to
deliver the copy over OSC 52 instead
(`home/dot_local/bin/executable_pbcopy:652-665`), silently, by design — the
comment there reasons that a warning on a copy that then succeeds is noise.
That reasoning was sound when the bridge was unauthenticated: both paths were
equally trusted, so the choice between them was purely about reachability.

Under RECOB it stops being sound. OSC 52 is an unauthenticated terminal escape
that traverses whatever is between the shell and the terminal emulator, and
`unauthorized`, `busy` and a slow-but-healthy listener are all failures of a
control rather than absences of a bridge. Falling back on any of them means the
authentication requirement can be evaded by making the bridge merely slow.

**Rule: OSC 52 is a fallback for an absent bridge, never for a refusing or
overloaded one.** The whole question is how a client tells those apart, and the
answer must not be "did we get a reply in time" — because anything an attacker
can slow down, an attacker can turn into a downgrade.

So the test is the **connect result**, which an attacker cannot forge without
already owning the port:

| Observation | Meaning | Behavior |
| --- | --- | --- |
| `ECONNREFUSED` — nothing bound | no bridge here | OSC 52, silently. Unchanged, and still the common case: a host with no tunnel has nothing on loopback 2490 |
| connect succeeds, or times out, or is reset | something is bound | **no fallback**, ever; fail with the diagnostic |

The connection refusal is the only signal admitted, and this is deliberate.
Consider the alternative: a client that infers absence from *silence* can be
downgraded by a local attacker who simply exhausts the listener's accept
backlog. Legitimate SYNs are then dropped rather than refused, the victim's
client times out, and — under a rule keyed on timeouts — every copy quietly
becomes an unauthenticated OSC 52 while the real bridge is healthy and
listening a few descriptors away. The same reasoning disposes of a subtler
variant: a `busy` write from [§3.5](#35-pre-authentication-limits) that is cut
short by `EAGAIN` can leave the client holding four preamble bytes instead of
six, and a rule of "six bytes or it's absent" would downgrade on exactly the
overload condition the `busy` frame was added to report. Under the rule as
written, both cases are a completed TCP connect, so both fail loudly.

Once bytes do arrive, everything is reported rather than papered over:
`unauthorized` says the credential is missing or stale and names the fix,
`busy` says to back off and retry, a timeout says the bridge is not responding.
`RECOB_HELLO_TIMEOUT_MS` exists so a genuinely slow machine can be given more
room, and the client retries once on preamble timeout before reporting — but it
reports either way. **Guessing "absent" from silence is the inference that
leads to a silent downgrade, so the client never makes it.**

---

## 6. Operation registry

Fourteen operations replace sixteen live opcodes plus two error stubs. Four
collapses are structural, not cosmetic: each removes a whole connection from a
real user action.

### 6.1 The registry

| Operation | Replaces | Request fields | Response fields |
| --- | --- | --- | --- |
| `host.identity` | `H` | — | `host` |
| `clip.get` | `G` + `R` + `S` | — | `text`, `regtype`, `timestamp`, `host` |
| `clip.set` | `T` + `O` | `text`, `regtype`, `origin_host`?, `app`? | — |
| `clip.set.rich` | `C` | `uti`, `blob`, `origin_host`? | — |
| `clip.set.files` | `U` | `paths` \| `clip_id` | — |
| `clip.restore` | picker-internal `restore_by_id` | `clip_id`, `plain_only`? | — |
| `store.persist.text` | `P` | `host`, `kind`, `app`, `regtype`, `text` | — |
| `store.persist.files` | `M` | `host`, `paths` | — |
| `files.list` | `L` | — | `kind`, `host`, `timestamp`, `paths` |
| `files.grant` | `K` | — | `kind`, `host`, `timestamp`, `token`, `paths` |
| `files.fetch` | `f` + `a` | `token`, `index` | `kind`, `size`, then a `D` stream |
| `osd.notify` | `n` | `origin_host`, `style`, `icon`, `sound`, `text` | — |
| `window.fullscreen.toggle` | `W fullscreen-toggle` | `terminal` | — |
| `window.fullscreen.state` | `W fullscreen-state` | — | `state` |

`?` marks an optional field. Retired without replacement: `O`, `F`, `A`, and
the already-retired `N`.

**Reachability is not an operation.** `clipbridge::probe` is a bare `nc -z`
connect scan (`clipboard-bridge-client.zsh:32-37`) and two callers key real
behavior on it: `pick-clipboard:103-105` shows the live peer-clipboard row only
when it succeeds, and `docs/notify-over-bridge.md` documents the same test for
routing notifications. Nothing in the registry replaces it, and it must not
become `host.identity` — that is an authenticated round trip where a connect
scan costs nothing, and it would make the picker's row depend on a credential.

The replacement is the connect result of [§5.2](#52-timeouts), which the client
library already has to compute: **`ECONNREFUSED` means down, anything else
means up.** That is strictly more accurate than today's probe, which reports
down for a listener that is bound but saturated. `clipbridge::probe` keeps its
name and signature and changes only its implementation, so neither caller
changes.

Three fields need their exact shape pinned down, because "same as today" is not
a specification when the wire is being replaced:

- **`clip.set.files`'s `clip_id`.** Exactly one of `paths` or `clip_id` is
  present; both, or neither, is `bad-request`. `clip_id` is the decimal `clips`
  rowid as a bare integer — *not* today's `id:<rowid>` string. The `id:` prefix
  exists only to disambiguate a positional payload that could otherwise hold
  paths; named fields make the discriminator the field name, so the prefix is
  redundant and is dropped. A value that is not a positive decimal integer is
  `bad-request`, and one that names no row is `not-found`.
- **`clip.set`'s `app`** is the source application recorded on the store row.
  It has no analogue on the wire today because today the watcher supplies it;
  under §6.2 the handler writes the row, so a suppressed capture means nobody
  else can. Absent, the row records the empty string, which is what
  `clip::persist_text_row` already stores for an unknown app.
- **`clip.get`'s `timestamp`** is the store's `last_ts` for the current clip,
  and it is honestly platform-dependent. `clip::op_get_ts` content-matches the
  pasteboard against the store on macOS but short-circuits to `MAX(last_ts)` on
  Linux (`clipboard-store-core.zsh:600-608`), so on Linux it is "the newest row"
  rather than "the row matching what is on the clipboard right now." RECOB
  carries the value through unchanged; it does not fix the divergence, and the
  field's documented meaning is the weaker of the two so that no client is
  encouraged to rely on the stronger.

### 6.2 The four collapses

**`clip.get` returns everything about the current clip.** nvim's `paste()`
issues `G` then `R` today, and the picker's live-peer row issues `G`, `H` and
`S` — two and three connections respectively, for facts the receiver reads from
the same place at the same time. One exchange now returns all of them.

**`clip.set` carries its own provenance**, per P3 — and the `O` opcode goes
away because provenance is a field. That much was true of the earlier draft
too. What changed is what happens *behind* the pasteboard write, and it is
worth being precise about why, because this is the largest simplification in
the redesign and it did not come from the protocol.

Provenance is currently a message left in a file for a stranger. The daemon
writes the pasteboard; the Hammerspoon watcher, a **separate process**, notices
the change up to half a second later and pulls the origin from
`$XDG_STATE_HOME/pick-clipboard/current-origin`, matching on `SHA256(plain)`
within `ORIGIN_TTL = 5` seconds (`clipboard-history.lua:167-198`, consumed at
`:697`). Every part of that — the file, the hash keying, the TTL, the
`suppress-echo` flag — exists for one reason: **the writer and the observer
cannot see each other.** None of it is about clipboards.

**The daemon absorbs the watcher, and the whole apparatus goes.** One process
writes the pasteboard and polls `changeCount`, so when a change appears it
already knows whether it caused it. Provenance stops being a marker with a
lifetime and becomes a field on an in-memory record of the write the daemon
just performed. Deleted outright: `current-origin`, `ORIGIN_TTL`, the SHA256
keying, the `suppress-echo` flag, and `current-regtype` — the regtype is
likewise something the writer knows and no longer has to leave a note about.

This is what closes §23.2 rather than shrinking it. An earlier draft could only
narrow the window for plain text and had to admit the defect survived for rich
and file clips; the reviewer was right to press on it, and the honest answer
turned out to be that no protocol change could fix it, because the race was
never in the protocol. **With one process there is no window at all, for any
clip kind.** An identical physical copy on the receiving machine is
distinguishable from an echo of the daemon's own write by construction: the
daemon compares the observed `changeCount` against the value it recorded when
it wrote.

Two probes establish that a plain non-GUI process can do the observer's job,
both of which the audit had flagged as unverified:

```
Q7 frontmostApplication from non-GUI process: OK
   name = "Ghostty", bundleIdentifier = "com.mitchellh.ghostty"
Q8c changeCount poll cost: 0.560 us each
```

Q7 matters because `source_app` and the **password-manager deny-list** both
depend on it — if a daemon could not read the frontmost application, absorbing
the watcher would have silently disabled a security control, and the right
answer would have been to leave the watcher in Hammerspoon. Q8c matters because
the 0.5 s poll interval is the source of the capture lag that
[§6.5](#65-behavior-the-registry-must-carry-across) has to retry around. At
0.56 µs a poll, the interval is free to shrink by an order of magnitude, and
for the daemon's *own* writes the lag is not shortened but removed — the store
row and the pasteboard write happen in the same operation.

**What absorption obliges the daemon to reimplement**, in full, because these
are behaviors and not incidental details of the Lua: the sensitive-UTI refusal
(`Concealed`, `Transient`, `AutoGenerated`), the password-manager deny-list
keyed on the frontmost application, the 5 MB per-image cap, the empty and
whitespace-only rejection, dedup by `type_hash` over the sorted `uti=blob`
set, the 1000-row and 200 MB retention sweeps, `file_authorities` written only
for local captures, and `file_grants` expiry. [§14](#14-the-macos-integration-surface)
specifies these as requirements with tests, because "the rewrite quietly
dropped the password-manager guard" is precisely the kind of regression a wire
protocol document is bad at noticing.

**`files.fetch` handles files and directories.** Today `f` replies with the
exact string `is-directory`, and the client opens a *second connection* to
retry the same capability as `a`. The server already knows which it is: the
response declares `kind` as `file` or `directory` and streams accordingly. The
retry, and the magic string the retry keys on, both disappear.

**`W`'s sub-actions become operations.** `fullscreen-toggle` and
`fullscreen-state` were an action word parsed out of a payload string, which
made per-action authorization impossible — a state read and a window
manipulation shared one authorization decision. Separate operations get
separate table entries, and the read-only one is no longer gated with the
mutating one.

### 6.3 Frames and connections per user action

| Action | Today | RECOB v1, no caller changes | RECOB v1, caller restructured |
| --- | --- | --- | --- |
| `copy-pwd` over the bridge | 5 connections (`O`, `T`, `P`, announce `n`, completion `n`), 3 on the critical path | **4** — `pbcopy` folds `O`+`T` into one peer connection; `P` stays separate because it targets a different machine; the two `notify` calls keep their own | 2 — one peer connection carrying `clip.set` + both `osd.notify` exchanges, plus the backgrounded local `store.persist.text` |
| nvim paste over the tunnel | 2–3 connections (`G`, `R`, plus a one-off `H`) | 1 exchange (`clip.get`), plus the existing fire-and-forget persist | unchanged |
| `pbpaste --files`, remote directory item | 2 connections per item (`f`, then `a` after the `is-directory` reply) | 1 exchange per item on one connection | unchanged |

**Why `copy-pwd` needs a fourth column, and what that costs the headline
claim.** An earlier draft promised one connection for `copy-pwd`. The protocol
alone cannot deliver that, for two independent reasons that both had to be
found by tracing the flow rather than reading the registry.

First, `copy-pwd` reaches the bridge through **three separate processes**: a
backgrounded `notify` fired before the copy
(`executable_copy-pwd:154-157`), an exec of the `pbcopy` shim at an absolute
path (`:166`), and a second backgrounded `notify` (`:196-200`). Separate
processes cannot share a connection and no wire format changes that.

Second, `pbcopy` itself talks to **two different machines**. `O` and `T` go to
the reverse-tunneled peer on 2490 (`executable_pbcopy:630`, `:643`) while `P`
goes to this machine's own bridge on 2489 (`:683`) — the peer sets its
clipboard, the local store records the copy. Those are different endpoints, so
P2 cannot merge them however good the protocol is. What does merge is `O`+`T`,
which is the pair on the critical path.

So the protocol delivers five connections down to four, with the peer critical
path going from two to one. The right-hand column additionally needs
`copy-pwd` restructured to make a single client call that both copies and
notifies — a **caller** change, listed as follow-on work rather than smuggled
into a protocol claim.

**Net of authentication.** Each surviving public-endpoint connection pays
§9.2's challenge, and the copy path pays the mutual-proof round trip on top.
That is a real cost the old design did not have, because the old design had no
authentication at all. It remains strongly favorable — a round trip is bought
once per connection, while each eliminated connection cost a round trip **plus**
the ~145 ms of process startup the brief attributes to accept-fork-dispatch —
but "strongly favorable" is a prediction, and [§12](#12-benchmark-harness) is
required to verify it on the authenticated public endpoint rather than assume
it.

### 6.4 Streaming responses

`files.fetch` is the only streaming operation. Its shape:

```
R { kind = "file" | "directory", size = <decimal> }
D <chunk>          zero or more, each ≤ 64 KiB
D <empty>          clean end of stream
```

`size` is exact for a `file` and a `du`-based **estimate** for a `directory`,
with no directional guarantee — that honesty is inherited from today's `a` and
must survive into the client's progress rendering, which clamps at 100%.

An error discovered mid-stream is sent as an `E` frame in place of the next
`D`. This is the concrete win over today's design, where `a` writes a raw `tar`
stream until EOF with no trailing frame at all: a truncation caused by an I/O
error on the far end is currently indistinguishable from a clean end, and is
caught only because `tar` happens to notice its archive is malformed. Under
this specification, absence of the terminating empty `D` *is* the truncation
signal.

The connection remains reusable, and that needs one rule to be true rather than
merely hoped for: **a mid-stream `E` terminates the exchange, not the
connection, and the server sends no further `D` frames for it.** The client
resumes reading at the next frame boundary, which is the next exchange's `R`.
Both ends must agree, because the alternative — a client that closes on a
mid-stream error while the server keeps the connection open for the next
request — turns a recoverable per-file failure into a dropped connection in the
middle of a multi-item `pbpaste --files`. `internal` and `unreadable-entries`
are the codes that reach a client this way.

**What the client then does with the overall command is a separate decision,
and it stays as it is today: abort.** `pbpaste --files` fails the whole run on
the first item that fails rather than delivering a partial set, because a
caller that asked for three paths and silently received two has been given a
wrong answer rather than a degraded one. The connection staying open is what
makes the *next* command cheap; it is not permission to continue this one. The
partially written staging directory is removed on the way out, as today.

### 6.5 Behavior the registry must carry across

A clean-slate wire is an easy place to lose hard-won behavior by omission. Two
things in the current implementation are not obvious from any opcode's
signature and must be carried across explicitly, because a reasonable
reimplementation from the registry alone would drop both.

**`files.list` must not race the capture, and how it avoids that changes.**
Today `clip::resolve_current_file_manifest` sleeps 0.3 s and re-reads when the
newest row is not a files row (`clipboard-store-core.zsh:711-717`), because the
store trails the pasteboard by up to half a second and a paste issued
immediately after a Finder copy otherwise sees the *previous* text row.

**This retry is the §6.2 race in a different costume**, and it has the same
cause: a store written by a process that observes the pasteboard
asynchronously. Absorbing the watcher removes the cause. For a clip the daemon
wrote, there is no lag at all — the row and the pasteboard change happen in one
operation. For an external copy from Finder, the lag is whatever the poll
interval is, and at 0.56 µs a poll ([§14.1](#141-what-the-daemon-does-natively))
that interval is no longer bound to 0.5 s.

The operation's *contract* is therefore stated as a property rather than as a
sleep: **`files.list` reflects the pasteboard as of the moment the request
arrived**, and the daemon satisfies it by comparing the live `changeCount`
against the one its store row was captured at, capturing synchronously if they
differ, rather than by sleeping and hoping. `files.grant` inherits the same
property. A reimplementation that keeps the 0.3 s sleep is not wrong, but it is
carrying a workaround past the constraint that caused it.

**Content operations are capped, and the cap is stated.** Today there is no
size limit on `clip.set.rich`'s blob: `pbcopy --content` of a large PDF or image
either works or exhausts memory, undefined either way. A declared cap is
strictly better than undefined behavior, but the global 64 MiB frame limit of
[§4.2](#42-frames) is the wrong number for this one
operation, so it is raised per-operation rather than globally:

| Operation | Cap | Error |
| --- | --- | --- |
| `clip.set.rich` `blob` | 128 MiB | `file-too-large` |
| everything else | 64 MiB frame body | `too-large` |

128 MiB sits below the store's own 200 MiB total-store cap
(`clipboard-history.lua:68`) and above anything a clipboard realistically
carries. This is a *new* limit where none existed; it is declared here rather
than discovered later as an out-of-memory kill.

### 6.6 Field validation

Every field is validated against a declared shape before a handler sees it.
Per P5, fields that select behavior are closed enums:

| Field | Shape |
| --- | --- |
| `regtype` | exactly one of `v`, `l`, `b` |
| `style` (`osd.notify`) | exactly one of `plain`, `ansi` |
| `terminal` | exactly one of `ghostty`, `wezterm` |
| `kind` (`store.persist.text`) | exactly one of `text`, `files`, `file`, `directory` |
| `host`, `origin_host` | `[A-Za-z0-9][A-Za-z0-9.-]*`, ≤ 253 bytes |
| `uti` | member of the endpoint's allow-list ([§9.3](#93-per-operation-policy-fields)) |
| `index` | decimal, within the grant's path count |
| `token` | 64 lowercase hex characters |
| `auth` | NUL-joined, 1–8 entries, each 64 lowercase hex characters |
| `paths` | NUL-joined, each element absolute, no `..` component |
| `nonce`, `cnonce` | exactly 32 bytes, from `/dev/urandom` |
| `proof` | 64 lowercase hex characters |
| `app` | ≤ 256 bytes, no NUL or newline |
| `text` (`clip.set`, `store.persist.text`) | arbitrary bytes, up to the operation's cap |
| `blob` (`clip.set.rich`) | arbitrary bytes, up to 128 MiB |
| `proto` | decimal integer, 1–4 digits |
| `impl` | ≤ 64 bytes, `[A-Za-z0-9._-]` |
| `caps` | NUL-joined, each element matching `[a-z0-9_.]+` |
| `icon` (`osd.notify`) | ≤ 256 bytes |
| `sound` (`osd.notify`) | ≤ 64 bytes |
| `text` (`osd.notify`) | ≤ 1024 bytes |

The four length caps on `osd.notify` and `host` are not new limits — they are
today's, at `clip::parse_notify_payload` (`clipboard-store-core.zsh:1141-1143`),
written down because a clean-slate wire that omits them would let two clients
disagree about what is sendable and discover it as a runtime rejection.

`style` replacing `n`'s `fn` field is P5 made concrete: `fn` names a Lua global
(`notify` or `notifyAnsi`) that the handler interpolates into a generated
script. The enum is mapped to a callable by a table inside the handler; the
wire never carries the symbol.

### 6.7 Adding an operation

This daemon is expected to grow — the retired opcode letters are the evidence
of the last round of growth, and P4 exists because that namespace ran out. The
mechanisms for extending safely are spread across §6, §7, §9 and §11, so the
procedure is collected here rather than reconstructed each time.

**Before anything else, apply P8.** Can this machine determine the complete set
of effects the operation can have, with the wire only selecting among them? If
the reach arrives in a field, redesign it until it does not — a slot into a
local table, or a locally issued grant — or drop it. That question is answered
first because every step below is wasted if the answer is no, and because it is
far cheaper to change now than after the operation has clients.

Then, in one change:

1. **Name it** under an existing prefix where one fits — `clip.`, `files.`,
   `osd.`, `window.`, `store.`, `host.`. A new prefix is a claim that a new
   category of capability exists, which is worth making deliberately.
2. **Add the registry row** ([§6.1](#61-the-registry)): request fields,
   response fields, and what it replaces if anything.
3. **Add the policy row** ([§9.3](#93-per-operation-policy-fields)) with a
   tier. There is no default — §9.4's first assertion fails if the entry is
   missing, which is the mechanism that makes "ungated" a decision rather than
   an oversight. Prefer `local` unless the operation demonstrably needs to
   cross the tunnel; §9.7 explains why an `authed` addition deserves more
   thought than it looks like it needs.
4. **Stamp `since`** with the `proto` the operation first appears in, and bump
   `proto`. §9.4's fourth assertion catches a `since` ahead of the current
   version; §7.1's diagnostic is what turns a missing operation on the far side
   into "that machine is behind" instead of a bare failure.
5. **Validate every field** ([§6.6](#66-field-validation)) with a closed enum
   wherever a field selects behavior, per P5.
6. **Decide the backend** ([P9](#p9-the-daemon-mediates-a-capability-it-need-not-implement-it)):
   implement it in the daemon, or delegate. Delegation is fine and expected;
   what is fixed is the capability's contract, not who fulfils it.
7. **Add coverage** ([§11.4](#114-new-coverage-the-specification-requires)) —
   at minimum the policy enforcement case, which §9.4 generates from the table,
   plus whatever behavior is specific to the operation.

**Adding a *field* to an existing operation is not the cheap version of this.**
P6 makes an unknown field a hard error, so an older peer receiving a new field
fails the request rather than ignoring it. That is deliberate — silently
ignored fields are how authorization bypasses hide — but it means a field
addition carries the same `proto` bump and `since` stamp as a new operation,
and the client must check `proto` before sending it — `caps` will not tell it,
since a new field does not change the operation's name. An extender
who assumes fields are additive will ship a change that works perfectly on one
machine and breaks the other until both are applied. The cost is real, it is
paid once per addition, and §7's negotiation is what makes it survivable.

---

## 7. Version skew and the diagnostic contract

Skew is permanent: the two ends are updated by independent `chezmoi apply`
runs, at different times. The requirement is that a mismatch produces a precise
diagnostic naming **which side is behind**.

### 7.1 Which side is behind, and how the client knows

Comparison is between the client's own `proto` and the server's `proto` from
the hello. Naming the machine is the *client's* job, because only the client
knows which address it dialed:

| Dialed | Names |
| --- | --- |
| `~/.local/state/cb.sock`, or `127.0.0.1:2489` | "this machine" |
| `CLIPBOARD_BRIDGE_PORT` (default `2490`) | "the machine at the other end of the SSH tunnel" |

This is what retires `unknown_opcode_hint`, which exists in `pbcopy` only
because that pain was patched once, per-operation, after the fact. The
mechanism is now general and lives in one place.

Message shapes, in the client's voice:

- *Far side behind:* `pbcopy: the clipboard bridge on the machine at the other
  end of the SSH tunnel is behind — it speaks RECOB proto 1, this client
  speaks proto 2, and clip.set.files needs proto 2. Run chezmoi apply there.`
- *This side behind:* `pbcopy: this machine's clipboard bridge is ahead of this
  client (proto 2 vs 1) — run chezmoi apply here.`
- *Operation missing, versions equal:* the `caps` set is authoritative over the
  version integer. `unknown-op` carries the server's `impl`, so two builds
  sharing a `proto` are still distinguishable.

The clause "and `clip.set.files` needs proto 2" requires a fact the client
cannot derive from anything above, so the registry supplies it: **every
operation carries a `since` field naming the `proto` in which it first
appeared**, and the client reads the failing operation's `since` straight out
of its own registry. Every v1 operation has `since: 1`; the field only starts
carrying information at the first `proto` bump, which is exactly when the
diagnostic starts needing it. Without it an implementer would have to invent a
hardcoded operation-to-version map, and two implementers would invent different
ones. When `since` equals the server's `proto` or lower, the operation is
missing for some reason other than age, and the message drops the clause rather
than asserting something false.

### 7.2 Differing `proto` does not refuse the connection

Skew is normal, so a version difference alone never fails a connection. The
**operation** is the unit of compatibility: a request is refused only if its
name is absent from the server's `caps`, or if one of its fields is unknown to
the server. Both produce a named, actionable error. A client that has read the
server's `caps` may also decline to send an operation it can see is
unsupported, which improves the message but is not required. Note which frame
that means: `caps` arrives in the capabilities `C` frame *after* authentication
([§5.1](#51-hello-fields)), not in the banner, so on the public endpoint the
pre-flight check is available for the second and later exchanges of a
connection and the first is diagnosed by `unknown-op`. On the trusted socket,
where the client pipelines everything at once, it is always post-hoc.

### 7.3 Meeting a pre-RECOB peer

Both directions must produce a diagnostic rather than a hang or a bare exit
code, because this is precisely the failure the brief cites as already having
bitten.

**Old client → new listener.** The listener reads the first five bytes. If
they are not `RECOB`, the peer predates this protocol. The listener replies
with a frame in the *old* format — `E`, BE32 length, message — so the old
client's existing error path renders it, then closes:

> `this endpoint now speaks RECOB v1; the client that called it is behind —
> run chezmoi apply on the machine you are calling from`

This is a diagnostic shim, not compatibility: it serves no operation and it is
deleted once both machines have been applied. `pbcopy` prints such a message
verbatim today. `clipbridge::send` and nvim's `frame_request` only inspect the
status byte and will lose the text — an accepted gap, documented rather than
engineered around, because `pbcopy` is the loud path and the condition is
transient.

**New client → old listener.** The client writes `RECOB\x01`; the old
dispatcher reads `R` as an opcode and `ECOB` as a length of 1,162,039,106
bytes, then waits out its own 5-second read timeout and exits without
answering. The client's 500 ms preamble timeout fires first. **No `RECOB`
preamble within the timeout, or EOF before six bytes, means the far endpoint
predates this protocol** — the client says so, naming the side per §7.1, and
does not retry.

The old dispatcher's `LEGACY_GRACE_S` bare-connect fallback (an even older
client that connects and sends nothing, answered with an unframed `pbpaste`
dump) is **deleted**. It predates Phase 5, nothing in the tree still produces
that shape, and the preamble sniff gives a bare connect a real diagnostic
instead.

---

## 8. Client contract

Today one wire format has three independent implementations, each with its own
timeout, retry and reply-checking semantics. That is why `pbcopy` delivered
plain text over OSC 52 for a long time while nvim's provider had been using the
bridge for the same job.

This specification defines **one client contract** with **one shared codec**.
`pbcopy` and `pbpaste` become Rust binaries built from the daemon's own codec
crate ([D2](#d2-what-language-are-pbcopy-and-pbpaste-written-in), decided), so
the wire format has exactly one implementation rather than three
interpretations of one document. The Lua client in nvim remains a second
implementation and is the reason [§11](#11-the-observation-seam) tests the
contract at the wire rather than in a shared library — a rule that only one
implementation obeys is a rule that has not been tested.

**The clients must not link AppKit.** Measured, it costs 2.6 ms of dynamic
linking, against a total client-side saving of ~3.9 ms ([§1.2](#12-what-a-compiled-client-is-actually-worth)).
A client has no reason to touch the pasteboard — that is the daemon's job — so
this costs nothing to obey and is worth a build-level assertion, because a
shared crate can pull the framework in without anyone noticing until someone
re-measures.

Every client, in any language, must:

1. Write the preamble immediately on connect. On the trusted socket, write the
   hello and first requests immediately too; on the public endpoint, wait for
   the banner's `nonce`, then write the hello, pipelining behind it only the
   four payload-free requests of [§9.2](#92-connection-authentication).
2. Enforce the §5.2 timeouts, including the short preamble timeout, and back
   off on `busy` per [§3.5](#35-pre-authentication-limits) before giving up.
   **Never send the token itself** — only the challenge response
   ([§9.2](#92-connection-authentication)).
3. Treat the `code` field of an `E` frame as the contract and the `message`
   field as human text. **No client may branch on message text.** Today
   `pbpaste` greps for the exact strings `not-files`, `unknown opcode` and
   `is-directory`. The first two become codes; the third stops being an error
   at all, since `files.fetch` declares `kind` in its response and the retry it
   triggered no longer exists.
4. Reuse one connection for consecutive operations to the same endpoint (P2).
5. Render the §7.1 diagnostic, naming the side, from the endpoint it dialed.
6. On the public endpoint, verify the server's `proof` before sending any
   request carrying user data and before parsing any response; treat an `R` or
   `D` that arrives ahead of `proof` as a protocol error and close. The two
   frames exempt from that rule are the banner `H` and the capabilities `C`
   that carries the proof, plus a renderable-but-unactionable `E`
   ([§9.2](#92-connection-authentication)). Nothing else in `C` — `caps`,
   `impl`, `endpoint` — may drive a decision until `proof` verifies; an
   unverified peer's inventory is a claim, not a fact.
7. Never send an operation absent from the server's `caps`, once `caps` has
   arrived. Because `caps` now follows authentication ([§5.1](#51-hello-fields))
   and requests are pipelined ahead of it, this is a check on the *second and
   later* exchanges of a connection; the first is covered by `unknown-op`,
   which carries everything the diagnostic needs.
8. **Never treat a reachable-but-unsatisfied bridge as an absent one.** A
   client may fall back to a less trusted delivery path only when the connect
   itself was refused; a connect that succeeds, times out or is reset means
   something is listening, and the operation must fail loudly
   ([§5.2](#52-timeouts)). This binds `pbcopy`'s OSC 52 path specifically, and
   it is the difference between authentication being a control and being a
   suggestion.

The Rust clients spawn nothing: no `nc`, no `shasum`, no `sqlite3`. The Lua
client keeps its libuv implementation, which already frames correctly, and
gains the preamble, the hello, the challenge response and the code-based error
handling. Its SHA256 comes from `vim.fn.sha256()`, which is built in and
verified — `vim.fn.sha256("abc")` returns `ba7816bf…20015ad` — rather than from
a subprocess. nvim's provider sits on the interactive paste path, so a spawned
digest there would reintroduce exactly the cost §9.2 exists to avoid.

---

## 9. Authorization

### 9.1 Tiers

| Tier | Held by |
| --- | --- |
| `authed` | a connection that presented a valid credential, or arrived on the trusted socket |
| `local` | a connection on the trusted Unix socket only |

`local` implies `authed`. Orthogonal to both, an operation may require a
**grant**: a bearer token issued by `files.grant`, scoped to one clip id and
its path set, idle- and hard-expiring as today.

There is deliberately no "anyone who can open the port" tier. The public
endpoint requires a credential at the connection level
([D1](#d1-does-the-public-endpoint-require-authentication), decided), before any
operation is parsed — which is stronger than a per-operation check and cannot
be defeated by forgetting a table entry.

### 9.2 Connection authentication

The credential is a 32-byte random value, hex-encoded. The client sends it as
the `auth` field of its hello — **never the token itself, but a response to a
challenge**, for the reason worked out below. On mismatch or absence the
endpoint answers `E{code=unauthorized}` and closes without dispatching
anything. The trusted Unix socket requires no credential — its uid boundary is
the credential.

#### Keyed by the owning machine, not by the tunnel

**Tokens are stored one file per owning machine**, on both ends:

| Side | Path | Mode |
| --- | --- | --- |
| the machine that owns the endpoint | `$XDG_STATE_HOME/clipboard/accepted-token` | 0600, dir 0700 |
| every remote it has pushed to | `$XDG_STATE_HOME/clipboard/tunnel-tokens/<owner-host>` | 0600, dir 0700 |

This addresses a failure that a single `tunnel-token` file does not survive.
The deployment is symmetric — §23.3 notes either Mac can be origin or sit-at —
so two different machines can push to one remote, and with one flat file the
second push silently invalidates the first. Worse, the two are not
symmetrically constrained: only one `RemoteForward` can bind loopback 2490 on
the remote, so machine B's push can land while machine A's tunnel is the one
actually live, leaving a token that matches nobody. Keying the file by the
owner's host name removes the collision entirely; a losing push writes a
different file and sits unused.

`<owner-host>` is `clip::self_host`'s value, which already has a defined shape
rule (`[A-Za-z0-9][A-Za-z0-9.-]*`) and is already validated defensively at
every read site. The client re-validates it before using it as a path
component.

#### The token must never be sent, and the round trip is not optional

An earlier draft had the client send the token itself, and — when
`tunnel-tokens/` held exactly one file — send it immediately without waiting
for the server's banner, to avoid a round trip. **Both halves of that are
wrong, and the second is a credential-theft vector.**

Port 2490 on the remote is ordinary unprivileged loopback. It is bound by
whichever process gets there first, and it is only *usually* the SSH
`RemoteForward`. Any other user on that shared host can bind it whenever no
tunnel is active — after a disconnect, before the first connect of the day, or
by racing a reconnect. A client that sends its token to whatever answers hands
the secret to that process on the first copy after the window opens. The
attacker then holds a valid credential for the real bridge.

The obvious repair — read the banner first and check its `host` — **does not
work**, and it is worth stating why so that nobody re-proposes it: the banner
is unauthenticated. A fake listener claims whatever `host` gets the client to
send the matching token. Verifying an assertion made by the party you are
trying to authenticate is not authentication.

So the token stops crossing the wire:

1. The server's banner carries a fresh 32-byte random `nonce`, generated per
   connection.
2. The client answers `auth = SHA256(token || ":c:" || nonce)`, hex-encoded.
3. The server recomputes it from its own `accepted-token` and compares.

The `":c:"` separator marks this as the *client's* direction. It matters once
the server has to prove itself too, which the next subsection establishes; the
canonical statement of both digests is the table there.

**Both nonces are 32 bytes from the operating system CSPRNG, drawn per
connection.** In a native daemon that is one call and the obvious
implementation is the correct one, so the requirement is stated and the test
retained rather than argued for at length.

It is retained rather than dropped because the reason it was written is worth
keeping visible. Under the persistent *zsh* listener this was the difference
between the scheme working and not working at all: a forked zsh child inherits
its parent's `$RANDOM` state, so every handler forked from one warm listener
draws the same sequence. Measured at the time:

```
$ zsh -fc 'for i in 1 2 3 4; do ( print -r -- "child$i: $RANDOM $RANDOM" ) & done; wait'
child1: 30817 24160
child2: 30817 24160
child3: 30817 24160
child4: 30817 24160
```

Every connection would have been challenged with an identical nonce, making the
response a static password. The hazard is gone with the fork, but **§11.4 still
requires a test that many concurrent connections receive pairwise distinct
nonces**, because a seeded-once generator reintroduces it in any language and
the failure looks like nothing at all until someone is reading the wire.

Nonces are single-use: the daemon challenges once and the connection either
authenticates or closes, so there is no reuse window to track and no replay
cache to maintain. `cnonce` is under the identical rule — a repeating client
nonce lets a squatter who once observed a genuine `proof` replay it to
impersonate the bridge — and the distinctness test of
[§11.4](#114-new-coverage-the-specification-requires) covers both.

A fake listener now learns one digest bound to a nonce it chose itself. It
cannot replay that against the real bridge, which issues a different nonce, and
it cannot recover the token from the digest. The client no longer needs to know
which machine it is talking to *before* proving anything, which is what lets
the unauthenticated banner stop being load-bearing.

#### The server must prove itself too, or the payload leaks instead of the token

Protecting the token is not sufficient, and the reason is worth being blunt
about: **what an attacker actually wants is the clipboard content, and a
one-directional credential hands it straight over.** The squatting listener
above fails to authenticate the client — and then simply reads the `clip.set`
frame the client already sent it. The round-3 rules made that worse rather than
better: §5.2 forbids falling back once the connect succeeds, so the victim is
committed to this connection, and §5 had the client pipeline its requests
alongside its hello. The token stayed secret and the text did not. Guarding the
credential while streaming the plaintext past it is worse than useless, because
it looks like protection.

So authentication is **mutual** — one extra field in each direction, no extra
frames:

| Step | Frame | Adds |
| --- | --- | --- |
| 1 | server banner | `nonce`, the server's challenge |
| 2 | client hello | `cnonce`, the client's challenge, and `auth = SHA256(token \|\| ":c:" \|\| nonce)` |
| 3 | server capabilities | `proof = SHA256(token \|\| ":s:" \|\| cnonce)` |

The client verifies `proof` before sending anything carrying user data, and
closes on mismatch with a diagnostic naming the endpoint as untrusted. The two
domain separators `":c:"` and `":s:"` are what defeat reflection: a listener
that echoes the client's own digest back cannot satisfy step 3, because the
hashed string differs in a position it cannot influence.

**Requests are then split by whether they carry anything worth stealing.**
Before `proof` arrives a client may pipeline only these four, whose request
bodies are empty or trivial:

`host.identity`, `clip.get`, `files.list`, `window.fullscreen.state`

Everything else — every `clip.set*`, both `store.persist.*`, `osd.notify`, and
`files.fetch` with its grant token — waits. This keeps the **paste** path at
the cost it had before mutual authentication existed and moves only the
**copy** path, which is the one with something to lose. A fake listener that
receives a pipelined `clip.get` learns **no clipboard content and no paths** —
the request body is empty, the response flows the other way, and a client
discards any response from a peer that never proved itself. What it does learn
is that a paste was attempted, and which of the four was asked; intent is
visible even when data is not. On a shared host that is worth stating rather
than rounding down to "nothing."

**Response frames arriving before `proof` are a protocol error, not merely
untrusted.** On the public endpoint the only frames a client parses before
verifying `proof` are the banner `H` and the capabilities `C` that carries the
proof itself. Any `R` or `D` arriving first means the peer is answering
requests it never earned the right to answer: the client closes and reports an
untrusted endpoint without parsing the body. The weaker rule — read
everything, verify later — invites an implementation that parses a hostile
payload before the check, which is the class of bug the verification exists to
prevent.

`E` is the one exception, and it is narrow. A server that rejects the
credential answers `E{code=unauthorized}` and closes, so it never sends a `C` —
under a blanket rule the client could not read the one message that tells the
human what went wrong, and a stale token would surface as an unexplained
disconnect. So a client **may render** a pre-`proof` `E`, and **may not act on
it** beyond that: the message is displayed as coming from an unverified
endpoint, no fallback is unlocked by it ([§5.2](#52-timeouts) keys on the
connect result, not on any frame), and no field of it is trusted for anything
else. A squatter can forge a misleading error; a squatter cannot use one to
extract data or force a downgrade, which is the boundary that matters.

The cost is one further round trip on the copy path only, and it is not
optimizable away — the client cannot know the peer is genuine before the peer
has answered a challenge the client chose. [§6.3](#63-frames-and-connections-per-user-action)
carries the corrected numbers.

**When the client holds several tokens** — the multi-owner remote of the
previous subsection — it sends a response for each, as a **NUL-joined list in
the single `auth` field**, ordered newest file first. Spelling that out matters
because the obvious alternative encodings are both illegal or broken here:
repeating the `auth` field is a `bad-field` protocol error under
[§4.3](#43-bodies-named-fields), and reconnecting once per token turns a
credential check into N connections against a listener that rate-limits
connections. The list is capped at **8** entries; beyond that the client sends
the 8 newest and the rest are unreachable until rotation.

The server authenticates the connection **iff any entry equals its own
recomputed digest**. Every comparison is constant-time and every entry is
compared — no short-circuit on the first match, so the reply time does not vary
with the position of the matching token, which correlates with which machine
the client thinks it is talking to. Failure discloses nothing either way: one
`unauthorized` with `reason=bad-credential`, regardless of how many entries
were offered or how close any came.

Constant-time comparison is a requirement here rather than an aspiration, which
it could not have been under a shell implementation: `[[ $a == $b ]]` gives no
such guarantee and there is no primitive in zsh that does. In the daemon it is
one dependency and a 167 ns call, measured.

Plain SHA256 over the concatenation is sufficient and HMAC is not required. The
length-extension weakness of a naive prefix construction needs an attacker who
controls the message and profits from extending it; here the message is a nonce
the *verifier* chose, and a digest over an extension of it matches no nonce the
server will ever issue.

**The digest is computed in-process, and this is what makes the handshake
affordable at all.** An earlier draft reused `clip::sha256`, which resolves to
`shasum` on macOS — a Perl script, measured at **14.82 ms per spawn**. Two
digests per side is ~30 ms added to every authenticated connection, against the
~50 ms the redesign was saving; the authentication would have consumed the
performance win and then some. In-process the same digest is **0.000282 ms**.
The scheme is unchanged; only its cost is, and the cost was the thing that made
it questionable.

**One round trip remains, and that is accepted.** The client must have the
nonce before it can answer, so hello can no longer be pipelined blind on the
public endpoint. Against the ~145 ms of per-connection process startup this
design removes, and the connections [§6.3](#63-frames-and-connections-per-user-action)
eliminates outright, one added round trip on a *single* connection per user
action is affordable. Two things keep it contained:

- **The trusted Unix socket is unaffected.** It needs no credential, so local
  operations — including the backgrounded `store.persist.text` — still pipeline
  with zero waiting.
- **It is per connection, not per exchange.** P2's whole point is that one
  connection now carries a user action's worth of work.

The benchmark harness ([§12](#12-benchmark-harness)) must therefore measure the
authenticated public endpoint, not just the trusted socket, or it will report a
win the user does not experience.

#### Distribution, with the mode fixed

Distribution reuses `ssh-prepare-connection`'s `step_mount`, which already
pushes `self-name` to the remote at connect time. **The existing pattern is
`mkdir -p "$d" && cat > "$d/self-name"` with no `chmod`
(`executable_ssh-prepare-connection:168`), so the file lands at whatever umask
the remote login shell has.** That is adequate for a hostname and completely
inadequate for a secret. The token push must therefore be explicit rather than
copied:

```
umask 077; mkdir -p "$d/tunnel-tokens" && chmod 700 "$d/tunnel-tokens" &&
cat > "$d/tunnel-tokens/<owner-host>" && chmod 600 "$d/tunnel-tokens/<owner-host>"
```

The mode is set by `umask` *before* the write and re-asserted after, so there
is no window in which the token exists at a permissive mode.

#### Validation on read

The token gets the same defensive treatment `self-name` already gets at
`clip::self_host` (`clipboard-store-core.zsh:187-198`) and in `pbcopy`'s
`self_host` — this file sits on a shared box and can be stale, truncated,
hand-edited or garbage. Before use, on both ends: exactly 64 characters, all
`[0-9a-f]`, single line, no trailing content, and the file's mode must not
grant group or other any bits. A file failing any check is treated as absent
and reported as such, never partially matched.

#### Bootstrap

`accepted-token` is created by the listener at startup when it is absent or
fails validation: 32 bytes from `/dev/urandom`, hex-encoded, written with
`umask 077` to the 0700 state directory. There is no separate provisioning
step, no user action, and no state in which the listener is running without a
credential to check against — an endpoint that cannot load or create one
refuses to start rather than serving unauthenticated, per P6.

A remote acquires its copy on the next `ssh-prepare-connection` run, which is
every connection. So the bootstrap sequence for a brand-new remote is: connect,
push lands, works from then on — with the first-connection race of the
consequences below.

#### Rotation, and why not per-connection

A token is regenerated when the owner rotates it — on demand, or when an
existing file fails validation. Rotation overwrites `accepted-token` and the
next connect pushes the new value. A remote still holding only the old one gets
`unauthorized` with `reason=bad-credential`; because the response is computed
per token held and the stale file is replaced on the next connect, this
self-heals on reconnect rather than needing a protocol affordance.

Generating a *fresh* token on every outbound connection was considered and
rejected. It reintroduces on every connect exactly the push race described
below, for no security gain: the control that actually protects the secret is
the 0600 file's uid boundary, not the secret's age — and now also the fact that
the secret never leaves the machine at all. Rotation on demand gets the same
isolation, without making every connection racy.

#### Two honest consequences

- **The push is backgrounded and fail-soft, and the token is a hard
  dependency.** A bridge operation issued in the seconds between connecting to
  a brand-new remote and the push landing will fail. This is survivable only
  because the token is long-lived and per-owner: once written it is reused
  across every later connection, so only a first-ever connect or a rotation can
  race, and the failure is a clean `unauthorized` naming the fix. Making the
  push synchronous is rejected — `step_mount`'s comment is explicit that the
  connection must never wait. **This is a real availability regression against
  today's unauthenticated bridge and is accepted deliberately.**

On a shared multi-user development host this closes the actual hole: a
mode-0600 file is protected by the same uid boundary the trusted socket relies
on, so "whoever can open a loopback socket" stops being the trust model.

### 9.3 Per-operation policy fields

The policy is one table, declared once, in the source the daemon dispatches
from and the test reads. P7's guarantee is that there is exactly one place
where an operation's authorization is stated, and a policy the test re-declares
in its own fixture would satisfy every assertion while protecting nothing —
so the enforcement test of [§9.4](#94-the-enforcement-test) reads the same
table the dispatcher does, and the operation registry is derived from that
table rather than maintained beside it. Each entry declares:

| Field | Meaning |
| --- | --- |
| `tier` | `authed` or `local` |
| `grant` | whether a valid `files.grant` token is required |
| `rate` | rate-limit bucket, or none |
| `effect` | descriptive: `read`, `write`, `store`, `fs-read`, `gui` |
| `uti_allow` | for `clip.set.rich` only: the permitted UTI set per endpoint |
| `mints_authority` | for `store.persist.files` only: the tier at which the row may confer file authority rather than being a pointer |
| `since` | the `proto` in which the operation first appeared, for §7.1's diagnostic. **Every v1 operation is `since: 1`**; the column is omitted from the table below for that reason and becomes load-bearing at the first `proto` bump |

Proposed v1 policy:

| Operation | tier | grant | rate | effect |
| --- | --- | --- | --- | --- |
| `host.identity` | authed | — | — | read |
| `clip.get` | authed | — | — | read |
| `clip.set` | authed | — | — | write |
| `clip.set.rich` | authed | — | — | write |
| `clip.set.files` | **local** | — | — | write |
| `clip.restore` | **local** | — | — | write |
| `store.persist.text` | authed | — | `store` | store |
| `store.persist.files` | authed | — | `store` | store |
| `files.list` | authed | — | — | read |
| `files.grant` | authed | — | — | fs-read |
| `files.fetch` | authed | **yes** | — | fs-read |
| `osd.notify` | authed | — | `osd` | gui |
| `window.fullscreen.toggle` | authed | — | `window` | gui |
| `window.fullscreen.state` | authed | — | — | read |

Two entries preserve today's behavior as *data* rather than as branches in the
dispatch `case`. The brief asks for the authorization table **as data**, so the
values are given here rather than described — a prose reference to "the
seven-UTI allow-list" would leave the table incomplete and the enforcement test
unable to generate anything.

**`clip.set.rich.uti_allow`**, lifted from the `case` at
`executable_clipboard-bridge-dispatch:216-217`:

| Endpoint | Allowed |
| --- | --- |
| `trusted` | any UTI |
| `public` | `public.png`, `public.jpeg`, `public.tiff`, `public.utf8-plain-text`, `com.adobe.pdf`, `com.compuserve.gif`, `org.webmproject.webp` |

A `uti` outside the endpoint's set is `refused`. The `trusted`/`public` split is
itself the point: the trusted socket is same-uid local, so an arbitrary UTI is
the caller's own business, while the public endpoint is reachable from every
host the user connects to.

**`store.persist.files.mints_authority: local`** keeps the split where a
trusted call may authorize self-host paths while a public one produces a
pointer row that cannot mint file authority. It is evaluated against the
endpoint, never against the caller-supplied `host`
([§9.7](#97-findings-this-does-not-close)).

### 9.4 The enforcement test

Required deliverable 3. Four assertions, all generated from the tables rather
than written per-operation. Assertions 1, 2 and 4 are pure table properties and
belong in the daemon's own test suite, where the compiler can additionally make
the first one structural — an operation enum whose match arms include the
policy lookup cannot acquire a member with no entry. Assertion 3 drives real
connections and belongs in the spec suite:

1. **Every dispatchable operation has a policy entry.** Enumerate the
   dispatcher's operation → handler map; fail naming any operation absent from
   the policy table. This is the test the brief asks for: it makes "ungated" a
   deliberate, reviewable choice instead of an omission.
2. **Every policy entry names a real operation.** Catches an entry left behind
   by a rename.
3. **Each declared requirement is actually enforced.** For every `local`
   operation, a connection on the public endpoint receives `unauthorized`. For
   every `grant` operation, a request without a valid token receives
   `unauthorized`. Generated by iterating the table, so a new operation is
   covered the moment it has an entry.
4. **Every entry declares a `since` no greater than the current `proto`.** This
   is what keeps §7.1's diagnostic from asserting that an operation "needs
   proto 3" on a build that only speaks 2, and it catches the likeliest
   mistake at the next version bump: adding an operation and forgetting to
   stamp it.

### 9.5 Rate limiting

`osd.notify` and `window.fullscreen.toggle` are annoyance vectors and nothing
throttles them today. Buckets:

| Bucket | Limit |
| --- | --- |
| `osd` | 20 per 10 s |
| `window` | 5 per 10 s |
| `store` | 120 per 10 s |

Exceeding a bucket answers `E{code=rate-limited, retry_after=<seconds>}`.

The `store` bucket covers `store.persist.text` and `store.persist.files`, and
exists for a different reason than the other two. Those throttle annoyance;
this one throttles *growth*. An authenticated peer can otherwise drive
unbounded inserts, and while the `MAX_ROWS` sweep bounds the table, it bounds it
by **evicting the human's real clipboard history** — the flood costs the
attacker nothing and costs the user everything they had saved. The limit sits
far above any plausible human rate, so it is invisible in normal use.

The counters live in memory, behind a mutex, and are exact. Revision 1 had to
specify an approximate counter in a state file with a bounded `flock`, because
forked handlers cannot update parent state and keeping the count in the parent
would have meant reading and dispatching each request before forking —
serializing the listener. That whole apparatus, and the lost-increment and
corrupt-file failure modes it brought with it, exists only in a design with a
process per connection. One process counting its own connections needs none of
it.

The buckets are per endpoint. A flood arriving over the tunnel must not be able
to throttle the human's own local operations on the trusted socket, which is
what a single global bucket would allow — an attacker who cannot read the
clipboard could still make the sit-at machine's own copies fail. Rate limiting
that becomes a denial-of-service lever is worse than none.

Counters reset on daemon restart. That is a real, accepted gap — a peer that
can crash the daemon can clear its throttle — and it is bounded by the fact
that the daemon restarting is itself the more visible event.

### 9.6 Configurable exposure

P9 makes delegation deliberate, which immediately raises the question of how
much of it the operator should be able to configure. The useful distinction is
not per-feature but by what the configuration *changes*:

| Kind | Effect | Verdict |
| --- | --- | --- |
| **Subtractive** — narrow which operations an endpoint answers | can only make something stop working | **safe, and specified below** |
| **Backend substitution** — change how a fixed capability is served | grants the network nothing new, provided the capability's contract is unchanged | safe; already practised, see below |
| **Additive** — define new things the network can cause | widens the blast radius of a leaked credential | **refused** |

**Subtractive configuration is the one v1 gets.** A local file may declare that
this machine does not answer a given operation on a given endpoint, and the
check sits in the same call site as the §9.3 policy lookup, evaluated *after*
it — so disabling can only ever remove a capability the table already granted,
never restore one it denied. Refusal is `E{code=unauthorized,
reason=not-exposed}`, distinct from `bad-credential` so an operator can tell
"this machine does not offer that" from "your token is wrong" without the
error disclosing anything an unauthenticated peer could use.

**Local exposure does not filter `caps`.** The advertised set stays what §5.1
defines it as — the operations *this build* can dispatch — because §7.1 makes
`caps` authoritative for "operation missing at equal versions", and a set that
also encoded local policy would render that diagnostic a lie: a deliberately
withdrawn operation would be indistinguishable from an older build, and the
client would tell the operator to run `chezmoi apply` on a machine that is
perfectly up to date. The cost of keeping `caps` a pure build signal is one
wasted round trip when a client invokes a withdrawn operation, answered by
`not-exposed`, which says precisely what happened. That is the right trade:
`caps` exists to answer a version question, and it can only answer it if
nothing else is folded into it.

**Backend substitution already exists and is simply not named.** Today
`MUX_TOGGLE_FULLSCREEN_BIN`, `MUX_FULLSCREEN_PROBE` and `CLIPBOARD_MOUNT_BIN`
are overridable paths to the programs that fulfil an operation. That remains
legitimate under P9 because the *capability* is fixed — the wire cannot reach
these values, and substituting one does not let a peer ask for anything it
could not ask for before. The requirement it does carry: a substituted backend
is still bound by the operation's declared contract and by its policy entry.

**Additive configuration is refused, and not because it is unthinkable.** A
config-file mapping from operation to command is meaningfully safer than P5's
original sin, since the file is uid-protected and the wire cannot write it. The
reason to refuse it is what it does to the value of a stolen token: today that
buys clipboard access and the ability to raise toasts, which is bad and
bounded. With an operation-to-command map it buys arbitrary execution on the
machine the human is sitting at. That is a different system with a different
threat model. P8 refuses it on the narrower ground that matters here: the
reach of such an operation is named by the caller, so no amount of local
configuration bounds it.

**The clipboard is not configurable, and it needs no special case to say so.**
After the watcher absorption it has no backend — the daemon is the
implementation ([§14](#14-the-macos-integration-surface)). There is nothing to
substitute. It can still be *disabled* like anything else, which is the correct
amount of control to offer over it.

### 9.7 Findings this does not close

Stated plainly rather than left implied:

- **`clip.get` and `files.list` remain exfiltration paths for an authenticated
  caller.** Authentication narrows "anyone on the box" to "anyone holding the
  token"; it does not make a clipboard read safe. The mitigation would be
  making them `local`, which would break remote nvim paste — the feature the
  bridge exists for.
- **A port squatter can deny both transports.** Loopback 2490 on the remote is
  unprivileged, so during any window with no active `RemoteForward` another
  user can bind it. Mutual authentication means the client detects the
  impostor and refuses to send anything; §5.2 means it does not fall back to
  OSC 52 either, because the connect succeeded. The copy therefore fails
  outright until the tunnel is re-established. That is a real availability
  regression against today's behavior, and it is the deliberate counterpart of
  refusing to be downgraded: the same attacker previously harvested the
  clipboard content instead, silently. Denial is loud, bounded and
  recoverable; disclosure is none of those.
- **`clip.set` remains an injection path** for an authenticated caller.
  Poisoning a clipboard a human later pastes into a shell prompt is code
  execution with extra steps, and no protocol change fixes it.
- **Provenance is asserted, not proven.** `origin_host` on `clip.set`, and
  `host` on the two `store.persist.*` operations, are values the caller
  supplies. An authenticated peer can claim to be any machine, and the store row
  and the picker's "from ⟨host⟩" label will agree with it. This is exactly
  today's property — `O` and `P` take the host from the payload as well — and it
  is not a regression, but writing `origin_host` into the specification as a
  provenance mechanism makes it worth naming: it is a *label*, useful because
  the peers are cooperating, and it carries no authority. The one place it must
  not be treated as a label is `store.persist.files`, where a row claiming
  `host` equal to this machine would confer local file authority; that is why
  `mints_authority: local` exists in §9.3, and it is enforced against the
  *endpoint*, never against the claimed host. Validation of the value's shape
  (`clip::valid_host`) is required everywhere regardless, since it reaches SQL
  and path construction.
- **§6.2's handler-written row does not make that worse, with one exception.**
  A reviewer read the suppressed capture as an escalation — the watcher can no
  longer correct a forged `origin_host`. It never could: `clip::op_declare_origin`
  takes the host straight from `O`'s payload today, and the watcher copies it
  through. The forgery surface is identical. The exception is `app`: today the
  watcher derives `source_app` from the frontmost application, and under §6.2 a
  suppressed capture means it arrives from the wire instead. A peer can label a
  row with any application name. It is a display string in the picker with no
  authority attached, so it is accepted — but it is newly attacker-controlled
  where it previously was not, which is exactly the kind of quiet change a
  clean-slate rewrite is prone to smuggling in unremarked.
- **Two tiers will not scale as capabilities grow.** `authed` and `local` mean
  every tunnel-reachable operation becomes reachable the instant a token
  validates: there is no gradation between "read the clipboard" and "toggle a
  window", and a leaked credential yields the whole `authed` set at once. That
  is proportionate to today's inventory, where the worst `authed` operation is
  an unwanted toast, and it is why v1 ships two tiers rather than a consent
  model nobody needs yet. It stops being proportionate the moment an operation
  lands whose misuse the human would actually mind, and the model for what to
  do then already exists in this document: `grant`, the bearer-token tier the
  file operations use, which scopes authority to one resource for a bounded
  time. **The trigger to revisit is a new `authed` operation whose worst-case
  misuse is worse than annoyance** — P8's bounded-reach test is what keeps that
  day distant, since an operation whose reach is fixed locally has a smaller
  worst case than its name suggests, and [§9.6](#96-configurable-exposure)'s
  subtractive control is the interim lever, since an operator can withdraw an
  operation from an endpoint without waiting for a finer model.

---

## 10. Error taxonomy

An `E` frame carries `code` (required, stable, machine-readable), `message`
(required, human, free-form and explicitly **not** a contract), and
operation-specific detail fields.

| Code | Meaning | Connection |
| --- | --- | --- |
| `wire-version-mismatch` | preamble `wire_version` differs | closed |
| `unauthorized` | missing or bad credential; tier, grant or local exposure not satisfied. Carries `reason`: `no-credential`, `bad-credential`, `tier`, `no-grant`, `not-exposed` | closed for credential failures, open for tier/grant/exposure |
| `unknown-op` | operation name absent from `caps`; carries `op`, `proto`, `impl` | open |
| `unknown-field` | field name unrecognized; carries `field` | open |
| `missing-field` | required field absent; carries `field` | open |
| `bad-field` | field failed §6.6 validation; carries `field` | open |
| `bad-request` | structurally malformed, or a mutually exclusive field pair violated | open |
| `not-found` | nothing to answer with; carries `reason` (`empty-store`, `not-files`, `no-grant`, `no-row`) | open |
| `refused` | policy refusal, e.g. a UTI outside the allow-list | open |
| `rate-limited` | bucket exhausted; carries `retry_after` | open |
| `busy` | pre-auth capacity limit reached ([§3.5](#35-pre-authentication-limits)); carries `retry_after` | closed |
| `too-large` | declared length above the §4.2 cap | closed |
| `file-too-large` | a named file, or a `clip.set.rich` blob, exceeds its operation's cap | open |
| `unreadable-entries` | a manifest entry cannot be read or traversed; carries `count` | open |
| `unavailable` | this machine cannot perform it (no OSD, no fullscreen toggle) | open |
| `internal` | handler failure | open |

Mapping from today's magic strings, all of which stop being strings clients
match on:

| Today | Becomes |
| --- | --- |
| `unknown opcode` | `unknown-op` |
| `is-directory` | removed — `files.fetch` declares `kind` |
| `not-files` | `not-found` + `reason=not-files` |
| `empty-store` | `not-found` + `reason=empty-store` |
| `capability-required; update pbpaste` | `unauthorized` |
| `trusted-endpoint-required` | `unauthorized` |
| `rich type not allowed on public endpoint` | `refused` |
| `no OSD on this host` | `unavailable` |
| `file-too-large` | `file-too-large` — kept as a code, with the offending size in a detail field |
| `unreadable-entries: <path>` | `unreadable-entries` + `count`, **without the path** |

The last row is a deliberate narrowing. Today the message interpolates the
unreadable path straight onto the wire (`clipboard-store-core.zsh:938-940`),
which hands a peer a filesystem probe: names outside anything it was granted,
disclosed one refusal at a time. The count is what a human needs to understand
the failure; the path goes to the local log instead. The same rule applies to
every code — **`message` never interpolates a filesystem path the peer did not
itself supply.**

---

## 11. The observation seam

138 examples across five spec files watch the wire through a fake `nc` on
`PATH` that records the frame a client tried to send and models a refusing
endpoint, an `E` reply and an `O` reply. Three more spec files
(`pbcopy_spec.sh`, `pbcopy-files_spec.sh`, `pbpaste-files_spec.sh`) stub `nc`
the same way for roughly another 107 examples. That seam works only because
the client shells out to a binary found on `PATH`. Under §8 it stops existing,
and the brief is explicit that a replacement transport must ship an equivalent
or the coverage silently stops testing anything.

### 11.1 A recording listener, not a fake client

The replacement is a **real listener that records**, not a fake transport:
`recobd --record`, the production binary in a recording mode, bound to a test
port or a test socket that the specs point the existing `CLIPBOARD_BRIDGE_PORT`
/ `CLIPBOARD_BRIDGE_LOCAL_SOCKET` overrides at.

A mode of the real binary, rather than a separate harness built from the same
parts. The distinction is the whole point of the seam: "built from the same
codec" is a claim that decays the first time someone edits one and not the
other, whereas a flag on the shipped binary cannot drift from itself. The cost
is a test-only code path in production code, which is real — it is bounded by
making `--record` do nothing but tee decoded exchanges to a log and consult a
reply script, changing no dispatch decision and no authorization check.

This is strictly stronger than what it replaces. The fake `nc` observes only
the bytes a client wrote and invents the reply; the recorder decodes the frame
with the production decoder, so a client that emits a subtly wrong frame fails
the test instead of being faithfully recorded as wrong. A test-only recording
hook *inside* the client was considered and rejected for the same reason the
brief gives: a seam inside the code under test drifts from the real path.

The Lua client is the reason this seam has to exist at all. If Rust were the
only implementation, most of what the recorder checks could be an in-process
test against the codec crate. nvim's provider is a second, independent
implementation of the same contract, so the contract has to be observable from
outside any one implementation — and the same recorder then serves both, which
is the arrangement that catches a divergence rather than documenting one.

| Variable | Purpose |
| --- | --- |
| `RECOB_RECORD_LOG` | append one line per decoded exchange |
| `RECOB_RECORD_SCRIPT` | scripted replies, one directive per exchange |
| `RECOB_RECORD_ENDPOINT` | `public` or `trusted`, so endpoint-dependent policy is testable |

Log line, a stable contract:

```
<endpoint>\t<op>\t<field>=<hex>\t<field>=<hex>…
```

Values are hex so NUL and binary payloads are exact and assertions are
unambiguous; the spec suite gets a `recob_field <n> <name>` helper that decodes
one, so assertions stay readable (`recob_field 1 text` → `hello`).

Reply directives: `ok <field>=<hex>…`, `err <code> <message>`, `stream <file>`,
`close` (disconnect mid-frame, to exercise truncation handling), and
`hello proto=<n>` (answer with a chosen version, which is how §7's skew
diagnostics get tested without two machines).

A "bridge is down" case needs no directive: point the client at a port where no
recorder is listening. Note that this must be a **closed** port rather than a
silent one, since §5.2 keys the fallback on `ECONNREFUSED`.

**Every public-endpoint spec now needs a credential fixture**, which the fake
`nc` never did. The recorder therefore ships a one-call setup that writes a
throwaway token into a sandboxed `$XDG_STATE_HOME/clipboard/`, points
`accepted-token` and `tunnel-tokens/<host>` at the same value, and answers the
mutual challenge correctly by default. Without it every converted spec would
have to hand-roll the handshake, and the first one to get it slightly wrong
would be "fixed" by weakening the assertion. The directives `no-proof` and
`bad-proof` exist to exercise the client's untrusted-endpoint path
deliberately, and `deny-auth` to exercise `unauthorized`.

### 11.2 Cost, and how it is kept down

A recorder is a process; 245 examples each starting and stopping one would add
real time. One recorder per spec file, started in `BeforeAll` and torn down in
`AfterAll`, with the log truncated per example, keeps it to one process per
file.

### 11.3 Which spec files change, and how much

| Spec file | Change |
| --- | --- |
| `notify_bridge_spec.sh` | fake `nc` → recorder; assertions move from US-split fields to `recob_field` |
| `pick-clipboard-files_spec.sh` | same; its `port:frame` log lines become recorder lines |
| `pick-clipboard-feedback_spec.sh` | setup only — it stubs `nc` but asserts nothing about the wire |
| `pbcopy_spec.sh`, `pbcopy-files_spec.sh`, `pbpaste-files_spec.sh` | same conversion |
| `mux_fullscreen_probe_spec.sh`, `terminal_toggle_fullscreen_spec.sh` | unaffected by the transport (they stub `clipbridge::*` through `MUX_LIB_DIR`, not `nc`), but affected by the `W` → `window.fullscreen.*` rename |
| `clipboard-bridge_spec.sh`, `clipboard-files-ops_spec.sh` | drive the dispatcher directly with prebuilt frames; the frames are rebuilt in the new format, the structure is unchanged |

The conversion is mechanical but it is not small, and it is the largest single
piece of work in the implementation phase. Every one of those examples must
pass before cutover ([§13](#13-rollout-and-cutover)).

### 11.4 New coverage the specification requires

Beyond the conversion:

- Byte-exactness: a payload containing NUL, and a payload larger than one
  `sysread` block, are distinct cases and both belong here.
- Trusted socket mode is 0600 and its parent directory 0700 (§3.3).
- Cached-state staleness: rewriting `self-name` changes the next connection's
  answer without restarting the daemon (§3.4). This is the one §3.4 hazard the
  native rewrite does not remove, so it is the one that keeps its test; zombie
  reaping and descriptor inheritance no longer arise.
- Skew: a `hello proto=` recorder directive produces each of §7.1's messages.
- A pre-RECOB peer in both directions (§7.3).
- Stream truncation is detected by the missing terminating empty `D` (§6.4).
- **Authentication, as a control rather than a field.** A connection with no
  credential, with a malformed one, and with one belonging to a different owner
  each get `unauthorized` and dispatch nothing. A token file at mode 0640 is
  rejected as if absent (§9.2).
- **The pre-auth banner discloses `proto`, `host` and `nonce` and nothing
  else** — an assertion over the frame's field set, so that a later addition of `caps` to
  the banner fails a test rather than passing review (§5.1).
- **No fallback on a completed connect.** `pbcopy` against a listener that
  answers `unauthorized`, `busy`, or nothing at all must fail loudly and must
  not emit an OSC 52 sequence; against a refused connect it still must (§5.2,
  §8 rule 8). This is the fail-open regression test and it is the most
  important one here. **It must be written for the Lua client too**, which has
  the identical fallback today (`universal.lua:288-296`, OSC 52 on any failed
  `frame_request` under SSH) and would otherwise reintroduce the downgrade for
  nvim while `pbcopy` stayed correct. §8 rule 8 binds every client; so does
  this test.
- **The client refuses an unproven server.** A recorder that authenticates the
  client but returns a wrong or absent `proof` must receive no `clip.set`, and
  the client must report an untrusted endpoint rather than a timeout (§9.2).
  Assert the clipboard text appears nowhere in the recorded stream — the leak
  this closes was of the payload, not the credential.
- **Pre-auth limits hold**: connections beyond the in-flight cap are refused
  at accept, a peer that stalls mid-hello is dropped at the 1 s deadline,
  and a pre-auth frame declaring more than 4 KiB is refused (§3.5).
- **Nonces are unique per connection, in both directions.** Open many
  connections concurrently against one warm listener and assert every `nonce`
  is pairwise distinct; do the same for `cnonce` across many client
  invocations. The forked-`$RANDOM` failure this was written for cannot occur
  in the daemon, but a generator seeded once at start reproduces it in any
  language, and it is invisible in every other test because authentication
  still *succeeds* when the nonce repeats.
- **A response before `proof` is refused.** A recorder that sends an `R` ahead
  of its capabilities `C` frame must cause the client to close and report an
  untrusted endpoint, with no evidence it parsed the body (§9.2).
- **A refused connection still writes `RECOB` + `busy`** before closing, and a
  client that receives it does **not** fall back to OSC 52 (§3.5). This is the
  regression test for the bypass the first revision introduced, where the
  pre-auth limits and the no-fallback rule combined into an authentication
  bypass; it pairs with the no-fallback test above and neither is sufficient
  alone.
- **The token never appears on the wire.** Record a full authenticated
  connection and assert the token's bytes appear nowhere in it; assert the same
  token produces a different `auth` value against a different `nonce`; assert a
  response captured from one nonce is rejected against another (§9.2).
- **One copy, one row.** A `clip.set` produces exactly one store row carrying
  the declared `origin_host`, and the daemon's own change observation adds no
  second row for the same write (§6.2). The inverse case matters as much: a
  *physical* copy of that same text afterwards must still be captured, since
  what is suppressed is one specific observed change and not the text. This
  test also guards §14.4 — with the Lua watcher still running it fails,
  which is the point, because that is the failure that otherwise ships silently.
- **`files.list` does not race the capture**: a files copy followed
  immediately by `files.list` resolves rather than returning `not-found`
  (§6.5). The assertion is unchanged from revision 1; only its cause is. It
  passed there because of a 0.3 s sleep and must pass here **without one**, so
  the test asserts the answer and forbids the delay.
- **Restore covers every clip kind** (§14.5): `clip.restore` on a text row, an
  image row, a local file row and a multi-representation row each reinstate the
  full stored set, and the row's `regtype` survives the round trip (§14.6).
  `plain_only` gets its own cases, one per branch: a markdown link for a file /
  directory / url / image row, `text_plain` for a text row, a derived plain
  form for a row that has only `public.html`, and **no** `regtype` reinstated
  in any of them.
- **Restore does not become a capture.** `clip.restore` writes the pasteboard,
  so the daemon observes its own change; assert the row count is unchanged and
  only `last_ts` moved. This is the §14.4 duplicate-row guard applied to the
  one operation that writes a clip the store already holds, and it is a
  different code path from `clip.set`.
- **Rate limits bite per endpoint** (§9.5): exhausting a bucket over the public
  endpoint returns `rate-limited` there while the same operation on the trusted
  socket still succeeds. The second half is the assertion that matters — a
  shared bucket would let a peer across the tunnel throttle the human's own
  local copies, turning a throttle into the denial-of-service lever it exists
  to prevent.
- **A withdrawn operation subtracts and nothing else** (§9.6): configure an
  operation off for one endpoint and assert three things — it answers
  `unauthorized{reason=not-exposed}` there, it still succeeds on the endpoint
  where it was not withdrawn, and the handler never ran. Then assert the two
  properties the mechanism's safety rests on: an operation the §9.3 table
  denies for an endpoint cannot be *enabled* by the exposure file, and the
  server's advertised `caps` is byte-identical with and without the file, so
  §7.1's "operation missing at equal versions" diagnostic cannot be triggered
  by local policy.

---

## 12. Benchmark harness

Required deliverable 2. Its purpose is not to discover the per-frame
attribution — the brief already did that — but to keep it honest as the design
changes and to prove the persistent-listener win rather than assume it.

`tests/bench/recob-bench.zsh`, driving hyperfine, encoding the brief's
`#how-to-measure` rules as behavior rather than as advice. It stays a shell
script: it drives binaries from outside and has no reason to be one.

- **Decompose and subtract.** Separate benchmarks for the client floor, one
  exchange, N exchanges on one connection, and a whole user action; the
  differences attribute the cost.
- **Never interleave.** Each arm runs to completion before the next starts.
  The harness refuses to accept an interleaved configuration, because the
  interleaved A/B is what produced the false null result of 132 vs 133 ms.
- **Both orders, one session.** Every A/B runs A-then-B and B-then-A and
  reports the pair. A single ordering is not a result — the same unchanged code
  measured 240.7 ms and 259.7 ms minutes apart.
- **Read-only by default.** `host.identity` exercises accept, dispatch and
  reply without touching the store. A benchmark that must write saves and
  restores the clipboard around itself and silences the OSD, so a 20-run
  benchmark does not mean 20 toasts and 20 history rows.
- **Probe code in a file, never inline.** Endpoint security can silently kill
  an inline one-liner that opens a socket — exit 0, no output, a few
  milliseconds, reading exactly like a shell bug. This was reproduced while
  writing this document: an inline `zsh -fc` probe returned empty in 14 ms,
  and the identical code in a file ran fine.

The arms it must support: today's socat/`Accept=yes` shape against `recobd`;
today's shell clients against the Rust ones; one connection with N exchanges
against N connections with one each; and a whole `copy-pwd`, on both machines.

**Two arms exist specifically to hold §1.1 and §1.2 honest**, because those are
the measurements that reversed the implementation language and a reversal
deserves to be falsifiable. The first compares a rich copy against today's
`hs`-per-operation path, where the predicted saving is the largest in the
design. The second compares an authenticated public-endpoint connection against
today's unauthenticated one, where the handshake's two digests per side are
predicted to cost ~0.0006 ms rather than the ~30 ms the shell path would have
paid. If either fails to reproduce, the language decision needs revisiting, not
explaining.

**The authenticated public endpoint is a required arm, not an optional one.**
§9.2's challenge-response costs a round trip that the trusted socket does not
pay, and the tunnel is where a round trip is expensive. A harness that measures
only the trusted socket would report a win the human never experiences on the
path this system exists to serve. Both endpoints, every arm.

---

## 13. Rollout and cutover

**"Keep the current implementation serving until the replacement passes" means
the replacement does not land until it is green — not that both run at once.**
Two listeners cannot bind port 2489 simultaneously, and a runtime dual-stack
would be exactly the backwards compatibility the mandate excludes. The gate is
the commit, not a feature flag.

Order:

1. The benchmark harness lands first, measuring the current implementation.
   Baseline numbers must exist before anything changes.
2. The daemon, the codec, the policy table, the clients, the recorder and the
   converted specs are developed together and land as one change.
3. That change may not land until the full existing suite passes — the
   ~245 converted examples plus `clipboard-bridge_spec.sh` and
   `clipboard-files-ops_spec.sh` — together with §11.4's new coverage.
4. `make test-all` once before the commit; three warnings in
   `quick_launch_menu_spec.sh` and four skips are pre-existing baseline.
5. Cut over with one `chezmoi apply` per machine.

**The build hook is part of the cutover, not a detail after it.** `recobd` and
the clients are built by a `run_onchange` hook fingerprinted on the source, the
pattern `run_onchange_after_55-build-pty-frame.sh.tmpl` already establishes:
build to `~/.local/libexec` and `~/.local/bin` via a Makefile, skip with a
warning when the toolchain is missing. Measured, that costs 11.4 s on a cold
build including bundled SQLite and 0.33 s on a source change.

Unlike `pty-frame`, **a missing toolchain here is not a graceful degradation.**
`pty-frame` falls back to a plainer picker; a missing `recobd` means no bridge
at all. The hook must therefore fail loudly rather than warn quietly, and the
machine is left running the old implementation until the build succeeds — which
is precisely why step 5 is one `chezmoi apply` per machine rather than a
simultaneous cutover, and why §7's skew diagnostics have to work.

### 13.1 What the human sees during the skew window

A machine is entirely on one protocol or the other the moment it is applied;
there is no intra-machine mixed state, because the listener definition and the
client library ship in the same change. Only cross-machine operations degrade,
from the first `chezmoi apply` until the second:

| Situation | Result |
| --- | --- |
| local operations on an applied machine | work immediately |
| new client → old peer listener | ~500 ms, then §7.3's message naming the far machine |
| old client → new peer listener | old-format `E`; today's `pbcopy` prints §7.3's message, the other current clients see a bare failure |
| `pbcopy` plain text over SSH, peer not yet applied | **fails loudly** with §7.3's message — *not* an OSC 52 fallback; see below |
| `pbcopy <path>` over SSH, peer not yet applied | local record succeeds, peer push warns — already best-effort today |
| nvim paste over the tunnel, peer not yet applied | falls back to the per-process cache, unchanged from today |

**Row 4 is the one place where rollout convenience and P6 genuinely conflict,
and P6 wins.** An earlier draft promised the OSC 52 fallback here on the
reasoning that an old listener never writes a `RECOB` preamble, so the client
sees "no bridge speaking this protocol" and may fall back. That reasoning does
not survive [§5.2](#52-timeouts) as now written: the old listener *accepts* the
connection, so the client observes a successful connect followed by a preamble
timeout — which is byte-for-byte what an attacker stalling a connection
produces. Any exception carved out for skew is an exception an attacker can
trigger at will, which is how a fail-open path becomes permanent.

So plain-text copy over an unapplied peer fails, with a message naming the
machine to run `chezmoi apply` on. The cost is bounded and self-inflicted: it
lasts from the first apply until the second, on machines the user controls,
with an actionable instruction. Trading a permanent downgrade vector for a
brief inconvenience during a migration the user is actively performing is the
right side of that trade, but it is a real cost and it belongs in
`docs/recob-migration.md` as the first thing an operator reads.

Row 6 remains a genuine fallback: nvim's per-process cache is local state, not
a less trusted transport, so nothing is disclosed by using it.

One case in the table is a genuine regression and is called out rather than
buried: **the first connection to an applied remote will fail if the token push
has not landed yet** ([§9.2](#92-connection-authentication)). It resolves on
reconnect, and the error says so.

### 13.2 Deliverable 4: the migration note

The brief's fourth deliverable is a migration/skew note, and it belongs to the
implementation phase rather than to this document. This section is the *design*
of the skew behavior — what the protocol guarantees and why. The deliverable is
`docs/recob-migration.md`, landing with the implementation, and it is
operator-facing rather than design-facing:

- the apply order across machines, and what to expect between the two applies;
- how to recognize each row of §13.1's table from the message alone;
- the token bootstrap: what to do on a remote that has never been pushed to,
  and how to force a rotation;
- how to verify a machine is on RECOB, and how to read the recorder's log when
  it is not;
- rollback: the single `git revert` plus `chezmoi apply` per machine, and the
  fact that rollback is all-or-nothing per machine for the same reason the
  cutover is.

Keeping it separate matters because its audience is a human at 2 a.m. whose
copy stopped working, not a reviewer deciding whether the design is sound.

---

## 14. The macOS integration surface

The wire is language-agnostic; this section is not. It exists because
absorbing the watcher ([§6.2](#62-the-four-collapses)) moves a body of
*behavior* into the daemon, and behavior that moves without being written down
is behavior that gets dropped.

### 14.1 What the daemon does natively

All of the following were verified on this machine from a plain binary — no
`NSApplication`, no run loop, no bundle, no Accessibility grant — because the
audit could not confirm from documentation alone whether a non-GUI process may
do them:

| Capability | Verified |
| --- | --- |
| atomic multi-UTI write (`hs.pasteboard.writeAllData` equivalent) | 4 UTIs in one change, `changeCount` delta 1 |
| `NSFilenamesPboardType` property-list write | `setPropertyList_forType` → true |
| byte-exact round trip including an embedded NUL | true |
| a private marker UTI surviving the write | true |
| property-list parse of the filenames blob | 2 entries, a literal `"` in a path preserved |
| `changeCount` on the general pasteboard | 649, read in 69 µs; 0.56 µs per poll thereafter |
| frontmost application name and bundle id | `"Ghostty"`, `com.mitchellh.ghostty` |

The atomicity result is load-bearing twice over. It is what makes
`clip.set.rich` and `clip.restore` possible at all — a clip is a *set* of
representations, and publishing them one at a time would leave the pasteboard
briefly holding a partial clip and would fire the daemon's own change
observation once per representation. And it is the specific thing the
maintained Go clipboard package cannot do — every write there clears the
pasteboard first — which is why [D6](#d6-implementation-language) settles on
Rust rather than the language this repo already builds two programs in.

The plist result retires a real defect rather than a theoretical one. Today the
filenames blob is decoded by `plutil -convert json` followed by hand-rolled
JSON string splitting in zsh, and the comment at
`clipboard-platform-macos.zsh:210-217` records the bug that produced: a path
ending in `"` came back mangled. `PropertyListSerialization` handles the case
the probe deliberately fed it.

### 14.2 Behaviors absorbed from the watcher

Each of these is a **requirement with a test**, not an implementation note. The
list is the audit's inventory of `clipboard-history.lua`'s capture path, and
the risk being managed is that a rewrite silently drops one:

| Behavior | Requirement |
| --- | --- |
| sensitive UTIs | refuse to capture `Concealed`, `Transient`, `AutoGenerated`, and the private untrusted-file-URL marker |
| password managers | refuse to capture when the frontmost application is on the deny-list — **a security control, and the reason Q7 above had to be probed before this section could be written** |
| empty and whitespace | refuse empty type sets, zero-byte payloads, whitespace-only text |
| image cap | skip any image representation above 5 MB |
| dedup | `type_hash` over the sorted `uti=blob` set; an existing unpinned row is updated, not duplicated |
| retention | 1000 rows and 200 MB of blobs, oldest unpinned dropped, orphaned `clip_types` cleaned |
| file authority | `file_authorities` rows written **only** for local captures, never for a remote-origin row |
| grant expiry | `file_grants` expired at 30 minutes idle or past `hard_expires_ts` |
| classification | `text` / `rtf` / `html` / `image` / `files` / `mixed` / `url`, including the single-path file-versus-directory split and the synthetic resolved-path entry the picker previews |
| attribution | stamp `source_app` and `source_bundle_id` from the frontmost application on a **local** capture, and never on a row whose origin is remote — where the origin host is authoritative and the sit-at machine's frontmost window is irrelevant |

The store schema is unchanged. The daemon becomes its sole writer, which is
what `docs/clipboard-universal-project.md` §23.1 already claims and the system
does not currently do — `P`, `M` and Linux `clip::op_set` all write rows today.
The claim becomes true rather than aspirational.

### 14.3 What the daemon delegates

The previous two subsections are the work the daemon takes *on*, which makes it
easy to read this one as the residue — the parts the rewrite could not reach.
It is the opposite. **Delegation is the mechanism the product is built on**
(P9), and the operations below are the clearest expression of what RECOB is
for: a remote host causing a deliberately chosen thing to happen on the machine
the human is sitting at, without being able to say *how* — or, per P8, *to
what*.

- **The OSD.** Notifications are drawn by Hammerspoon on a 210×130 canvas with
  an icon glyph set, optional ANSI text, a sound and a fade, plus a separate
  progress capsule for long transfers. Reimplementing that natively is a
  substantial GUI job with no protocol benefit, and swapping it for
  `UNUserNotificationCenter` would change the UX. It stays — and it stays
  *correctly*, not as a compromise. The wire carries
  `osd.notify{style, text, icon, sound}`; the handler maps `style` through a
  table to the Lua that renders it. A peer that can raise a toast on this Mac
  cannot name what runs, cannot add a style, and cannot reach anything the
  enum does not already list.
- **Fullscreen toggle and probe** remain the external scripts they already are,
  under the same contract: `window.fullscreen.toggle{terminal}` names a
  terminal from a closed set, not a command.
- **The GUI picker** (`clipboard-picker.lua`) and the headless fzf picker
  (`pick-clipboard`) stay. Both read the store; concurrent readers are what WAL
  is for. What they cannot keep is writing to it — see §14.5, which is not a
  detail of the picker but the piece of work absorption actually creates.

The clipboard is the contrast that makes the pattern legible. It is *not*
delegated, because after §14.1 the daemon has no one to delegate to — it holds
the pasteboard directly. So the system has both shapes at once: capabilities
the daemon implements, and capabilities it merely authorizes and forwards.
Which shape an operation takes is an implementation choice
([§9.6](#96-configurable-exposure)); that it presents one fixed, named,
authorized contract to the wire is not.

**How the daemon reaches the OSD is an open decision**, not an omission — see
[D7](#d7-how-the-daemon-raises-the-osd). Today every notification spawns the
`hs` CLI, measured at **17.9 ms ± 2.0** for a trivial script, before the
temporary directory, side files and generated Lua that wrap it. That is the
largest single spawn left anywhere in the design, and this document does not
settle it silently.

### 14.4 Retiring the Lua writer

Absorption is not complete until the old writer stops, and this is the step
most likely to be skipped because everything appears to work without it. On
macOS today `init.lua:40` calls `clipHistory.setup()`, which starts
`hs.pasteboard.watcher` and opens the store for writing. If the daemon begins
capturing while that call remains, **both processes capture every change** —
two rows per copy, or one row and one dedup update, depending on which wins.
Nothing errors. The store just quietly doubles.

So the cutover requires, in the same change that ships the daemon:

1. `clipboard-history.lua` stops starting the watcher and stops inserting. What
   remains of the module is the read path the pickers use.
2. The Hammerspoon module opens the store **read-only**, so a reintroduced
   write fails loudly instead of racing.
3. A test asserts that one physical copy produces exactly one row.

The sole-writer claim in §14.2 is conditional on this, and stating it as
already true would be the kind of claim that is correct in the specification
and false on the machine.

### 14.5 Restore is an operation, not a picker internal

The picker's `restore_by_id` is the one existing caller that genuinely writes
the pasteboard, and it does more than any current wire operation covers:

```
function M.restore_by_id(id)
  ...
  if next(data) == nil then pasteboard.setContents(plain)
  else pasteboard.writeAllData(data) end
  write_regtype_for(id)
  bump_last_ts(id)
```

It restores **every clip kind**, not just files — plain text, RTF, HTML,
images, a full multi-UTI set — then reinstates the register type and bumps
`last_ts`. Mapping it onto `clip.set.files` with a `clip_id`, as an earlier
draft of §14.3 did, would silently break Ctrl+Y and Alt+Enter on every
non-file row in the picker. That is one operation short, not one call site
short.

The registry therefore gains **`clip.restore`**:

| Field | Meaning |
| --- | --- |
| `clip_id` | bare rowid of the row to restore |
| `plain_only` | optional flag selecting the degraded-to-text restore the picker binds to Alt+Enter |

The default restores the stored representation set atomically, reinstates the
row's `regtype`, bumps `last_ts`, and — because the daemon performed the write
— is attributed with no marker and no capture.

**`plain_only` is not "restore `text_plain`",** which is what a first draft of
this table said and what the name suggests. `restore_plain_by_id` is a
degrade-to-something-pasteable path with three distinct branches, and a
reimplementation from the flag name alone would silently lose two of them:

1. For `file`, `directory`, `url` and `image` rows it writes a **markdown
   link**, not the text — which is the entire point of the binding, since
   those rows have no useful plain form. If there is nothing to link to it
   **falls through** to branch 2 rather than failing; the Lua notes this
   should not happen for those kinds in practice, which is exactly why it
   needs stating — an implementer who treats branch 1 as terminal turns a
   documented soft path into a hard error.
2. Otherwise it writes `text_plain`.
3. When `text_plain` is empty it **derives** text from the row's
   `public.html`, `public.rtf` or RTFD representation, tried in that order.
4. It **does not** reinstate `regtype`, unlike the default path. A
   degraded-to-text restore is not the register the original clip had, and
   asserting otherwise would give a later nvim paste the wrong block-ness.

Both paths bump `last_ts`. A restore that finds no row answers
`not-found{reason=no-row}`; one that finds a row but can produce nothing
pasteable from it — every branch exhausted — answers `not-found` with the same
reason rather than `internal`, since the row existing but being unrestorable is
a property of the data, not a fault.

Branch 3 was the one part of the absorbed set with a real chance of not working
outside a GUI application: natively it is
`NSAttributedString(data:options:documentAttributes:)`, whose HTML importer is
WebKit-backed. Probed from a plain binary:

```
Q9 html (NSHTML) -> "hi & bye"
Q9 rtf  (NSRTF)  -> "hello rtf\n"
```

Both work, with entities decoded and markup stripped. Worth recording that the
probe first failed with `NSCocoaErrorDomain 65806` because the options
dictionary named the document-type *constant* rather than its value — a
mistake that reads exactly like "this API does not work here," which is how a
capability gets wrongly ruled out.

Policy: **tier `local`**. Restoring an arbitrary stored clip by rowid onto the
sit-at machine's pasteboard is not something a peer across the tunnel has any
business doing, and it is the same reasoning that makes `clip.set.files` local.

### 14.6 Regtype without the sidecar file

§6.2 deletes `current-regtype` along with `current-origin`, and that deletion
has a consumer the provenance argument does not cover: the register type is
read back by `clip.get` and written by restore
(`clipboard-history.lua`'s `write_regtype_for`, and today's
`clip::op_get_regtype`, which hashes the pasteboard to decide whether the
stored value still applies).

The file exists for the same reason the origin file did — the writer and the
reader are different processes — and it goes for the same reason. The daemon
holds the register type of the clip it last wrote, alongside the `changeCount`
at which it wrote it. `clip.get` answers from that when the counts still match,
and falls back to today's trailing-newline heuristic when the pasteboard has
moved on beneath it. Same two-case logic, same answers, no file and no hash
comparison — the hash existed only to detect the change the daemon can now
observe directly.

### 14.7 The Linux build

Headless Linux has no pasteboard, so §14.1 and §14.2 compile out entirely
behind `#[cfg(target_os = "macos")]`. What remains is the store, the sockets,
the codec and the authorization table — which is the whole of the wire and
none of the platform. The reduced build is the reason a single codebase is
possible at all, and the reason the language question was decided on the
quality of macOS interop rather than on either half alone.

---

## 15. Decisions

These change behavior or scope and should not be settled silently.

### D1. Does the public endpoint require authentication?

**Decided: yes** — a credential is required at connect time on the public
endpoint. It closes the shared-host finding at the connection level, where it
cannot be defeated by a missing table entry, and it reuses a distribution hook
that already exists.

The cost is a hard dependency on a push that is currently backgrounded and
fail-soft: only a brand-new or freshly rotated remote can race, and the failure
is a clean, actionable `unauthorized`, but it is a real availability regression
and §9.2 records it as one.

**The credential is a challenge response, not the token.** A second review
round found that sending the token itself hands it to whatever process happens
to be bound to loopback 2490 on the remote, which any local user can be when no
tunnel is active. §9.2 now specifies **mutual** challenge-response: a
per-connection nonce in each direction, `auth = SHA256(token || ":c:" || nonce)`
from the client and `proof = SHA256(token || ":s:" || cnonce)` from the server.
The server must prove itself because otherwise a squatter, unable to steal the
token, simply reads the clipboard payload the client sends it.

This costs one round trip on the public endpoint for reads and two for writes —
the hello can no longer be pipelined blind, and anything carrying user data
waits for `proof`. That cost is accepted rather than optimized away, because
every way of avoiding it requires trusting an assertion made by the party being
authenticated.

**One further refinement to flag, because it departs from the option as posed.** The
decision was taken as "a per-tunnel token, generated at connect and bound to
the session." §9.2 specifies a token **per owning machine**, keyed by host name
and rotated on demand, rather than one minted per connection. Generating a
fresh token on each connect turns out to make *every* connection depend on a
racing background push, rather than only the first — and it buys nothing,
because what protects the secret is the mode-0600 file's uid boundary, not the
secret's age. Keying by owner delivers the property the decision was reaching
for (no single shared secret, a token useless against any other machine,
rotation invalidating every copy) and additionally fixes a defect a single flat
`tunnel-token` file has: two machines pushing to one remote silently
invalidating each other. If the intent was specifically per-connection
freshness rather than isolation, this is the point to say so.

### D2. What language are `pbcopy` and `pbpaste` written in?

**Decided: Rust, superseding an earlier decision of zsh.**

The original question was whether to convert them from POSIX `sh` to zsh, and
the answer was yes: they are the last hand-rolled implementation of the wire
format, they spawn per frame, and §4.3's length-prefixed fields are genuinely
unpleasant to parse in `sh`. That reasoning is unchanged and it now points
further. Once the daemon is Rust ([D6](#d6-implementation-language)), the
clients share its codec instead of reimplementing it, which is a stronger
version of the same argument: not three implementations reduced to two, but one
implementation with no reimplementations at all.

It is also worth less than it looks, and §1.2 gives the measured reason — the
saving is ~3.9 ms per invocation against a 4.7 ms platform floor, not the ~8 ms
the zsh floor implies. The reason to do it is that the client stops being a
second, hand-written interpretation of the protocol.

**The constraint this creates** is that the clients must not link AppKit: it
costs 2.6 ms of dynamic linking, which is most of the win. A client has no
business touching the pasteboard — it talks to the daemon — so the constraint
is natural, but it must be a build assertion rather than a good intention,
because a shared crate can pull AppKit in silently.

The cost is the standing rationale in `pbcopy`'s header: standalone POSIX `sh`,
no library sourcing, so it works from any caller with zero fragile
dependencies. A static binary in `~/.local/bin` satisfies that rationale better
than either shell does — no interpreter, no library path, no `PATH`-dependent
custom zsh build on the dev-shell.

### D3. Rename the service, or only the protocol?

**Recommended: only the protocol, for this change.** The name
`clipboard-bridge` is actively misleading — two of its operations have nothing
to do with clipboards — but renaming reaches launchd labels, systemd unit
names, the self-heal calls in both shims, `.chezmoiignore`, `services.toml.tmpl`,
and a large number of documentation references. Folding that into a protocol
rewrite makes the diff much harder to review for the thing that actually
matters. Proposed as a separate follow-up.

### D4. Rate-limit numbers

20 per 10 s for `osd`, 5 per 10 s for `window` are starting points, not
measured. `copy-pwd`'s two-phase feedback sends two `osd.notify` per keypress,
so 20 allows ten keypresses in ten seconds before throttling. Worth a sanity
check against how fast the operator actually presses it.

### D5. Is `clip.get` returning four fields the right granularity?

It collapses three connections into one for the picker's live-peer row, but it
also means a caller wanting only the regtype pays for a store query for the
timestamp. Given the measured per-connection cost dwarfs a local SQLite read,
the collapse looks right — but it is a judgement, and the alternative is a
`fields` request parameter, which is more protocol for less benefit.

### D6. Implementation language

**Decided: Rust**, for the daemon and both clients, reversing this document's
earlier premise of a persistent zsh listener.

Two measurements forced it, neither of which is about the protocol. Digesting a
credential costs **14.82 ms** per `shasum` spawn on macOS because that binary is
a Perl script, and the §9.2 handshake needs two per side — so authentication
alone would have spent more than the persistent listener saved. Every rich
copy, file copy and notification spawns Hammerspoon at a **17.9 ms** floor to
reach an API any native process can call directly. Neither cost is reachable
from a shell, at any listener design.

Rust over the alternatives, on verified facts rather than preference:

- **Over Go**, which this repo already builds two programs in and which would
  otherwise win on precedent and build speed: the maintained Go clipboard
  package cannot perform an atomic multi-UTI write, because every write clears
  the pasteboard first, and it exposes no `changeCount`. Matching §14.1 would
  mean hand-writing the Objective-C binding layer, which forfeits exactly the
  simplicity that was Go's case.
- **Over Swift**, which has the best pasteboard ergonomics of the three: the
  headless-Linux half is the problem — community-maintained SQLite bindings
  with documented linker issues, and a second toolchain to install on a machine
  where the build must be non-interactive and unprivileged.

Costs, measured on a probe crate carrying the same dependency shape — bundled
SQLite, `objc2-app-kit`, `sha2`, `subtle` — rather than on the real tree, which
does not exist yet: 11.4 s for a cold build, 0.33 s to rebuild after a source
change, a 505 KB binary. Treat these as the right order of magnitude and not as
the finished figures; the real ones are the benchmark harness's to report. They
fit the `run_onchange` + source-SHA hook pattern `pty-frame` already uses,
with the failure-handling difference §13 sets out.

The residual risk is that this repo now maintains Rust and Go side by side for
no reason a future reader will infer. Worth a line in the build docs.

### D7. How the daemon raises the OSD

**Open.** The notification UI stays in Hammerspoon ([§14.3](#143-what-the-daemon-delegates)),
so the daemon has to reach it, and the options differ by more than performance:

1. **Spawn `hs` per notification, as today.** 17.9 ms, backgrounded, no new
   mechanism, no new failure mode. Simplest, and the only option that needs
   nothing new to work.
2. **A persistent subscription.** Hammerspoon opens a long-lived connection to
   the trusted socket and the daemon streams notifications to it as `D` frames
   — which is the streaming shape [§6.4](#64-streaming-responses) already
   specifies, so it is not new protocol. It removes the last significant spawn
   and inverts the dependency so the daemon never has to know how to launch
   Hammerspoon. It also introduces a reconnect contract, a behavior when
   nothing is subscribed, and a queue-or-drop policy.

Recommendation: **option 1 for v1**, with the subscription noted as a
follow-up. The notification is already backgrounded, so 17.9 ms is not on the
path the user waits for, and option 2 spends a genuinely new failure mode on a
cost the user cannot perceive. This is the one place in the design where the
cheaper mechanism is the more complex one, which is a reason to be suspicious
of the instinct to take it.

---

## 16. Out of scope

- **The store schema**, which is unchanged. Only its writer changes.
- **The pickers.** Both the Hammerspoon GUI picker and the headless
  `pick-clipboard` keep reading the store directly. The single change forced on
  them is that the GUI picker's in-process `restore_by_id` becomes a call to
  the daemon over the trusted socket, because sole-writer means sole-writer
  ([§14.3](#143-what-the-daemon-delegates)).
- **The OSD**, which stays in Hammerspoon, along with the fullscreen toggle and
  probe scripts.
- **The clipboard mount.**
- OSC 52, which stays as the no-tunnel fallback for both shims.

The watcher's capture logic was on this list until the daemon absorbed it. It
is now a requirement with tests in [§14.2](#142-behaviors-absorbed-from-the-watcher),
and the change of status is called out here rather than silently deleted,
because a reader comparing drafts should not have to infer that the largest
scope change in the document happened.
- The `clipboard-mount` peer-mount path used by `pbpaste --files` on a local
  Mac.
- Renaming the service (D3), if declined.
- Anything in `docs/recob-audit-brief.md#out-of-scope--already-landed`.
