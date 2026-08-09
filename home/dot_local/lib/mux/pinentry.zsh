#!/usr/bin/env zsh
# mux/pinentry.zsh — open the passphrase float for pinentry-mux.
#
# Off-PATH internal library, SOURCED (not executed) by
# libexec/pinentry-mux-popup, which is itself run from the POSIX-sh
# pinentry-mux Assuan filter. See docs/gpg-signing-ux.md.
#
# The caller hands us the tty gpg-agent named in `OPTION ttyname=` — an agent
# pane's pty that nobody is looking at. We map it to its tmux session, open a
# float on the client attached to that session, and print the float's OWN tty
# back, which the filter substitutes into the Assuan stream so pinentry draws
# where the human will see it.
#
# Sources mux-bootstrap.zsh, never mux.zsh: this runs under a launchd-spawned
# gpg-agent in a minimal environment, and mux.zsh drags in pick-common, which
# `die`s at source time when fzf is missing.
#
# Every sibling below is resolved from THIS file's own path rather than $HOME,
# the way the rest of the lib layer does it: correct in the installed tree, the
# repo checkout and the ShellSpec sandbox alike, and it keeps a wrapper that
# runs in launchd's minimal environment from depending on one more variable.
_mux_pe_self="${(%):-%x}"
typeset -g _MUX_PE_LIB="${_mux_pe_self:A:h:h}"        # ~/.local/lib
typeset -g _MUX_PE_ROOT="${_mux_pe_self:A:h:h:h}"     # ~/.local
source "$_MUX_PE_LIB/mux-bootstrap.zsh"
unset _mux_pe_self

# Floor measured against pinentry 1.3.3: the stock dialog chrome is 55x7 and
# below that pinentry answers `ERR … Screen or window too small` instead of
# drawing. That is a clean Assuan error rather than a hang, but it fails the
# signature — so a client too small to host the dialog must fall back to
# pass-through and prompt in place, which at least works. The extra margin
# over 55x7 is for a SETDESC that wraps to several lines.
typeset -gr MUX_PINENTRY_MIN_W=58
typeset -gr MUX_PINENTRY_MIN_H=9
typeset -gr MUX_PINENTRY_MAX_W=78
typeset -gr MUX_PINENTRY_MAX_H=16

# mux::pinentry_session_for_tty <tty> — the tmux session owning that pane tty.
#
# The pane tty is the one thing gpg-agent gives us that ties back to the mux:
# it names a pane, a pane names a session, and a session names the client we
# have to paint on.
mux::pinentry_session_for_tty() {
  local want="$1" tx
  [[ -n "$want" ]] || return 1
  tx="$(_mux_tx_bin)" || return 1
  "$tx" list-panes -a -F '#{pane_tty} #{session_name}' 2>/dev/null |
    while read -r ptty sess; do
      [[ "$ptty" == "$want" ]] || continue
      print -r -- "$sess"
      return 0
    done
  return 1
}

# mux::pinentry_client_for_session <session> — the attached client to paint on.
#
# This is NOT optional garnish, and `-t` is not a substitute for it. Measured
# on tmux 3.7b with two sessions each holding their own client:
# `display-popup -t '=B:'` painted the float on the client attached to session
# A. tmux resolves a popup's client from the CURRENT client and uses -t only
# for context, so aiming a popup by session alone puts the passphrase prompt on
# whichever screen tmux happened to touch last. `-c <client>` was exact every
# time. No client at all -> non-zero, and the caller passes through: a detached
# session cannot paint (HI-7), and display-popup would fail with
# "no current client" anyway.
#
# One session can hold SEVERAL clients, and a popup is per-client — it appears
# on the one it is aimed at and nowhere else. So "an attached client" is not
# good enough; it has to be the one with a human in front of it. Measured on a
# real session: two clients on the same session, one last active a second ago
# and one abandoned twelve hours earlier. Taking the first tmux listed would
# have painted the passphrase prompt on the dead screen — the original
# complaint, reproduced by the fix for it. `client_activity` is the only signal
# available here, so the most recently active client wins.
mux::pinentry_client_for_session() {
  local want="$1" tx cname csess act
  local best="" best_t=-1
  [[ -n "$want" ]] || return 1
  tx="$(_mux_tx_bin)" || return 1
  "$tx" list-clients -F '#{client_activity} #{client_name} #{client_session}' 2>/dev/null |
    while read -r act cname csess; do
      [[ "$csess" == "$want" ]] || continue
      [[ "$act" == <-> ]] || act=0
      (( act > best_t )) && { best_t=$act; best="$cname" }
    done
  [[ -n "$best" ]] || return 1
  print -r -- "$best"
}

# mux::pinentry_geometry <client> — "W H" for the float, or non-zero when the
# client is too small to host the dialog at all.
#
# `-t` here, `-c` for the popup below, and they are not interchangeable — the
# two commands invert. Measured on tmux 3.7b against a 120x40 client and a
# 64x18 one: `display -p -t <client>` reported each client's own size, while
# `display -p -c <client>` reported the CURRENT client's size for both. For
# display-popup it is the other way round. Swapping either flag for the
# other-looking one silently sizes or paints against the wrong screen.
mux::pinentry_geometry() {
  local client="$1" tx size cw ch w h
  tx="$(_mux_tx_bin)" || return 1
  size="$("$tx" display -p -t "$client" -F '#{client_width} #{client_height}' 2>/dev/null)" || return 1
  cw="${size%% *}" ch="${size##* }"
  [[ "$cw" == <-> && "$ch" == <-> ]] || return 1

  # Leave a margin so the float reads as a float and not as a takeover.
  w=$(( cw - 6 )); h=$(( ch - 6 ))
  (( w > MUX_PINENTRY_MAX_W )) && w=$MUX_PINENTRY_MAX_W
  (( h > MUX_PINENTRY_MAX_H )) && h=$MUX_PINENTRY_MAX_H
  (( w < MUX_PINENTRY_MIN_W || h < MUX_PINENTRY_MIN_H )) && return 1
  print -r -- "$w $h"
}

