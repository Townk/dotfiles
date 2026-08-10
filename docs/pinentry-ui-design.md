# A pinentry we own — design

Status: **shipped on this host.** `pinentry-auto` execs
`~/.local/libexec/pinentry-ui` for the curses lane; the shell filter
(`pinentry-mux`) and its watcher are deleted. `docs/gpg-signing-ux.md` is the
history — how the filter worked, and the two dead ends that ended it. Read it
first; this file assumes it.

What is still open: the other three profiles. `pinentry-auto` is macOS-only
(Homebrew paths, a VNC probe, Touch ID), so `work`, `dev-shell` and `server`
need dispatch work of their own before any of this reaches them, and each host
builds its own binary.

Everything below is the design as built, with the places reality corrected it
marked. Two are worth knowing before reading anything else, because both were
found by running the thing rather than by thinking about it:

- **`Drop` is not enough to close the float.** gpg-agent killing its pinentry
  does not unwind, and the first real-world run left a float on screen that
  swallowed every keystroke — worse than the invisible prompt this project
  exists to fix. The fatal-signal handler now closes it too.
- **`pane_active` does not mean "somebody is looking at this".** Every window
  has an active pane, so on a live server four panes claim it at once. Deciding
  the float on that alone would have reintroduced the original bug through a
  format string.

## Why replace a thing that works

Two dead ends, both recorded in the other file, both with the same root.

The filter sits in **one** direction. pinentry's stdout is the filter's stdout,
so replies go straight back to gpg-agent and the filter cannot see or swallow
them. Assuan is strictly synchronous, one response per command, so a filter in
that position may only ever rewrite a line — never add one. Adding one leaves a
surplus `OK` that the agent reads as the answer to `GETPIN`: a result with no
data, which *is* "No passphrase given". Every signature fails while a perfectly
good dialog sits on screen. That was measured, not theorised.

That constraint is what makes the float the wrong size. The dialog's dimensions
are computable from `SETDESC`, but `SETDESC` arrives 23 commands after the
`OPTION ttyname=` the float must be opened from; `tmux 3.7b` sets a popup's size
only at creation (`display-popup -w/-h`, with no command that resizes an open
one); and moving a live dialog to a new float needs the extra `OPTION` the
paragraph above rules out. The size is knowable and unreachable at the same
time.

Owning the dialog dissolves both. There is no proxy to desynchronise, and the
program that decides the layout is the program that opens the float, so it knows
the size before it asks for the canvas.

## Scope

Wider than the float that prompted it, and the width is a decision rather than
an accident.

**All four profiles.** `personal`, `work`, `dev-shell` and `server` — anywhere a
signature might be asked for, which is anywhere. `work` is explicitly included.
That is worth stating rather than assuming, because a binary that reads
passwords is structurally the shape endpoint tooling is built to notice, and on
a managed machine it can also meet policy. Included, deliberately, with the
fallback discipline below as the thing that keeps it from being a liability.

**Every curses prompt, agent pane or not.** So this dialog is what appears when
signing at your own keyboard too, and a bug in it is felt everywhere rather than
only where nobody is watching.

**Spawned helpers only — never a PAM module.** The natural next front-ends are
`SUDO_ASKPASS` and `SSH_ASKPASS`: each is a subprocess with its own address
space that hands a secret back over a pipe, exactly like pinentry. Being *loaded
into* the authenticating process is out of scope and should stay out. A PAM
module is a C-ABI shared object living inside a setuid-root, forking host, which
is a different security posture entirely and would also constrain the language
choice below to one answer.

Two ceilings worth knowing before anyone plans around them. `SUDO_ASKPASS`
requires the secret to leave the process on stdout — that is the protocol, not a
flaw in the design. And on macOS the reachable set stops at GPG, sudo, ssh and
git credentials: the login window, Keychain and authorization prompts belong to
the system's own Security stack.

**Blast radius is the reason the fallback rules are absolute.** Today a bug
means an agent cannot sign. Wired into sudo, a bug means you cannot become root
on a remote host. Every failure path reaches the stock prompt, and no front-end
may ever become the only way to authenticate.

## Shape

One binary, `pinentry-ui`, invoked by `pinentry-auto` in place of today's
`pinentry-mux` + `pinentry-curses` pair. It is a pinentry: Assuan on stdin and
stdout, no arguments that matter.

```
gpg-agent  <--Assuan-->  pinentry-ui  --draws on-->  float pty   (agent pane)
                                      --draws on-->  caller pty  (everything else)
```

