# spec_helper.sh — suite-wide hermetic guard for ShellSpec tests.
#
# Unset the ambient tmux environment (the mux.zsh shim dispatches on $TMUX) so
# specs that do NOT explicitly set it always take the no-mux path: specs that
# need the tmux backend export TMUX themselves in their setup(), which runs
# per-example and takes precedence over this module-level unset.
unset TMUX TMUX_PANE
# And for Rex, the other backend: every pane Rex starts exports these, so a
# suite launched from a Rex pane would otherwise resolve `mux::backend` to rex
# in every spec that expects "none". REX_SERVER goes too — a spec that drives
# rex must name its own scratch server, never inherit the developer's live one.
unset REX_SESSION REX_BLOCK REX_SERVER
# Every job::start schedules a tab in Rex's Jobs session from the background,
# and job::_rex finds the live CLI on its own (PATH, then the app bundle). A
# rex that always fails keeps every spec that starts a job off the live
# server; the Rex specs export their own fake in setup().
export JOB_REX_BIN=/usr/bin/false
# The same for the mux shim's Rex (mux/rex.zsh, rex-bin.sh.tmpl): without a
# seam it finds the live CLI on PATH, and a spec that sets REX_SESSION but no
# scratch $REX_SERVER then queries the developer's live server. Specs that
# stub rex export their own MUX_REX_BIN; the three that start a scratch server
# (mux_rex, quick_launch_rex, rex_keymap) name the real binary themselves.
export MUX_REX_BIN=/usr/bin/false
# A suite run over SSH must look like one run at the machine: `notify` sends a
# toast to the ORIGIN machine through the clipboard bridge whenever the shell
# is remote (_notify_bridge_target: NOTIFY_VIA_BRIDGE, else mux::is_remote,
# which reads these three). Specs of the bridge route set their own.
unset SSH_TTY SSH_CONNECTION SSH_CLIENT NOTIFY_VIA_BRIDGE

# tm scrub-session debounce: real sessions nap before each synthesis so a
# held key only builds the rung the user settles on — specs step rapidly
# on purpose and would pay the nap dozens of times.
export BKP_TM_SCRUB_DEBOUNCE=0

# Render the single-source palette (.chezmoidata/theme.yaml ->
# custom-builds/theme/templates/palette.zsh.tmpl) to a temp file and point
# common.zsh at it via THEME_PALETTE_FILE, so palette-dependent specs resolve the
# canonical, machine-independent palette rather than any per-machine build
# artifact the ambient shell exported (e.g. ~/.cache/theme/chezmoi-system.zsh,
# which carries this box's background wash). Overriding THEME_PALETTE_FILE here
# keeps the suite hermetic regardless of the invoking shell's environment.
_palette_tpl="custom-builds/theme/templates/palette.zsh.tmpl"
if command -v chezmoi >/dev/null 2>&1 && [ -f "$_palette_tpl" ]; then
  _palette_tmp="$(mktemp 2>/dev/null)"
  if [ -n "${_palette_tmp:-}" ] \
    && chezmoi execute-template <"$_palette_tpl" >"$_palette_tmp" 2>/dev/null \
    && [ -s "$_palette_tmp" ]; then
    export THEME_PALETTE_FILE="$_palette_tmp"
  fi
fi

# A $SHELLSPEC_TMPBASE of each spec file's own. shellspec gives the whole run
# one, and the specs write fixed names under it ($SHELLSPEC_TMPBASE/state,
# /bin, /calls, ...), so under `--jobs` two files using the same name overwrite
# each other's fixtures mid-example. These root hooks run in each file's own
# process, after shellspec has fixed that file's $SHELLSPEC_WORKDIR (which its
# own bookkeeping uses) and around all of its blocks, so the file's top-level
# code, hooks and examples all see the new value. tests/spec_tmpbase_spec.sh
# pins it.
#
# The directory is a sibling of shellspec's, not inside it: recob specs bind
# Unix sockets under it, and macOS caps a socket path at 103 bytes. Under
# shellspec's own base those paths are already 101 bytes long; this one is
# shorter than that base.
spec_helper_configure() {
  before_all spec_helper_own_tmpbase
  after_all spec_helper_drop_tmpbase
}
spec_helper_own_tmpbase() {
  SPEC_HELPER_TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/spec.XXXXXX") || return 1
  SHELLSPEC_TMPBASE=$SPEC_HELPER_TMPBASE
  spec_helper_clipboard_guard
  spec_helper_desktop_guard
  # pick-clipboard reads the alias map while it loads (host::sql_case), so no
  # spec may see the human's real one. Per-file tmpbase; specs that need a map
  # export their own. HOST_SELF_ALIAS_FILE is NOT pinned (it follows HOME).
  HOST_ALIASES_FILE="$SPEC_HELPER_TMPBASE/no-host-aliases"
  export HOST_ALIASES_FILE
  # Every `notify` appends to the notification history, and `--ack` to the
  # unacked ledger; both follow XDG_STATE_HOME/HOME, so a spec that moves
  # neither would write the human's real ones. A spec that asserts on them
  # exports its own paths (or unsets these to test the default location).
  NOTIFY_HISTORY_FILE="$SPEC_HELPER_TMPBASE/.notify/history.jsonl"
  NOTIFY_UNACKED_FILE="$SPEC_HELPER_TMPBASE/.notify/unacked"
  export NOTIFY_HISTORY_FILE NOTIFY_UNACKED_FILE
}

