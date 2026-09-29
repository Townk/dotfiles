# The suite-wide clipboard guard (tests/spec_helper.sh). No spec may write the
# REAL clipboard: before it existed, share::clip resolved `pbcopy` through PATH
# and every `make test` left Report.pdf → *.example.com rows in the human's
# clipboard history (found 2026-09-29, rows dating back to at least 09-26).

Describe 'spec_helper clipboard guard'
  It 'resolves pbcopy to the guard, not the real clipboard'
    When call command -v pbcopy
    The output should include '.clip-guard/pbcopy'
  End

  It 'swallows what is written to it'
    guarded_copy() { printf 'must not reach the clipboard' | pbcopy; }
    When call guarded_copy
    The status should be success
    The output should equal ''
  End

  # A spec that wants to OBSERVE clipboard writes stubs pbcopy in its own
  # setup; prepending wins over the guard.
  It 'yields to a spec-local pbcopy stub'
    local_stub() {
      mkdir -p "$SHELLSPEC_TMPBASE/own-bin"
      printf '#!/bin/sh\ncat > "%s/own-clip"\n' "$SHELLSPEC_TMPBASE" >"$SHELLSPEC_TMPBASE/own-bin/pbcopy"
      chmod +x "$SHELLSPEC_TMPBASE/own-bin/pbcopy"
      PATH="$SHELLSPEC_TMPBASE/own-bin:$PATH" command -v pbcopy
    }
    When call local_stub
    The output should include 'own-bin/pbcopy'
  End
End

Describe 'spec_helper real-pasteboard opt-in'
  It 'is off unless SPEC_REAL_PASTEBOARD=1'
    When call spec_real_pasteboard_off
    The status should be success
  End

  It 'turns on with SPEC_REAL_PASTEBOARD=1'
    opted_in() { SPEC_REAL_PASTEBOARD=1 spec_real_pasteboard_off; }
    When call opted_in
    The status should be failure
  End
End
