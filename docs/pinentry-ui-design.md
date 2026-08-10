# A pinentry we own — design

Status: **proposal, not built.** `docs/gpg-signing-ux.md` describes what ships
today: a shell Assuan filter that retargets `pinentry-curses` into a tmux float.
This file is the design for replacing that pair with one program that speaks
Assuan and draws its own dialog. Read the other file first; this one assumes it.

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

## Shape

One binary, `pinentry-ui`, invoked by `pinentry-auto` in place of today's
`pinentry-mux` + `pinentry-curses` pair. It is a pinentry: Assuan on stdin and
stdout, no arguments that matter.

```
gpg-agent  <--Assuan-->  pinentry-ui  --draws on-->  float pty   (agent pane)
                                      --draws on-->  caller pty  (everything else)
```

The float is still opened by `pinentry-mux-popup --open`, unchanged. It already
resolves the tty to a session, picks the most recently active client, checks the
client is big enough, opens a non-dismissable popup, fires the OSD alert, and
hands back `"<popup_tty> <holder_pid>"`. None of that logic is about Assuan and
none of it needs rewriting — the only difference is that the caller now passes
an exact `w h` it computed from its own layout instead of a guess.

`pinentry-mux` (the shell filter) goes away entirely. So does the watcher that
ties the float's lifetime to the dialog: one process owns both, so the float
closes in a `defer`.

## The protocol surface, and what we refuse to implement

29 verbs exist. Passphrase *entry* — the whole reason this project exists — uses
a small subset, and the rest belong to passphrase changes, key generation and
confirmation dialogs.

Implement: `SETDESC`, `SETPROMPT`, `SETERROR`, `SETOK`, `SETCANCEL`, `SETTITLE`,
`OPTION`, `GETINFO`, `GETPIN`, `BYE`, `RESET`, `NOP`.

Delegate everything else — `CONFIRM`, `MESSAGE`, `SETREPEAT`, `SETQUALITYBAR`,
`SETGENPIN` and friends — by spawning the real `pinentry-curses`, replaying the
buffered state to it, and relaying both directions until the connection ends.
Two things make this safe here and unsafe in the filter: we own the response
direction, so the extra `OK`s our replay produces are ours to consume; and we
have not answered anything yet, so nothing is out of step.

That fallback is also the general safety net. No tmux, no agent behind the tty,
a client too small, a float that will not open, a verb we do not know — every
one of them ends at the prompt we have today. Degrading is always allowed;
wedging the agent is not.

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

### What Go makes harder, and the shape that answers it

Go is chosen for zeroable buffers and for having no runtime dependency inside
gpg-agent's minimal, mise-less environment. It brings three hazards that are not
obvious:

- **Strings are immutable and cannot be zeroed.** The passphrase must live in a
  `[]byte` and never become a `string` — not for a length check, not for an
  error message, not for a `fmt` verb.
- **Goroutine stacks are grown by copying.** A secret in a stack local can be
  duplicated to a new stack with the old copy left behind for the collector.
- **The heap is non-moving today, but that is an implementation detail** of the
  current collector, not a language guarantee. It is not a thing to build a
  security property on.

One decision answers all three: allocate the buffer with an anonymous `mmap`
*outside* the Go heap, `mlock` it, use it, zero it, `munlock`/`munmap`. It is
GC-proof, stack-copy-proof and swap-proof, and it is the same code on both
platforms (`golang.org/x/sys/unix`, already an indirect dependency of the two Go
programs in `custom-builds/`).

Around it:

- `RLIMIT_CORE = 0` on both platforms.
- On Linux, `PR_SET_DUMPABLE = 0` (which also denies same-uid ptrace, closing
  the row above) and `MADV_DONTDUMP` on the buffer. macOS has neither; the
  core-dump limit carries it there.
- If `mlock` fails — the Linux `RLIMIT_MEMLOCK` case — say so on stderr and
  continue. Refusing to prompt would fail the signature to protect against a
  weaker threat than the one we would create.
- **No reveal toggle.** tmux keeps a popup's screen contents in the server and
  `capture-pane` can read a pane's, so the passphrase must never be drawn.
  pinentry's "make visible" feature is deliberately not reimplemented.
- No panics on the secret's path: recover at the top of `GETPIN` and answer
  `ERR` rather than let the runtime print a goroutine dump into gpg-agent's log.

The residual risk after all that is our own bugs, not memory management — a
debug print, a wrong variable in an error path. So the secret's code path stays
tiny and reviewable: read bytes from the tty, percent-encode, write one `D`
line, zero the buffer. Layout, colour, Assuan bookkeeping and the float never
touch it.

## Drawing

Open the target tty (`/dev/ttysNNN` for the float, the caller's for the
in-place case) `O_RDWR`, put it in raw mode with `golang.org/x/term`, draw, read
keys, restore on every exit path including signals. A popup cannot be resized,
so there is no `SIGWINCH` case to handle for the float; the in-place case
redraws.

The holder process inside the float must keep not reading its stdin — it holds
the pane open and nothing else. Two readers on one pty would race for
keystrokes.

Editing keys are worth naming as a requirement rather than discovering later:
Backspace, `Ctrl-U`, `Ctrl-W`, `Ctrl-C`, Enter, and — because this repo sets
`extended-keys always` in tmux — unrecognised `CSI … ~` sequences must be
consumed and discarded rather than landing in the buffer as literal text.

## Build and deployment

`custom-builds/pinentry-ui/`, matching `pty-frame` and `tm-timeline` exactly:
`go.mod`, `main.go`, `Makefile`, `README.md`, and a `.gitignore` for the built
binary. `make install` puts it in `~/.local/libexec/pinentry-ui`; nothing in the
repo builds automatically, and that is the existing convention rather than a new
gap.

`pinentry-auto` keeps its guard shape — if `~/.local/libexec/pinentry-ui` is not
executable it falls through to `pinentry-curses`, so a host that has pulled the
dotfiles but not run `make` signs exactly as it does today. Linux is designed
for (portable syscalls, no Homebrew paths in the Go code) but not shipped or
tested in this round; `pinentry-auto` itself is macOS-only today and would need
its own dispatch work first.

## Testing

The Assuan half is testable without a terminal: drive the binary with pipes and
assert the response for each command, including one example per delegated verb
that asserts the handoff to `pinentry-curses` stays in step. That is the class of
bug that cost the last session, and unlike the filter it is now fully
observable, because we produce both directions.

The drawing half needs a pty: allocate one, run the dialog against it, and
assert on what was written and what the buffer ends up containing. `pty-frame`
already depends on `creack/pty` for this.

The float half is already covered by `tests/pinentry_mux_spec.sh` and does not
change.

## Open questions

1. Does the in-place (non-agent) prompt get our UI too, or stay
   `pinentry-curses`? "Every curses prompt" was the answer, so: ours — but that
   means our dialog is what appears when you sign at your own keyboard, and a
   bug there is felt everywhere rather than only in agent panes.
2. How much UI? A themed rounded border matching the popup options is the stated
   goal; a quality bar, a title, and colour beyond a two-colour tint are all
   possible and all cost.
3. Does `pinentry-touchid` stay in front for the physical-console case? Nothing
   here touches it, but it is worth stating that the answer is yes.