# No spec may write the REAL clipboard. Code under test resolves `pbcopy`
# through PATH (share::clip, the ~/.local/bin trampoline), and before this
# guard every `make test` left Report.pdf → *.example.com rows in the human's
# clipboard history. A stub first on PATH swallows those writes. A spec that
# wants to OBSERVE clipboard writes stubs pbcopy in its own setup, and that
# prepend wins over this one. tests/spec_clipboard_guard_spec.sh pins it.
#
# The guard cannot shadow an ABSOLUTE /usr/bin/pbcopy, so the few examples that
# exist to round-trip the real pasteboard are opt-in instead:
#   Skip if 'writes the REAL clipboard (opt in: SPEC_REAL_PASTEBOARD=1)' spec_real_pasteboard_off
spec_real_pasteboard_off() { [ "${SPEC_REAL_PASTEBOARD:-}" != 1 ]; }
spec_helper_clipboard_guard() {
  mkdir -p "$SPEC_HELPER_TMPBASE/.clip-guard" || return 1
  printf '#!/bin/sh\ncat >/dev/null\n' >"$SPEC_HELPER_TMPBASE/.clip-guard/pbcopy"
  chmod +x "$SPEC_HELPER_TMPBASE/.clip-guard/pbcopy"
  PATH="$SPEC_HELPER_TMPBASE/.clip-guard:$PATH"
  export PATH
}
# Never fails and never writes to stderr: shellspec reports anything an
# after-all hook prints there as an error ("0 failures, 1 error"). One `rm -rf`
# is not enough when an example left a background process behind (a disowned
# `cmd &!` in the code under test) that is still creating files while rm walks
# the tree: rm then ends with "Directory not empty". Retry for about 2 s, which
# outlives any such straggler seen so far; a directory that still cannot be
# removed is left for the OS's own tmp cleanup rather than failing the run.
# tests/spec_helper_spec.sh pins it.

