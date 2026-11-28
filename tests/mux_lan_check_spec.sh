# mux-lan-check — the startup warning for a tmux server macOS has cut off
# from the LAN. The probe (_mux_lan_responsible) is replaced by a fake: what
# is under test is when the warning prints, not macOS's answer.
Describe 'mux_lan_check'
  SRC="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/functions.d/mux-lan-check.sh"

  setup() { FIX=$(mktemp -d); }
  cleanup() { rm -rf "$FIX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # check <TMUX value> <pid the fake probe answers, or "fail"> [times]
  check() {
    source "$SRC"
    if [[ "$2" == fail ]]; then
      _mux_lan_responsible() { return 1; }
    else
      eval "_mux_lan_responsible() { print -r -- $2; }"
    fi
    local n
    for n in {1..${3:-1}}; do
      OSTYPE=darwin27 TMUX="$1" TMPDIR="$FIX" mux_lan_check || return $?
    done
  }

  It 'warns when the server is its own responsible process'
    When call check "/tmp/tmux-501/default,2458,0" 2458
    The status should be success
    The output should include "tmux server (pid 2458) outlived the terminal app"
    The output should include "tmux kill-server"
  End

  It 'stays quiet while the terminal app still answers for the server'
    When call check "/tmp/tmux-501/default,2458,0" 89295
    The status should be success
    The output should equal ""
  End

  It 'warns once per server, not once per pane'
    When call check "/tmp/tmux-501/default,2458,0" 2458 3
    The lines of output should equal 3
  End

  It 'warns again for a different server'
    twice() { check "/tmp/tmux-501/default,2458,0" 2458; check "/tmp/tmux-501/other,777,0" 777; }
    When call twice
    The output should include "pid 2458"
    The output should include "pid 777"
  End

  It 'warns again once the last warning is older than the window'
    aged() {
      check "/tmp/tmux-501/default,2458,0" 2458 >/dev/null
      touch -t 202001010000 "$FIX/mux-lan-orphan.2458"
      check "/tmp/tmux-501/default,2458,0" 2458
    }
    When call aged
    The output should include "pid 2458"
  End

  # One stamp per server, and servers come and go: nothing removed the
  # stamps of the ones that are gone, so they collected in $TMPDIR for ever
  # (176 of them after a day of test runs, each starting scratch servers).
  It 'removes the stamps of servers that are gone when it writes a new one'
    pruned() {
      : >"$FIX/mux-lan-orphan.99999999"          # no such process
      : >"$FIX/mux-lan-orphan.$$"                # a live one: this shell
      : >"$FIX/mux-lan-orphan.notapid"           # not ours to judge
      check "/tmp/tmux-501/default,2458,0" 2458 >/dev/null
      ls "$FIX" | sed "s/\\.$$\$/.LIVE/" | sort | tr '\n' ' '
    }
    When call pruned
    The output should equal "mux-lan-orphan.2458 mux-lan-orphan.LIVE mux-lan-orphan.notapid "
  End

  It 'is silent outside tmux'
    When call check "" 2458
    The status should be success
    The output should equal ""
  End

  It 'is silent when the probe cannot tell'
    When call check "/tmp/tmux-501/default,2458,0" fail
    The status should be success
    The output should equal ""
  End

  It 'is silent off macOS'
    linux() { source "$SRC"; _mux_lan_responsible() { print 2458; }; OSTYPE=linux-gnu TMUX="/tmp/tmux-1000/default,2458,0" TMPDIR="$FIX" mux_lan_check; }
    When call linux
    The status should be success
    The output should equal ""
  End
End
