# Characterization test for edit-terminal-config's SSH detection after the C3
# migration (Decision 4, 2026-08-01): it now reads SSH state from the tmux
# SESSION env via mux::session_is_remote — the attach-time truth — instead of
# this process's (the tmux server's BIRTH) env. So a locally-attached session
# whose server merely happened to be born over ssh now edits the GHOSTTY config,
# and a remote-attached session edits ~/.ssh/config, regardless of the server's
# birth env. This is the deliberate behavior change; it pins that behavior.
Describe 'edit-terminal-config — session-env SSH detection (Decision 4)'
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
    When call zsh "$SCRIPT"
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
    When call zsh "$SCRIPT"
    The contents of file "$NEWWIN_LOG" should include "Ghostty Config"
    The contents of file "$NEWWIN_LOG" should not include ".ssh/config"
    The status should be success
  End

  It 'still matches a capitalized TERM_PROGRAM (case-insensitive)'
    export STUB_TERM_PROGRAM="Ghostty"
    When call zsh "$SCRIPT"
    The contents of file "$NEWWIN_LOG" should include "Ghostty Config"
    The status should be success
  End

  It 'opens the Wezterm config for TERM_PROGRAM=WezTerm'
    export STUB_TERM_PROGRAM="WezTerm"
    When call zsh "$SCRIPT"
    The contents of file "$NEWWIN_LOG" should include "Wezterm Config"
    The status should be success
  End
End
