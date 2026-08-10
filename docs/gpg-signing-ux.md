# GPG signing UX — plan

> **Status**: implemented (option A) and verified on both hosts — the laptop
> against nested tmux servers and a throwaway key, and `mac-mini`, the host it is
> actually for, against the real signing key and a live agent pane. Sections
> below were corrected in place where a measurement contradicted the design —
> those corrections are marked **Measured**. Public repo; no employer/work
> identifiers. The personal Mac mini is `mac-mini` where a concrete host name is
> needed.

---

## Problem

Two signing annoyances, on two different hosts, that turn out to be the same
dispatch decision seen from opposite sides.

**On `mac-mini`, agent work stalls.** An AI coding agent driven over SSH inside
tmux signs commits (`commit.gpgsign=true`). When the passphrase is not cached,
`gpg-agent` runs `pinentry-auto` → `pinentry-curses` (`pinentry-auto:42-44`),
which draws on the **caller's** tty — the agent pane's pty, which nobody is
looking at. The prompt parks. The `gpg-check` alias
(`aliases.d/personal.sh:40`) does not rescue it: the parked pinentry must be
killed first, and a retry in the meantime forces another kill.

**On the Linux dev-shell, Touch ID never fires.** That host is keyless and
consumes the laptop's forwarded gpg-agent, so the passphrase prompt is served by
the **laptop's** agent — where Touch ID is available and should be used. It
isn't, because the remote shell tells the agent to use curses.

Both trace to `PINENTRY_USER_DATA=USE_CURSES=1`, exported by every SSH shell at
`environment.sh:111-115` and forwarded to whichever agent serves the request.

---

## One variable, four outcomes

The end state is a single dispatch tree. Two of these leaves work today; two are
the work below.

| Situation | `USE_CURSES` | Prompt | Status |
|---|---|---|---|
| Sitting at a Mac | unset (no SSH triple) | Touch ID locally (`pinentry-auto:50`) | works |
| SSH'd to the keyless dev-shell | unset by Part 2 | Touch ID on the laptop | **Part 2** |
| SSH'd to `mac-mini`, agent pane | set | mux floating popup | **Part 1** |
| SSH'd to `mac-mini`, human pane | set | in-pane curses | works |

The mini holds the signing key and runs its own agent, and deliberately does
**not** consume a forwarded one; the dev-shell is keyless and does. That
asymmetry is why rows two and three differ, and it is a fixed constraint here,
not something this plan revisits.

---

## Root cause of the parked prompt

Three mechanisms stack.

**TTY routing.** Each `gpg` client hands the agent its terminal —
`dot_zshrc.tmpl:207` sets `GPG_TTY=$TTY` — so pinentry targets the pane that
invoked it. For an agent that is a pty with no human attached.

**Agent context.** `gpg-agent` is a launchd daemon
(`services.toml.tmpl:155-158`, inside the darwin block at `:46`) with no mux
environment of its own, and it execs `pinentry-program` in a minimal env
(`pinentry-auto:1-6`). Where pinentry draws is determined entirely by the Assuan
`OPTION ttyname=` the agent sends, independent of pinentry's stdio — verified by
piping `OPTION ttyname=/dev/null\nBYE\n` into `pinentry-curses`, which answers
`OK`. `pinentry-curses --help` also exposes `-T, --ttyname` and `-N, --ttytype`.
So a wrapper that can name a *visible* tty can put the prompt anywhere.

**Serialization, with a ceiling.** GnuPG's agent takes a global `entry_lock`;
upstream states that `start_pinentry` "must always be used to acquire the lock
for the pinentry - we will serialize _all_ pinentry calls"
(`agent/call-pinentry.c`). The wait is bounded: the lock is taken with
`npth_mutex_timedlock` against `#define LOCK_TIMEOUT (1*60)`
(`agent/call-pinentry.c:54`, `:333-345`), so a queued request fails with
`GPG_ERR_TIMEOUT` rather than hanging.

