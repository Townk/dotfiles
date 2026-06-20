Describe 'ai-assist-ask'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-ask"

  # satisfy-compatible helper: reads stdin, compares byte-for-byte to $EXPECT_FILE.
  # Avoids passing control chars (US/RS) through ShellSpec's eval boundary.
  output_matches_file() { [ "$(cat)" = "$(cat "$EXPECT_FILE")" ]; }

  setup() {
    TEST_TMP="$(mktemp -d)"
    gum="$TEST_TMP/gum"
    { echo '#!/usr/bin/env zsh'; echo 'printf "%s" "${GUM_OUT:-}"'; echo 'exit ${GUM_RC:-0}'; } > "$gum"
    chmod +x "$gum"; export GUM_BIN="$gum"
    aii="$TEST_TMP/ai-assist-input"
    { echo '#!/usr/bin/env zsh'; echo 'printf "%s" "${AII_OUT:-}"'; echo 'exit ${AII_RC:-0}'; } > "$aii"
    chmod +x "$aii"; export AI_ASSIST_INPUT_BIN="$aii"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset GUM_BIN AI_ASSIST_INPUT_BIN GUM_OUT GUM_RC AII_OUT AII_RC EXPECT_FILE; }
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

  It 'assembles --field tokens into US/RS spec and returns form answers'
    export GUM_OUT="x"
    printf 'name\037x\036email\037x' > "$TEST_TMP/expected"
    export EXPECT_FILE="$TEST_TMP/expected"
    When run "$SCRIPT" --type form "Sign up" --field "name:line:Name" --field "email:line:Email"
    The output should satisfy output_matches_file
    The status should be success
    The stderr should be present
  End

  It '--field param containing colons survives without truncation'
    # A param value like "https://x:8080" contains colons; old ${(@s/:/)fld} parse would
    # have split it into extra fields, producing a malformed spec and a broken form.
    # The fix parses name:type:label and treats the rest as param verbatim.
    export GUM_OUT="myval"
    printf 'url\037myval\036host\037myval' > "$TEST_TMP/expected"
    export EXPECT_FILE="$TEST_TMP/expected"
    When run "$SCRIPT" --type form "Connect" --field "url:line:URL:https://x:8080" --field "host:line:Host:localhost:9090"
    The output should satisfy output_matches_file
    The status should be success
    The stderr should be present
  End
End
