# Tests for input-common.zsh — themed inline widgets.
Describe 'input-common.zsh'
  Include home/dot_local/lib/input-common.zsh

  setup() {
    TEST_TMP="$(mktemp -d)"
    # ai-playbook recording stub: append argv to aii.args, print $AII_OUT, exit $AII_RC.
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

  Describe '_input::bin (binary resolution)'
    It 'honors the AI_PLAYBOOK_INPUT_BIN override'
      export AI_PLAYBOOK_INPUT_BIN=/custom/path/ai-playbook
      When call _input::bin
      The output should equal "/custom/path/ai-playbook"
    End
    It 'falls back to the install path when ai-playbook is not on PATH'
      # A zellij-spawned pane's PATH lacks ~/.local/share/go/bin (only the
      # interactive profile adds it), so a bare command-v fails there. Simulate
      # that PATH and assert the resolver still finds the installed binary.
      When run env PATH=/opt/homebrew/bin:/usr/bin:/bin zsh -c 'unset AI_PLAYBOOK_INPUT_BIN; source "'"$SHELLSPEC_PROJECT_ROOT"'/home/dot_local/lib/input-common.zsh"; _input::bin'
      The output should equal "$HOME/.local/share/go/bin/ai-playbook"
      The status should be success
    End
  End

  Describe 'input::confirm'
    It 'maps binary exit 0 to yes and forwards confirm flags'
      export AII_RC=0
      When call input::confirm "Proceed?"
      The output should equal "yes"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--type confirm"
    End
    It 'maps binary exit 1 to no'
      export AII_RC=1
      When call input::confirm "Proceed?"
      The output should equal "no"
      The status should eq 1
    End
    It 'maps other exits to 130'
      export AII_RC=130
      When call input::confirm "Proceed?"
      The status should eq 130
    End
    It '--danger forwards --danger and the danger theme color'
      export AII_RC=1
      When call input::confirm "Delete?" --danger --affirmative Delete --negative Cancel
      The output should equal "no"
      The status should eq 1
      The contents of file "$TEST_TMP/aii.args" should include "--danger"
      The contents of file "$TEST_TMP/aii.args" should include "--affirmative Delete"
      The contents of file "$TEST_TMP/aii.args" should include "--theme-danger #ff5555"
    End
    It '--warning forwards --warning and the warning theme color'
      export AII_RC=0
      When call input::confirm "Heads up?" --warning
      The output should equal "yes"
      The contents of file "$TEST_TMP/aii.args" should include "--warning"
      The contents of file "$TEST_TMP/aii.args" should include "--theme-warning #e5bf7b"
    End
    It '--title is forwarded'
      export AII_RC=0
      When call input::confirm "Body?" --title "Heads up"
      The output should equal "yes"
      The contents of file "$TEST_TMP/aii.args" should include "--title Heads up"
    End
    It 'maps the positional to --prompt and keeps --title'
      export AII_RC=0
      When call input::confirm "Proceed?" --title "Confirm"
      The output should equal "yes"
      The contents of file "$TEST_TMP/aii.args" should include "--title Confirm"
      The contents of file "$TEST_TMP/aii.args" should include "--prompt Proceed?"
    End
    It 'no --title forwarded when none given (no title duplication)'
      export AII_RC=0
      When call input::confirm "Proceed?"
      The output should equal "yes"
      The contents of file "$TEST_TMP/aii.args" should include "--prompt Proceed?"
      The contents of file "$TEST_TMP/aii.args" should not include "--title"
    End
  End

  Describe 'input::line'
    It 'prints the typed line and forwards --type line'
      export AII_OUT="hello there"
      When call input::line "Name?"
      The output should equal "hello there"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--type line"
    End
    It 'forwards placeholder and theme args'
      export AII_OUT="x"
      When call input::line "Name?" --placeholder "type…"
      The output should equal "x"
      The contents of file "$TEST_TMP/aii.args" should include "--placeholder type…"
      The contents of file "$TEST_TMP/aii.args" should include "--theme-field-border #585b70"
    End
    It 'exits 130 on empty'
      export AII_OUT=""
      When call input::line "Name?"
      The status should eq 130
    End
    It 'maps the positional to --prompt and keeps --title'
      export AII_OUT="answer"
      When call input::line "Enter name" --title "User Info"
      The output should equal "answer"
      The contents of file "$TEST_TMP/aii.args" should include "--title User Info"
      The contents of file "$TEST_TMP/aii.args" should include "--prompt Enter name"
    End
    It 'empty positional does not emit --prompt'
      export AII_OUT="answer"
      When call input::line --title "User Info"
      The output should equal "answer"
      The contents of file "$TEST_TMP/aii.args" should include "--title User Info"
      The contents of file "$TEST_TMP/aii.args" should not include "--prompt"
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
    It 'maps the positional to --prompt and keeps --title'
      export AII_OUT="body text"
      When call input::text "Enter notes" --title "Notes"
      The output should equal "body text"
      The contents of file "$TEST_TMP/aii.args" should include "--title Notes"
      The contents of file "$TEST_TMP/aii.args" should include "--prompt Enter notes"
    End
    It 'empty positional does not emit --prompt'
      export AII_OUT="body text"
      When call input::text --title "Notes"
      The output should equal "body text"
      The contents of file "$TEST_TMP/aii.args" should include "--title Notes"
      The contents of file "$TEST_TMP/aii.args" should not include "--prompt"
    End
    It 'forwards theme args (--theme-field-border) to the binary'
      export AII_OUT="themed text"
      When call input::text "Notes?"
      The output should equal "themed text"
      The contents of file "$TEST_TMP/aii.args" should include "--theme-field-border #585b70"
    End
  End

  Describe 'input::choose --measure passthrough'
    It 'forwards --measure and --width to the binary and returns its printed height'
      # When --measure is present the stub should receive --measure --width 56
      # and we return whatever the binary printed (a height number).
      {
        echo '#!/usr/bin/env zsh'
        echo 'print -r -- "$@" >> "'"$TEST_TMP"'/aii.args"'
        echo 'if [[ "$*" == *"--measure"* ]]; then printf "12"; exit 0; fi'
        echo 'printf "%s" "${AII_OUT:-}"'
        echo 'exit ${AII_RC:-0}'
      } > "$aii"; chmod +x "$aii"
      When call input::choose --measure --width 56 "Pick" a b c
      The output should equal "12"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--measure"
      The contents of file "$TEST_TMP/aii.args" should include "--width 56"
    End
    It '--measure forwards the same widget flags as a normal run plus --measure/--width'
      {
        echo '#!/usr/bin/env zsh'
        echo 'print -r -- "$@" >> "'"$TEST_TMP"'/aii.args"'
        echo 'if [[ "$*" == *"--measure"* ]]; then printf "7"; exit 0; fi'
        echo 'printf "%s" "${AII_OUT:-}"'
        echo 'exit ${AII_RC:-0}'
      } > "$aii"; chmod +x "$aii"
      When call input::choose --measure --width 40 --title "My Title" "Pick one" alpha beta
      The output should equal "7"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--type choose"
      The contents of file "$TEST_TMP/aii.args" should include "--title My Title"
      The contents of file "$TEST_TMP/aii.args" should include "--prompt Pick one"
      The contents of file "$TEST_TMP/aii.args" should include "--measure"
      The contents of file "$TEST_TMP/aii.args" should include "--width 40"
    End
  End

  Describe 'input::choose'
    It 'forwards --type choose and options after --'
      export AII_OUT="beta"
      When call input::choose "Pick" -- alpha beta gamma
      The output should equal "beta"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--type choose"
      The contents of file "$TEST_TMP/aii.args" should include "-- alpha beta gamma"
    End
    It 'forwards bare positional choices'
      export AII_OUT="alpha"
      When call input::choose "Pick one" alpha beta gamma
      The output should equal "alpha"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--type choose"
      The contents of file "$TEST_TMP/aii.args" should include "alpha"
    End
    It 'maps the first positional to --prompt'
      export AII_OUT="alpha"
      When call input::choose "Pick one" alpha beta
      The output should equal "alpha"
      The contents of file "$TEST_TMP/aii.args" should include "--prompt Pick one"
      The contents of file "$TEST_TMP/aii.args" should not include "-- Pick one"
    End
    It 'forwards --title'
      export AII_OUT="alpha"
      When call input::choose "Pick one" --title "My Title" alpha beta
      The output should equal "alpha"
      The contents of file "$TEST_TMP/aii.args" should include "--title My Title"
      The contents of file "$TEST_TMP/aii.args" should include "--prompt Pick one"
    End
    It 'forwards --multi'
      export AII_OUT="alpha"$'\n'"beta"
      When call input::choose "Pick" --multi -- alpha beta gamma
      The output should equal "alpha
beta"
      The contents of file "$TEST_TMP/aii.args" should include "--multi"
    End
    It 'forwards --other'
      export AII_OUT="alpha"
      When call input::choose "Pick" --other "Something else" -- alpha beta
      The output should equal "alpha"
      The contents of file "$TEST_TMP/aii.args" should include "--other Something else"
    End
    It 'forwards theme args'
      export AII_OUT="alpha"
      When call input::choose "Pick" -- alpha beta
      The output should equal "alpha"
      The contents of file "$TEST_TMP/aii.args" should include "--theme-field-border"
    End
    It 'exits 130 when binary returns empty'
      export AII_OUT=""
      When call input::choose "Pick" -- alpha beta
      The status should eq 130
    End
    It 'exits 130 on non-zero exit'
      export AII_RC=130
      When call input::choose "Pick" -- alpha beta
      The status should eq 130
    End
  End

  Describe 'input::form'
    make_spec() {
      # Minimal 2-field spec: name<US>line<US>Your name<RS>subscribe<US>confirm<US>Subscribe?
      printf 'name\x1fline\x1fYour name\x1esubscribe\x1fconfirm\x1fSubscribe?'
    }
    It 'passes --type form --spec <file> to the binary and returns its stdout'
      export AII_OUT="form-answers"
      spec="$TEST_TMP/form.spec"
      make_spec > "$spec"
      When call input::form --title "Setup" --spec "$spec"
      The contents of file "$TEST_TMP/aii.args" should include "--type form"
      The contents of file "$TEST_TMP/aii.args" should include "--spec"
      The contents of file "$TEST_TMP/aii.args" should include "--title Setup"
      The output should equal "form-answers"
      The status should be success
    End
    It 'reads spec from stdin when --spec is omitted'
      export AII_OUT="stdin-answers"
      Data
        #|spec-from-stdin
      End
      When call input::form --title "Setup"
      The contents of file "$TEST_TMP/aii.args" should include "--type form"
      The contents of file "$TEST_TMP/aii.args" should include "--spec"
      The output should equal "stdin-answers"
      The status should be success
    End
    It 'returns 130 when the binary exits non-zero'
      export AII_RC=130
      spec="$TEST_TMP/form.spec"
      make_spec > "$spec"
      When call input::form --spec "$spec"
      The status should eq 130
    End
    It '--measure with --spec forwards --type form --measure --width to binary without reading stdin'
      {
        echo '#!/usr/bin/env zsh'
        echo 'print -r -- "$@" >> "'"$TEST_TMP"'/aii.args"'
        echo 'if [[ "$*" == *"--measure"* ]]; then printf "18"; exit 0; fi'
        echo 'printf "%s" "${AII_OUT:-}"'
        echo 'exit ${AII_RC:-0}'
      } > "$aii"; chmod +x "$aii"
      spec="$TEST_TMP/form.spec"
      make_spec > "$spec"
      When call input::form --measure --width 64 --spec "$spec"
      The output should equal "18"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--type form"
      The contents of file "$TEST_TMP/aii.args" should include "--measure"
      The contents of file "$TEST_TMP/aii.args" should include "--width 64"
      The contents of file "$TEST_TMP/aii.args" should include "--spec"
    End
    It '--measure without --spec does not read stdin and returns promptly'
      # Regression test: input::form --measure with no --spec must NOT do
      # `cat > tmpfile` (which would block on a live TTY).  With stdin from
      # /dev/null the call must complete and forward --type form --measure.
      {
        echo '#!/usr/bin/env zsh'
        echo 'print -r -- "$@" >> "'"$TEST_TMP"'/aii.args"'
        echo 'if [[ "$*" == *"--measure"* ]]; then printf "18"; exit 0; fi'
        echo 'printf "%s" "${AII_OUT:-}"'
        echo 'exit ${AII_RC:-0}'
      } > "$aii"; chmod +x "$aii"
      When call input::form --measure --width 64
      The output should equal "18"
      The status should be success
      The contents of file "$TEST_TMP/aii.args" should include "--type form"
      The contents of file "$TEST_TMP/aii.args" should include "--measure"
      The contents of file "$TEST_TMP/aii.args" should include "--width 64"
    End
  End
End