**Measured** (gpg 2.5.21, two agent panes, first prompt left unanswered): the
queued request died after **~120 s**, not ~60 s, and the client reported
`gpg: signing failed: Timeout`. The string "failed to acquire the pinentry
lock" never reached gpg's stderr — expect it in the agent's log, not the
client's. The error *class* is as designed; the number and the message in the
original plan were wrong. The first prompt still completed normally afterwards
and no float was leaked.

That last detail is the operator-visible symptom, and it reframes the goal: a
retry does not hang forever, it *dies a minute later and leaves the flow
half-done*. Nothing can make the queue pleasant. The only thing worth
engineering is that the **first** prompt is always answerable.

`gpg-agent.conf` today carries only cache TTLs and `pinentry-program`
(`private_gpg-agent.conf.tmpl:1-5`) — no `pinentry-timeout`, no
`allow-preset-passphrase` (both per `man gpg-agent`).

---

## Existing primitives

`pinentry-auto:42-50` (dispatch seam); `mux/tmux.zsh:207` (`_mux_tx_popup`) and
`:377` (`display-popup -E -B`, plus the HI-7 blocking note at `:368`);
`mux/dialog.zsh:83-90` (the shared modal chrome); `mux/zellij.zsh:327-343`
(pinned floats); `mux-bootstrap.zsh` (`mux::backend`, `mux::is_remote`);
`common.zsh:173` (`common::tmpfile`); `mux.yaml:15` (default backend **tmux**);
`tests/mux_float_launch_spec.sh` (fifo-rendezvous launch pattern).

Most importantly, `keymap-base.conf.tmpl:158` already answers "is this tty an
agent?" with a probe that needs no tmux at all:

    ps -o state= -o comm= -t '<tty>' | grep -iqE '^[^TXZ ]+ +(\S+\/)?(cursor-)?agent(\.exe)?$'

Since the wrapper is handed the caller's tty directly, it can run that probe on
the ttyname it already has. tmux is then needed only to locate the *session* to
open the popup in — not to make the agent/human decision.

Note the probe matches `agent` and `cursor-agent` only, while `mux.yaml:83-88`
lists a broader hidden-process set (`claude`, `pi`, `pi-coding-agent`). Pick one
list and share it; the narrower regex will silently miss those agents.

**Done.** `.chezmoidata/mux.yaml` now carries `muxAgentProcs`, and the name
alternation in both the keymap probe and `pinentry-mux` is generated from it, so
neither can drift. `muxHiddenProcs` stays separate — same five names today, but
it answers "which commands can tmux not name?", which a non-agent node CLI could
join tomorrow. Zellij's `when agent,cursor-agent:` context-keys clause is still
hand-written and is the one remaining copy; it is a plugin payload rather than a
regex, and widening it changes key routing in a backend this work never
exercised. Follow-up, deliberately.

---

## Part 1 — the mux popup for agent panes

### A. Assuan filter + on-demand popup — recommended

Replace the bare `exec pinentry-curses` on the `USE_CURSES` path with
`pinentry-mux`: a POSIX-sh wrapper (same constraint as `pinentry-auto:1-6`) that
reads the leading Assuan `OPTION` lines, runs the agent probe on the caller's
`ttyname`, maps that tty to a tmux session
(`tmux list-panes -a -F '#{pane_tty} #{session_name} #{pane_id}'`), opens a
non-dismissable float in that session, rewrites `OPTION ttyname=` to the popup
pane's `#{pane_tty}`, and proxies the remaining protocol to the real
`pinentry-curses` until `BYE`.

**Measured — rewrite the line; never insert one.** Assuan is strictly
synchronous, one response per command, and pinentry answers the agent directly:
its stdout IS ours, so a reply this filter did not ask for cannot be swallowed
again on the way back. An injected `OPTION ttyname=` therefore leaves a surplus
`OK` in the stream, and the next thing the agent reads it as is the answer to
`GETPIN` — a result carrying no data, which IS "No passphrase given". The agent
hangs up while pinentry is still drawing a perfectly good dialog, so every
signature fails and the float looks blameless. This was tried for real, to buy
the sizing described below, and cost a session to track down. One command in,
one command out is the only shape this filter can have; anything that needs to
tell pinentry something the agent did not say needs a different design, not
another line here.

