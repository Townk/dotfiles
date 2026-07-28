# Tests for the which-key panel's DISPATCH DECISION — the two orthogonal
# questions it answers for every keypress (migration Phase 5):
#
#   execution    who performs the entry: the panel runs its `cmd` (deferred
#                when a dialog owns the screen next), or the PANE owns the
#                key and the panel forwards it (an entry with no cmd — the
#                copy-mode motions, whose one real binding is the
#                conditional in copy-mode-vi)
#   disposition  what happens to the MODE STACK: push a mode, keep it
#                (sticky), or end it
#
# `mux-whichkey dispatch <table> <key>` reports the decision without a tty,
# which is the whole point: pressing j in the Scroll panel used to run
# nothing AND end the mode, and nothing in the suite could see it.
Describe 'mux-whichkey dispatch'
  setup() {
    WK_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/mux/whichkey.data.tmpl >"$WK_TMP/wk.data" 2>/dev/null
    export WK_DATA="$WK_TMP/wk.data" TMPDIR="$WK_TMP"
    W="$PWD/home/dot_config/mux/scripts/executable_mux-whichkey"
  }
  cleanup() { rm -rf "$WK_TMP"; unset WK_DATA W; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  d() { zsh "$W" dispatch "$1" "$2"; }

  Describe 'the copy-mode motions — the pane owns them, and they are sticky'
    It 'forwards j in Scroll and keeps the mode'
      # j is scroll-down in Scroll and cursor-down in Copy: ONE tmux table
      # serves both states, so the conditional bind in copy-mode-vi stays the
      # single definition and the panel hands the key over
      When call d scroll j
      The output should equal 'forward sticky'
    End

    It 'forwards the named twin of the same entry'
      When call d scroll Up
      The output should equal 'forward sticky'
    End

    It 'forwards the paging keys'
      When call d scroll C-b
      The output should equal 'forward sticky'
    End

    It 'forwards cursor motion in Copy'
      When call d copy h
      The output should equal 'forward sticky'
    End

    It 'keeps Search on its match jumps'
      When call d search n
      The output should equal 'forward sticky'
    End

    It 'keeps Search on its flag toggles'
      When call d search M-c
      The output should equal 'forward sticky'
    End

    It 'keeps Copy when v begins the selection'
      When call d copy v
      The output should equal 'forward sticky'
    End
  End

  Describe 'entries that end the mode'
    It 'ends Scroll when the scrollback opens in an editor'
      When call d scroll V
      The output should equal 'forward clear'
    End

    It 'ends Copy on the yank'
      When call d copy y
      The output should equal 'forward clear'
    End

    It 'ends the stack on a plain action'
      # `h` splits — `s` used to, and now opens Session mode, so this example
      # had to move with the 2026-07-28 rebinding rather than be deleted.
      When call d prefix h
      The output should equal 'run clear'
    End
  End

  Describe 'entries that move the stack'
    It 'pushes the mode a switch entry names'
      When call d prefix p
      The output should equal 'run push:pane'
    End

    It 'pushes a mode with no panel of its own'
      When call d prefix L
      The output should equal 'run push:locked'
    End

    It 'pushes Copy from Scroll without a command of its own'
      When call d scroll v
      The output should equal 'forward push:copy'
    End
  End

  Describe 'entries whose dialog owns the screen next'
    It 'defers the search dialog and pushes Search'
      # a popup opened over a popup mutates the outer one
      When call d scroll /
      The output should equal 'defer push:search'
    End

    It 'steps aside for a text object but stays in Copy'
      # i/a prompt for the object key — command-prompt must not fire under
      # the panel's popup, and the mode outlives the prompt
      When call d copy i
      The output should equal 'defer-forward sticky'
    End

    # Rename's dialog owns the screen, so entering it ENDS the panel's mode
    # rather than standing on the stack: the stack driver owns one popup, and
    # a stackable rename had it closing the dialog it had just opened. The
    # mode is real on the RIBBON (pill + key hints) for as long as the dialog
    # is up — see tmux_status_right_spec.
    It 'ends the mode for a rename, whose dialog owns the screen'
      When call d pane r
      The output should equal 'defer clear'
    End

    It 'does the same for a session rename'
      When call d session r
      The output should equal 'defer clear'
    End
  End

  Describe 'the mode tables keep their existing sticky keys'
    It 'keeps Pane on a focus move'
      When call d pane Up
      The output should equal 'run sticky'
    End

    It 'keeps Resize on a resize'
      When call d resize j
      The output should equal 'run sticky'
    End
  End

  It 'swallows a key the current mode does not bind'
    # the panel is a closed surface: it shows what it accepts
    When call d scroll Z
    The output should equal 'ignore'
  End
End