# mux::pinentry_alert <session> — OSD that a passphrase is waiting.
#
# The float is useless if you never learn it is there, which is the whole
# complaint: the agent stalls silently. The alert is best-effort and must never
# fail the spawn.
#
# NOTIFY_VIA_BRIDGE is the trap here. We run under a launchd-spawned gpg-agent
# with no SSH_* in the environment, so mux::is_remote is false and a bare
# `notify` would paint the OSD on THIS machine's screen — the very wrong-screen
# bug the bridge route exists to remove. The session env is the attach-time
# truth (mux::session_is_remote), so resolve it there and hand notify the
# verdict, exactly as tmux-alert-notify does.
#
# Both redirections matter. Detaching with `&!` is not enough on its own: the
# subshell would inherit this function's stdout, which is the command
# substitution our caller is reading the float's tty out of, and a pipe stays
# open until its LAST writer closes. A backgrounded alert would then hold that
# substitution open for as long as the OSD took, stalling the Assuan filter
# before it had forwarded a single line. Measured as exactly that hang.
mux::pinentry_alert() {
  local sess="$1"
  (
    [[ -n "$sess" ]] && mux::session_is_remote "$sess" && export NOTIFY_VIA_BRIDGE=1
    source "$_MUX_PE_LIB/common.zsh" 2>/dev/null || exit 0
    notify --icon 'glyph:nf-md-key' --sound Glass \
      'Passphrase needed — a signing prompt is waiting in tmux' || true
  ) >/dev/null 2>&1 &!
  return 0
}

# mux::pinentry_spawn <caller_tty> — open the float; print "<popup_tty> <pid>".
#
# Non-zero on every failure, and the filter then leaves the Assuan stream
# untouched so the prompt lands in the agent pane exactly as it does today.
# Degrading to today's behavior is always allowed; wedging the agent is not.
mux::pinentry_spawn() {
  local caller_tty="$1"
  local tx sess client geom w h fifo out popup_pid reader_pid line

  tx="$(_mux_tx_bin)" || return 1
  sess="$(mux::pinentry_session_for_tty "$caller_tty")" || return 1
  client="$(mux::pinentry_client_for_session "$sess")" || return 1
  geom="$(mux::pinentry_geometry "$client")" || return 1
  w="${geom%% *}" h="${geom##* }"

  # 0600 fifo under the common.zsh scratch discipline. Nothing secret crosses
  # it — the holder publishes only its tty and pid, and the passphrase never
  # leaves the pinentry<->agent pipe — but the tty name is a handle to the pane
  # the passphrase is typed into, so it is not world-readable either.
  source "$_MUX_PE_LIB/common.zsh" 2>/dev/null || return 1
  out="$(common::tmpfile)" || return 1
  fifo="${out}.fifo"
  if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
    rm -f -- "$out"
    return 1
  fi

  # HI-7 rendezvous: display-popup -E blocks for as long as the float lives —
  # here, the whole time the human is typing — so it cannot be waited on for a
  # launch verdict. Background it, read the fifo in a second background job,
  # and poll for either the holder's line or the popup client dying early.
  cat "$fifo" >"$out" 2>/dev/null &
  reader_pid=$!

  # -B, no title: pinentry draws its own framed dialog, so a tmux border would
  # be a second box around the first. Same reason the pickers pass it.
  #
  # </dev/null is load-bearing. This client lives for as long as the float
  # does, and without it the process inherits the filter's stdin — the Assuan
  # pipe from gpg-agent — and reads from it. Measured: the tmux client ate the
  # `BYE`, pinentry never saw the end of the conversation, and the filter hung
  # waiting for a child that would never exit.
  "$tx" display-popup -E -B -w "$w" -h "$h" -c "$client" \
    "$_MUX_PE_ROOT/libexec/pinentry-mux-popup" --hold "$fifo" </dev/null >/dev/null 2>&1 &
  popup_pid=$!

  local -i i=0
  line=""
  while (( i < 100 )); do              # 10s ceiling; a float that has not
    if [[ -s "$out" ]]; then           # published by then is not coming
      line="$(<"$out")"
      [[ "$line" == *' '* ]] && break  # tty and pid both present
    fi
    kill -0 "$popup_pid" 2>/dev/null || break   # launch failed
    sleep 0.1
    (( i++ ))
  done

  kill "$reader_pid" 2>/dev/null
  wait "$reader_pid" 2>/dev/null
  rm -f -- "$fifo" "$out"

  if [[ "$line" != /dev/*' '<-> ]]; then
    kill "$popup_pid" 2>/dev/null
    return 1
  fi

  mux::pinentry_alert "$sess"
  print -r -- "$line"
}