**Pass-through is the safety net.** No tmux, no pane match, or a non-agent pane
→ `exec pinentry-curses` unchanged. Every failure mode degrades to today's
behavior rather than to a broken prompt.

**Blocking.** `display-popup -E` blocks its invoker (`tmux.zsh:368`), so the
popup must be spawned from a helper subprocess with a fifo rendezvous (the
pattern in `tests/mux_float_launch_spec.sh`), keeping the Assuan proxy in the
main wrapper.

**Measured — aim the popup with `-c`, not `-t`.** With no `$TMUX` in a
launchd-spawned process the wrapper does resolve the default socket, but
`-t "=$session:"` (`tmux.zsh:213`) is **not** enough to choose the screen: with
two sessions each holding their own client, `display-popup -t '=B:'` painted on
the client attached to session A. tmux resolves a popup's client from the
*current* client and uses `-t` only for context; `man tmux` says the popup runs
"on target-client", which is `-c`. `-c <client>` was exact every time. So the
spawner resolves the session from the pane tty, then the attached client from
the session, and passes `-c`.

**Measured — the two commands invert.** For reading a client's size it is the
other way round: against a 120x40 client and a 64x18 one,
`display -p -t <client>` reported each client's own size while
`display -p -c <client>` reported the current client's for both. Popup: `-c`.
Size: `-t`. Swapping either silently targets the wrong screen.

**Measured — the dialog's size is knowable, but not from here.** pinentry draws
its own framed box and centres it, so the generous float leaves the dialog
adrift in a half-empty pane — 65x11 of content in a 78x16 box. The arithmetic
is not the hard part, and it is recorded here so nobody re-derives it:
`width = max(56, longest line + 4)`, `height = SETDESC lines + 6`, two rows more
once `SETERROR` is set, where lines are the `%0A`-separated fields (counting the
empty one the real description leaves after its trailing separator) and each
`%XX` escape is one character. The canvas needs one column MORE than the dialog
but EXACTLY its height: at equal width pinentry keeps the frame, drops an inner
column and wraps into a row nobody budgeted for; one row short and it refuses
with `ERR … Screen or window too small`.

What makes it unreachable is timing, not arithmetic. `SETDESC` arrives 23
commands after the `OPTION ttyname=` the float has to be opened from, `tmux 3.7b`
takes `-w/-h` only when the popup is created and has no command that resizes an
open one (`resize-pane`/`resize-window` target panes and windows), and telling a
live pinentry to move to a differently-sized float needs the extra `OPTION` that
the finding above rules out. Undersizing has no safety net either, since
pinentry's error goes to the agent without passing through the filter. So the
box stays generous, and the way to a snug dialog is to own the dialog — see
`docs/pinentry-ui-design.md`.

**Measured — "a client" is not enough; it has to be the live one.** One session
can hold several clients, and since a popup paints only on the client it is
aimed at, the choice among them *is* the feature. Found on the mini's real
session: two clients on `Main`, one last active a second earlier and one
abandoned twelve hours before, with tmux listing the stale one first. Taking the
first match would have painted the passphrase prompt on a dead screen — this
plan's own complaint, reproduced by the fix for it. `client_activity` is the
only signal available, so the most recently active client wins.

### How far the dialog itself can be customised

Asked and measured, so it does not have to be investigated again. The float is
cut to the dialog above; these are the options for the dialog *inside* it.

**Colour: yes, but coarse.** `pinentry-curses -c FG,BG,SO` works — `cyan,black`
produced `[36m`/`[40m` in a capture — and since the filter is what spawns
pinentry, argv is ours to set. Two limits: one foreground and one background
apply to the *whole* dialog, frame, text and both buttons alike, so it is a tint
rather than per-element theming; and the third "standout" slot produced no
visible change in any render. Only palette names are accepted (`blue`,
`bright-red`, …), not hex, which is arguably right — they follow the terminal
palette. It is argv-only: `OPTION colors=` is answered `ERR … Unknown option`.