The float is still opened by `pinentry-mux-popup --open`. It already resolves
the tty to a session, picks the most recently active client, opens a
non-dismissable popup, fires the OSD alert, and hands back
`"<popup_tty> <holder_pid>"`. None of that logic is about Assuan and none of it
needed rewriting. Three things changed, all at the edges: it takes `w h` from
the caller instead of guessing, so its size check inverted from "what fits?" to
"does this fit?"; it takes the requester's name, for the OSD sentence; and it no
longer passes `-B`, because pinentry-ui skips its own frame and wears tmux's
themed rounded border instead of drawing a second box inside the first.

`pinentry-mux` (the shell filter) goes away entirely, along with the watcher
subshell that tied the float's lifetime to the dialog.

**Owning both ends removes that watcher for every exit that unwinds, and only
those.** The first real run proved the gap: `SIGTERM` — which is how gpg-agent
ends a pinentry it is finished with — skips `Drop` entirely, and the float
survived its owner. What was left on screen was a pane that swallowed every
keystroke and answered to nothing, which is strictly worse than the invisible
prompt this project exists to fix, and is the same symptom the filter's watcher
existed to prevent. So the holder's pid lives in an atomic the fatal-signal
handler can read, beside the terminal it already restores, and `kill` joins
`write` and `tcsetattr` in the async-signal-safe teardown.

**One edge that teardown does not cover, recorded because it looks like the bug
above and is not.** A signal aimed at the whole process group — what `timeout`
sends, and what a foreground Ctrl-C reaches — kills the `display-popup` client
along with us. The popup then closes, but the holder inside it is a child of the
tmux server rather than of the client, so it survives as an orphan holding a
fifo. It answers `SIGUSR1` the instant anything sends one, so nothing is wedged
and no float is left on screen; the difference from the real bug is precisely
that there is nothing to see. A signal aimed at us alone, which is what
gpg-agent and sudo send, tears down both. Left alone deliberately: nothing in
the live path wraps a pinentry in a process-group kill, and the fix would mean
reintroducing something that watches the holder.

## The protocol surface, and what we refuse to implement

29 verbs exist. Passphrase *entry* — the whole reason this project exists — uses
a small subset, and the rest belong to passphrase changes, key generation and
confirmation dialogs.

Implement: `SETDESC`, `SETPROMPT`, `SETERROR`, `SETOK`, `SETCANCEL`, `SETTITLE`,
`SETKEYINFO`, `SETTIMEOUT`, `OPTION`, `GETINFO`, `GETPIN`, `BYE`, `RESET`, `NOP`.

The last two of those were added after shipping, and the way they were missed is
the most useful thing in this document. See *The bug the whole test suite
missed*, below.

Delegate everything else — `CONFIRM`, `MESSAGE`, `SETREPEAT`, `SETQUALITYBAR`,
`SETGENPIN` and friends — by spawning the real `pinentry-curses`, replaying the
buffered state to it, and relaying both directions until the connection ends.

There is a second trigger for the same machinery, and it goes to a *different*
binary. A `GETPIN` whose terminal will not open is a GUI app signing with no
`GPG_TTY` — an editor's source-control panel, most likely, with `commit.gpgsign`
on — and the answer there is `pinentry-mac`, which never wanted a terminal.
Telling that caller "no dialog" would fail a signature something else could
complete. The two cases want opposite front-ends, which is why the handover
carries which one it is rather than assuming.

Two things have to be *withheld* from that handover, and both were found by
running it against the real `pinentry-mac` rather than a stub. Neither failed
loudly: each produced a terminal complaint from a GUI binary, which reads like a
broken handover rather than something we handed it.

The first is `ttyname` — and `ttytype` with it. We only go to the GUI because
that terminal would not open, and pinentry-mac opens the ttyname it is given
before deciding anything, so replaying it fails on the same stone we did
(`S ERROR mac.open_tty_for_read`). The second is the `USE_CURSES` token in
`PINENTRY_USER_DATA`. pinentry-mac obeys it by re-execing a curses pinentry —
that token is how a terminal client opts out of the GUI, and it is how this
program gets chosen in the first place, so passing it down sends the request
straight back to a terminal that does not exist (`S ERROR mac.isatty`, once the
ttyname is gone). The curses lane keeps both: it was handed a working terminal
and needs to know which one.

This is also what lets the VNC lane in `pinentry-auto` prefer `pinentry-ui`.
That lane used to go straight to `pinentry-mac`, which was the right answer only
half the time: someone viewing the desktop over Screen Sharing and typing in a
terminal got a GUI dialog for a request that had a perfectly good tty. The
dispatcher cannot tell the two apart — `ttyname` arrives over Assuan *after* the
exec — so the branch hands the lane to `pinentry-ui`, which decides with the
fact in hand.
Two things make this safe here and unsafe in the filter: we own the response
direction, so the extra `OK`s our replay produces are ours to consume; and we
have not answered anything yet, so nothing is out of step.

