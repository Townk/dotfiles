# Regression test for home/dot_local/lib/zellij.zsh — zj::pick.
#
# `zellij action new-pane` prints the created pane id (e.g. "terminal_5") to
# stdout ("Returns: Created pane ID" in its --help). zj::pick spawns the float
# with that command and then prints the FIFO selection on its own stdout, so a
# caller that captures `$(zj::pick ...)` (ai-commit / ai-assist harness pickers)
# must receive ONLY the selection — never the leaked pane id prepended to it.
#
# Stub FIFO delivery: each stub writes the selection through an O_RDWR fd held
# open briefly (`exec 3<>fifo; printf …>&3; sleep; exec 3>&-`) instead of a
# blocking `> "$fifo" &` writer. The blocking-open writer could be lost before
# it rendezvoused with zj::pick's reader — leaving `cat "$fifo"` waiting forever
# and the captured stdout/stderr pipe held open (the suite hung here). An O_RDWR
# open never blocks, so the byte is buffered and the reader always drains it.
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
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "claude" >&3; sleep 0.5; exec 3>&- } &! }'
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

Describe 'zellij.zsh — zj::confirm borderless float'
  Include home/dot_local/lib/zellij.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "yes" >&3; sleep 0.5; exec 3>&- } &! }'
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

  It 'spawns confirm in a borderless pane with the title on the widget'
    When call zj::confirm --title "Quit" "Really?"
    The output should equal "yes"
    The contents of file "$ZJ_ARGS" should include "--borderless true"
    The contents of file "$ZJ_ARGS" should include "--type confirm"
    The contents of file "$ZJ_ARGS" should include "--title Quit"
    The status should be success
  End

  It 'spawns confirm without --title when none given (no title duplication)'
    When call zj::confirm "Really?"
    The output should equal "yes"
    The contents of file "$ZJ_ARGS" should include "--type confirm"
    The contents of file "$ZJ_ARGS" should not include "--title"
    The status should be success
  End
End

Describe 'zellij.zsh — zj::choose borderless float'
  Include home/dot_local/lib/zellij.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "alpha" >&3; sleep 0.5; exec 3>&- } &! }'
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

  It 'spawns choose in a borderless pane with --type choose'
    When call zj::choose --title "Pick one" "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--borderless true"
    The contents of file "$ZJ_ARGS" should include "--type choose"
    The status should be success
  End

  It 'passes --multi through to the float'
    When call zj::choose --title "Pick" "Select" --multi -- alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--multi"
    The status should be success
  End

  It 'passes --other through to the float'
    When call zj::choose --title "Pick" "Select" --other "Something else" -- alpha beta
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--other"
    The status should be success
  End
End

Describe 'zellij.zsh — zj::choose --measure-based pane height'
  Include home/dot_local/lib/zellij.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1

    # Stub ai-playbook input: when --measure is present, print a known height (9)
    # so we can assert the pane is spawned with --height 9.
    aii="$TEST_TMP/ai-playbook"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$*" == *"--measure"* ]]; then printf "9"; exit 0; fi'
      echo 'printf "%s" "${AII_OUT:-}"'
      echo 'exit ${AII_RC:-0}'
    } > "$aii"; chmod +x "$aii"
    export AI_PLAYBOOK_INPUT_BIN="$aii"

    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "alpha" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset AI_PLAYBOOK_INPUT_BIN AII_OUT; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'spawns the pane with --height equal to the measured value from the binary'
    When call zj::choose --title "Pick" "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--height 9"
    The status should be success
  End

  It 'does not contain any hardcoded vis+9 style height when binary returns a height'
    # The pane must carry --height matching the stub (9), not a formula result.
    # With 3 choices the old formula would yield min(3,8)+9=12; new must be 9.
    When call zj::choose --title "Pick" "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--height 9"
    The contents of file "$ZJ_ARGS" should not include "--height 12"
    The status should be success
  End
End

Describe 'zellij.zsh — zj:: input drop-ins (off-Zellij fallback)'
  Include home/dot_local/lib/zellij.zsh

  # Off-Zellij: zj::* must call the inline input::* with args intact. Stub the
  # input::* the wrappers delegate to (defined after Include → overrides).
  input::confirm() { printf 'confirm:%s' "$*"; }
  input::line()    { printf 'line:%s' "$*"; }
  input::choose()  { printf 'choose:%s' "$*"; }

  setup() { unset ZELLIJ; }   # force the non-Zellij path
  BeforeEach 'setup'

  It 'zj::confirm delegates to input::confirm with prompt only (no --title when none given)'
    When call zj::confirm "Proceed?"
    The output should include "Proceed?"
    The output should not include "--title"
    The status should be success
  End

  It 'zj::confirm forwards --title when explicitly given'
    When call zj::confirm --title "Confirm" "Proceed?"
    The output should include "--title Confirm"
    The output should include "Proceed?"
    The status should be success
  End

  It 'zj::confirm strips --pane-* before delegating'
    When call zj::confirm "Proceed?" --pane-width 40 --pane-height 7
    The output should not include "--pane-width"
    The output should include "Proceed?"
  End

  It 'zj::choose forwards choices'
    When call zj::choose "Pick" a b c
    The output should include "Pick"
    The output should include "a"
    The output should include "b"
    The output should include "c"
  End

  It 'zj::choose does not forward --title when none given'
    When call zj::choose "Pick" a b c
    The output should not include "--title"
    The status should be success
  End
End

Describe 'zellij.zsh — zj::form borderless float'
  Include home/dot_local/lib/zellij.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "form-result" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
    # Spec file for the form
    spec="$TEST_TMP/form.spec"
    printf 'name\x1fline\x1fYour name\x1esubscribe\x1fconfirm\x1fSubscribe?' > "$spec"
    FORM_SPEC="$spec"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'spawns form in a borderless pane with --type form'
    When call zj::form --title "Setup" --spec "$FORM_SPEC"
    The contents of file "$ZJ_ARGS" should include "--borderless true"
    The contents of file "$ZJ_ARGS" should include "--type form"
    The output should equal "form-result"
    The status should be success
  End
End