**Owning the whole UI: possible, at a price.** Nothing stops the filter from
answering `GETPIN` itself and drawing anything, including the themed rounded
border the popup options already define and that `-B` currently suppresses. Two
costs. The command surface is 29 verbs — `SETREPEAT`, `SETQUALITYBAR`,
`SETGENPIN`, `CONFIRM`, `MESSAGE` and the rest are what passphrase *changes* and
key generation use — so a sane version implements `GETPIN` and delegates the
others. And pinentry keeps the passphrase in locked secure memory (verified:
`nm -u` on the binary shows it references `mlock` and `mmap` directly), which a
replacement has to reproduce rather than inherit — reading it with `read` in a
shell would put it in ordinary swappable memory.

This is the direction chosen. `docs/pinentry-ui-design.md` carries the design
and the argument for why the memory protection survives the move.

### B. Dedicated long-lived pinentry pane

A persistent pane whose tty agent shells export as `GPG_TTY`. No Assuan work,
but the agent still sends `OPTION ttyname=` from the gpg client's own tty, so a
`GPG_TTY`-only redirect only works when every agent shell cooperates — and a
tiled pane is not a floating modal, so it needs recreate-on-session hooks to
survive. Simpler to build, weaker guarantee.

### C. Alerts alone

A bell, `display-message`, or the Hammerspoon OSD (`tmux-alert-notify:42-48`,
itself a no-op over SSH) can surface that a prompt is waiting but cannot accept
a passphrase. Useful as an addition to A, not a substitute.

### The gate

Fire the popup only when **all** hold: `PINENTRY_USER_DATA` contains
`USE_CURSES`; the caller tty passes the agent probe; and a tmux server is
reachable with a pane matching that tty. Human SSH panes keep in-pane curses;
the Touch ID and VNC branches (`pinentry-auto:46-50`) are untouched.

Scope v1 to **tmux only** — it is the baked default (`mux.yaml:15`) — and to
darwin hosts where `pinentry-auto` is the `pinentry-program`
(`private_gpg-agent.conf.tmpl:3-5`). Zellij needs its own pane-tty discovery and
can follow.

### Hard questions

**Popup over SSH.** Coherent: the tmux server runs on the mini and the popup
paints for the attached client, exactly as the pickers do. A detached session
with no client cannot paint — that is an HI-7-class failure, and it must fall
back to pass-through rather than hang.

**Concurrency.** Only one popup can exist, because the agent serializes on
`entry_lock`. A second request fails on the lock timeout rather than hanging —
**measured at ~120 s with `gpg: signing failed: Timeout`**, see the correction
above. The `pinentry-timeout` backstop below does not change that: it buys *you*
time to walk back and answer the first prompt, while anything queued behind it
dies regardless.

**No mux at all.** `ssh mac-mini 'gpg --clearsign'` has no pane; pass-through
applies and one-shots remain as broken as today. Documented, not fixed: use tmux
for agent work.

**Security.** The passphrase is typed into a pane, so `capture-pane` and
`mux::dump_screen` (`tmux.zsh:153-156`) could capture the viewport mid-entry —
avoid calling them from the popup path. Fifos at `0600` via the `common.zsh:173`
scratch discipline. Otherwise no worse than in-pane curses today.

**If you never come back.** `pinentry-timeout` fails the operation and releases
`entry_lock`, so the next request is served normally.

---

## Part 2 — the dev-shell stops claiming `USE_CURSES`

Export `PINENTRY_USER_DATA` only when remote **and** `gpg.conf` lacks
`no-autostart` (`environment.sh:111-115`; `GNUPGHOME` is already set at `:16`).
`no-autostart` is the existing marker for "this host never runs its own agent
and consumes a forwarded one" (`gpg.conf.tmpl:12-18`), so it is exactly the
right discriminator and needs no new data flag.