That fallback is also the general safety net. No tmux, no agent behind the tty,
a client too small, a float that will not open, a verb we do not know — every
one of them ends at the prompt we have today. Degrading is always allowed;
wedging the agent is not.

### The bug the whole test suite missed

The first real signature after shipping went to `pinentry-curses` on the
unwatched agent tty — the exact failure this program was written to remove.
Sixty-four tests were green at the time.

gpg-agent sends `SETKEYINFO` and `SETTIMEOUT` as part of the setup before
`SETDESC`, on every prompt. Neither was in the list above, so the first one hit
the catch-all and delegated the entire conversation before a dialog was ever
considered. Nothing was broken in the code that was written; the verb list was
simply guessed from the pinentry man page and the subset that *entry* needs,
and the man page does not tell you which verbs the agent actually sends.

Every test drove a script written by the same person who wrote the verb list, so
every test agreed with the mistake. The lesson is narrow and repeatable: **when
the input comes from another program, capture the input from that program.** It
cost one throwaway shim — a shell script that logs stdin, answers `OK` to
everything and cancels `GETPIN`, dropped in place of the binary — and produced
the exact stream, which is now `REAL_STREAM` in `assuan.rs` and the assertion
that nothing in it delegates. That shim is worth rebuilding on any host whose
gpg version differs.

`SETTIMEOUT` also turned out to matter beyond being accepted. It carries
`pinentry-timeout` from `gpg-agent.conf`, and the agent serialises every pinentry
on one global entry lock — so a prompt nobody answers does not just stall its own
signature, it kills every request raised while it sits there. The dialog now
takes a deadline against the whole prompt, not each keystroke (half-typing and
walking away holds the lock exactly as hard as not typing at all), and answers
`(Pinentry, Timeout)` when it expires. The deadline survives `RESET` for the same
reason the ttyname does: it belongs to the connection, not to one prompt's text.

### Three pieces of state whose lifetime is not obvious

Each of these is a one-line decision that would be a silent, plausible-looking
bug in the other direction, and none of them is visible from the verb list.

- **`RESET` clears the text but keeps the terminal.** gpg-agent sends `RESET`
  between prompts on one connection and does *not* repeat the `ttyname`. Drop it
  and the retry goes to whatever tty we happened to inherit.
- **`SETERROR` is one-shot.** A rejected passphrase means a second `GETPIN` on
  the same connection, and the error belongs to the attempt that produced it. A
  stale one tells the human their correct passphrase has just been rejected.
- **The description is parsed, and allowed not to parse.** gpg — not gpg-agent —
  builds it, from `"%.*s"` / `%u-bit %s key, ID %s,` / `created %s%s.`. The key
  tree comes from that shape; anything that does not match is drawn verbatim,
  which is what the stock pinentry does and is never wrong, only plainer. The
  clauses keep gpg's own wording, because rewriting them would splice our
  English into a string that may already have been translated.

One more, in the delegation path: the child's answers can include a passphrase,
so it is the single place in the program where a secret crosses memory we did
not lock. It cannot be avoided — a child cannot be handed our stdout after the
fact, and handing it ours from the start is exactly what would let the replay
`OK`s reach the agent — so the relay buffer is small, reused, and wiped after
every write.

## Security

The one protection worth preserving is memory: `nm -u` on
`/opt/homebrew/bin/pinentry-curses` shows it references `mlock` and `mmap`
directly, so the passphrase lives in locked pages that cannot be written to
swap. Everything else about the secret's path is unchanged by this project —
keystrokes travel terminal → ssh → tmux → pty exactly as now, and the answer
goes back over the same Assuan pipe — so it should not weigh on the decision.

### The two platforms differ, and Linux is the demanding one

| | macOS (measured on this host) | Linux |
| --- | --- | --- |
| Secret paged to disk | `vm.swapusage … (encrypted)`, FileVault On | swap usually unencrypted; hibernation writes RAM out |
| Another process reading our RAM | needs `task_for_pid`, SIP-gated | same-uid ptrace unless `yama.ptrace_scope` forbids it |
| Crash artefacts | `ulimit -c` 0, crash reports only | `systemd-coredump` persists dumps on disk |
| Can we lock pages | `ulimit -l` unlimited | `RLIMIT_MEMLOCK` capped, commonly 8 MB |

On macOS, losing `mlock` would be a modest downgrade — encrypted swap and
FileVault already cover the disk case, and a same-user process cannot read our
memory without a debugging entitlement. On Linux it is load-bearing: unencrypted
swap and hibernation both put RAM on disk, and with `ptrace_scope=0` any process
running as you can read the passphrase out of our address space. That last one
is equally true of `pinentry-curses` today, so it is not a regression — but it
is the one risk worth actively closing, and we can, which today we cannot.

