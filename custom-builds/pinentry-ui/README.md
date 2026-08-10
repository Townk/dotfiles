# pinentry-ui

The password prompt for this machine: a pinentry that speaks Assuan and draws
its own dialog, in a tmux float when the pane that asked is one nobody is
watching. With `--askpass` it is the same dialog for sudo, ssh and git, which
ask for a password without speaking Assuan at all.

Design and rationale: `docs/pinentry-ui-design.md` for the pinentry,
`docs/askpass-design.md` for the askpass lane. Background on why the shell
Assuan filter it replaces could not be fixed in place: `docs/gpg-signing-ux.md`.

## State

**Live on this host.** `pinentry-auto` execs `~/.local/libexec/pinentry-ui` for
the curses lane, and the shell filter it replaces (`pinentry-mux`) is gone. The
askpass lane has authenticated a real `sudo` through the float.

Installing is a deliberate step and the guard around it is the safety net:
nothing in this repo builds automatically, so a host that has applied the
dotfiles but not run `make install` has no binary at this path and
`pinentry-auto` falls through to `pinentry-curses`. It signs exactly as it did
before any of this existed. No front-end may ever become the only way to
authenticate.

The dialog was built and validated by hand **before** any protocol code was
written. That order was the plan and it paid: the dialog is the only part a
human has to judge, the protocol is the part a test can, and wrapping the
protocol around a finished dialog meant no UI decision ever had to be unpicked
from underneath it.

## What it implements

Fourteen verbs — `SETDESC`, `SETPROMPT`, `SETERROR`, `SETOK`, `SETCANCEL`,
`SETTITLE`, `SETKEYINFO`, `SETTIMEOUT`, `OPTION`, `GETINFO`, `GETPIN`, `BYE`,
`RESET`, `NOP` — which is all of passphrase entry. The other fifteen belong to
passphrase changes, key generation and confirmation dialogs; the first one of
those we see ends the experiment and hands the whole conversation to
`pinentry-curses`, replaying everything we were told so it draws a complete
dialog.

## The askpass lane

`pinentry-ui --askpass PROMPT` is the same dialog for programs that never
learned Assuan. sudo, ssh and git share one crude convention: prompt in
`argv[1]`, secret on the helper's stdout, non-zero exit for no answer.

Two measured facts shape it, both in `docs/askpass-design.md`. There is **no
terminal** — sudo and ssh detach the helper completely, so `/dev/tty` will not
even open, and the float stops being a nicety because `display-popup` needs
`$TMUX` rather than a tty. And **`TMUX_PANE` survives** in the environment,
which is the only handle back to the mux, so the pane is looked up by id here
rather than by ttyname. With no pane at all the whole thing goes to
`pinentry-mac`, driven over Assuan by `src/gui.rs`.

Reached through the `askpass-auto` symlink, which is `pinentry-auto` wearing its
second face. There is no Touch ID rung in that lane: `pinentry-touchid` is a
keychain store for a GPG passphrase keyed by fingerprint, so it cannot produce
an account password, and PAM has already offered Touch ID upstream.

## Handing over

A `GETPIN` with no terminal to open hands over the same way, but to
`pinentry-mac`: that is a GUI app signing with no `GPG_TTY`, and it wants a
pinentry that never asked for a terminal. That handover withholds two things,
both learned by pointing it at the real binary — the `ttyname`/`ttytype` it
would try to open and fail on exactly as we did, and the `USE_CURSES` token in
`PINENTRY_USER_DATA`, which pinentry-mac obeys by re-execing a curses pinentry
and landing back in the terminal we could not find. Because of that, `pinentry-auto` sends
the VNC lane here too — viewing the desktop over Screen Sharing and typing in a
terminal used to get a GUI dialog for a request that had a perfectly good tty,
and the dispatcher cannot tell those apart because `ttyname` only arrives after
the exec.

`SETKEYINFO` and `SETTIMEOUT` are in that list because of a bug, and the shape
of it is worth keeping. Both are part of the setup gpg-agent sends before
`SETDESC` on **every** prompt; neither was implemented; so the catch-all fired
on the first real signature and quietly delegated the whole thing — putting a
curses dialog on exactly the unwatched tty this program exists to avoid. Sixty
tests were green throughout, because every one of them drove a script somebody
here had written. The fix was to stop inventing the input:
`we_answer_everything_gpg_agent_really_sends` replays the stream captured off
the wire from gpg-agent 2.5.21, and fails if anything in it reaches the
catch-all.