**Why the two parts do not collide.** Part 1 keys the popup on `USE_CURSES`
being present; Part 2 removes it. They are disjoint because the mini has no
`no-autostart` — it runs its own agent — so it keeps `USE_CURSES` and Part 1's
gate still fires. The dev-shell loses `USE_CURSES` and reaches Touch ID on the
laptop, which is correct there: its pinentry runs on the laptop, where a mux
popup on the remote host would be the wrong screen entirely.

---

## Implementation

1. `home/dot_local/libexec/executable_pinentry-mux.tmpl` — POSIX-sh Assuan
   filter and proxy; agent probe on the caller ttyname; `exec` pass-through when
   any gate fails. A template because it bakes the shared agent-name list.
2. `home/dot_local/libexec/executable_pinentry-mux-popup` — zsh, both halves:
   `--open` (spawner, called by the filter) and `--hold` (run inside the float
   by `display-popup -E`).
3. `home/dot_local/lib/mux/pinentry.zsh` — session lookup, client resolution,
   sizing, popup spawn with the fifo rendezvous and a launch-failure guard, and
   the OSD.
4. `home/dot_local/libexec/executable_pinentry-auto` — the `USE_CURSES` branch
   dispatches to `pinentry-mux`; other branches unchanged.
5. `home/dot_config/private_gnupg/private_gpg-agent.conf.tmpl` — add
   `pinentry-timeout 900`.
6. `home/dot_config/zsh/environment.sh` — Part 2's `no-autostart` condition.
7. `home/.chezmoidata/mux.yaml` — `muxAgentProcs`, the shared list.

### What the plan got wrong here

**The float publishes `tty`, not `#{pane_tty}`.** A popup does not appear in
`list-panes` and `#{pane_tty}` inside it reports the *originating* pane, so the
holder has to ask its own stdin: `tty`. That is why `--hold` exists at all.

**It does not wrap `_mux_tx_popup`.** That helper defers to the server with
`run-shell -b`, which returns immediately and so yields no launch verdict, and
it aims with `-t`. Both are wrong here. The spawner calls `display-popup`
directly, in the shape `_mux_tx_pick_float` (`tmux.zsh:377`) uses.

**Non-dismissable means trapping signals.** Escape, `q`, `x` and Space are all
consumed by the pinentry dialog, but Ctrl-C reaches the float's foreground job
and killed it, leaving pinentry drawing on a tty that no longer existed — a
15-minute wedge under `pinentry-timeout`. `--hold` ignores INT/TERM/HUP/QUIT and
takes USR1 as a private close channel from the filter. Its traps are armed
*before* it publishes its pid, or a fast close lands on USR1's default
disposition and kills it.

**…and so the float must not outlive the dialog.** Teardown was tied to the
filter's EXIT trap, which fires when the agent closes our stdin. For a
*correct* passphrase that is the same moment — gpg-agent hangs up at once — so
it looked right on both hosts. Reject one and the two come apart: pinentry
exits on `BYE` while gpg-agent keeps the connection, the filter blocks in
`read` with nothing left to wake it, and the float stays on screen ignoring
every signal a keystroke can send. Measured by driving the pre-fix filter with
stdin held open behind the hang-up: still standing after 8s, and only a
SIGKILL ended it. A terminal the human cannot reclaim is worse than the
invisible prompt this file exists to fix, so the child, not stdin, now decides
when we are done — a watcher polls pinentry and TERMs the filter when it goes,
and the signal handlers exit rather than merely closing the float. Live
against a real float afterwards: open at 700ms, closed at 1000ms, with the
agent's end of the pipe still held open for another 19 seconds.

The lesson generalises past this bug: anything that can pin the float on
screen has to be driven by the dialog's own lifetime, never by a peer's
willingness to hang up.

**pinentry has a minimum size.** Below roughly 55x7 it answers
`ERR … Screen or window too small` instead of drawing. That is a clean error but
it still fails the signature, so a client too small to host the dialog falls
back to pass-through instead.