# No spec may reach the REAL desktop: no notification, sound, dialog, app or
# Quick Look panel. Before this guard a `make test-all` played sounds and
# raised toasts on the machine it ran on. The ONE notification a test run may
# cause is the end-of-run toast of tests/run-shellspec.sh, which fires after
# shellspec has exited. tests/spec_helper_spec.sh pins the guard.
#
# Default deny, for every spec file:
#   * stubs for hs, osascript, afplay, say, terminal-notifier and open, first
#     on PATH. Each records its call and succeeds in silence. A spec that
#     stubs one of them itself prepends its own directory and wins;
#   * a `pueue` there too, which records and FAILS as a client with no daemon
#     does: no spec may read or queue into the human's real pueue. Specs that
#     run jobs name their own through JOB_PUEUE_BIN;
#   * the seams that name such a tool by ABSOLUTE path are pinned to the stubs:
#     HS (a set HS is the whole answer of notify::available) and
#     WIDGETS_OSASCRIPT_BIN (mux-fullscreen-probe, quick-launch-window:
#     /usr/bin/osascript);
#   * NOTIFY_TMUX_BIN, which defaults to `tmux` (a `refresh-client -S` to the
#     live server on every acknowledgable toast), is pinned to a recording
#     stub: `spec_desktop_calls notify-tmux`;
#   * NOTIFY_HISTORY_FILE and NOTIFY_UNACKED_FILE live in the tmpbase (set
#     with HOST_ALIASES_FILE, in spec_helper_own_tmpbase);
#   * at the top of this file: MUX_REX_BIN and JOB_REX_BIN refuse, and the
#     SSH_* variables are unset, so `notify` never takes the bridge route to
#     another machine's screen;
#   * SPEC_RUN_TOAST=0, so a spec that runs the wrapper raises no toast.
#
# To ASSERT on what the code under test asked of the desktop:
#   spec_desktop_calls [tool]   every recorded call, "tool argv" per line, in
#                               order; with a tool, only its calls, argv only
#   spec_notifications          the notifications: hs / terminal-notifier /
#                               osascript calls
#   spec_sounds                 the sounds: the sound name of each `notify
#                               --sound` (it rides the hs call), afplay and
#                               say calls
# The log is per spec FILE; an example that counts calls clears it first with
# spec_desktop_reset.
#
# What the guard cannot hold: a spec that replaces PATH wholesale
# (PATH=/usr/bin:/bin puts /usr/bin/osascript, afplay, say and open back) or
# drops the environment (`env -i`, `env -u HS`: notify finds the real
# /opt/homebrew/bin/hs again). Keep the guard in such a spec:
#   env -i PATH="$SPEC_DESKTOP_GUARD:/usr/bin:/bin" HS="$HS" …
# A spec that needs the real desktop says so, and is skipped unless the owner
# opts in, as with the pasteboard:
#   Skip if 'reaches the REAL desktop (opt in: SPEC_REAL_DESKTOP=1)' spec_real_desktop_off
#   BeforeEach 'spec_desktop_unguard'
#
# SPEC_DESKTOP_AUDIT=<file>, set for a whole run, additionally appends
# "<spec file><TAB><tool argv>" for every call that reached a guard stub, and
# adds pass-through loggers for rex and launchctl (logged, then the real one
# runs): the measurement behind the leak table in
# tests/README-scaffolding.md.
spec_real_desktop_off() { [ "${SPEC_REAL_DESKTOP:-}" != 1 ]; }
spec_helper_desktop_guard() {
  SPEC_DESKTOP_GUARD="$SPEC_HELPER_TMPBASE/.desktop-guard"
  mkdir -p "$SPEC_DESKTOP_GUARD" || return 1
  _dg_audit=
  if [ -n "${SPEC_DESKTOP_AUDIT:-}" ]; then
    _dg_audit="printf '%s\\t%s\\n' '${SHELLSPEC_SPECFILE:-?}' \"\$line\" >>'$SPEC_DESKTOP_AUDIT'"
  fi
  # notify-tmux is not a tool: it is what NOTIFY_TMUX_BIN is pinned to below.
  # pueue is the one that FAILS (a client with no daemon): succeeding would
  # tell share::jobs_available that jobs can be queued.
  for _dg_tool in hs osascript afplay say terminal-notifier open notify-tmux pueue; do
    _dg_rc=0
    [ "$_dg_tool" != pueue ] || _dg_rc=1
    printf '%s\n' '#!/bin/sh' \
      "line=\"$_dg_tool \$(printf '%s' \"\$*\" | tr '\\n' ' ')\"" \
      "printf '%s\\n' \"\$line\" >>'$SPEC_DESKTOP_GUARD/calls.log'" \
      "$_dg_audit" \
      "exit $_dg_rc" >"$SPEC_DESKTOP_GUARD/$_dg_tool"
    chmod +x "$SPEC_DESKTOP_GUARD/$_dg_tool"
  done
  if [ -n "$_dg_audit" ]; then
    for _dg_tool in rex launchctl; do
      _dg_real=$(command -v "$_dg_tool" 2>/dev/null) || continue
      case $_dg_real in /*) ;; *) continue ;; esac
      printf '%s\n' '#!/bin/sh' \
        "line=\"$_dg_tool \$(printf '%s' \"\$*\" | tr '\\n' ' ')\"" \
        "$_dg_audit" \
        "exec '$_dg_real' \"\$@\"" >"$SPEC_DESKTOP_GUARD/$_dg_tool"
      chmod +x "$SPEC_DESKTOP_GUARD/$_dg_tool"
    done
  fi
  PATH="$SPEC_DESKTOP_GUARD:$PATH"
  HS="$SPEC_DESKTOP_GUARD/hs"
  WIDGETS_OSASCRIPT_BIN="$SPEC_DESKTOP_GUARD/osascript"
  NOTIFY_TMUX_BIN="$SPEC_DESKTOP_GUARD/notify-tmux"
  SPEC_RUN_TOAST=0
  export PATH HS WIDGETS_OSASCRIPT_BIN NOTIFY_TMUX_BIN SPEC_RUN_TOAST SPEC_DESKTOP_GUARD
}
spec_desktop_calls() {
  [ -f "$SPEC_DESKTOP_GUARD/calls.log" ] || return 0
  if [ $# -eq 0 ]; then
    cat "$SPEC_DESKTOP_GUARD/calls.log"
  else
    sed -n "s/^$1 //p" "$SPEC_DESKTOP_GUARD/calls.log"
  fi
}
spec_desktop_reset() { rm -f "$SPEC_DESKTOP_GUARD/calls.log"; }
spec_notifications() { spec_desktop_calls | grep -E '^(hs|terminal-notifier|osascript) ' || :; }
spec_sounds() {
  # notify(icon, text, sound): the sound is the last Lua argument, nil when
  # the notification is silent.
  spec_desktop_calls | sed -n -E \
    -e 's/^hs .*notify(Ansi)?\(.*, "([^"]*)"\)$/\2/p' \
    -e 's/^(afplay|say) (.*)$/\1 \2/p'
}
# Only with the owner's opt-in: take the guard off for this example.
spec_desktop_unguard() {
  spec_real_desktop_off && { echo "spec_desktop_unguard: needs SPEC_REAL_DESKTOP=1" >&2; return 1; }
  PATH=$(printf '%s' "$PATH" | sed "s|$SPEC_DESKTOP_GUARD:||g")
  unset HS WIDGETS_OSASCRIPT_BIN NOTIFY_TMUX_BIN
  export PATH
}

spec_helper_drop_tmpbase() {
  [ -n "${SPEC_HELPER_TMPBASE:-}" ] || return 0
  _sh_try=0
  while [ "$_sh_try" -lt 20 ]; do
    rm -rf "$SPEC_HELPER_TMPBASE" 2>/dev/null
    [ -e "$SPEC_HELPER_TMPBASE" ] || break
    sleep 0.1
    _sh_try=$((_sh_try + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Shared scaffolding: sandbox, stubs, PATH, a fake rex, template rendering.
# Conversion rules and pitfalls: tests/README-scaffolding.md. Every helper is
# pinned in tests/spec_helper_spec.sh.
#
# Scoping, which all of these rely on: shellspec runs every example in its own
# subshell, hooks included (BeforeEach, the example body, AfterEach). So what a
# helper sets or exports from a BeforeEach or an example ($SANDBOX, PATH, any
# STUB_* knob) is gone when the example ends: no save/restore, no `unset` in an
# AfterEach. Called at the top of a file or from BeforeAll they last for the
# rest of the block instead.
# ---------------------------------------------------------------------------

# spec_sandbox [name] — make a fresh, empty directory under $SHELLSPEC_TMPBASE
# and set $SANDBOX to it. Unique per call; `name` (default "sb") is only a
# readable prefix. Nothing to clean up: the per-file tmpbase is removed after
# the file. It SETS a variable instead of printing the path because a
# `dir=$(spec_sandbox)` would run it in a subshell; copy it when a spec wants
# its own name or a second sandbox:
#
#   setup() { spec_sandbox; RH_TMP=$SANDBOX; }
#   BeforeEach 'setup'
#
# The path is one component longer than a bare `mktemp -d`; a spec that binds
# a Unix socket (103-byte cap on macOS) should bind it under $SHELLSPEC_TMPBASE.
spec_sandbox() {
  SANDBOX=$(mktemp -d "${SHELLSPEC_TMPBASE:?spec_sandbox: no SHELLSPEC_TMPBASE}/${1:-sb}.XXXXXX") || {
    echo "spec_sandbox: could not create a directory under $SHELLSPEC_TMPBASE" >&2
    return 1
  }
}

# spec_stub <dir> <name> [body-line...] — write the executable <dir>/<name>, a
# /bin/sh script that appends its argv as ONE line to <dir>/<name>.log (the
# arguments joined by spaces, newlines inside them flattened to spaces) and
# then runs the body, if any. No body: it exits 0. With a body the stub exits
# with the body's status, as any script does. <dir> is created if missing.
#
# The body is given as ARGUMENTS, one or more, each written as its own line(s).
# Single-quote it: nothing is expanded when the stub is written, and the body
# reaches its own directory as $STUB_DIR (and its log as $STUB_LOG), so no
# `\$` escaping and no spec variable baked into the script:
#
#   spec_stub "$SANDBOX" croc                        # log argv, exit 0
#   spec_stub "$SANDBOX" uname 'echo Darwin'
#   spec_stub "$SANDBOX" ssh \
#     'case "$*" in *ComputerName*) echo "Mac Mini" ;; esac' \
#     'cat >"$STUB_DIR/ssh.stdin"'
#
# spec_stub_calls <dir> <name> — print that log; nothing, status 0, if the
# stub was never run.
spec_stub() {
  [ $# -ge 2 ] || { echo "usage: spec_stub <dir> <name> [body-line...]" >&2; return 2; }
  _st_dir=$1
  _st_name=$2
  shift 2
  mkdir -p "$_st_dir" || return 1
  _st_q=$(printf '%s' "$_st_dir" | sed "s/'/'\\\\''/g")
  {
    printf '%s\n' '#!/bin/sh'
    printf "STUB_DIR='%s'\nSTUB_LOG='%s/%s.log'\n" "$_st_q" "$_st_q" "$_st_name"
    # printf, not echo: sh's echo expands backslashes on macOS.
    printf '%s\n' 'printf '"'"'%s\n'"'"' "$(printf '"'"'%s'"'"' "$*" | tr '"'"'\n'"'"' '"'"' '"'"')" >>"$STUB_LOG"'
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } >"$_st_dir/$_st_name" || return 1
  chmod +x "$_st_dir/$_st_name"
}
spec_stub_calls() {
  [ ! -f "$1/$2.log" ] || cat "$1/$2.log"
}

# spec_path_prepend <dir>... — put the directories first on PATH (the first
# argument ends up first) and export it. From a BeforeEach or an example there
# is nothing to undo (see "Scoping" above).
spec_path_prepend() {
  _pp_new=
  for _pp_dir in "$@"; do _pp_new="$_pp_new$_pp_dir:"; done
  PATH="$_pp_new$PATH"
  export PATH
}

# --- a clock the test drives -------------------------------------------------
# No test may wait, and no test may assert on elapsed real time
# (tests/README-scaffolding.md). Code whose SUBJECT is time (a poll loop that
# gives up, a deadline, a TTL, a debounce) runs against a virtual clock:
#
#   spec_clock_set <epoch seconds>   start the clock (2000000000 if omitted),
#                                    export it, and put a fake `sleep` and a
#                                    fake `date` first on PATH
#   spec_clock_advance <seconds>     move it forward; fractions allowed (0.2)
#   spec-clock-advance <seconds>     the same, as a COMMAND on PATH: for the
#                                    body of a stub that has to "take time"
#   spec_clock_now [ms]              print it: whole seconds, or milliseconds
#   spec_clock_slept                 print every sleep asked for, one request
#                                    per line, in order: of the fake `sleep`
#                                    (its argv) and of common::sleep (seconds)
#
# The fake `sleep N` returns at once, ADVANCES the clock by N and records the
# request (N may carry the s/m/h/d suffix; several arguments add up). The fake
# `date` is the real one answering for the virtual now: `date +%s`, `date
# +%F`, `date -u …`, BSD `date -v-1d …`. A date that is handed a time of its
# own (-r, -d, -j, -f) passes straight through.
#
#   spec_clock_set 1000
#   poll_until_gone block:x          # code under test: 25 polls, sleep 0.2 each
#   spec_clock_now ms                # -> 1005000: it believes it waited 5 s
#   spec_clock_slept | wc -l         # -> 25
#
# ACROSS PROCESSES. The clock is a file, named by the exported
# $SPEC_CLOCK_FILE, so a script run as a child (`When run zsh script`), the
# helpers it spawns, `$(…)` subshells and background jobs all read and advance
# the same one; the stubs reach them through the exported PATH. The file is an
# append-only journal, one short line per event:
#
#   = 1000000        the clock was set to this many milliseconds
#   + 200            it advanced by this many (spec_clock_advance)
#   + 200 0.2        a sleep advanced it: the rest of the line is the request
#
# and "now" is the last `=` plus every `+` after it. A line is written with one
# O_APPEND write far below PIPE_BUF, which the kernel does not interleave: two
# processes advancing at once cannot lose an update, with no lock and nothing
# to clean up after a killed process. Milliseconds are integers, so 25 sleeps
# of 0.2 are exactly 5 s, not 5.000000000000001.
#
# THE PRODUCTION SEAM. zsh code that sources common.zsh reads the time with
# common::now and waits with common::sleep (so do poll::until, spin::nap and
# job::_follow_nap). Both use THIS journal whenever $COMMON_CLOCK_FILE names
# it, which spec_clock_set arranges: no PATH needed, no fork. The journal has
# two readers, the awk below and the read loop in common.zsh;
# tests/common_spec.sh feeds both the same journal and compares.
#
# WHAT IT DOES NOT REACH: code that still reads $EPOCHSECONDS /
# $EPOCHREALTIME / $SECONDS directly or waits with `read -t`, a bare
# `zselect`, `wait`, or a tool's own `--timeout`; a script that resets PATH
# and does not source common.zsh; a file's real mtime (set it with `touch
# -t`, relative to the virtual now).
spec_clock_set() {
  if [ -z "${SPEC_CLOCK_FILE:-}" ]; then
    _ck_dir=$(mktemp -d "${SHELLSPEC_TMPBASE:?spec_clock_set: no SHELLSPEC_TMPBASE}/clock.XXXXXX") || return 1
    _ck_date=$(command -v date)
    SPEC_CLOCK_FILE="$_ck_dir/journal"
    SPEC_CLOCK_BIN="$_ck_dir/bin"
    # The name production code knows the journal by (common.zsh: common::now,
    # common::sleep). Always the same file as SPEC_CLOCK_FILE.
    COMMON_CLOCK_FILE=$SPEC_CLOCK_FILE
    export SPEC_CLOCK_FILE SPEC_CLOCK_BIN COMMON_CLOCK_FILE
    : >"$SPEC_CLOCK_FILE"
    spec_stub "$SPEC_CLOCK_BIN" sleep \
      'ms=$(awk '"'"'BEGIN { t = 0; for (i = 1; i < ARGC; i++) { a = ARGV[i]; u = 1
         if (a ~ /m$/) u = 60; else if (a ~ /h$/) u = 3600; else if (a ~ /d$/) u = 86400
         sub(/[smhd]$/, "", a); t += a * u }
         printf "%.0f\n", t * 1000 }'"'"' "$@")' \
      'echo "+ $ms $*" >>"$SPEC_CLOCK_FILE"'
    spec_stub "$SPEC_CLOCK_BIN" date \
      'for a in "$@"; do case $a in -r | -d | -j | -f | --date*) exec '"'$_ck_date'"' "$@" ;; esac; done' \
      'now=$(awk '"'"'$1 == "=" { t = $2 } $1 == "+" { t += $2 } END { printf "%.0f\n", int(t / 1000) }'"'"' "$SPEC_CLOCK_FILE")' \
      'if '"'$_ck_date'"' -r 0 +%s >/dev/null 2>&1; then exec '"'$_ck_date'"' -r "$now" "$@"; fi' \
      'exec '"'$_ck_date'"' -d "@$now" "$@"'
    # For a /bin/sh stub that has to "take time": `spec-clock-advance 2`.
    printf '%s\n' '#!/bin/sh' \
      'ms=$(awk -v s="$1" '"'"'BEGIN { printf "%.0f\n", s * 1000 }'"'"')' \
      'echo "+ $ms" >>"$SPEC_CLOCK_FILE"' >"$SPEC_CLOCK_BIN/spec-clock-advance"
    chmod +x "$SPEC_CLOCK_BIN/spec-clock-advance"
    spec_path_prepend "$SPEC_CLOCK_BIN"
  fi
  echo "= $(_spec_clock_ms "${1:-2000000000}")" >>"$SPEC_CLOCK_FILE"
}
spec_clock_advance() {
  echo "+ $(_spec_clock_ms "$1")" >>"${SPEC_CLOCK_FILE:?spec_clock_advance: call spec_clock_set first}"
}
spec_clock_now() {
  awk -v unit="${1:-s}" '$1 == "=" { t = $2 } $1 == "+" { t += $2 }
    END { printf "%.0f\n", (unit == "ms") ? t : int(t / 1000) }' \
    "${SPEC_CLOCK_FILE:?spec_clock_now: call spec_clock_set first}"
}
spec_clock_slept() {
  sed -n 's/^+ [0-9][0-9]* //p' "${SPEC_CLOCK_FILE:?spec_clock_slept: call spec_clock_set first}"
}
_spec_clock_ms() { awk -v s="$1" 'BEGIN { printf "%.0f\n", s * 1000 }'; }

# Code that runs BESIDE the test (a follower in the background, a detached
# helper) advances the clock by itself, at full speed: its naps cost nothing.
# Two ways to stay in step with it, neither of which waits for TIME:
#
#   spec_clock_await <seconds>       block until the clock stands that far past
#                                    where it was last SET: "the code has now
#                                    napped for half a second", then look
#   spec_clock_guard <pid> [seconds] in the background: kill -9 <pid> if the
#                                    clock ever gets that far (7200 if
#                                    omitted) past where it was last set. The
#                                    bound a polling loop needs, in the loop's
#                                    own time: a follower that is never told
#                                    to stop is killed after two of ITS hours
#                                    (at 0.1 s a nap, a few real seconds of
#                                    spinning, some 20,000 naps a second)
#   spec_clock_guard_off             stand the guard down (always, once the
#                                    process has been joined with `wait`)
#
# Both follow the journal as it grows (`tail -f`, which the kernel wakes: no
# polling here either). To join the process itself use `wait <pid>`. What
# they cannot do is hold the code still: between two of its naps nothing can
# be slipped in from outside. An event that must land at one exact point
# needs a fake the code calls at that point (a counter, a FIFO the fake
# blocks on), not the clock.
spec_clock_await() {
  _ca_fifo=$(mktemp -u "${SHELLSPEC_TMPBASE:?}/await.XXXXXX") && mkfifo "$_ca_fifo" || return 1
  tail -n +1 -f "${SPEC_CLOCK_FILE:?spec_clock_await: call spec_clock_set first}" >"$_ca_fifo" 2>/dev/null &
  _ca_tail=$!
  awk -v d="$(_spec_clock_ms "$1")" '$1 == "=" { base = $2; t = $2 } $1 == "+" { t += $2 }
    t - base >= d { exit }' <"$_ca_fifo"
  kill "$_ca_tail" 2>/dev/null
  wait "$_ca_tail" 2>/dev/null
  rm -f "$_ca_fifo"
  return 0
}
spec_clock_guard() {
  _cg_fifo=$(mktemp -u "${SHELLSPEC_TMPBASE:?}/guard.XXXXXX") && mkfifo "$_cg_fifo" || return 1
  tail -n +1 -f "${SPEC_CLOCK_FILE:?spec_clock_guard: call spec_clock_set first}" >"$_cg_fifo" 2>/dev/null &
  SPEC_CLOCK_GUARD=$!
  # awk ends at the bound (then the kill) or at EOF, when the guard is stood
  # down by killing its tail (then nothing).
  ( awk -v d="$(_spec_clock_ms "${2:-7200}")" '$1 == "=" { base = $2; t = $2 } $1 == "+" { t += $2 }
      t - base >= d { hit = 1; exit } END { exit !hit }' <"$_cg_fifo" && kill -9 "$1" 2>/dev/null
    rm -f "$_cg_fifo" ) >/dev/null 2>&1 &
  SPEC_CLOCK_GUARD_SUB=$!
}
spec_clock_guard_off() {
  [ -n "${SPEC_CLOCK_GUARD:-}" ] || return 0
  kill "$SPEC_CLOCK_GUARD" 2>/dev/null
  wait "$SPEC_CLOCK_GUARD" "$SPEC_CLOCK_GUARD_SUB" 2>/dev/null
  SPEC_CLOCK_GUARD=
  return 0
}

# spec_fake_rex <dir> [arm...] [--offline arm...] — write <dir>/rex, a
# spec_stub (so: argv logged flat to <dir>/rex.log, read it with
# `spec_stub_calls <dir> rex`) that answers what most specs ask a Rex CLI.
# The spec points the code under test at it itself (MUX_REX_BIN, JOB_REX_BIN).
#
# Each call is matched against " $* " (argv joined, a space at both ends, so a
# pattern can ask for whole words: *" client ls "*). First match wins:
#
#   1. the --offline arms, which answer even when the server is down;
#   2. STUB_SERVER=down: every other call exits 4, as rex does with no server;
#   3. the spec's own arms;
#   4. the canned answers:
#        client ls            <dir>/clients.json, else one connected local Mac app
#        ls --json            <dir>/sessions.json, else one session "Main"
#        session.view         <dir>/view.json, else session:main with no windows
#        session.new_layer    saves the request (stdin) to <dir>/req.json, then
#                             {"block_ids":["block:layer"]}; STUB_LAYER=fail: exit 1
#        block inspect        the layer's life, below; STUB_INSPECT_RC=N: exit N
#        block close          ends the layer's life
#        block call … process a zsh foreground whose cwd is <dir>
#        window new           {"window_id":"window:new","block_ids":["block:new"]};
#                             STUB_NEW=fail: exit 1
#        whoami               <dir>/whoami.json if the spec wrote one; exit 0
#      and anything else exits 0 in silence.
#
# An arm is one complete `case` arm, single-quoted, with $STUB_DIR for <dir>:
#
#   spec_fake_rex "$SANDBOX" \
#     '*" window focus "*) [ "${STUB_FOCUS:-ok}" = ok ] || exit 1 ;;' \
#     --offline '*" config check "*) [ "${STUB_CHECK:-ok}" = ok ] ;;'
#
# The fake exits with the status of the arm that matched. The STUB_* knobs are
# read when the fake RUNS, so an example sets them with `export STUB_NEW=fail`.
#
# A layer that lives for a while, with no time passing. Code that opens a
# float then polls `block inspect` until the block is gone (exit 3; 0 = alive).
# The fake counts instead of sleeping: <dir>/layer.life holds how many more
# inspects find the layer alive. session.new_layer writes
# ${STUB_LAYER_LIFE:-0} there, each inspect that finds it alive takes one off,
# `block close` writes 0. The word `open` instead of a number is a layer that
# stays until it is closed. An example can write the file itself at any point
# ("the block went away"), and counts the polls afterwards:
#
#   export STUB_LAYER_LIFE=3          # alive for three polls, gone on the 4th
#   spec_stub_calls "$SANDBOX" rex | grep -c ' block inspect '    # -> 4
#
# Under spec_clock_set the poll loop's own `sleep 0.2` costs nothing either,
# and the clock says how long the code believes it waited.
spec_fake_rex() {
  [ $# -ge 1 ] || { echo "usage: spec_fake_rex <dir> [arm...] [--offline arm...]" >&2; return 2; }
  _fr_dir=$1
  shift
  _fr_arms=
  _fr_offline=
  _fr_mode=arms
  for _fr_arm in "$@"; do
    if [ "$_fr_arm" = --offline ]; then
      _fr_mode=offline
    elif [ "$_fr_mode" = offline ]; then
      _fr_offline="$_fr_offline  $_fr_arm
"
    else
      _fr_arms="$_fr_arms      $_fr_arm
"
    fi
  done
  spec_stub "$_fr_dir" rex \
    'answer() { if [ -f "$STUB_DIR/$1" ]; then cat "$STUB_DIR/$1"; else printf '"'"'%s\n'"'"' "$2"; fi; }' \
    'case " $* " in' \
    "$_fr_offline"'  *)' \
    '    [ "${STUB_SERVER:-up}" = up ] || exit 4' \
    '    case " $* " in' \
    "$_fr_arms"'      *" client ls "*) answer clients.json '"'"'{"clients":[{"client_id":"client:mac","info":{"kind":"app","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"connected","session_ids":["session:main"]}]}'"'"' ;;' \
    '      *" ls --json "*) answer sessions.json '"'"'{"sessions":[{"session_id":"session:main","label":"Main"}]}'"'"' ;;' \
    '      *" session.view "*) answer view.json '"'"'{"session_id":"session:main","windows":[]}'"'"' ;;' \
    '      *" session.new_layer "*)' \
    '        cat >"$STUB_DIR/req.json"' \
    '        [ "${STUB_LAYER:-ok}" = ok ] || exit 1' \
    '        echo "${STUB_LAYER_LIFE:-0}" >"$STUB_DIR/layer.life"' \
    '        echo '"'"'{"block_ids":["block:layer"]}'"'"' ;;' \
    '      *" block inspect "*)' \
    '        [ -z "${STUB_INSPECT_RC:-}" ] || exit "$STUB_INSPECT_RC"' \
    '        life=$(cat "$STUB_DIR/layer.life" 2>/dev/null)' \
    '        case ${life:-0} in' \
    '          0) exit 3 ;;' \
    '          *[!0-9]*) exit 0 ;;' \
    '          *) echo $((life - 1)) >"$STUB_DIR/layer.life"; exit 0 ;;' \
    '        esac ;;' \
    '      *" block close "*) echo 0 >"$STUB_DIR/layer.life" ;;' \
    '      *" block call "*" process"*) echo "{\"foreground\":{\"cwd\":\"$STUB_DIR\",\"name\":\"zsh\"}}" ;;' \
    '      *" window new "*)' \
    '        [ "${STUB_NEW:-ok}" = ok ] || exit 1' \
    '        echo '"'"'{"window_id":"window:new","block_ids":["block:new"]}'"'"' ;;' \
    '      *" whoami "*) [ ! -f "$STUB_DIR/whoami.json" ] || cat "$STUB_DIR/whoami.json" ;;' \
    '    esac ;;' \
    'esac'
}

# spec_render_template <template> [dest] — render a chezmoi template against
# THIS source tree (never the applied one) and set $SPEC_RENDERED to the file
# written. <template> is relative to the repository root, or absolute. [dest]
# defaults to $SANDBOX/<template's basename without .tmpl>.
#
# A template that does not render fails loudly: chezmoi's own error stays on
# stderr, one line naming the template follows it, no file is left at dest, and
# the status is non-zero. In a BeforeEach that is enough: shellspec fails the
# example on anything a hook writes to stderr and shows it. Inside a function
# an example calls, stop there yourself:
#
#   spec_render_template home/.chezmoiscripts/run_after_60-x.sh.tmpl || return 1
#   sh "$SPEC_RENDERED"
spec_render_template() {
  [ $# -ge 1 ] || { echo "usage: spec_render_template <template> [dest]" >&2; return 2; }
  case $1 in
    /*) _rt_src=$1 ;;
    *) _rt_src="${SHELLSPEC_PROJECT_ROOT:?spec_render_template: no SHELLSPEC_PROJECT_ROOT}/$1" ;;
  esac
  if [ $# -ge 2 ]; then
    _rt_dest=$2
  else
    _rt_dest=${_rt_src##*/}
    _rt_dest="${SANDBOX:?spec_render_template: no dest and no \$SANDBOX (call spec_sandbox first)}/${_rt_dest%.tmpl}"
  fi
  if [ ! -f "$_rt_src" ]; then
    echo "spec_render_template: no such template: $_rt_src" >&2
    return 1
  fi
  SPEC_RENDERED=
  if chezmoi -S "$SHELLSPEC_PROJECT_ROOT" execute-template <"$_rt_src" >"$_rt_dest"; then
    SPEC_RENDERED=$_rt_dest
    return 0
  fi
  echo "spec_render_template: $1 did not render" >&2
  rm -f "$_rt_dest"
  return 1
}