`SETKEYINFO` we accept and ignore — it is the keygrip, offered for pinentries
that keep passphrases in an external password manager. `SETTIMEOUT` is honoured:
it carries `pinentry-timeout` out of `gpg-agent.conf`, and the agent serialises
every pinentry on one global lock, so a prompt nobody answers does not merely
stall its own signature — it kills every request made while it sits there.
Timing out answers `(Pinentry, Timeout)` and releases the lock.

Every response was measured against `pinentry-curses` 1.3.3 rather than
recalled, by driving it with pipes and a pty: the greeting wording, `D`-then-`OK`
for a data reply, `%25` for a per cent in the passphrase, and the error numbers.

The rule the whole protocol layer serves is **one response per command, never
one more**. A surplus `OK` is read by the agent as the answer to the next
command, and when that is `GETPIN` the answer is an empty result — "No
passphrase given" — while a perfectly good dialog sits on screen. That is what
killed the filter, and it is why the filter could not be repaired: it did not
own the response direction, so it could rewrite a line but never add one.

## The look

It is the ai-playbook `ask` widget, reproduced rather than invented, so a
passphrase prompt looks like every other question the toolchain asks:

```
╭───────────────────────────────────────────────────────╮
│                                                       │
│  ▓▓▓ Passphrase                                       │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│                                                       │
│  Please enter the passphrase to unlock the OpenPGP    │
│  secret key:                                          │
│                                                       │
│  "Example Key <key@example.invalid>"                  │
│   ├ 󰌾 4096-bit RSA key                                │
│   ├ 􏊻 ID 0123456789ABCDEF                             │
│   ╰ 󰃭 created in 2020-01-01                           │
│                                                       │
│  􎡡 requested by claude · pane %3 (Main:2)             │
│                                                       │
│  ╭─────────────────────────────────────────────────╮  │
│  │ 􏂄 •••••••                                       │  │
│  ╰─────────────────────────────────────────────────╯  │
│                                                       │
│  󰌑 submit · 󰘴 U clear · 󱊷 cancel                      │
╰───────────────────────────────────────────────────────╯
```

The geometry comes from `pkg/dialog/frame.go` and `field_text.go` in that repo:
57 columns, 2 columns of horizontal padding, one row of top padding and none at
the bottom (the hints sit on the border), one blank row between sections, and an
entry box the full 51-column interior with a 1-column pad and a 3-column icon
gutter. The colours are the same hexes too, reached through this repo's own role
names — `UI_BORDER_FOCUS`, `UI_TITLE`, `UI_SEPARATOR`, `UI_FG`, `UI_BORDER`,
`UI_KEY`, `UI_OVERLAY` and a `UI_DIALOG_BG` card fill — so both dialogs follow a
theme switch together.

A retry takes the danger variant: `--error` turns the border and the title
`STATE_ERROR` red and adds the message above the entry box.

The line above the entry names who asked. It is muted when the request came
from the pane you are attached to and attention-yellow when it did not, which
is the only reason it is worth a row. Both come from the `ttyname` gpg-agent
sends: `requester.rs` maps it to a pane, and takes the name from that pane's
`@win_proc` stamp rather than `#{pane_current_command}` — tmux names a pane
after a process it picks from the foreground process group, and on macOS that
is `node` for every agent. "Being watched" needs the session attached, the
window current *and* the pane focused; every window has an active pane, so
testing `pane_active` alone would call a background window watched. `--demo
--requester NAME [--elsewhere]` forces either state for a look.

That query's fields are separated by `|`, and the reason is worth knowing before
anybody "tidies" it back to a tab. tmux runs its output through `utf8_sanitize`
when the locale is not UTF-8, turning every non-printable byte into `_`, and
gpg-agent gives a pinentry no `LANG` or `LC_*` whatsoever. With tabs, every line
arrived as a single field, no pane matched, and the prompt fell back to the
unwatched pane it was supposed to rescue — silently, because falling back is a
supported outcome rather than an error.

Its glyph is the requester's **tab icon**: `icons.rs` looks the name up in
`~/.config/mux/tab-icons.data`, a chezmoi projection of the `.muxTabIcons`
table that already paints the tmux pills and zj-hud. So `claude` wears
`fa-claude`, `agent` wears `usr-cursor-ai`, and anything unlisted wears the
generic `nf-md-run`, exactly as that pane's pill would. A host that has never
run `chezmoi apply` has no table and gets the generic glyph rather than no
dialog.

