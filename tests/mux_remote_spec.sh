# Characterization tests for the canonical remote-detection pair in
# home/dot_local/lib/mux-bootstrap.zsh:
#
#   mux::is_remote          — the process-env triple (SSH_TTY / SSH_CONNECTION /
#                             SSH_CLIENT). Pins that SSH_TTY is part of the
#                             identity — three call sites had dropped it, which
#                             misclassified a no-pty `ssh -T` login as local.
#   mux::session_is_remote  — the tmux SESSION-env probe (attach-time truth),
#                             with quick-launch-window's pane-pinned target
#                             resolution: an explicit target wins, else
#                             $MUX_MODAL_TARGET_PANE, else `display -p
#                             '#{session_name}'`.

Describe 'mux-bootstrap.zsh — mux::is_remote'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() { unset SSH_TTY SSH_CONNECTION SSH_CLIENT; }
  BeforeEach 'setup'

  It 'is remote when only SSH_TTY is set (the ssh -T case the 3 copies dropped)'
    export SSH_TTY=/dev/ttys003
    When call mux::is_remote
    The status should be success
  End

  It 'is remote when only SSH_CONNECTION is set'
    export SSH_CONNECTION="1.2.3.4 51000 5.6.7.8 22"
    When call mux::is_remote
    The status should be success
  End

  It 'is remote when only SSH_CLIENT is set'
    export SSH_CLIENT="1.2.3.4 51000 22"
    When call mux::is_remote
    The status should be success
  End

  It 'is local when none of the three are set'
    When call mux::is_remote
    The status should be failure
  End
End

Describe 'mux-bootstrap.zsh — mux::session_is_remote'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    # A tmux stub: `display -p` yields the "most recently used" session, and
    # `show-environment` records the target it was asked about and answers with
    # (or without) an SSH_CONNECTION line, mirroring real tmux — a LOCAL
    # session reports "-SSH_CONNECTION" (leading dash), a remote one the
    # "SSH_CONNECTION=..." assignment.
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == display ]]; then'
      echo '  print -r -- "${STUB_DISPLAY_SESSION:-mru-session}"'
      echo '  exit 0'
      echo 'fi'
      echo 'if [[ "$1" == show-environment ]]; then'
      echo '  tgt=""'
      echo '  [[ "$2" == -t ]] && tgt="$3"'
      echo '  print -r -- "$tgt" > "$STUB_TARGET_FILE"'
      echo '  if [[ -n "${STUB_SSH:-}" ]]; then'
      echo '    print -- "SSH_CONNECTION=$STUB_SSH"'
      echo '  else'
      echo '    print -- "-SSH_CONNECTION"'
      echo '  fi'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
    export STUB_TARGET_FILE="$TEST_TMP/target"
    export TMUX="/tmp/fake-tmux,1,0"   # enable the no-target (in-session) path
    unset MUX_MODAL_TARGET_PANE STUB_SSH STUB_DISPLAY_SESSION
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset MUX_TMUX_BIN STUB_TARGET_FILE TMUX MUX_MODAL_TARGET_PANE STUB_SSH STUB_DISPLAY_SESSION
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'is remote when the session env carries SSH_CONNECTION'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    When call mux::session_is_remote
    The status should be success
  End

  It 'is local when the session env has no SSH_CONNECTION'
    When call mux::session_is_remote
    The status should be failure
  End

  It 'pins the probe to MUX_MODAL_TARGET_PANE when set'
    export MUX_MODAL_TARGET_PANE="%7"
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    When call mux::session_is_remote
    The status should be success
    The contents of file "$STUB_TARGET_FILE" should include "%7"
  End

  It 'falls back to display -p session_name when no pane is pinned'
    export STUB_DISPLAY_SESSION="mru-session"
    When call mux::session_is_remote
    The status should be failure
    The contents of file "$STUB_TARGET_FILE" should include "mru-session"
  End

  It 'probes an explicit target session when given one'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    When call mux::session_is_remote "other-sess"
    The status should be success
    The contents of file "$STUB_TARGET_FILE" should include "other-sess"
  End

  It 'is local (non-tmux) when no target and not inside tmux'
    unset TMUX
    When call mux::session_is_remote
    The status should be failure
  End
End
