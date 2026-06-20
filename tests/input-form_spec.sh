# Tests for input::form — sequential tabbed multi-field widget.
Describe 'input::form'
  Include home/dot_local/lib/input-common.zsh

  US=$(printf '\037'); RS=$(printf '\036'); GS=$(printf '\035')

  # Stub the sub-widgets so the form runs headless with scripted answers.
  input::line()    { printf '%s' "${LINE_ANS:-}";    return ${LINE_RC:-0}; }
  input::confirm() { printf '%s' "${CONF_ANS:-yes}"; return ${CONF_RC:-0}; }
  input::choose()  { printf '%s' "${CHOOSE_ANS:-}";  return ${CHOOSE_RC:-0}; }

  setup() { TEST_TMP="$(mktemp -d)"; }
  cleanup() { rm -rf "$TEST_TMP"; unset LINE_ANS LINE_RC CONF_ANS CONF_RC CHOOSE_ANS CHOOSE_RC; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'collects answers from a 2-field spec into US/RS output'
    export LINE_ANS="Ada"; export CONF_ANS="yes"
    printf 'name%sline%sName%s%semail%sconfirm%sSubscribe%syes' \
      "$US" "$US" "$US" "$RS" "$US" "$US" "$US" > "$TEST_TMP/spec"
    export EXPECTED_OUT="$(printf 'name%sAda%semail%syes' "$US" "$RS" "$US")"
    When call input::form --title "Sign up" --spec "$TEST_TMP/spec"
    The output should equal "$EXPECTED_OUT"
    The status should be success
    The stderr should be present
  End

  It 'aborts the whole form (130) when a field is cancelled'
    export LINE_RC=130
    printf 'a%sline%sA%s%sb%sline%sB' "$US" "$US" "$US" "$RS" "$US" "$US" > "$TEST_TMP/spec"
    When call input::form --spec "$TEST_TMP/spec"
    The status should eq 130
    The stderr should be present
  End

  It 'rejects a spec with fewer than 2 fields'
    printf 'solo%sline%sSolo' "$US" "$US" > "$TEST_TMP/spec"
    When run input::form --spec "$TEST_TMP/spec"
    The status should eq 2
    The stderr should include "2-5 fields"
  End
End