### The rules the buffer has to obey

Stated without reference to a language, because they are what the language then
has to be judged against:

1. The secret lives in a **mutable** buffer that can be overwritten. Never in an
   immutable string type, not even briefly, not for a length check.
2. The **wipe cannot be optimised away**. A zeroing loop over memory about to be
   freed is a dead store, and a compiler is entitled to delete it.
3. The buffer sits in **locked pages** (`mlock`), so it is never written to swap
   or a hibernation image.
4. The runtime must not **silently copy** it — no relocating collector, no stack
   that grows by being copied elsewhere.
5. It is **excluded from crash artefacts**: `RLIMIT_CORE = 0` on both platforms,
   plus `PR_SET_DUMPABLE = 0` and `MADV_DONTDUMP` on Linux. `PR_SET_DUMPABLE`
   also denies same-uid ptrace, which closes the one Linux row above that macOS
   closes for us.
6. If `mlock` fails — the Linux `RLIMIT_MEMLOCK` case — **warn and continue**.
   Refusing to prompt would fail the signature to protect against a weaker
   threat than the one that refusal creates.
7. **It is never drawn.** tmux keeps a popup's screen contents in the server and
   `capture-pane` can read a pane's, so there is no reveal toggle: pinentry's
   "make visible" feature is deliberately not reimplemented. The same rule binds
   any demo or test harness — length or digest, never the bytes.
8. **No crash path prints it.** An uncaught panic that dumps state into
   gpg-agent's log is a leak; the secret's code path answers `ERR` instead.

The residual risk after all that is our own bugs, not memory management — a
debug print, a wrong variable in an error path. So the secret's code path stays
tiny and reviewable: read bytes from the tty, percent-encode, write one `D`
line, wipe. Layout, colour, Assuan bookkeeping and the float never touch it.

## Go or Rust — decided: Rust

The trade is recorded below because the reasoning outlives the choice. What
decided it is not in the general comparison: **every failure this project has
actually produced has been an unenforced invariant**, not a logic error. The
float outlived the dialog because its lifetime was bound to a pipe instead of to
the dialog. Signing broke because Assuan's one-response-per-command rule existed
only in a maintainer's head. The third of that family has not happened yet and
is the one the rules above keep circling: the secret reaching a log line.

Rust makes two of the three structural. `Drop` ties the float to a value's
scope rather than to remembering a trap on every exit path. A secret type with
no `Debug` and no `Display` turns the leak into a compile error instead of a
discipline that has to be sustained across sessions by whoever picks this up
next — which is the decisive consideration for a component edited months apart
with partial context.

The costs are real and accepted: cross-compilation gets harder, and the only
directly reusable terminal code in this repo is `pty-frame`'s, which is Go, so
termios and raw mode are written from scratch here.

Both toolchains are mise-managed and installed here, and
`custom-builds/` already holds two Go programs (`pty-frame`, `tm-timeline`) and
a Rust workspace (`recob`), so neither is a new dependency and "what we already
use" decides nothing.

**What Go costs.** Rules 1, 2 and 4 all bite. Strings are immutable, so the
secret must stay a `[]byte` and never meet `fmt`. Goroutine stacks grow by being
copied, so a stack local can be duplicated with the old copy abandoned. The heap
is non-moving in the current collector, but that is an implementation detail
rather than a guarantee, and rule 4 should not rest on one. There is no
zeroization primitive with a promise attached. One decision answers all of it —
allocate with an anonymous `mmap` *outside* the Go heap, `mlock` it, wipe,
`munlock`/`munmap` — which is perhaps forty lines and escapes the runtime
entirely. It works; it is just a workaround for the runtime rather than a use of
the language.

**What Rust buys.** Rules 1–4 stop being work. `zeroize` wipes with
`write_volatile` plus compiler fences, which is rule 2 as a guarantee instead of
an observation about today's compiler. `secrecy` makes rule 7 and rule 8 *type
errors*: a `Secret<T>` implements neither `Debug` nor `Display`, so the accident
this design says is the dominant residual risk becomes unrepresentable. No
collector and deterministic `Drop` give rule 4 for free, so the secret can live
in an ordinary locked allocation instead of a hand-rolled one outside the heap.
`recob` already demonstrates the security-conscious idiom in this repo, down to
constant-time comparison via `subtle`.

**What Go buys.** Cross-compilation, and it is not a small thing across four
profiles: `GOOS=linux GOARCH=amd64 go build` from a Mac needs no toolchain,
where the Rust equivalent needs musl or `cross`. It is also faster to write,
which matters for a component whose failure mode is "cannot sign, cannot sudo,
anywhere". If every host builds its own binary — the existing `custom-builds`
convention, and the `dev-shell` bootstrap already installs a Rust toolchain —
that advantage largely evaporates. The one piece of directly reusable precedent
in this repo is also Go's: `pty-frame` already does raw-mode terminal work
against a pty, which is exactly the drawing half. `recob` gives Rust the
security idiom and the workspace shape, but no terminal code at all.

