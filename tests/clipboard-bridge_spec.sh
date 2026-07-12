# Tests for the clipboard-bridge dispatcher's O (declare-origin) op, spec §23:
# writes a hash-keyed current-origin state file the HS watcher consults.
Describe 'clipboard-bridge-dispatch: O declare-origin'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard"
    ORIGINFILE="$XDG_STATE_HOME/pick-clipboard/current-origin"
    REQ="$SHELLSPEC_TMPBASE/req"
    # frame: 'O' + BE32(len) + "TESTHOST\x1fhello"; payload len = 8+1+5 = 14 = 0x0e
    printf 'O\000\000\000\016TESTHOST\037hello' > "$REQ"
  }
  BeforeEach 'setup'

  # -f: skip ~/.zshenv et al. Without it, this repo's ~/.zshenv unconditionally
  # re-exports XDG_STATE_HOME (~/.config/zsh/environment.sh, no ${VAR:-default}
  # guard) and clobbers the sandbox override above before the dispatcher ever
  # sees it -- confirmed empirically: the unguarded invocation silently wrote
  # to the real $HOME/.local/state/pick-clipboard/current-origin instead of
  # the test tmpdir. The dispatcher itself is self-contained (own zmodload/
  # setopt), so -f changes nothing it depends on.
  It 'acknowledges with an O status byte'
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"
  End

  It 'writes the origin host as line 1'
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "O"
    The contents of file "$ORIGINFILE" should include "TESTHOST"
  End

  It 'writes sha256(text) as line 2'
    expected=$(printf 'hello' | shasum -a 256 | awk '{print $1}')
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "O"
    The contents of file "$ORIGINFILE" should include "$expected"
  End

  # A plain O must NOT set the N op's one-shot suppress-echo flag (origin-file
  # line 4, files-yazi T11): text flows (nvim / pbcopy) NEED the watcher's
  # capture -- only N suppresses it, because N inserts its own authoritative
  # store row. Exactly 3 lines = the pre-existing format, nothing extra.
  It 'does not write the suppress-echo flag (exactly 3 lines)'
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "O"
    The contents of file "$ORIGINFILE" should not include "suppress-echo"
    lines=$(wc -l < "$ORIGINFILE" | tr -d ' ')
    The variable lines should equal 3
  End
End
