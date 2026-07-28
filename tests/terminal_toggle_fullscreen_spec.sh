# Tests for terminal-toggle-fullscreen's host-terminal dispatch.
Describe 'terminal-toggle-fullscreen'
  setup() {
    TEST_TMP=$(mktemp -d)
    export APPLESCRIPT_LOG="$TEST_TMP/applescript.log"

    cat >"$TEST_TMP/osascript" <<'EOF'
#!/usr/bin/env zsh
while IFS= read -r line; do print -r -- "$line" >>"$APPLESCRIPT_LOG"; done
print -- true
EOF
    cat >"$TEST_TMP/uname" <<'EOF'
#!/usr/bin/env zsh
print -- Darwin
EOF
    chmod +x "$TEST_TMP/osascript" "$TEST_TMP/uname"
    ORIGINAL_PATH="$PATH"
    export PATH="$TEST_TMP:$PATH"
    unset SSH_CONNECTION SSH_CLIENT
  }
  cleanup() {
    PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMP"
    unset APPLESCRIPT_LOG TERM_PROGRAM GHOSTTY_RESOURCES_DIR
  }
  BeforeEach setup
  AfterEach cleanup

  It 'uses Ghostty fullscreen action on the focused terminal'
    export TERM_PROGRAM=ghostty
    When call zsh home/dot_config/mux/scripts/executable_terminal-toggle-fullscreen
    The contents of file "$APPLESCRIPT_LOG" should include 'focused terminal'
    The contents of file "$APPLESCRIPT_LOG" should include 'perform action "toggle_fullscreen"'
    The contents of file "$APPLESCRIPT_LOG" should not include 'AXFullScreen'
    The output should equal ""
    The status should be success
  End
End