**What does not distinguish them.** Memory safety (both). Syscall access —
`nix`/`libc` against `golang.org/x/sys/unix` is a wash. Static Linux binaries
(both, Go slightly more easily). Terminal libraries: `ratatui`/`crossterm` and
`bubbletea`/`tcell` are both mature, and both should be declined anyway — a
hand-rolled ANSI dialog on a raw tty is a few hundred lines either way, and a
security component wants the smallest audit surface it can have.

**What would have decided it, and does not.** A PAM module has to be a C-ABI
shared object loaded into a setuid-root, forking host; Go's runtime — its own
threads at init, its own signal handlers, a collector — makes that a category
error rather than a tuning problem, while Rust's `cdylib` carries no runtime at
all. That would settle the question outright, but PAM is explicitly out of scope
(see Scope), so it stays an argument in reserve rather than the deciding one.

## Drawing

### The look is not ours to invent

The dialog reproduces the ai-playbook `ask` widget rather than designing a
passphrase prompt from scratch, so that a request for a passphrase looks like
every other question the toolchain puts on screen. The source of truth is that
repo's `pkg/dialog/frame.go` and `pkg/dialog/field_text.go`:

- 57 columns fixed (its `FloatWidthDefault`), 2 columns of horizontal padding
  and a rounded border, leaving 51 columns of content.
- One row of top padding and **none** at the bottom — the hint line sits
  directly on the closing border.
- A `▓▓▓ Title` line in the accent colour over a `━` rule the full interior
  width, then one blank row between every section.
- The entry in its own rounded box the full 51 columns, with a 1-column left pad
  and a glyph in a 2-column gutter.
- Hints as Nerd Font key glyphs in the key colour with their words in the muted
  one, joined by ` · `.

The colours are the same values reached through this repo's own role names, so
one theme switch moves both dialogs: `UI_BORDER_FOCUS`, `UI_TITLE`,
`UI_SEPARATOR`, `UI_FG`, `UI_BORDER`, `UI_KEY`, `UI_OVERLAY`, and a
`UI_DIALOG_BG` fill painted on every row so the dialog reads as a card. A retry
takes the danger variant — border and title in `STATE_ERROR`, with the message
above the entry box.

Deliberate departures, each forced by what this dialog is and not by taste. The
entry is masked, drawn from a character count rather than from the buffer, so
there is no path from the passphrase to the screen, and its gutter holds a key
rather than the `❯` of a command prompt. The hints gain a `clear` segment,
because unlike a text prompt there is no visible content to select and retype,
and they follow the `pick::hints` shape defined in
`home/dot_local/lib/pick-common.zsh` rather than ai-playbook's, so every dialog
in this repo renders a keybind the same way. And pinentry's `SETPROMPT` becomes
the title while `SETDESC` becomes the body, which is the mapping that makes the
widget fit without adding a row the reference layout does not have.

Glyphs are verified against `~/.local/share/fonts/nerd-font/symbols.db`, the
symbol table for the font this repo builds, and written as `\u{…}` escapes
because private-use characters do not survive every editor in the chain. Ones at
`0x10xxxx` are Font Awesome 7: that build relocates FA7 to `0x100000 + native`
so it does not clobber the Nerd Font copy, which means they are as portable as
any other glyph here — they need this repo's font, not a Mac.

### The key block

gpg words the key as a run-on sentence. The dialog takes it apart and draws it
as a tree, which is the same information in a form that can be scanned:

```
"Example Key <key@example.invalid>"
 ├ 󰌾 4096-bit RSA key
 ├ 􏊻 ID 0123456789ABCDEF
 ╰ 󰃭 created in 2020-01-01
```

The connectors are muted, the glyphs green (`ACTION_CONFIRM`), and the text
plain.

Green rather than the yellow this block first used, for a reason that outranks
taste: **yellow has to keep meaning one thing.** It says "this request did not
come from your pane" on the requester line below, and a colour that is also
sprinkled over three glyphs on every single prompt is a colour nobody sees any
more by the second week. So the dialog spends yellow once, on the only element
that is not always drawn, and the key's identifying marks — which are neutral
detail, present every time — take green. No role means "identifying detail";
`ACTION_CONFIRM` is the least wrong of the three names sharing that hex, since
the key block is precisely the thing you confirm before typing, and it beats
`STATE_SUCCESS`, which would claim something had succeeded.

