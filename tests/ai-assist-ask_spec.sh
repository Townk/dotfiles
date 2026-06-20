Describe 'ai-assist-ask'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-ask"

  setup() {
    TEST_TMP="$(mktemp -d)"
    gum="$TEST_TMP/gum"
    { echo '#!/usr/bin/env zsh'; echo 'printf "%s" "${GUM_OUT:-}"'; echo 'exit ${GUM_RC:-0}'; } > "$gum"
    chmod +x "$gum"; export GUM_BIN="$gum"
    aii="$TEST_TMP/ai-assist-input"
    { echo '#!/usr/bin/env zsh'; echo 'printf "%s" "${AII_OUT:-}"'; echo 'exit ${AII_RC:-0}'; } > "$aii"
    chmod +x "$aii"; export AI_ASSIST_INPUT_BIN="$aii"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset GUM_BIN AI_ASSIST_INPUT_BIN GUM_OUT GUM_RC AII_OUT AII_RC; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'returns a free-text answer'
    export AII_OUT="rebuild with -j1"
    When run "$SCRIPT" --type free "What did you try?"
    The output should equal "rebuild with -j1"
    The status should be success
  End

  It 'maps a yes confirm to exit 0'
    export GUM_RC=0
    When run "$SCRIPT" --type confirm "Did this solve it?"
    The output should equal "yes"
    The status should be success
  End

  It 'maps a no confirm to exit 1'
    export GUM_RC=1
    When run "$SCRIPT" --type confirm "Did this solve it?"
    The output should equal "no"
    The status should eq 1
  End

  It 'treats an empty free answer as cancel (130)'
    export AII_OUT=""
    When run "$SCRIPT" --type free "anything?"
    The status should eq 130
  End

  It 'returns a line answer'
    export GUM_OUT="some typed input"
    When run "$SCRIPT" --type line "Enter something"
    The output should equal "some typed input"
    The status should be success
  End
End
