# Regression test for home/dot_local/lib/mux/zellij.zsh — _mux_zj_session_state.
#
# HI-6: the liveness probe matched the session NAME with `grep -qE "^${name}\b"`,
# where `\b` is a word boundary (NOT a field/line anchor) and $name is
# interpolated raw into an ERE. So "Main" matched "Main-work" (word boundary at
# the hyphen), metacharacter names ("Project(1)") broke the ERE, and
# `grep -v EXITED` dropped any LIVE session whose name merely contained "EXITED".
# The tmux twin (_mux_tx_session_state) gets this right via `has-session -t=`
# (exact). The fix matches the session NAME field exactly as a fixed string and
# filters the resurrectable "(EXITED …)" record by its trailing marker, not by a
# whole-line substring.
#
# Stub zellij: `list-sessions -n` emits the real formatting — one line per
# session, "<name> [Created <t> ago]" with a trailing "(EXITED - attach to
# resurrect)" for resurrectable records — driven by ZJ_LIVE / ZJ_EXITED. The
# `--session <name> action list-clients` probe prints a header row plus one
# client row per name listed in ZJ_BUSY (the real command always prints a
# header, hence the code's `tail -n +2`).
Describe 'mux/zellij.zsh — _mux_zj_session_state exact NAME matching (HI-6)'
  Include home/dot_local/lib/mux/zellij.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == list-sessions ]]; then'
      echo '  for s in ${(f)ZJ_LIVE};   do [[ -n "$s" ]] && print -r -- "$s [Created 5m ago]"; done'
      echo '  for s in ${(f)ZJ_EXITED}; do [[ -n "$s" ]] && print -r -- "$s [Created 2h ago] (EXITED - attach to resurrect)"; done'
      echo '  exit 0'
      echo 'fi'
      echo 'if [[ "$1" == --session ]]; then'
      echo '  sess="$2"'
      echo '  print -r -- "CLIENT_ID ZOOMED PANE_ID"'   # header row
      echo '  for s in ${(f)ZJ_BUSY}; do [[ "$s" == "$sess" ]] && print -r -- "1 false 0"; done'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
    # Export the fixtures so the stub subprocess (an external "binary") sees them.
    # Reassigning an already-exported var in a test keeps the export attribute.
    export ZJ_LIVE="" ZJ_EXITED="" ZJ_BUSY=""
  }
  cleanup() { rm -rf "$TEST_TMP"; unset ZELLIJ_BIN ZJ_LIVE ZJ_EXITED ZJ_BUSY; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'reports missing when only a longer-named session (Main-work) is live'
    # The bug: "^Main\b" matches "Main-work" (word boundary at the hyphen).
    ZJ_LIVE="Main-work"
    When call _mux_zj_session_state Main
    The output should equal "missing"
  End

  It 'reports idle for an exact, live, client-less session'
    ZJ_LIVE="Main"
    When call _mux_zj_session_state Main
    The output should equal "idle"
  End

  It 'reports busy for an exact, live session that has a client'
    ZJ_LIVE="Main"
    ZJ_BUSY="Main"
    When call _mux_zj_session_state Main
    The output should equal "busy"
  End

  It 'does not let a truly-absent name match a coexisting Main / Main-work pair'
    ZJ_LIVE="Main
Main-work"
    When call _mux_zj_session_state Other
    The output should equal "missing"
    # And the exact one still resolves to its live state.
  End

  It 'keeps a LIVE session whose name contains EXITED (not a resurrectable record)'
    # The bug: `grep -v EXITED` dropped this line as if it were an exited record.
    ZJ_LIVE="Main-EXITED"
    When call _mux_zj_session_state Main-EXITED
    The output should equal "idle"
  End

  It 'treats a genuine (EXITED …) record as missing'
    ZJ_EXITED="Ghost"
    When call _mux_zj_session_state Ghost
    The output should equal "missing"
  End

  It 'exact-matches a name containing ERE metacharacters without error'
    # The bug: "^Project(1)\b" is an invalid/greedy ERE; a fixed-string match
    # must resolve it exactly and never error.
    ZJ_LIVE="Project(1)"
    When call _mux_zj_session_state 'Project(1)'
    The output should equal "idle"
  End

  It 'does not false-match a metacharacter query against an unrelated live session'
    ZJ_LIVE="ProjectX"
    When call _mux_zj_session_state 'Project(1)'
    The output should equal "missing"
  End
End
