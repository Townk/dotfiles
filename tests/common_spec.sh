# Tests for the shared base library (home/dot_local/lib/common.zsh): the
# logging/dispatch/command-presence primitives every other library builds on.
Describe 'common.zsh'
  Include home/dot_local/lib/common.zsh

  Describe 'log_info'
    It 'writes the message to stdout'
      When call log_info "hello world"
      The output should include "hello world"
      The status should be success
    End
  End

  Describe 'log_warn / log_error'
    It 'write to stderr, not stdout'
      When call log_warn "warnmsg"
      The error should include "warnmsg"
      The output should equal ""
      The status should be success
    End
  End

  Describe 'die'
    It 'writes an error and exits non-zero'
      When run die "boom"
      The status should be failure
      The stderr should include "boom"
    End
  End

  Describe 'is_help accepts help tokens'
    Parameters
      -h
      --help
      help
    End
    It "recognizes [$1]"
      When call is_help "$1"
      The status should be success
    End
  End

  Describe 'is_help rejects non-help tokens'
    Parameters
      list
      --update
    End
    It "rejects [$1]"
      When call is_help "$1"
      The status should be failure
    End

    It 'rejects an empty token'
      When call is_help ""
      The status should be failure
    End
  End

  Describe 'args_contain_help'
    It 'finds a help flag anywhere in the list'
      When call args_contain_help --update --help
      The status should be success
    End
    It 'finds a lone -h'
      When call args_contain_help -h
      The status should be success
    End
    It 'finds -h among other args'
      When call args_contain_help --all -h --update
      The status should be success
    End
    It 'returns failure for an empty list'
      When call args_contain_help
      The status should be failure
    End
    It 'returns failure when no help flag is present'
      When call args_contain_help --update --all
      The status should be failure
    End
    It 'ignores a bare help token (collides with positionals)'
      When call args_contain_help help
      The status should be failure
    End
  End

  Describe 'require_cmd'
    It 'passes when every command is present'
      When call require_cmd awk sort sed
      The status should be success
    End
    It 'dies listing the missing command(s)'
      When run require_cmd awk definitely_missing_xyz sort
      The status should be failure
      The stderr should include "definitely_missing_xyz"
    End
  End

  Describe 'for_each'
    ok_one() { return 0; }
    act() { [ "$1" = bad ] && return 1; return 0; }

    It 'runs the action per non-empty line and returns 0 when all pass'
      Data
        #|a
        #|
        #|b
        #|c
      End
      When call for_each demo ok_one
      The status should be success
    End

    It 'tallies failures, warns, and returns the failure count'
      Data
        #|good
        #|bad
        #|good
        #|bad
      End
      When call for_each demo act
      The status should eq 2
      The stderr should include "demo: 2 of 4 failed"
    End

    It "exposes the caller's locals to the action via dynamic scope"
      need_ctx() { [ "$PREFIX" = ctx ] || return 1; return 0; }
      outer() { local PREFIX=ctx; printf 'x\n' | for_each demo need_ctx; }
      When call outer
      The status should be success
    End
  End

  Describe 'notify::available (Hammerspoon OSD probe)'
    # The probe `notify` uses to decide whether the running Hammerspoon's `hs`
    # CLI is reachable — extracted so copy-pwd (and any OSD caller) shares the
    # one implementation. $HS overrides the path; PATH is the fallback.
    # A fresh dir per example — TMPBASE is shared across examples, so a stub
    # left by one example must not leak onto the next one's PATH.
    setup_hs() { HSDIR=$(mktemp -d "$SHELLSPEC_TMPBASE/hsbin.XXXXXX"); }
    BeforeEach 'setup_hs'

    It 'is true when the hs CLI is present and executable'
      present() {
        printf '#!/bin/sh\nexit 0\n' >"$HSDIR/hs"; chmod +x "$HSDIR/hs"
        HS="$HSDIR/hs" notify::available
      }
      When call present
      The status should be success
    End

    It 'prints the resolved hs path with --path'
      with_path() {
        printf '#!/bin/sh\n' >"$HSDIR/hs"; chmod +x "$HSDIR/hs"
        HS="$HSDIR/hs" notify::available --path
      }
      When call with_path
      The status should be success
      The output should equal "$HSDIR/hs"
    End

    It 'is false when hs is absent (no override, none on PATH)'
      absent() { HS="$HSDIR/nope" PATH="$HSDIR" notify::available; }
      When call absent
      The status should be failure
    End
  End

  Describe 'poll::until (bounded in-process wall-clock poll)'
    # The in-process twin of the `wait-until` bin: run a shell command/function
    # until it succeeds or the wall-clock budget elapses. Checked once before
    # the first sleep; wall-clock bounded; a non-positive interval collapses to
    # one check.
    setup_poll() { PDIR=$(mktemp -d "$SHELLSPEC_TMPBASE/poll.XXXXXX"); }
    BeforeEach 'setup_poll'

    It 'returns 0 as soon as the condition becomes true within budget'
      # True on the 3rd probe (counter in a file).
      becomes_true() {
        local n; n=$(( $(cat "$PDIR/c" 2>/dev/null || echo 0) + 1 ))
        print -r -- "$n" >"$PDIR/c"
        (( n >= 3 ))
      }
      drive() { poll::until 5 0.01 becomes_true; }
      When call drive
      The status should be success
    End

    It 'returns non-zero when the condition never holds, bounded by the wall clock'
      # 0.2s budget on an always-false condition returns promptly (not hung);
      # the guard turns a runaway wait into a distinct failure instead of a hang.
      never() { false; }
      drive() {
        zmodload zsh/datetime
        local -F t0=$EPOCHREALTIME
        poll::until 0.2 0.01 never
        local rc=$?
        (( (EPOCHREALTIME - t0) < 2 )) || return 3
        return $rc
      }
      When call drive
      The status should equal 1
    End

    It 'checks once before sleeping (an already-true condition returns immediately)'
      # A huge interval would hang here if the first check came after a sleep.
      yes_now() { true; }
      drive() { poll::until 5 999 yes_now; }
      When call drive
      The status should be success
    End

    It 'respects the interval — a coarser interval means far fewer probes'
      bump() { printf x >>"$PDIR/probes"; false; }
      probe_count() {
        poll::until 0.3 0.1 bump
        local n; n=$(wc -c <"$PDIR/probes" | tr -d ' ')
        # ~3-4 probes at 0.1s over 0.3s; a 0.01s poll would be ~30.
        [ "$n" -ge 1 ] && [ "$n" -le 6 ]
      }
      When call probe_count
      The status should be success
    End
  End

  Describe 'have_tty'
    It 'is callable and yields a boolean (0/1) status'
      yields_boolean() { have_tty; rc=$?; [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; }
      When call yields_boolean
      The status should be success
    End
  End

  # HI-1: have_tty must test whether /dev/tty can be OPENED, not merely whether
  # the node exists. /dev/tty always exists, but opening it fails (ENXIO) when
  # the process has no controlling terminal (setsid/launchd/CI). The two
  # environments below — a session with no controlling terminal, and a real pty
  # on stdin — are exactly what `[ -e /dev/tty ]` cannot tell apart but the
  # openability test can.
  #
  # Simulation note: `setsid(1)` is absent on this macOS host, so python3's
  # os.setsid()/pty.openpty() stand in for it. The child sources the real
  # common.zsh and exits with have_tty's status, which python propagates.
  Describe 'have_tty controlling-terminal semantics (HI-1)'
    LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh"

    setup() {
      HELPER="$SHELLSPEC_TMPBASE/have_tty_probe.py"
      cat >"$HELPER" <<'PY'
import os, sys, pty
lib = os.environ["COMMON_LIB"]
mode = sys.argv[1]
child_stdin = None
if mode == "tty":
    # Give the child a real terminal on stdin so `[ -t 0 ]` is true.
    _, child_stdin = pty.openpty()
pid = os.fork()
if pid == 0:
    os.setsid()  # new session => no controlling terminal => /dev/tty unopenable
    if child_stdin is not None:
        os.dup2(child_stdin, 0)
    os.execvp("zsh", ["zsh", "-c", 'source "$COMMON_LIB"; have_tty'])
if child_stdin is not None:
    os.close(child_stdin)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PY
    }
    BeforeEach 'setup'

    no_ctty()  { COMMON_LIB="$LIB" python3 "$HELPER" notty </dev/null; }
    tty_stdin() { COMMON_LIB="$LIB" python3 "$HELPER" tty; }

    It 'returns non-zero with no controlling terminal and stdin not a tty'
      When run no_ctty
      The status should be failure
    End

    It 'returns zero when stdin is a tty'
      When run tty_stdin
      The status should be success
    End
  End
End
