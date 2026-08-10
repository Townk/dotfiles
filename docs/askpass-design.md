# One dialog for every password — design

Status: **shipped on this host.** A real `sudo` has authenticated through the
float: the helper resolved its pane from `TMUX_PANE`, the dialog opened on the
attached client, and the password went back on stdout. What has not been
exercised is the no-pane rung against the real `pinentry-mac` (only against a
stub) and every profile other than this one.

Worth knowing when you verify it yourself, because it looks like a failure and
is not: `sudo -k -v` prompts but is documented to *not* update the cached
credentials, so a following `sudo -n -v` still reports that a password is
required. The `exit 0` is what says the password was accepted.

`docs/pinentry-ui-design.md` is the prerequisite: the
dialog, the float, the requester line and the handover discipline all come from
there and are reused here unchanged. This file covers only what is new — reaching
that dialog from the programs that ask for a password *without* speaking Assuan.

The goal, stated as the repo owner did: `pinentry-auto` becomes the single front
door for any password asked of the user, and the UX behind it is the same
wherever the question comes from.

## What the chain actually is

The obvious model — Touch ID, then our dialog if there is a tty, then
pinentry-mac, then the system default — is right in spirit and wrong in three
specifics. All three were measured, and each one changes what gets built.

**Touch ID is not a rung the dispatcher can choose.** `pinentry-touchid` is not
an authenticator; it is a keychain-backed secret *store*. Its item is service
`GnuPG`, account = a GPG key fingerprint, so it unlocks a stored GPG passphrase
behind a fingerprint. Your account password is not in there and cannot be looked
up by that key. Touch ID for sudo is real, but it belongs to PAM
(`/etc/pam.d/sudo_local` has `pam_tid.so` as `sufficient`) and it runs *before*
sudo ever asks for a password — so by the time an askpass helper is invoked,
Touch ID has already been offered and declined. Over SSH it always declines,
because `pam_reattach` is configured `ignore_ssh`.

**There is never a tty, so "if we have a tty" cannot be the test.** Both callers
detach the helper completely. Measured, `sudo -A`:

```
argv[1]=[Password:]
stdin_tty=no  stdout_tty=no  stderr_tty=no   ctty=??
devtty=NOT openable
TMUX=[…]  TMUX_PANE=[%29]
```

and `ssh`, with a throwaway key, identically:

```
argv[1]=[Enter passphrase for "/tmp/askpass-k": ]
stdin_tty=no  ctty=??  devtty=NOT openable
TMUX_PANE=[%29]  DISPLAY=[<unset>]
```

No controlling terminal at all — `/dev/tty` does not open. What survives is the
environment, and `TMUX_PANE` is in it. So the discriminator becomes "is there a
pane", and the float stops being a nicety: `display-popup` needs `$TMUX`, not a
tty, which makes it the only way to draw in this lane.

**There is no system default underneath.** Once askpass is forced, sudo "will
exit with an error" rather than prompting, and `SSH_ASKPASS_REQUIRE=force` never
touches the TTY. The bottom rung is not a stock prompt; it is `\sudo`, and it
only exists because the `-A` comes from an alias rather than a `PATH` shim. That
is the whole reason the alias was chosen — see "Blast radius" below.

So, per lane:

| Lane | Touch ID | Preferred | Then | Bottom |
| --- | --- | --- | --- | --- |
| GPG | pinentry-touchid (physical) | pinentry-ui (tty) | pinentry-mac | pinentry-curses |
| sudo | PAM, before askpass | pinentry-ui (pane) | pinentry-mac, adapted | `\sudo` |
| ssh, git | n/a | pinentry-ui (pane) | pinentry-mac, adapted | unset the variable |

## Shape

**The askpass personality of the dispatcher is nearly empty, on purpose.**
`askpass-auto` is a chezmoi `symlink_` to `pinentry-auto`, which branches on
`$0`. In askpass mode it execs `pinentry-ui --askpass "$1"` when the binary
exists and fails closed when it does not. It does *not* choose between the float
and the GUI, because it cannot see whether a pane exists — the same lesson the
VNC lane taught an hour before this file was written: put the choice where the
facts are. The lane logic that is genuinely shell-shaped (the remote test, the
VNC probe) stays in the one file, which is why this is a personality rather than
a second script.

**`pinentry-ui --askpass`** takes the prompt verbatim from `argv[1]`, resolves
`$TMUX_PANE` instead of a ttyname, opens the float, and writes the secret plus a
newline to stdout with exit 0. Cancel is exit 1 and no output. The dialog needs
nothing new: the prompt string goes where the key tree goes in the GPG lane, and
the requester line works unchanged.

Two details that only became obvious once it ran. The pane lookup grew a `By`
key rather than a second function, because a pane id and a ttyname must never be
confusable — matching one against the other's field would silently prompt on
some other pane, and there is a test that crosses them deliberately. And the
`Requester` now carries the pane's own tty: the float opener takes a tty (a tty
names a session, a session names the client to paint on) while this lane only
has a pane id, and the pane list already had the tty in it. That kept the entire
zsh layer out of the change.