**Two hangs, both from an inherited file descriptor.** The backgrounded
`display-popup` client inherited the filter's stdin — the Assuan pipe — and ate
the `BYE`, so pinentry never saw the end of the conversation. And the OSD
subshell inherited the spawner's stdout, which was the command substitution
carrying the float's tty back, holding that pipe open and stalling the filter
before it forwarded a line. Anything spawned on this path needs its descriptors
closed explicitly.

Tests: `tests/pinentry_mux_spec.sh` (the ttyname rewrite; a response budget that
counts commands forwarded against commands received, because every content
assertion here passed while the injected line was silently desynchronising the
protocol; teardown — including the abandoned-connection case above, pinned with
the agent's end of the pipe held open so a regression stalls until the watchdog
kills it rather than passing on an EOF it should never have seen —
pass-through on every gate, the whole shared name list, plus the lib's
session/client/geometry lookups); `tests/pinentry_auto_spec.sh` (dispatch: `USE_CURSES` → mux, and the
fallback when the wrapper is not applied — the VNC and Touch ID branches are
left alone, since exercising them would raise a real biometric prompt);
`tests/environment_spec.sh` (`no-autostart` → empty `PINENTRY_USER_DATA`,
keeping the existing remote cases). `tests/tmux_keymap_spec.sh` was updated: it
pinned the old hand-written `(cursor-)?agent` regex.

---

## Verification

### Done on the laptop

Against nested tmux servers, a throwaway key in an isolated `GNUPGHOME`, and a
real `gpg-agent` with caching off:

- Cold cache, `gpg --clearsign` from a pane `ps` reports as an agent: the float
  opened on the attached client carrying gpg's own key description, typing into
  it returned exit 0, `gpg --verify` said `Good signature`, the agent pane stayed
  clean, and the float closed afterwards.
- The same run from a pane with no agent on it: prompt in place, no float,
  signature fine.
- Two agent panes at once: see the concurrency correction above.
- Pass-through on every failing gate, plus the whole shared name list, under
  `tests/pinentry_mux_spec.sh`.
- Full suite green (1811 examples), with the three pre-existing
  `quick-launch --no-border` warnings unchanged.

### Done on `mac-mini`

The mini runs tmux 3.7b, the same version every measurement above was taken
against, so none of them needed re-deriving.

- Isolated first, changing nothing: throwaway key in its own `GNUPGHOME` and a
  nested tmux server. Float opened, accepted the passphrase, signature
  completed, float closed; the same run from a non-agent pane prompted in place.
- Then the real thing. `gpg-agent` killed for a cold cache — which also brought
  `pinentry-timeout 900` live for the first time — and the signature raised from
  the genuine agent pane, a live `claude.exe` session. The float landed on the
  attached client, the typed passphrase was accepted, and `keyinfo --list`
  afterwards showed that key cached. No `pinentry` or holder process survived,
  so teardown was clean and no float leaked.
- The OSD arrived on the laptop over the bridge — a real delivery, not just the
  routing decision.
- Warm cache, plain `ssh mac-mini` with no tmux and no pane: exit 0, no float,
  nothing left behind. The no-mux pass-through path and the "second signature is
  silent" case, together.
- `claude.exe` is worth noting: the original hand-written `(cursor-)?agent`
  regex would not have matched the user's actual agent. The shared
  `muxAgentProcs` list does.

Still unverified, all cheap but none of them exercised: Ctrl-C in the float by
hand on the mini (the traps are covered by the spec and the laptop run), Touch
ID when sitting at the mini without SSH (`pinentry-auto:50`), and the *cold*
one-shot `ssh mac-mini 'gpg --clearsign'` with no tmux — only the warm path was
run.

On the dev-shell, signing over SSH raises Touch ID on the laptop instead of a
curses prompt in the remote pane.

**Risks.** Assuan proxy bugs are the main one, mitigated by pass-through on
every uncertain path plus the spec above. A silently failed popup spawn must hit
the launch guard rather than wedge the agent. An agent-heuristic miss degrades
to today's behavior, recoverable with `gpg-check`.
