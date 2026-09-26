# Tests for the MOUSE SELECTION gestures in keymap-base.conf — specifically
# the word/WORD distinction:
#
#   double-click          -> `viw`  : a word, per tmux.conf's word-separators
#   SHIFT + double-click  -> `viW`  : the whole run of non-space characters
#
# Both run the SAME `select-word`; only `word-separators` differs, narrowed to
# a single space for the duration of the shift gesture and unset afterwards so
# the global from tmux.conf is the one source of truth for the real list.
#
# Driven as REAL mouse events through the REAL rendered keymap, using the
# nested-tmux probe from docs/mux-parity.md: an outer server holds a client
# attached to an inner one, and `send-keys -H` writes raw SGR bytes into that
# client. Two rapid press/release pairs make a double-click; the SGR button
# code carries the modifier (0 = plain, 4 = shift).
#
# Testing it any shallower is not worth much: this binding's failure modes are
# a swallowed click and a `word-separators` value left narrowed behind it,
# neither of which is visible from calling the pieces directly.
Describe 'mouse word/WORD selection'
  setup_all() {
    MS_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/tmux/keymap-base.conf.tmpl >"$MS_TMP/keymap.conf" 2>/dev/null
    # The separator list under test is tmux.conf's, restated here only because
    # the scratch server does not load it.
    { echo 'set -g mouse on'
      echo 'setw -g word-separators " !\"#$%&'"'"'()*+,-./:;<=>?@[]^\\`{|}~"'
      echo "source-file $MS_TMP/keymap.conf"
    } >"$MS_TMP/inner.conf"
  }
  cleanup_all() { [ -n "$MS_TMP" ] && rm -rf "$MS_TMP"; }
  BeforeAll setup_all
  AfterAll cleanup_all

  # sgr <button> <col> <row> <M|m> -> the hex bytes send-keys -H wants
  sgr() { printf "\033[<$1;$2;$3$4" | xxd -p | fold -w2 | tr '\n' ' '; }

  # gesture <button-code> <n-clicks> -> what landed in the paste buffer
  gesture() {
    IN="$MS_TMP/in$$"; OUT="$MS_TMP/out$$"; mkdir -p "$IN" "$OUT"
    TMUX_TMPDIR=$IN tmux -f "$MS_TMP/inner.conf" new-session -d -s I -x 60 -y 8 \
      "printf 'aa foo-bar_baz.txt/qux bb\n'; sleep 120"
    TMUX_TMPDIR=$OUT tmux -f /dev/null new-session -d -s O -x 60 -y 8 \
      "env -u TMUX TMUX_TMPDIR=$IN tmux attach -t I"
    ms_until ms_attached
    local n
    for n in $(seq 1 $2); do
      TMUX_TMPDIR=$OUT tmux send-keys -t O -H $(sgr "$1" 8 1 M)
      TMUX_TMPDIR=$OUT tmux send-keys -t O -H $(sgr "$1" 8 1 m)
    done
    # Each gesture copies after a 0.3s run-shell delay, and a triple-click's
    # double-click copies first: wait for a copy, then for it to hold still.
    ms_until ms_settled && sleep 0.5 && ms_until ms_settled
    BUF="$(TMUX_TMPDIR=$IN tmux show-buffer 2>/dev/null)"
    SEP="$(TMUX_TMPDIR=$IN tmux show -w -v word-separators 2>/dev/null)"
    TMUX_TMPDIR=$IN tmux kill-server 2>/dev/null
    TMUX_TMPDIR=$OUT tmux kill-server 2>/dev/null
    print -r -- "$BUF"
  }
  leftover_separators() { print -r -- "$SEP"; }

  # ms_until <check> — poll a check for up to 2s, the fixed sleep it replaces,
  # so a gesture that never lands still fails the way it did.
  ms_until() { local i; for i in {1..40}; do "$1" && return 0; sleep 0.05; done; return 1; }
  # The outer client is attached to the inner session and the text is drawn.
  ms_attached() {
    [[ -n $(TMUX_TMPDIR=$IN tmux list-clients -t I 2>/dev/null) ]] &&
      [[ $(TMUX_TMPDIR=$IN tmux capture-pane -p -t I 2>/dev/null) == *foo-bar* ]]
  }
  # A copy landed and the gesture has finished: out of copy mode, flag unset.
  ms_settled() {
    [[ -n $(TMUX_TMPDIR=$IN tmux show-buffer 2>/dev/null) ]] &&
      [[ $(TMUX_TMPDIR=$IN tmux display -p -t I '#{pane_in_mode}#{@mouse_select}' 2>/dev/null) == 0 ]]
  }

  # Cursor lands inside `bar_baz` of `foo-bar_baz.txt/qux`, which is the point:
  # `-`, `.` and `/` are separators while `_` is not, so the two gestures give
  # visibly different answers on the same character.
  Describe 'double-click (viw)'
    It 'selects a word, stopping at the separators'
      When call gesture 0 2
      The output should equal "bar_baz"
    End
  End

  Describe 'SHIFT + double-click (viW)'
    It 'selects the whole run of non-space characters'
      When call gesture 4 2
      The output should equal "foo-bar_baz.txt/qux"
    End

    # A narrowed list left behind would silently turn every LATER plain
    # double-click into a WORD select — the gesture would look fine and the
    # other one would quietly break.
    It 'leaves no window-local word-separators behind'
      When call gesture 4 2
      The result of function leftover_separators should equal ""
    End
  End

  # Line-select has no word/WORD distinction, but the chord must not land in
  # the inert S- gap and read as "shift broke triple-click".
  Describe 'SHIFT + triple-click'
    It 'selects the line, like the plain gesture'
      When call gesture 4 3
      The output should include "foo-bar_baz.txt/qux"
      The output should include "aa"
    End
  End
End
