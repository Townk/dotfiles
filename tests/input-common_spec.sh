# Tests for input-common.zsh — themed inline widgets.
Describe 'input-common.zsh'
  Include home/dot_local/lib/input-common.zsh

  setup() {
    TEST_TMP="$(mktemp -d)"
    # Recording gum stub: append argv to gum.args, print $GUM_OUT, exit $GUM_RC.
    gum="$TEST_TMP/gum"
    { echo '#!/usr/bin/env zsh'
      echo 'print -r -- "$@" >> "'"$TEST_TMP"'/gum.args"'
      echo 'printf "%s" "${GUM_OUT:-}"'
      echo 'exit ${GUM_RC:-0}'
    } > "$gum"; chmod +x "$gum"
    export GUM_BIN="$gum"
    # ai-assist-input stub.
    aii="$TEST_TMP/ai-assist-input"
    { echo '#!/usr/bin/env zsh'; echo 'printf "%s" "${AII_OUT:-}"'; echo 'exit ${AII_RC:-0}'; } > "$aii"
    chmod +x "$aii"; export AI_ASSIST_INPUT_BIN="$aii"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset GUM_BIN AI_ASSIST_INPUT_BIN GUM_OUT GUM_RC AII_OUT AII_RC; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'input::confirm'
    It 'prints yes and exits 0 on affirmative'
      export GUM_RC=0
      When call input::confirm "Proceed?"
      The output should equal "yes"
      The status should be success
    End
    It 'prints no and exits 1 on negative'
      export GUM_RC=1
      When call input::confirm "Proceed?"
      The output should equal "no"
      The status should eq 1
    End
    It 'exits 130 on cancel'
      export GUM_RC=130
      When call input::confirm "Proceed?"
      The status should eq 130
    End
    It '--danger uses bright-red selection and defaults to no'
      export GUM_RC=1
      When call input::confirm "Delete?" --danger
      The output should equal "no"
      The status should eq 1
      The contents of file "$TEST_TMP/gum.args" should include "#ff5555"
      The contents of file "$TEST_TMP/gum.args" should include "--default=false"
    End
    It '--warning uses yellow selection and keeps the normal default'
      export GUM_RC=0
      When call input::confirm "Heads up?" --warning
      The output should equal "yes"
      The status should be success
      The contents of file "$TEST_TMP/gum.args" should include "#e5bf7b"
    End
  End

  Describe 'input::line'
    It 'prints the typed line'
      export GUM_OUT="hello there"
      When call input::line "Name?"
      The output should equal "hello there"
      The status should be success
    End
    It 'themes the cursor mauve'
      export GUM_OUT="x"
      When call input::line "Name?"
      The output should equal "x"
      The contents of file "$TEST_TMP/gum.args" should include "--cursor.foreground #cba6f7"
    End
    It 'exits 130 on empty'
      export GUM_OUT=""
      When call input::line "Name?"
      The status should eq 130
    End
  End

  Describe 'input::text'
    It 'returns the multi-line value'
      export AII_OUT="line1
line2"
      When call input::text "Notes?"
      The output should equal "line1
line2"
      The status should be success
    End
  End

  Describe 'input::choose'
    pick::start() { print -r -- "$@" > "$TEST_TMP/pick.args"; cat > "$TEST_TMP/pick.rows"; printf '%s' "${PICK_OUT:-}"; return ${PICK_RC:-0}; }
    It 'returns the chosen row'
      export PICK_OUT="beta"
      When call input::choose "Pick" alpha beta gamma
      The output should equal "beta"
      The status should be success
    End
    It 'exits 130 when nothing is chosen'
      export PICK_OUT=""; export PICK_RC=130
      When call input::choose "Pick" alpha beta
      The status should eq 130
    End
    It 'passes question as --header and choices as rows, not as a selectable row'
      export PICK_OUT="alpha"
      When call input::choose "Pick one" alpha beta gamma
      The output should equal "alpha"
      The contents of file "$TEST_TMP/pick.args" should include "--header Pick one"
      The contents of file "$TEST_TMP/pick.rows" should include "alpha"
      The contents of file "$TEST_TMP/pick.rows" should include "beta"
      The contents of file "$TEST_TMP/pick.rows" should not include "Pick one"
    End
  End
End
