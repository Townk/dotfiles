# Tests for input::form — sequential tabbed multi-field widget.
Describe 'input::form'
  Include home/dot_local/lib/input-common.zsh

  US=$(printf '\037'); RS=$(printf '\036'); GS=$(printf '\035')

  # Stub the sub-widgets so the form runs headless with scripted answers.
  input::line()    { printf '%s' "${LINE_ANS:-}";    return ${LINE_RC:-0}; }
  input::confirm() { printf '%s' "${CONF_ANS:-yes}"; return ${CONF_RC:-0}; }
  input::choose()  { printf '%s' "${CHOOSE_ANS:-}";  return ${CHOOSE_RC:-0}; }

  # satisfy-compatible helper: reads stdin, compares byte-for-byte to $EXPECT_FILE.
  # Avoids passing control chars (US/RS) through ShellSpec's eval boundary.
  output_matches_file() { [ "$(cat)" = "$(cat "$EXPECT_FILE")" ]; }

  setup() { TEST_TMP="$(mktemp -d)"; }
  cleanup() { rm -rf "$TEST_TMP"; unset LINE_ANS LINE_RC CONF_ANS CONF_RC CHOOSE_ANS CHOOSE_RC EXPECT_FILE; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'collects answers from a 2-field spec into US/RS output'
    export LINE_ANS="Ada"; export CONF_ANS="yes"
    printf 'name%sline%sName%s%semail%sconfirm%sSubscribe%syes' \
      "$US" "$US" "$US" "$RS" "$US" "$US" "$US" > "$TEST_TMP/spec"
    printf 'name%sAda%semail%syes' "$US" "$RS" "$US" > "$TEST_TMP/expected"
    export EXPECT_FILE="$TEST_TMP/expected"
    When call input::form --title "Sign up" --spec "$TEST_TMP/spec"
    The output should satisfy output_matches_file
    The status should be success
    The stderr should be present
  End

  It 'continues past a confirm "no" (exit 1) and records both fields'
    export CONF_ANS="no"; export CONF_RC=1
    export LINE_ANS="after"
    printf 'ok%sconfirm%sProceed%s%snote%sline%sNote' \
      "$US" "$US" "$US" "$RS" "$US" "$US" > "$TEST_TMP/spec"
    printf 'ok%sno%snote%safter' "$US" "$RS" "$US" > "$TEST_TMP/expected"
    export EXPECT_FILE="$TEST_TMP/expected"
    When call input::form --spec "$TEST_TMP/spec"
    The output should satisfy output_matches_file
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
