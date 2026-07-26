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
    # the composite reads: where we landed | old index | match count
    *@search_idx*)                 print -r -- "${STUB_AFTER:-9:9:9}|${STUB_IDX:-1}|${STUB_COUNT:-3}" ;;
    *@search_mpos*)                print -r -- "${STUB_MPOS:-0|0|0|0}" ;;
    *copy_cursor_x*)               print -r -- "${STUB_BEFORE:-0:0:0}" ;;
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
  cleanup() { rm -rf "$MS_TMP"; unset LOG MUX_TMUX_BIN MUX_LIB_DIR WK_DATA S STUB_STACK STUB_FLAG STUB_TERM STUB_WRAP \
    STUB_AFTER STUB_BEFORE STUB_MPOS STUB_IDX STUB_COUNT; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  toggle() { STUB_STACK="$1" zsh "$S" --toggle "${2:-case}" '%1'; }
  step()   { STUB_STACK="${2:-search:0}" zsh "$S" "$1" '%1'; }
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

# n / N step the SEARCH's own position: they put the cursor back where the
# search was standing, search from THERE, and record where they landed — so
# scrolling the buffer to read it never changes which match comes next
# (tmux's own search-again looks from wherever the cursor happens to be).
Describe 'mux-search --next / --prev'
  setup() {
    MS_TMP=$(mktemp -d)
    LOG="$MS_TMP/calls.log"
    cat > "$MS_TMP/tmux" <<'EOS'
#!/usr/bin/env zsh
print -r -- "$*" >> "$LOG"
if [[ "$1" == show && "$3" == @mux_stack ]]; then print -r -- "$STUB_STACK"; exit 0; fi
if [[ "$1" == display ]]; then
  case "$*" in
    *@search_idx*)      print -r -- "${STUB_AFTER:-9:9:9}|${STUB_IDX:-1}|${STUB_COUNT:-3}" ;;
    *@search_mpos*)     print -r -- "${STUB_MPOS:-0|0|0|0}" ;;
    *copy_cursor_x*)    print -r -- "${STUB_BEFORE:-0:0:0}" ;;
    *@search_term*)     print -r -- "${STUB_TERM-jul}" ;;
    *)                  print -r -- 0 ;;
  esac
fi
exit 0
EOS
    chmod +x "$MS_TMP/tmux"
    export LOG MUX_TMUX_BIN="$MS_TMP/tmux" MUX_LIB_DIR="$PWD/home/dot_local/lib"
    S="$PWD/home/dot_config/mux/scripts/executable_mux-search"
  }
  cleanup() { rm -rf "$MS_TMP"; unset LOG MUX_TMUX_BIN MUX_LIB_DIR S STUB_STACK STUB_TERM \
    STUB_AFTER STUB_BEFORE STUB_MPOS STUB_IDX STUB_COUNT; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  step()   { STUB_STACK="${2:-search:0}" zsh "$S" "$1" '%1'; }
  logged() { cat "$LOG"; }

  It 'puts the cursor back on the search position before searching'
    When call step --next
    The result of 'logged()' should include 'top-line'
    The result of 'logged()' should include 'search-again'
  End

  It 'counts up toward older matches'
    export STUB_IDX=1 STUB_COUNT=3
    When call step --next
    The result of 'logged()' should include '@search_idx 2'
  End

  It 'wraps to the newest match past the oldest'
    export STUB_IDX=3 STUB_COUNT=3
    When call step --next
    The result of 'logged()' should include '@search_idx 1'
  End

  It 'counts back down on N'
    export STUB_IDX=2 STUB_COUNT=3
    When call step --prev
    The result of 'logged()' should include '@search_idx 1'
    The result of 'logged()' should include 'search-reverse'
  End

  It 'holds the index when the search did not move'
    # wrap off at the last match: tmux leaves the cursor where it was
    export STUB_IDX=3 STUB_COUNT=3 STUB_BEFORE='4:4:4' STUB_AFTER='4:4:4'
    When call step --next
    The result of 'logged()' should include '@search_idx 3'
  End

  It 'remembers where it landed'
    export STUB_AFTER='7:5:3'
    When call step --next
    The result of 'logged()' should include '@search_mpos 7'
    The result of 'logged()' should include '@search_my 5'
    The result of 'logged()' should include '@search_mx 3'
  End

  It 'keeps its other job outside Search: jumping between prompts'
    When call step --next 'command:1 scroll:1'
    The result of 'logged()' should include 'next-prompt'
    The result of 'logged()' should not include 'search-again'
  End

  It 'jumps prompts backward too'
    When call step --prev 'command:1 scroll:1'
    The result of 'logged()' should include 'previous-prompt'
  End
End
