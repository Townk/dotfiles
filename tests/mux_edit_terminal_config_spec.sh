# Characterization test for edit-terminal-config's SSH detection after the C3
# migration (Decision 4, 2026-08-01): it now reads SSH state from the tmux
# SESSION env via mux::session_is_remote — the attach-time truth — instead of
# this process's (the tmux server's BIRTH) env. So a locally-attached session
# whose server merely happened to be born over ssh now edits the GHOSTTY config,
# and a remote-attached session edits ~/.ssh/config, regardless of the server's
# birth env. This is the deliberate behavior change; it pins that behavior.
Describe 'edit-terminal-config — session-env SSH detection (Decision 4)'
  # Two warm slots for the two stubs every example writes: see
  # tests/exec_warm_helper.sh.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 2'
  SCRIPT="home/dot_config/mux/scripts/executable_edit-terminal-config"

  setup() {
    TEST_TMP=$(mktemp -d)
    NEWWIN_LOG="$TEST_TMP/new-window.log"
    export NEWWIN_LOG

    # tmux stub: answers show-environment (TERM_PROGRAM + the SSH_CONNECTION the
    # session-env probe reads, targeted or not), display -p, and logs new-window.
    cat >"$TEST_TMP/tmux" <<'EOS'
#!/usr/bin/env zsh
if [[ "$1" == show-environment ]]; then
  if [[ "$2" == -t ]]; then key="$4"; else key="$2"; fi
  case "$key" in
    SSH_CONNECTION)
      if [[ -n "${STUB_SSH:-}" ]]; then print -- "SSH_CONNECTION=$STUB_SSH"
      else print -- "-SSH_CONNECTION"; fi ;;
    TERM_PROGRAM) print -- "TERM_PROGRAM=${STUB_TERM_PROGRAM:-ghostty}" ;;
  esac
  exit 0
fi
[[ "$1" == display ]] && { print -- "${STUB_SESSION:-work}"; exit 0; }
[[ "$1" == list-windows ]] && exit 0        # no existing config window
[[ "$1" == new-window ]] && { print -r -- "$*" >>"$NEWWIN_LOG"; exit 0; }
exit 0
EOS
    cat >"$TEST_TMP/nvim" <<'EOS'
#!/usr/bin/env zsh
exit 0
EOS
    chmod +x "$TEST_TMP/tmux" "$TEST_TMP/nvim"
    ORIGINAL_PATH="$PATH"
    export PATH="$TEST_TMP:$PATH"
    export MUX_TMUX_BIN="$TEST_TMP/tmux"
    export MUX_LIB="$PWD/home/dot_local/lib"   # source the repo mux-bootstrap
    export TMUX="/tmp/fake,1,0"
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY MUX_MODAL_TARGET_PANE
  }
  cleanup() {
    PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMP"
    unset MUX_TMUX_BIN MUX_LIB TMUX STUB_SSH STUB_SESSION STUB_TERM_PROGRAM NEWWIN_LOG
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'opens ~/.ssh/config when the SESSION env reports a remote client'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    When call zsh -f "$SCRIPT"
    The contents of file "$NEWWIN_LOG" should include "Remote SSH Config"
    The contents of file "$NEWWIN_LOG" should include ".ssh/config"
    The status should be success
  End

  # Ghostty actually sets TERM_PROGRAM=ghostty (lowercase) — the value the tmux
  # session env carries and the script recovers. The match must be
  # case-insensitive; a literal "== Ghostty" fell through to UNKNOWN → exit 1
  # (the Cmd+, regression once Decision 4 stopped masking it as SSH).
  It 'opens the Ghostty config for the real lowercase TERM_PROGRAM=ghostty'
    export STUB_TERM_PROGRAM="ghostty"
    When call zsh -f "$SCRIPT"
    The contents of file "$NEWWIN_LOG" should include "Ghostty Config"
    The contents of file "$NEWWIN_LOG" should not include ".ssh/config"
    The status should be success
  End

  It 'still matches a capitalized TERM_PROGRAM (case-insensitive)'
    export STUB_TERM_PROGRAM="Ghostty"
    When call zsh -f "$SCRIPT"
    The contents of file "$NEWWIN_LOG" should include "Ghostty Config"
    The status should be success
  End

  It 'opens the Wezterm config for TERM_PROGRAM=WezTerm'
    export STUB_TERM_PROGRAM="WezTerm"
    When call zsh -f "$SCRIPT"
    The contents of file "$NEWWIN_LOG" should include "Wezterm Config"
    The status should be success
  End
End

# The Rex branch: the config tab is focused when it is open, opened otherwise,
# and shown either way — one call to the shim's tab verb. Hermetic: `rex` is a
# stub that logs its argv.
Describe 'edit-terminal-config on Rex'
  SCRIPT="home/dot_config/mux/scripts/executable_edit-terminal-config"

  setup() {
    TEST_TMP=$(mktemp -d)
    cat >"$TEST_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$TEST_TMP/rex.log"
case " \$* " in
  *" session.view "*) echo "{\"session_id\":\"session:s\",\"windows\":[{\"window_id\":\"window:one\",\"label\":\"\${STUB_LABEL:-shell}\"}]}" ;;
  *" client ls "*) echo '{"clients":[{"client_id":"client:mac","info":{"kind":"app"},"connection_state":"connected","session_ids":["session:s"]}]}' ;;
  *" window new "*) [ "\${STUB_NEW:-ok}" = ok ] || exit 1; echo '{"window_id":"window:new"}' ;;
esac
exit 0
EOS
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$TEST_TMP/nvim"
    chmod +x "$TEST_TMP/rex" "$TEST_TMP/nvim"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset STUB_LABEL STUB_NEW; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A HOME that does not exist, and NOT under /home: that is an automount
  # point on macOS, where every lookup of a dotfile below it (jq's ~/.jq,
  # zsh's ~/.zshenv) waits ~100 ms for autofs to say no.
  edit() {
    env -u TMUX -u MUX_BACKEND -u REX_CLIENT -u REX_BLOCK HOME=/nohome/u PATH="$TEST_TMP:$PATH" \
      REX_SESSION=session:s MUX_REX_BIN="$TEST_TMP/rex" MUX_LIB="$PWD/home/dot_local/lib" zsh -f "$SCRIPT" 2>/dev/null
    print -r -- "rc=$?"
  }
  calls() { grep -E ' window | session\.select ' "$TEST_TMP/rex.log" | sed -e 's/^--autostart=false //' -e 's/^--timeout 3s //'; }

  It 'opens the Rex config in a tab named for it, and shows the tab'
    run() { edit; calls; }
    When call run
    The output should equal "rc=0
window new -s session:s --json Rex Config -- $TEST_TMP/nvim /nohome/u/.config/rex/init.lua
-C client:mac do -s session:s session.select session_id=session:s window_id=window:new"
  End

  It 'focuses and shows the config tab that is already open instead of a second'
    export STUB_LABEL="Rex Config"
    run() { edit; calls; }
    When call run
    The output should equal "rc=0
window focus -s session:s window:one
-C client:mac do -s session:s session.select session_id=session:s window_id=window:one"
  End

  It 'fails when the tab cannot be opened'
    export STUB_NEW=fail
    When call edit
    The output should equal "rc=1"
  End
End