The key block is parsed out of gpg's own description, which it assembles from
`"%.*s"` / `%u-bit %s key, ID %s,` / `created %s%s.`. The clauses keep gpg's
wording exactly — rewriting "created 2020-01-01" into something that reads
better would be splicing English into a string that may already have been
translated — and any description that does not have that shape is drawn
verbatim, which is what the stock pinentry does and is never wrong, only
plainer.

Departures from the reference, each forced by what this dialog is. The entry is
masked, drawn from a character count rather than from the buffer, and its gutter
holds a key rather than the `❯` of a command prompt. The hint line gains a
`clear` segment, because unlike a text prompt this one has no visible content to
select and retype, and it follows the `pick::hints` shape the rest of the repo
uses — chord written `󰘴 U`, NBSP between key and label. And the key is laid out
as a tree under its user ID, its glyphs in green, instead of the run-on
sentence gpg words it as.

Yellow is spent on exactly one thing — a request from a pane you are not
attached to — and nothing that is drawn on every prompt is allowed to use it, or
it would stop being noticed long before the day it matters.

Glyphs are checked against `~/.local/share/fonts/nerd-font/symbols.db` — the
symbol table for the font this repo builds — and written as `\u{…}` escapes so
they survive editors that drop private-use characters. The `0x10xxxx` ones are
Font Awesome 7, which that build relocates to `0x100000 + native` so it does not
clobber the Nerd Font copy of FA.

## Try it

The dialog on its own, from canned text, reporting *about* what it read:

```sh
make build
./target/release/pinentry-ui --demo                       # in this pane
./target/release/pinentry-ui --demo --error 'Bad Passphrase (try 2 of 3)'
./target/release/pinentry-ui --demo --requester claude
./target/release/pinentry-ui --demo --requester claude --elsewhere
./target/release/pinentry-ui --demo --requester some-unlisted-tool --elsewhere
./target/release/pinentry-ui --demo --no-frame            # as it looks in a float
tmux display-popup -w 57 -h 18 -E './target/release/pinentry-ui --demo --no-frame'
```

`--no-frame` is for the float: tmux draws a themed rounded border of its own
(`popup-border-lines rounded`), and two borders is one too many. In a plain pane
the dialog draws the border itself. The interior works out the same either way —
a 57-column popup leaves a 55-column pty, and dropping our own border leaves the
same 51-column content width the framed dialog has.

It reports what it read without revealing it — byte count, character count, the
canvas the dialog wanted, and whether the buffer could be locked:

```
accepted: 7 bytes, 7 characters, canvas 57x19, mlock yes
```

Nothing prints the passphrase, here or anywhere. The rule binds the harness as
much as the dialog: if a future test needs to confirm exact content, it compares
a digest.

With no arguments it is the real thing, and can be driven the way gpg-agent
drives it:

```sh
printf 'GETINFO version\nOPTION ttyname=/dev/ttys002\nSETPROMPT Passphrase\nBYE\n' |
  ~/.local/libexec/pinentry-ui
```

## When it goes to the wrong place

Both bugs found on live signatures were routing bugs that fail as a *fallback*
rather than as an error: the prompt appears, just not where it should. There is
nothing to read afterwards, so set `PINENTRY_UI_DEBUG` to a file and do it
again.

```bash
# Any invocation you drive yourself.
PINENTRY_UI_DEBUG=/tmp/pui.log pinentry-ui < /dev/null

# A real signature. The token goes in PINENTRY_USER_DATA, beside USE_CURSES.
PINENTRY_USER_DATA='USE_CURSES=1,PINENTRY_UI_DEBUG=/tmp/pui.log' git commit -S
```

The second form is the one that matters and the reason the token channel
exists. gpg-agent hands a pinentry the *agent's* environment, so
`PINENTRY_UI_DEBUG=… git commit` never reaches this program and tracing a real
signature would otherwise mean restarting the agent. `gpg` does forward
`PINENTRY_USER_DATA` from the calling shell — that is already how `USE_CURSES`
arrives — so the token rides in with it.

What you get is every inbound command, the raw text tmux returned, the pane it
resolved to, whether a float was asked for and what came back, which terminal
was drawn on, and the kind of answer sent. Both shipped bugs are a single line
in that list: a `delegating: SETKEYINFO is not ours`, and a `panes=` whose
fields are joined by `_`.

The file is created `0600` and appended to, so a run of prompts reads as one
story. Nothing on the outbound side is traced and neither is the delegation
relay, because those are where a passphrase travels;
`the_trace_records_the_routing_and_never_the_passphrase` types one and asserts
the file holds its length and not its bytes.

