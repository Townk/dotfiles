# Tests for lib/dispatch-tmux.zsh — the quick-launch tmux backend (mux
# migration Phase 3). A stub tmux records every invocation; the zellij path
# is proven untouched by zellij_spec + the byte-identical dispatch functions
# (only the entry branches changed).
Describe 'quick-launch tmux dispatch'
  setup() {
    TEST_TMP=$(mktemp -d)
    TX_LOG="$TEST_TMP/tmux-calls.log"
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo "echo \"\$*\" >> \"$TEST_TMP/tmux-calls.log\""
      echo 'case "$1" in'
      echo '  list-panes) exit 0 ;;'
      echo '  list-sessions) print -- "${STUB_SESSIONS:-}" ;;'
      echo '  split-window|new-window) print -- "%42" ;;'
      echo '  show-options) print -- "0" ;;'
      echo 'esac'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"

    # Minimal QL world: config/command libs loaded for the shared helpers.
    export SCRIPT_DIR="$PWD/home/dot_config/zellij/scripts"
    source home/dot_config/zellij/scripts/lib/config.zsh
    source home/dot_config/zellij/scripts/lib/command.zsh
    source home/dot_config/zellij/scripts/lib/dispatch.zsh
    source home/dot_config/zellij/scripts/lib/dispatch-tmux.zsh
    QL_JSON='{"panes":[{"id":"logs","name":"Logs","direction":"down","action":{"type":"Run","args":["tail","-f","/tmp/x"]}}],"tabs":[{"id":"dev","name":"Dev","action":{"type":"Shell"}}],"workspaces":[{"id":"proj","name":"Proj","tabs":[{"id":"t1","name":"Edit","action":{"type":"Shell"}}]},{"id":"remote","name":"Remote","nested_mux":true,"action":{"type":"Run","args":["ssh","box"]}}]}'
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN STUB_SESSIONS; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'opens a pane as a directional split with @ql_id stamped'
    When call ql_dispatch pane logs
    The contents of file "$TX_LOG" should include "split-window -v"
    The contents of file "$TX_LOG" should include "@ql_id logs"
    The status should be success
  End

  It 'focuses an existing tab window by exact name'
    When call ql_dispatch tab dev
    The contents of file "$TX_LOG" should include "select-window -t =Dev"
    The status should be success
  End

  It 'creates a workspace session detached and switches to it'
    When call ql_dispatch workspace proj
    The contents of file "$TX_LOG" should include "new-session -d -s Proj"
    The contents of file "$TX_LOG" should include "new-window -n Edit"
    The contents of file "$TX_LOG" should include "switch-client -t Proj"
    The status should be success
  End

  It 'switches to an existing workspace session without recreating'
    export STUB_SESSIONS="Proj"
    When call ql_dispatch workspace proj
    The contents of file "$TX_LOG" should include "switch-client -t Proj"
    The contents of file "$TX_LOG" should not include "new-session"
    The status should be success
  End

  It 'nested_mux workspaces get prefix None + the nested key-table (D14)'
    When call ql_dispatch workspace remote
    The contents of file "$TX_LOG" should include "prefix None"
    The contents of file "$TX_LOG" should include "key-table nested"
    The status should be success
  End

  It 'nested_zellij is read as a nested_mux alias'
    ws='{"id":"x","nested_zellij":true}'
    When call ql_workspace_is_nested "$ws"
    The status should be success
  End
End
