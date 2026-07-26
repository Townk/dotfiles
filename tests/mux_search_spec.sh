# Tests for mux-search's (SearchMode) flag relay — the M-c/M-b/M-p chords
# that toggle case / whole-word / wrap on a committed search.
#
# The gate is the MODE STACK, not tmux's `search_present`: making a
# lowercase term case-sensitive can drop every match, which clears
# search_present — and the toggle that caused it must still be there to undo
# it. Gating on tmux's flag stranded the user with a dead chord (Mode B).
Describe 'mux-search --toggle'
  setup() {
    MS_TMP=$(mktemp -d)
    LOG="$MS_TMP/calls.log"
    # a tmux that records every call and answers the formats the relay reads
    cat > "$MS_TMP/tmux" <<'EOS'
#!/usr/bin/env zsh
print -r -- "$*" >> "$LOG"
if [[ "$1" == show && "$3" == @mux_stack ]]; then print -r -- "$STUB_STACK"; exit 0; fi
if [[ "$1" == display ]]; then
  case "$*" in
    *@search_case*|*@search_word*) print -r -- "${STUB_FLAG:-0}" ;;
    *@search_wrap*)               print -r -- "${STUB_WRAP:-1}" ;;
    *@search_term*)               print -r -- "${STUB_TERM-jul}" ;;
    *)                            print -r -- 0 ;;
  esac
fi
exit 0
EOS
    chmod +x "$MS_TMP/tmux"
    export LOG MUX_TMUX_BIN="$MS_TMP/tmux" MUX_LIB_DIR="$PWD/home/dot_local/lib"
    chezmoi execute-template <home/dot_config/mux/whichkey.data.tmpl >"$MS_TMP/wk.data" 2>/dev/null
    export WK_DATA="$MS_TMP/wk.data"
    S="$PWD/home/dot_config/mux/scripts/executable_mux-search"
  }
  cleanup() { rm -rf "$MS_TMP"; unset LOG MUX_TMUX_BIN MUX_LIB_DIR WK_DATA S STUB_STACK STUB_FLAG STUB_TERM STUB_WRAP; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  toggle() { STUB_STACK="$1" zsh "$S" --toggle "${2:-case}" '%1'; }
  logged() { cat "$LOG"; }

  It 'flips the flag while the stack is standing in Search'
    When call toggle 'command:1 scroll:1 search:0'
    The result of 'logged()' should include 'set -p -t %1 @search_case 1'
  End

  It 're-runs the search so the new flag takes effect'
    When call toggle 'command:1 scroll:1 search:0'
    The result of 'logged()' should include 'search-backward'
  End

  It 'still works when the last search matched NOTHING'
    # exactly the Mode B case: case-sensitivity dropped every match, so
    # tmux cleared search_present — the chord that undoes it must survive
    When call toggle 'search:0'
    The result of 'logged()' should include 'set -p -t %1 @search_case 1'
  End

  It 'does nothing when the mode is not Search'
    When call toggle 'command:1 scroll:1'
    The result of 'logged()' should not include '@search_case 1'
  End

  It 'does nothing with no mode at all'
    When call toggle ''
    The result of 'logged()' should not include '@search_case 1'
  End

  It 'leaves the search alone for a wrap toggle'
    # wrap changes where the NEXT n/N may land, not what matches now
    When call toggle 'search:0' wrap
    The result of 'logged()' should not include 'search-backward'
  End

  # tmux DOES have a no-wrap search: `wrap-search`, settable per pane.
  # M-p used to flip only the indicator glyph, so n/N kept wrapping (Mode B).
  It 'turns tmux wrapping off with the indicator'
    When call toggle 'search:0' wrap
    The result of 'logged()' should include 'set -p -t %1 @search_wrap 0'
    The result of 'logged()' should include 'set -p -t %1 wrap-search off'
  End

  It 'turns it back on'
    export STUB_WRAP=0
    When call toggle 'search:0' wrap
    The result of 'logged()' should include 'set -p -t %1 @search_wrap 1'
    The result of 'logged()' should include 'set -p -t %1 wrap-search on'
  End

  It 'leaves wrapping alone for a case toggle'
    When call toggle 'search:0' case
    The result of 'logged()' should not include 'wrap-search'
  End
End
