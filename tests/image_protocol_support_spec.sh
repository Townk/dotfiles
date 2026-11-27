# get_terminal_image_protocol — which graphics protocol the terminal that
# will finally draw the pixels speaks. Hermetic: tmux is a stub.
Describe 'get_terminal_image_protocol'
  Include home/dot_local/lib/image-protocol-support.zsh

  setup() {
    IP_TMP=$(mktemp -d)
    printf '%s\n' '#!/bin/sh' 'echo "TERM_PROGRAM=${STUB_OUTER:-}"' >"$IP_TMP/tmux"
    chmod +x "$IP_TMP/tmux"
    IP_PATH="$PATH"; PATH="$IP_TMP:$PATH"
    unset TMUX ITERM_SESSION_ID LC_TERMINAL TERM_PROGRAM STUB_OUTER
  }
  cleanup() { PATH="$IP_PATH"; rm -rf "$IP_TMP"; unset TMUX TERM_PROGRAM STUB_OUTER; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'answers Kitty in a Rex pane (libghostty: Kitty graphics, no sixel)'
    TERM_PROGRAM=rex
    When call get_terminal_image_protocol
    The output should equal "Kitty"
  End

  It 'answers Kitty for Ghostty, however it spells its name'
    both() { TERM_PROGRAM=Ghostty get_terminal_image_protocol; TERM_PROGRAM=ghostty get_terminal_image_protocol; }
    When call both
    The output should equal "Kitty
Kitty"
  End

  It 'answers Kitty for tmux running inside Rex'
    TMUX=/tmp/s,1,0 STUB_OUTER=rex
    export STUB_OUTER
    When call get_terminal_image_protocol
    The output should equal "Kitty"
  End

  It 'still answers Sixel for tmux inside WezTerm, and all three outside it'
    wez() { TERM_PROGRAM=WezTerm get_terminal_image_protocol; export STUB_OUTER=WezTerm; TMUX=/tmp/s,1,0 get_terminal_image_protocol; }
    When call wez
    The output should equal "Kitty Sixel iTerm2
Sixel"
  End

  It 'fails for a terminal with no image protocol'
    TERM_PROGRAM=Apple_Terminal
    When call get_terminal_image_protocol
    The status should be failure
  End
End
