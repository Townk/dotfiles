# Regression test for home/dot_local/lib/zellij.zsh — zj::pick.
#
# `zellij action new-pane` prints the created pane id (e.g. "terminal_5") to
# stdout ("Returns: Created pane ID" in its --help). zj::pick spawns the float
# with that command and then prints the FIFO selection on its own stdout, so a
# caller that captures `$(zj::pick ...)` (ai-commit / ai-assist harness pickers)
# must receive ONLY the selection — never the leaked pane id prepended to it.
Describe 'zellij.zsh — zj::pick'
  Include home/dot_local/lib/zellij.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    export ZELLIJ=1
    # Stub zellij: on `action new-pane`, reproduce the real behavior — emit a
    # pane id to stdout — and deliver the selection through the --capture FIFO,
    # standing in for the modal+picker child.
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { printf "claude" > "$fifo" & }'
      echo '  print -- "terminal_99"'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'returns only the FIFO selection, not the leaked new-pane id'
    Data
      #|claude  Claude Code
    End
    When call zj::pick --output field:1 --header "Pick"
    The output should equal "claude"
    The status should be success
  End
End