## Layout

| | |
| --- | --- |
| `src/secret.rs` | the passphrase buffer: fixed capacity, `mlock`ed, wiped, and deliberately not printable |
| `src/hardening.rs` | process-wide protections applied before any key is read |
| `src/term.rs` | opening the terminal, raw mode, and giving it back on every exit path |
| `src/dialog.rs` | layout, drawing, and the key loop |
| `src/theme.rs` | colours from the generated palette |
| `src/icons.rs` | the requester's glyph from the generated tab-icon table |
| `src/assuan.rs` | the protocol: the line loop, the state buffer, the fourteen verbs |
| `src/debug.rs` | the optional trace, and the rule that it never holds a passphrase |
| `src/keyinfo.rs` | gpg's description parsed into the key tree, verbatim when it does not fit |
| `src/requester.rs` | which pane asked, what it is running, and whether anyone is looking |
| `src/float.rs` | opening the tmux float, and making sure it closes |
| `src/prompt.rs` | the join: where the dialog goes, how big, and what comes back |
| `src/delegate.rs` | handing the conversation to another pinentry, in step |
| `src/askpass.rs` | the same dialog for sudo, ssh and git: prompt in argv, secret on stdout |
| `src/gui.rs` | the one place we are an Assuan *client*, driving `pinentry-mac` |
| `tests/dialog_pty.rs` | the dialog driven through a real pty |
| `tests/assuan_pipe.rs` | the protocol driven through pipes, as gpg-agent does |
| `tests/askpass.rs` | the askpass lane driven the way sudo drives it |

## Tests

`make test` runs `cargo fmt --check`, `clippy -D warnings`, the unit tests and
the pty suite.

The pty suite is where the interesting coverage is, because it checks the half
of the program the eyeball pass cannot: whether the bullets on screen correspond
to the bytes in the buffer. `escape_sequences_never_reach_the_buffer` is the
regression test for a real failure — under tmux's `extended-keys always` a
modified keypress arrives as a CSI sequence, and a dialog that only asks "is
this byte printable" stores the tail, so a typed `1234` reached gpg as
`1234[27;8;49~`. Delete the escape branch in `dialog.rs` and that example
reports 17 bytes instead of 4.

Two examples run the dialog on a terminal it **owns** — its own session, the pty
claimed with `TIOCSCTTY`, opening `/dev/tty` for itself — rather than being
handed a path. That is not redundancy with the two beside them. macOS `poll`
answers correctly for a pty slave opened by path and returns `POLLNVAL` for the
controlling terminal, so Esc was dead in tmux for as long as
`a_lone_escape_cancels` was green;
`a_lone_escape_cancels_on_a_controlling_terminal` was checked to fail against
the `poll` implementation and pass against `select`, and its neighbour pins the
other half — an arrow key must *not* cancel, which is what stops the bug being
"fixed" by treating every Esc as a cancel.

Two others replay the escape stream onto a grid and assert on the result,
because checking the text is not checking the layout: the dialog once emitted
every string it should have while drawing at row 45 of a 30-row screen, and
later parked the cursor a row below the entry box. Allocating a terminal is
serialised behind a mutex — `openpty` and `ttyname` are both non-reentrant on
macOS, and under parallel threads the first fails spuriously with a garbage
errno while the second hands back a path another thread is overwriting.

`tests/assuan_pipe.rs` drives the built binary over pipes, which is exactly how
gpg-agent talks to it. Most of it counts responses rather than reading them,
because the bug that ended the previous design was an off-by-one in that count
and nothing about it looks wrong. Two examples matter beyond that:

- `an_unimplemented_verb_is_handed_over_in_step` checks both halves of the
  handover — a stub pinentry records that it was told everything we had
  absorbed, and the agent sees exactly one response per command across the
  seam.
- `a_killed_pinentry_still_takes_its_float_with_it` covers the exit path that
  `Drop` cannot. It failed when written: gpg-agent killing its pinentry left
  the holder alive and a float on screen that swallowed every keystroke and
  answered to nothing — worse than the invisible prompt the project exists to
  fix. tmux and the popup helper are stubbed, with the test's own pty standing
  in for the float.

One trap, since it will be hit again by anyone extending these: **waiting means
draining the pty too.** The dialog repaints in full after every keystroke, so a
waiter watching only the Assuan pipe fills the terminal's output buffer and
blocks the child inside a `write` it never finishes. It looks precisely like a
pinentry that stopped answering — the demo path, which contains no protocol at
all, fails the same way in the same harness.
