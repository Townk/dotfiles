# Tests for .setup.sh's interactive auth gates (HI-11).
#
# .setup.sh is the `curl -fsSL …/.setup.sh | bash` install entrypoint. Under
# that invocation stdin IS the piped script text, so a bare `read` inside the
# 1Password / gh auth loops would consume the rest of the script; under
# `set -e` the read's EOF then exits 1 silently, before `chezmoi apply` ever
# runs. The fix gates both loops on an interactive TTY and reads any prompt
# from /dev/tty, so a piped stdin can never be swallowed.
#
# The gate block has no functions to source, so instead of copying it we
# extract the *actual* two-gate block from the real file at test time and run
# it in a fresh `bash` whose stdin carries the block PLUS stand-ins for "the
# rest of the script" — exactly how bash reads a piped script. If the gate's
# read swallows the stream, those trailing lines never execute.
Describe '.setup.sh: interactive auth gates (HI-11)'
  SETUP="$SHELLSPEC_PROJECT_ROOT/.setup.sh"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/setup-gate.XXXXXX")"
    mkdir -p "$WORK/bin"
  }
  cleanup() { rm -rf "$WORK"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Write fake op/gh onto PATH. $1/$2 are their exit codes (1 == "not
  # authenticated / integration disabled", the fresh-Mac state).
  stub_clis() {
    printf '#!/bin/sh\nexit %s\n' "$1" > "$WORK/bin/op"
    printf '#!/bin/sh\nexit %s\n' "$2" > "$WORK/bin/gh"
    chmod +x "$WORK/bin/op" "$WORK/bin/gh"
  }

  # Run the real gate block the way `curl | bash` runs the whole script:
  # `set -eufo pipefail` + the extracted block + stand-ins for the remaining
  # script body, all fed to `bash -s` on one stdin stream. REACHED_APPLY
  # stands in for the later `chezmoi apply`; the SENTINEL_BODY lines stand in
  # for any further script text a runaway read would eat.
  run_gate() {
    awk '/^# Interactive auth gates\./{p=1} /^# Self-onboard/{p=0} p' \
      "$SETUP" > "$WORK/block.sh"
    {
      echo 'set -eufo pipefail'
      cat "$WORK/block.sh"
      echo 'echo REACHED_APPLY'
      echo 'echo SENTINEL_BODY_1'
    } > "$WORK/piped.sh"
    PATH="$WORK/bin:$PATH" bash -s < "$WORK/piped.sh"
  }

  Describe 'no TTY (curl | bash) with op/gh not authenticated'
    It 'skips the gates with an actionable hint instead of dying, and never eats the piped script body'
      stub_clis 1 1
      When call run_gate
      The status should be success
      # The bug: these never appeared because `read` ate them / set -e exited.
      The output should include 'REACHED_APPLY'
      The output should include 'SENTINEL_BODY_1'
      # Actionable, one-time hints for both gates.
      The output should include 'op signin'
      The output should include 'gh auth login'
      # The interactive prompt must NOT fire in the no-TTY path.
      The output should not include 'Press [Enter]'
    End
  End

  Describe 'checks already satisfied'
    It 'confirms both gates and proceeds without prompting or consuming stdin'
      stub_clis 0 0
      When call run_gate
      The status should be success
      The output should include '1Password CLI is already integrated'
      The output should include 'GitHub CLI is authenticated'
      The output should include 'REACHED_APPLY'
      The output should include 'SENTINEL_BODY_1'
    End
  End

  Describe 'source guard against regression'
    It 'reads the interactive prompt from /dev/tty, not stdin'
      When call grep -F 'read -r -p "Press [Enter]' "$SETUP"
      The status should be success
      The output should include '</dev/tty'
    End
  End
End