That costs a parse, and the parse is the fragile part. The template is built by
**gpg**, not gpg-agent — confirmed in the installed binary's strings:

```
Please enter the passphrase to unlock the OpenPGP secret key:
%u-bit %s key, ID %s,
created %s%s.
 (main key ID %s)
```

It is a translated string, so under a non-English locale none of it matches, and
it is not a stable interface in any case. **The parse must fall back to printing
the description verbatim** rather than dropping information it failed to
recognise — and the ssh-agent path, where the description is an ssh fingerprint
instead, will always take that fallback.

Two fields are worth adding beyond what the tree draws today:

1. **The main key ID**, which that trailing `(main key ID %s)` carries whenever a
   subkey is being unlocked. It is free — already in the text we are parsing —
   and it answers "which of my keys is this", which the subkey ID alone does not.
Anything else (expiry, capabilities, whether the key lives on a card) would mean
running `gpg` from inside a process holding a passphrase, and is not worth it.

### Who is asking

Not in the protocol at any level, but this program is the one place that knows:
it has the requesting `ttyname` from the `OPTION` it is sent. For the problem
this project exists to solve — an agent asking for a signature on a tty nobody
is watching — that is worth more than any property of the key.

It gets **its own section directly above the entry box**, so it is the last
thing read before typing:

```
 􎡡 requested by claude · pane %3 (Main:2)
```

The glyph is the requester's **tab icon**, not a generic terminal mark — see
below. It is the same picture the human already associates with that pane, so
the line is recognisable before it is read.

The line is **variant-aware, and that is the whole point**. A line that always
says the same thing stops being read within a week, and is then worthless
exactly when it matters. So: the whole line muted when the requesting tty *is*
the pane the human is attached to (they asked for this themselves), and the
whole line in attention yellow when it is not.

**"The pane the human is attached to" takes three tests, not one**, and the
obvious single test is wrong in a way that reintroduces the original bug.
`pane_active` is per *window*: every window has exactly one, so on a live server
four panes claim it simultaneously. A prompt from a background window would be
treated as one somebody is watching, drawn in place, and never seen. The
condition is the session having an attached client **and** the window being the
current one **and** the pane being the focused one. Same for a split you are not
focused on.

It does **not** go in the title. The title stays gpg's `SETPROMPT`, because that
is the one element identical on every prompt — which is what makes the dialog
recognisable — and because it already distinguishes a passphrase from a PIN from
a repeat-confirmation. Each element gets one job: the title says *what* is being
asked, this line says *who* is asking, colour says *whether to worry*.

#### The name and the icon are already solved

`#{pane_current_command}` is the obvious source and it is not good enough: tmux
names a pane after a process it picks from the foreground process *group*, and
on macOS that is not the leader, so an agent pane reads `node`.

The repo hit this exact problem building the tab pills and fixed it there.
`mux-tab-proc.sh` stamps the real name onto the pane as `@win_proc` from
`preexec` — which is the one moment something knows the command it is about to
run — and drops it in `precmd`. Only `.muxHiddenProcs` are stamped, which is the
list of agents this project is about. Measured on a live server:

| pane | `@win_proc` | `#{pane_current_command}` |
| --- | --- | --- |
| running an agent | `agent` | `node` |
| shell at a prompt | *(unset)* | `zsh` |

So the requester name is the pill's own `win_cmd`: `@win_proc` if set, else
`#{pane_current_command}`, `.exe` stripped. It is correct for precisely the
window in which a signing prompt can fire — the stamp exists only while a
command is running — and it needs no new machinery, no process-tree walk, and no
guess about which descendant counts.

The icon follows for free, and must: the glyph comes from `.muxTabIcons` keyed
on that same name, so the dialog wears what the requester's tab pill wears
(`claude` → `fa-claude`, `agent`/`cursor-agent` → `usr-cursor-ai`), with
`nf-md-run` for anything unlisted. One table, three consumers — the tmux pill,
zj-hud's `icons::process_icon`, and this dialog.

The binary cannot read chezmoi data at runtime, so the table is **projected**
the way the palette already is: `home/dot_config/mux/tab-icons.data.tmpl`
renders `~/.config/mux/tab-icons.data`, one `BASENAME<TAB>GLYPH` record per
line, and `icons.rs` reads it. Baking the table in at compile time was the
alternative and is worse: a new entry in `mux.yaml` would reach the tab pills on
`chezmoi apply` and this dialog only after somebody remembered to rebuild.

The generic "unlisted process" glyph moved into the data as
`muxTabIconDefault` at the same time. It had been a literal inside the tmux
theme template, and a second copy in the dialog would have been a discrepancy
nobody would ever think to look for.

#### The OSD says it too

