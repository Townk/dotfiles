# Tests for mux-click — what tmux's ⌥+click aims at before mux-open opens it.
#
# Two kinds of "link" exist on a terminal screen and tmux only knows one:
# OSC 8 hyperlinks (which it stores, and reports as #{mouse_hyperlink}), and
# URL-shaped TEXT, which nothing linkifies. WezTerm's ⌘+click opens the latter
# because WezTerm regex-matches URLs itself, so without this fallback moving
# the gesture into tmux would be a downgrade on WezTerm.
#
# The column-based selection is why this is a script and not a format: tmux's
# word-separators includes `:` and `/` (tuned for double-click word-select in
# code), so #{mouse_word} under a URL is the fragment `https`.
#
# All of it is pure string logic, so it is testable without a mouse — which
# matters, because the alternative is a gesture whose only failure mode is
# "nothing happened", indistinguishable from an unbound key.
Describe 'mux-click'
  setup() {
    MC_TMP=$(mktemp -d)
    MC="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-click"
    # Stand in for mux-open and report what was resolved. mux-click finds it
    # as a sibling, so the copy has to live beside the stub.
    mkdir -p "$MC_TMP/bin"
    cp "$MC" "$MC_TMP/bin/mux-click"
    chmod +x "$MC_TMP/bin/mux-click"
    { echo '#!/bin/sh'; echo 'echo "RESOLVED: $2"'; } >"$MC_TMP/bin/mux-open"
    chmod +x "$MC_TMP/bin/mux-open"
  }
  cleanup() { [ -n "$MC_TMP" ] && rm -rf "$MC_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Values travel in the environment, not argv — see the header of mux-click.
  click() { MUX_CLICK_URI="$1" MUX_CLICK_LINE="$2" MUX_CLICK_COL="$3" "$MC_TMP/bin/mux-click"; }

  Describe 'an OSC 8 hyperlink'
    # Exact, and its target may differ from the text shown — OSC 8 allows that
    # — so it must never be second-guessed by scanning the line.
    It 'wins over URL-shaped text on the same line'
      When call click "file:///tmp/x" "see https://google.com here" 10
      The output should include "RESOLVED: file:///tmp/x"
    End
  End

  Describe 'URL-shaped text (what tmux cannot see)'
    It 'finds the URL under the clicked column'
      When call click "" "see https://google.com/x here" 10
      The output should include "RESOLVED: https://google.com/x"
    End

    # Forgiving on purpose: one URL is unambiguous wherever the click landed,
    # which also absorbs any off-by-one in how the column is reported.
    It 'opens a lone URL even when clicked away from it'
      When call click "" "see https://google.com/x here" 0
      The output should include "RESOLVED: https://google.com/x"
    End

    It 'picks the first of two by column'
      When call click "" "a http://one.com b https://two.com c" 4
      The output should include "RESOLVED: http://one.com"
    End

    It 'picks the second of two by column'
      When call click "" "a http://one.com b https://two.com c" 25
      The output should include "RESOLVED: https://two.com"
    End

    # With more than one candidate there is no safe guess, so a click on
    # neither must do nothing rather than open an arbitrary one.
    It 'opens nothing when the click is between two URLs'
      When call click "" "a http://one.com b https://two.com c" 17
      The output should not include "RESOLVED:"
    End

    It 'ignores a line with no URL at all'
      When call click "" "just some words here" 5
      The output should not include "RESOLVED:"
    End

    It 'ignores an empty line'
      When call click "" "" 0
      The output should not include "RESOLVED:"
    End
  End

  Describe 'trailing punctuation'
    # Needs extended_glob for the `[...]##` trim; without it the `##` is
    # literal and the trim silently does nothing.
    It 'trims a sentence full stop'
      When call click "" "see https://google.com. ok" 10
      The output should include "RESOLVED: https://google.com"
      The output should not include "google.com."
    End

    It 'trims a closing paren'
      When call click "" "(see https://google.com/a) ok" 12
      The output should include "RESOLVED: https://google.com/a"
    End

    # The case that makes a blunt "strip trailing dots" wrong.
    It 'keeps dots that are part of the path'
      When call click "" "get https://x.com/a.tar.gz now" 12
      The output should include "RESOLVED: https://x.com/a.tar.gz"
    End
  End

  Describe 'schemes'
    # mailto: has no double slash, so a `://` pattern drops it silently.
    It 'matches mailto, which has no double slash'
      When call click "" "mail mailto:a@b.com now" 10
      The output should include "RESOLVED: mailto:a@b.com"
    End

    It 'matches a file:// URL in plain text'
      When call click "" "at file:///etc/hosts ok" 10
      The output should include "RESOLVED: file:///etc/hosts"
    End
  End
  # The shape that broke this in the field. `eza` quotes filenames containing
  # spaces, so a real `ls` line carries single quotes — and the first version
  # passed the line as '#{q:mouse_line}', where q:'s backslashes are literal
  # and \' terminates the string. sh exited 2 and the click did nothing, for
  # exactly the files whose names have spaces.
  Describe 'screen content that is hostile to quoting'
    It 'survives an ls line with a quoted filename'
      When call click "file:///Users/x/US%20New%20Hire%20Toolkit.pdf" \
        ".rw-r--r--@ 5.0M thiago  4 May 06:11  'US New Hire Toolkit.pdf'" 60
      The output should include "RESOLVED: file:///Users/x/US%20New%20Hire%20Toolkit.pdf"
    End

    It 'survives shell metacharacters in the line'
      When call click "" 'see https://x.com/a `id` $HOME ;rm -rf / & | done' 8
      The output should include "RESOLVED: https://x.com/a"
    End

    # An empty hyperlink must not shift the other values — the failure mode
    # that made argv unusable even with correct escaping.
    It 'keeps line and column aligned when the hyperlink is empty'
      When call click "" "go https://example.com/z now" 6
      The output should include "RESOLVED: https://example.com/z"
    End

    It 'ignores a non-numeric column rather than misbehaving'
      When call click "" "a http://one.com b https://two.com c" "not-a-number"
      The output should not include "RESOLVED:"
    End
  End
  # The tests above call mux-click with values that are already correct, so
  # NONE of them would have caught the bug that actually shipped: it lived in
  # the tmux -> sh boundary, where the binding builds a command string. This
  # block exercises that boundary for real, through `run-shell` on a scratch
  # server, using the same #{q:…} env spelling the binding uses.
  #
  # pane_title stands in for mouse_line — a mouse event cannot be synthesised,
  # but the quoting path is identical for any format.
  Describe 'the tmux -> sh boundary (where the shipped bug lived)'
    boundary() {  # boundary <title> -> the values as the script received them
      export TMUX_TMPDIR="$MC_TMP/srv"; mkdir -p "$TMUX_TMPDIR"
      cat >"$MC_TMP/bin/probe" <<'PROBE'
#!/usr/bin/env zsh
print -r -- "URI=[$MUX_CLICK_URI] LINE=[$MUX_CLICK_LINE] SESSION=[$MUX_SESSION]" >>"$MC_LOG"
PROBE
      chmod +x "$MC_TMP/bin/probe"
      : >"$MC_TMP/blog"
      tmux -f /dev/null new-session -d -s 23 -x 80 -y 10
      tmux select-pane -t 23 -T "$1"
      tmux run-shell -b "MC_LOG=$MC_TMP/blog MUX_SESSION=#{q:session_name} MUX_CLICK_URI=#{q:pane_title} MUX_CLICK_LINE=#{q:pane_title} $MC_TMP/bin/probe"
      sleep 1
      tmux kill-server 2>/dev/null
      cat "$MC_TMP/blog"
    }

    # The exact shape from the field report: eza quotes names with spaces.
    It 'carries an ls line with quotes and spaces through intact'
      When call boundary ".rw-r--r--@ 5.0M thiago  4 May 06:11  'US New Hire Toolkit.pdf'"
      The output should include "'US New Hire Toolkit.pdf'"
      The output should include "SESSION=[23]"
    End

    It 'carries shell metacharacters through without executing them'
      When call boundary 'x $HOME `id` ;rm -rf / & | y'
      The output should include '$HOME'
      The output should include '`id`'
    End

    # With argv, an empty value vanished and shifted everything after it.
    It 'keeps an empty value as an empty variable'
      When call boundary ""
      The output should include "URI=[]"
    End
  End
  # A REAL mouse event, driven through the REAL binding. Everything above
  # tests the pieces; this tests the gesture. The technique is the nested-tmux
  # probe from docs/mux-parity.md: an outer server holds a client attached to
  # an inner one, and `send-keys -H` writes raw SGR mouse bytes into that
  # client, which parses them as an actual click.
  #
  # This exists because the binding shipped twice with guards that swallowed
  # the click — once for panes in copy/scroll mode — and no test that stopped
  # short of a real event could see it.
  Describe 'a synthesised ⌥+click through the binding'
    probe() {  # probe <extra-tmux-commands> -> what the binding handed over
      IN="$MC_TMP/in"; OUT="$MC_TMP/out"; mkdir -p "$IN" "$OUT"
      LOG="$MC_TMP/clicklog"; : >"$LOG"
      printf '\033]8;;file:///tmp/demo.txt\033\\CLICKME\033]8;;\033\\\n' >"$MC_TMP/osc8"
      { echo '#!/usr/bin/env zsh'
        echo "print -r -- \"FIRED uri=[\$MUX_CLICK_URI] col=[\$MUX_CLICK_COL]\" >>\"$LOG\"" \
      ; } >"$MC_TMP/bin/probe-click"
      chmod +x "$MC_TMP/bin/probe-click"
      { echo 'set -g mouse on'
        echo "bind -n M-MouseDown1Pane if -F \"#{mouse_any_flag}\" { send -M } { run-shell -b \"MUX_CLICK_URI=#{q:mouse_hyperlink} MUX_CLICK_COL=#{mouse_x} $MC_TMP/bin/probe-click\" }"
      ; } >"$MC_TMP/inner.conf"
      TMUX_TMPDIR=$IN tmux -f "$MC_TMP/inner.conf" new-session -d -s I -x 60 -y 8 "cat $MC_TMP/osc8; sleep 120"
      TMUX_TMPDIR=$OUT tmux -f /dev/null new-session -d -s O -x 60 -y 8 "env -u TMUX TMUX_TMPDIR=$IN tmux attach -t I"
      sleep 2
      [ -n "$1" ] && { TMUX_TMPDIR=$IN tmux $1 -t I; sleep 1; }
      # SGR press, button 0 + meta(8), column 3 row 1 — over CLICKME.
      TMUX_TMPDIR=$OUT tmux send-keys -t O -H 1b 5b 3c 38 3b 33 3b 31 4d
      sleep 2
      TMUX_TMPDIR=$IN tmux kill-server 2>/dev/null
      TMUX_TMPDIR=$OUT tmux kill-server 2>/dev/null
      cat "$LOG"
    }

    It 'resolves the hyperlink under the pointer in normal mode'
      When call probe ""
      The output should include "uri=[file:///tmp/demo.txt]"
      The stderr should equal ""
    End

    # Scrolling back to find a filename and then clicking it is a main use of
    # this gesture; a #{pane_in_mode} guard swallowed it entirely.
    It 'still fires when the pane is in copy/scroll mode'
      When call probe "copy-mode"
      The output should include "uri=[file:///tmp/demo.txt]"
      The stderr should equal ""
    End

    # SGR reports column 3; the binding sees 2.
    It 'reports mouse_x zero-based'
      When call probe ""
      The output should include "col=[2]"
    End
  End
End
