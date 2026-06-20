Describe 'ai-assist-ask'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-ask"

  setup() {
    TEST_TMP="$(mktemp -d)"
    # Stub zellij-modal: ignore everything up to `--`, run the target, echo its
    # stdout (the capture). Mirrors the real --capture contract closely enough.
    modal="$TEST_TMP/zellij-modal"
    { echo '#!/usr/bin/env zsh'
      echo 'while (($#)); do [[ "$1" == "--" ]] && { shift; break; }; shift; done'
      echo 'printf "%s" "$ANSWER"'   # the stubbed target would print this
    } > "$modal"; chmod +x "$modal"
    export AI_ASSIST_MODAL_BIN="$modal"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset AI_ASSIST_MODAL_BIN ANSWER; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'returns a free-text answer'
    export ANSWER="rebuild with -j1"
    When run "$SCRIPT" --type free "What did you try?"
    The output should equal "rebuild with -j1"
    The status should be success
  End

  It 'maps a yes confirm to exit 0'
    export ANSWER="yes"
    When run "$SCRIPT" --type confirm "Did this solve it?"
    The output should equal "yes"
    The status should be success
  End

  It 'maps a no confirm to exit 1'
    export ANSWER="no"
    When run "$SCRIPT" --type confirm "Did this solve it?"
    The output should equal "no"
    The status should eq 1
  End

  It 'treats an empty capture as cancel (exit 130)'
    export ANSWER=""
    When run "$SCRIPT" --type free "anything?"
    The status should eq 130
  End

  It 'returns a line answer'
    export ANSWER="some typed input"
    When run "$SCRIPT" --type line "Enter something"
    The output should equal "some typed input"
    The status should be success
  End

  It 'returns a choose answer'
    export ANSWER="option-b"
    When run "$SCRIPT" --type choose "Pick one" "option-a" "option-b" "option-c"
    The output should equal "option-b"
    The status should be success
  End
End