`mux::pinentry_alert` currently fires a generic *"Passphrase needed — a signing
prompt is waiting in tmux"*. That is the one place the sentence form earns its
words, because when it fires the human is by definition not looking at a
terminal and has no other context. It names the requester — no pane, first word
capitalised: *"Claude is requesting your passphrase"* — from the same
`@win_proc` lookup.

### The tab that tmux ate

The second bug found on a live signature, and the same shape as the first: an
assumption about the environment gpg-agent provides, invisible to every test.

The pane query asked tmux for eight tab-separated fields. tmux passes its output
through `utf8_sanitize` whenever the locale is not UTF-8, which rewrites every
non-printable byte as `_` — and gpg-agent hands a pinentry an environment with
no `LANG` and no `LC_*` at all. So every tab came back as an underscore, the
line split into one field, no pane ever matched, `is_agent` was false, and the
prompt was drawn *in place on the agent's own pane* — precisely the failure this
program exists to remove. It fails as a fallback rather than as an error, which
is why nothing complained.

Measured three ways before changing anything: in a normal shell the tabs
survive; under `env -i` reproducing gpg-agent's environment they become `_`;
adding `LC_CTYPE=en_US.UTF-8` back makes them survive again.

The fix is a printable separator (`|`) rather than exporting a locale, because
that removes the dependency instead of satisfying it — there is no portable
UTF-8 locale name to pick (`en_US.UTF-8` is not guaranteed on a minimal Linux
host, `C.UTF-8` does not exist on macOS), and the right value is a property of
the host rather than of this program. `session_name` moved to the end of the
format and the split is a `splitn`, so a human who puts a `|` in a session name
gets an odd label rather than a prompt in the wrong place. Non-ASCII in a
session or window name is still sanitised to `_`, which is cosmetic here: both
sides of the "is anybody attached" comparison come out of the same mangling, and
the routing fields are all ASCII by construction.

`the_field_separator_survives_a_locale_less_environment` asserts the format
holds no control character. That is a guard, not a proof — the real check is the
live one, and it is the second time in this project that only a live run found
the bug.

### Tracing, added after the second one

Both live bugs were routing bugs, both failed as a fallback rather than as an
error, and both cost a throwaway logging shim plus a round of temporary
`eprintln`s to find — because there was no way to ask the program what it had
decided. `PINENTRY_UI_DEBUG=<file>` now answers that: inbound commands, the raw
tmux text, the pane resolved, the float asked for and returned, the terminal
drawn on, and the kind of answer sent.

Two details are decisions rather than defaults. It writes to a **file**, not
stderr, because gpg-agent discards a pinentry's stderr unless the agent has its
own `log-file` — and the agent-spawned case is the one worth tracing. And it is
also read from a token inside `PINENTRY_USER_DATA`, because gpg-agent hands a
pinentry the *agent's* environment: an env var set beside `git commit` never
arrives, while `PINENTRY_USER_DATA` is forwarded from the calling shell, which
is how `USE_CURSES` already gets here.

Rule 7 binds the trace. The agent never sends a secret *to* a pinentry, so
inbound commands are safe to record; the outbound side and the delegation relay
are where a passphrase travels and neither is traced. A `GETPIN` answer is
recorded as its character count. The pty suite types a passphrase with tracing
on and asserts the file holds the length and none of the bytes.

### Mechanics

Open the target tty (`/dev/ttysNNN` for the float, the caller's for the
in-place case) `O_RDWR`, put it in raw mode, draw, read keys, restore on every
exit path including signals. A popup cannot be resized, so there is no
`SIGWINCH` case to handle for the float; the in-place case redraws.

A terminal narrower than 57 columns gets the dialog at the terminal's width
rather than drawn off the edge of it, with a floor below which it refuses.

The holder process inside the float must keep not reading its stdin — it holds
the pane open and nothing else. Two readers on one pty would race for
keystrokes.

Editing keys are worth naming as a requirement rather than discovering later:
Backspace, `Ctrl-U`, `Ctrl-W`, `Ctrl-C`, Enter, and — because this repo sets
`extended-keys always` in tmux — unrecognised `CSI … ~` sequences must be
consumed and discarded rather than landing in the buffer as literal text.

## Build order: the dialog first, and finished

*This is what happened, and it was worth the discipline: not one UI decision had
to be unpicked from under protocol code, and the two bugs that did surface were
both in the protocol half, where a test could hold them.*

The UI was built and fully validated **before** any Assuan code existed, and the
protocol was then wrapped around a dialog that was already done. Not an
aesthetic preference — the split follows what can be judged by what:

- The **dialog** is the only part that needs a human eye. Whether it looks right
  in a float, whether the cursor sits where you expect, whether a retry reads as
  a retry, whether it survives a 60-column client — none of that is assertable,
  and all of it is cheap to change before there is protocol code shaped around
  it.
