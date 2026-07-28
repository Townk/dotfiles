# Tests for lib/dispatch-tmux.zsh — the quick-launch tmux backend (mux
# migration Phase 3). A stub tmux records every invocation; the zellij path
# is proven untouched by zellij_spec + the byte-identical dispatch functions
# (only the entry branches changed).
Describe 'quick-launch tmux dispatch'
  setup() {
    TEST_TMP=$(mktemp -d)
    TX_LOG="$TEST_TMP/tmux-calls.log"
    WINDOW_LOG="$TEST_TMP/window-calls.log"
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
    cat >"$TEST_TMP/quick-launch-window" <<EOF
#!/usr/bin/env zsh
print -r -- "\$*" >>"$WINDOW_LOG"
EOF
    chmod +x "$stub" "$TEST_TMP/quick-launch-window"
    export MUX_TMUX_BIN="$stub"

    # Minimal QL world: config/command libs loaded for the shared helpers.
    export SCRIPT_DIR="$TEST_TMP"
    source home/dot_config/mux/scripts/lib/config.zsh
    source home/dot_config/mux/scripts/lib/command.zsh
    source home/dot_config/mux/scripts/lib/dispatch.zsh
    source home/dot_config/mux/scripts/lib/dispatch-tmux.zsh
    QL_JSON='{"panes":[{"id":"logs","name":"Logs","direction":"down","action":{"type":"Run","args":["tail","-f","/tmp/x"]}}],"tabs":[{"id":"dev","name":"Dev","action":{"type":"Shell"}}],"workspaces":[{"id":"proj","name":"Proj","tabs":[{"id":"t1","name":"Edit","action":{"type":"Shell"}}]},{"id":"remote","name":"Remote","nested_mux":true,"action":{"type":"Remote","args":["box"]}}]}'
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN STUB_SESSIONS SCRIPT_DIR; }
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

  It 'opens a nested workspace directly without an outer tmux session'
    When call ql_dispatch_window remote
    The contents of file "$WINDOW_LOG" should include "--new Remote --"
    The contents of file "$WINDOW_LOG" should include "ssh box"
    The contents of file "$WINDOW_LOG" should not include "attach"
    The contents of file "$TX_LOG" should not include "new-session"
    The status should be success
  End
End

Describe 'quick-launch terminal window detection'
  setup_window() {
    TEST_TMP=$(mktemp -d)
    OSASCRIPT_LOG="$TEST_TMP/osascript-calls.log"
    WEZTERM_LOG="$TEST_TMP/wezterm-calls.log"
    ORIGINAL_PATH="$PATH"

    cat >"$TEST_TMP/tmux" <<'EOF'
#!/usr/bin/env zsh
if [[ "$1" == show-environment ]]; then
  case "${@: -1}" in
    SSH_CONNECTION) print -- "-SSH_CONNECTION" ;;
    TERM_PROGRAM) print -- "TERM_PROGRAM=${STUB_TERM_PROGRAM:-ghostty}" ;;
  esac
fi
EOF
    cat >"$TEST_TMP/osascript" <<EOF
#!/usr/bin/env zsh
print -r -- "\$*" >>"$OSASCRIPT_LOG"
while IFS= read -r line; do print -r -- "\$line" >>"$OSASCRIPT_LOG"; done
EOF
    cat >"$TEST_TMP/wezterm" <<EOF
#!/usr/bin/env zsh
print -r -- "\$*" >>"$WEZTERM_LOG"
EOF
    cat >"$TEST_TMP/uname" <<'EOF'
#!/usr/bin/env zsh
print -- Darwin
EOF
    chmod +x "$TEST_TMP/tmux" "$TEST_TMP/osascript" "$TEST_TMP/wezterm" \
      "$TEST_TMP/uname"

    export PATH="$TEST_TMP:$PATH"
    export TMUX=/tmp/sock,1,0
    export MUX_MODAL_TARGET_PANE=%1
    export TERMINAL_LOCATION_ONBOARD_MAP="$TEST_TMP/onboard-map.yaml"
    export TERMINAL_LOCATION_SSH_CONFIG_DIR="$TEST_TMP/ssh-config"
    export TERMINAL_LOCATION_TINT_PALETTE="$TEST_TMP/tint-palette.toml"
    mkdir -p "$TERMINAL_LOCATION_SSH_CONFIG_DIR"
    cat >"$TERMINAL_LOCATION_ONBOARD_MAP" <<'EOF'
slot-aaaaaa:
  alias: box
  profile: personal
  kind: human
EOF
    printf 'cyan = "#112233"\ngrey = "#333333"\n' \
      >"$TERMINAL_LOCATION_TINT_PALETTE"
    unset SSH_CONNECTION SSH_CLIENT GHOSTTY_RESOURCES_DIR WEZTERM_UNIX_SOCKET
  }
  cleanup_window() {
    PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMP"
    unset TMUX MUX_MODAL_TARGET_PANE STUB_TERM_PROGRAM \
      TERMINAL_LOCATION_ONBOARD_MAP TERMINAL_LOCATION_SSH_CONFIG_DIR \
      TERMINAL_LOCATION_TINT_PALETTE
  }
  BeforeEach 'setup_window'
  AfterEach 'cleanup_window'

  It 'creates one tinted Ghostty surface through AppleScript'
    When call zsh home/dot_config/mux/scripts/executable_quick-launch-window \
      --new Target -- zsh -c "ssh box"
    The contents of file "$OSASCRIPT_LOG" should include "new surface configuration"
    The contents of file "$OSASCRIPT_LOG" should include "new window with configuration"
    The contents of file "$OSASCRIPT_LOG" should include "MUX_INITIAL_COMMAND="
    The contents of file "$OSASCRIPT_LOG" should include "MUX_INITIAL_TINT="
    The contents of file "$OSASCRIPT_LOG" should not include "set initial input of cfg"
    The contents of file "$OSASCRIPT_LOG" should not include "set command of cfg"
    The contents of file "$OSASCRIPT_LOG" should include "set wait after command of cfg to false"
    The contents of file "$OSASCRIPT_LOG" should include "#112233"
    The contents of file "$OSASCRIPT_LOG" should include "ssh"
    The contents of file "$OSASCRIPT_LOG" should include "box"
    The contents of file "$OSASCRIPT_LOG" should not include "Ghostty.app --args -e"
    The status should be success
  End

  It 'forces a new WezTerm window running the direct command'
    export STUB_TERM_PROGRAM=wezterm
    When call zsh home/dot_config/mux/scripts/executable_quick-launch-window \
      --new Target -- zsh -c "ssh box"
    The contents of file "$WEZTERM_LOG" should equal \
      "cli --no-auto-start spawn --new-window -- zsh -c ssh box"
    The status should be success
  End
End
