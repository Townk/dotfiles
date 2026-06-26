# Tests for input::form — native binary shim.
# The shell no longer runs a per-field loop; it delegates to ai-playbook
# --type form --spec FILE. These tests verify the shim wiring via the aii stub.
Describe 'input::form'
  Include home/dot_local/lib/input-common.zsh

  US=$(printf '\037'); RS=$(printf '\036')

  setup() {
    TEST_TMP="$(mktemp -d)"
    aii="$TEST_TMP/ai-playbook"
    { echo '#!/usr/bin/env zsh'
      echo 'print -r -- "$@" >> "'"$TEST_TMP"'/aii.args"'
      echo 'printf "%s" "${AII_OUT:-}"'
      echo 'exit ${AII_RC:-0}'
    } > "$aii"; chmod +x "$aii"; export AI_PLAYBOOK_INPUT_BIN="$aii"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset AI_PLAYBOOK_INPUT_BIN AII_OUT AII_RC; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'collects answers from a 2-field spec into US/RS output'
    export AII_OUT="name${US}Ada${RS}email${US}yes"
    printf 'name%sline%sName%s%semail%sconfirm%sSubscribe%syes' \
      "$US" "$US" "$US" "$RS" "$US" "$US" "$US" > "$TEST_TMP/spec"
    When call input::form --title "Sign up" --spec "$TEST_TMP/spec"
    The contents of file "$TEST_TMP/aii.args" should include "--type form"
    The contents of file "$TEST_TMP/aii.args" should include "--spec"
    The output should equal "name${US}Ada${RS}email${US}yes"
    The status should be success
  End

  It 'continues past a confirm "no" (exit 1) and records both fields'
    export AII_OUT="ok${US}no${RS}note${US}after"
    printf 'ok%sconfirm%sProceed%s%snote%sline%sNote' \
      "$US" "$US" "$US" "$RS" "$US" "$US" > "$TEST_TMP/spec"
    When call input::form --spec "$TEST_TMP/spec"
    The contents of file "$TEST_TMP/aii.args" should include "--type form"
    The output should equal "ok${US}no${RS}note${US}after"
    The status should be success
  End

  It 'aborts the whole form (130) when the binary exits non-zero'
    export AII_RC=130
    printf 'a%sline%sA%s%sb%sline%sB' "$US" "$US" "$US" "$RS" "$US" "$US" > "$TEST_TMP/spec"
    When call input::form --spec "$TEST_TMP/spec"
    The status should eq 130
  End

  It 'passes --title to the binary'
    export AII_OUT="solo${US}val"
    printf 'a%sline%sA%s%sb%sline%sB' "$US" "$US" "$US" "$RS" "$US" "$US" > "$TEST_TMP/spec"
    When call input::form --title "My Form" --spec "$TEST_TMP/spec"
    The contents of file "$TEST_TMP/aii.args" should include "--title My Form"
    The output should equal "solo${US}val"
    The status should be success
  End
End