- The **protocol** is machine-checkable end to end and needs no judgement at
  all.

So the first artefact was a standalone binary that renders the dialog from
canned text — description, prompt, error, retry — reads a passphrase, and
reports *only* its length or a digest (rule 7 binds the harness too). It was run
by hand until it was right: in a plain pane, in the float, at the error state,
and against the editing keys listed above under `extended-keys always`. That
mode is kept rather than retired — `--demo` — because the dialog is still the
one part of this program no assertion can judge.

Only when the dialog was finished did the Assuan layer go around it. A protocol
bug found later is a test failure; a UI decision found later is a rewrite of
everything built on top of it.

## Build and deployment

`custom-builds/pinentry-ui/`, matching the existing entries there — a manifest,
sources, `Makefile`, `README.md`, and a `.gitignore` for the built binary.
`make install` puts it in `~/.local/libexec/pinentry-ui`; nothing in the repo
builds automatically, and that is the existing convention rather than a new gap.

Across four profiles that means four builds, on hosts of two architectures and
both platforms. Either every host builds its own — the current convention, and
`dev-shell` already provisions a Rust toolchain in bootstrap — or one host
cross-compiles for the rest, which is the concrete form of the cross-compilation
argument in the language section.

`pinentry-auto` keeps its guard shape: if `~/.local/libexec/pinentry-ui` is not
executable it falls through to `pinentry-curses`, so a host that has pulled the
dotfiles but not run `make` signs exactly as it does today. That guard is what
makes a staged rollout across profiles safe, and it is the same mechanism the
blast-radius rule in Scope depends on. `pinentry-auto` itself is macOS-only
today — Homebrew paths, a VNC probe, Touch ID — so the Linux profiles need
dispatch work of their own before any of this reaches them.

## Testing

61 examples: 40 unit, 14 through a pty for the drawing, 7 through pipes for the
protocol, plus 15 shellspec examples for the shell that opens the float.

The Assuan half needs no terminal: `tests/assuan_pipe.rs` drives the built
binary with pipes and asserts the response for each command, including the
handoff to `pinentry-curses`. Most examples count responses rather than reading
them, because the bug that ended the previous design was an off-by-one in that
count and nothing about it looks wrong from either end.

The drawing half needs a pty: allocate one, run the dialog against it, assert on
what was written and on the state the buffer ends in. This is the automated
floor underneath the by-hand pass in Build order, not a replacement for it — no
assertion tells you the dialog looks wrong.

The float half kept its shellspec coverage, now `tests/pinentry_float_spec.sh`:
the filter examples went with the filter, and the sizing examples inverted —
the caller brings a size and the shell only checks the client can take it.

Two lessons from writing these, both of which cost time and will cost it again:

- **A waiter must drain the pty as well as the pipe.** The dialog repaints in
  full on every keystroke, so watching only the Assuan pipe fills the terminal's
  output buffer and blocks the child inside a `write`. It is indistinguishable
  from a pinentry that stopped answering. The tell is that the `--demo` path,
  which has no protocol in it, fails identically in the same harness.
- **A stub helper must redirect its background jobs.** A backgrounded holder
  inherits the script's stdout, and a caller reading that pipe to end-of-file
  waits for the holder's whole life. The real `mux::pinentry_alert` carries a
  comment about precisely this, from the last time it happened.

## Open questions

1. **Does `pinentry-touchid` stay in front for the physical-console case?**
   Nothing here touches it, and the answer is presumed yes.
2. **Do the Nerd Font hint glyphs survive a bare server?** The `server` profile
   is in scope and may have no patched font, in which case the hints render as
   tofu. Assumed acceptable until one actually does; the fallback would be ASCII
   labels behind an opt-out.

## Decided

- Rust, for the reasons in the language section.

- Every curses prompt gets this dialog, agent pane or not — so it is what
  appears when signing at your own keyboard too.
- All four profiles, `work` included.
- Spawned helpers only; no PAM module.
- The dialog is built and validated before any protocol code exists.
- The ai-playbook `ask` widget is the look, reproduced to the column and to the
  hex; a retry uses its danger variant.
- The key is drawn as a labelled tree, which commits us to parsing gpg's
  description with a verbatim fallback.
- The requester gets its own section above the entry, the whole line muted when
  it is your own pane and yellow when it is not; the title stays `SETPROMPT`.
- Yellow is reserved for that one line. Anything drawn on every prompt — the key
  glyphs, now green — must use another colour, or the alert stops registering.
- The requester is named by the pill's `@win_proc` stamp and wears the pill's
  `.muxTabIcons` glyph — no new resolution machinery.
- The OSD names the requester too, capitalised and without the pane.