# show_separators CMD [ARGS...] — run CMD and print its stdout with every US
# (\037) as <US> and every RS (\036) as <RS>, returning CMD's own status.
#
# US and RS are the field and record separators of ShellSpec's report stream.
# An expectation or subject that carries them raw splits a report record: the
# reporter evals a garbage field ("command not found: field_..."), the run is
# "Aborted", and ShellSpec 0.28.1 then exits 0 even with failures (see
# tests/run-shellspec.sh). Assert on the visible form instead:
#
#   When call show_separators input::form --spec "$SPEC"
#   The output should equal "name<US>Ada<RS>email<US>yes"
show_separators() {
  _ss_out=$("$@")
  _ss_rc=$?
  # No output stays no output: a lone newline would be unasserted stdout.
  if [ -n "$_ss_out" ]; then
    printf '%s\n' "$_ss_out" | LC_ALL=C sed "s/$(printf '\037')/<US>/g; s/$(printf '\036')/<RS>/g"
  fi
  return "$_ss_rc"
}

# with_tty CMD [ARGS...] — run CMD with a pty as its terminal, returning its
# status. `script` is the only pty tool on every machine, and its two
# families disagree: util-linux takes the command as one string after -c,
# BSD takes it as arguments after the typescript file.
with_tty() {
  if script --version >/dev/null 2>&1; then
    script -qec "${(j: :)${(q)@}}" /dev/null
  else
    script -q /dev/null "$@"
  fi
}