**The title is who asked, not what they asked for.** sudo's prompt is the
literal string `Password:`, which is accurate and useless in a float that
appeared while you were looking at something else. The process tree knows —
our parent is sudo, or ssh, or git, sometimes through a shell that has to be
walked past — so the title is the nearest ancestor that is not a shell, falling
back to reading the prompt for the word "passphrase".

**An Assuan client is the one new component.** With no pane, reaching
pinentry-mac means driving it — `SETDESC`, `GETPIN`, decode the `D` line, `BYE`
— and printing what comes back. Today we have only the server half;
`delegate.rs` relays a conversation but never conducts one. It inherits the
lesson from the GUI handover: strip `USE_CURSES` from the child's environment,
or pinentry-mac re-execs a curses pinentry and lands back in the terminal that
is not there.

## Wiring

Gated exactly like the `USE_CURSES` block in `dot_config/zsh/environment.sh` —
same SSH triple, same reasoning — and governed by one rule: **never clobber a
variable that is already set.**

**The guard names the binary, not the symlink**, and getting that backwards
broke sudo on a dev shell within an hour of shipping. `chezmoi apply` installs
`askpass-auto` on every host, while `pinentry-ui` is compiled and nothing builds
it automatically — `system-update` does not touch `custom-builds`. A guard on
the symlink is therefore always true, so a host that has only pulled the
dotfiles exports a helper that can only exit 1, and with `sudo -A` there is
nothing underneath it. The staged-rollout guarantee the pinentry lane gets for
free (`pinentry-auto` falls through to `pinentry-curses`) has to be written out
by hand here, because in this lane there is no fallback to fall through to.

That rule is doing real work. Cursor sets `SUDO_ASKPASS` in its agent sessions,
pointing at its own helper, and deferring to it is the right call: it prompts on
the laptop the human is actually sitting at, not in a float on a machine they
are not looking at. Expressing that as "first setter wins" rather than as a
check for Cursor keeps the vendor's name out of the config and extends the same
courtesy to anything else with an opinion.

The consequence is worth stating plainly, because it narrows the win: **inside a
Cursor agent session, sudo will keep using Cursor's helper, not ours.** What
this buys is plain SSH shells and agents that ship no helper of their own.

`SSH_ASKPASS` additionally needs `SSH_ASKPASS_REQUIRE=force`. `prefer` still
defers to the TTY when `DISPLAY` is unset, which over SSH it always is; `force`
is documented as "used for all passphrase input regardless of whether DISPLAY is
set", and the probe above confirms it fires with no `DISPLAY`.

`GIT_ASKPASS` is wired for completeness and will rarely fire: `credential.helper`
is `osxkeychain`, so git almost never falls back to asking.

The `sudo -A` alias lives in the interactive alias layer, guarded on the helper
existing and on the same remote test. It is an alias specifically so that
`\sudo` and `command sudo` bypass it.

## Blast radius

This is the part that differs in kind from the GPG work, and it is why the
fallback rule from `pinentry-ui-design.md` — every failure path reaches the
stock prompt — cannot be honoured literally here.

A pinentry that fails hands its conversation to another pinentry. An askpass
helper has nobody to hand to, and it cannot fall back to reading the terminal
because it has not got one. So a bug in this path does not produce an uglier
prompt; it stops sudo working in that pane until you type `\sudo`. Fail-closed
is the chosen behaviour, with the alias as the documented escape, and that
choice is the reason the `-A` must never move into a `PATH` shim: a shim would
catch scripts too, and take the escape hatch with it.

## Testing

`custom-builds/pinentry-ui/tests/askpass.rs` drives the binary the way sudo
does: the argv contract (prompt in, secret out, trailing newline), cancel as
exit 1 with nothing on stdout, the no-pane path against a stubbed GUI with
`USE_CURSES` stripped, and the case where there is neither a pane nor a GUI.

`tests/environment_spec.sh` covers the gating and the non-clobber rule;
`tests/pinentry_auto_spec.sh` covers the new personality, including the case
that matters most on a fresh host — dispatcher present, binary absent.

**The deadlock to know about before writing another pty test.** The dialog
repaints in full after *every* keystroke, about 1.3KB a time. A test that types
a seven-character passphrase without reading the master fills the pty's output
buffer around the fourth character; the child then blocks writing its repaint,
never reaches its next read, and the test waits forever for a process that is
waiting for it. It presents as a hang with no output at all, and it is
direction-dependent in a way that misleads: typing only `Enter` passes every
time, because that is one repaint. The harness therefore drains the master from
a thread of its own for the whole life of the test. The Assuan suite learned the
same lesson from the other end, where `Agent::line` drains while waiting for a
reply.

## Open

Linux. Everything here is macOS-shaped (`pinentry-mac`, the Homebrew paths,
PAM's Touch ID), and the GUI rung has no Linux answer chosen yet — the same gap
`pinentry-ui-design.md` records for the pinentry lane.
