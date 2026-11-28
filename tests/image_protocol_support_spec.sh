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

# get_chafa_format_args — "which chafa arguments for this terminal": the one
# answer `preview` and term-quick-view render with (the yazi shim carries the
# tmux-sixel form as a Lua literal, pinned below).
Describe 'get_chafa_format_args'
  Include home/dot_local/lib/image-protocol-support.zsh

  setup() {
    CF_TMP=$(mktemp -d)
    printf '%s\n' '#!/bin/sh' 'echo "TERM_PROGRAM=${STUB_OUTER:-}"' >"$CF_TMP/tmux"
    chmod +x "$CF_TMP/tmux"
    CF_PATH="$PATH"; PATH="$CF_TMP:$PATH"
    unset TMUX ITERM_SESSION_ID LC_TERMINAL TERM_PROGRAM STUB_OUTER
  }
  cleanup() { PATH="$CF_PATH"; rm -rf "$CF_TMP"; unset TMUX TERM_PROGRAM STUB_OUTER LC_TERMINAL; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'names the protocol outright outside tmux'
    direct() {
      TERM_PROGRAM=rex get_chafa_format_args
      TERM_PROGRAM=ghostty get_chafa_format_args
      TERM_PROGRAM=WezTerm get_chafa_format_args
      LC_TERMINAL=iTerm2 get_chafa_format_args
      TERM_PROGRAM=Apple_Terminal get_chafa_format_args
    }
    When call direct
    The output should equal "-f kitty
-f kitty
-f sixel
-f sixel
-f symbols"
  End

  It 'pins passthrough and turns probing off inside tmux'
    in_tmux() {
      export TMUX=/tmp/s,1,0
      STUB_OUTER=WezTerm get_chafa_format_args
      STUB_OUTER=ghostty get_chafa_format_args
      STUB_OUTER=rex get_chafa_format_args
      STUB_OUTER= get_chafa_format_args
    }
    When call in_tmux
    The output should equal "-f sixel --passthrough none --probe off
-f kitty --passthrough tmux --probe off
-f kitty --passthrough tmux --probe off
-f symbols"
  End

  # A caller that knows the outer terminal by other means (the viewer: by
  # terminal NAME, or because it is opening a Rex layer) names it.
  It 'answers for a terminal the caller names, in or out of tmux'
    named() {
      TERM_PROGRAM=Apple_Terminal get_chafa_format_args rex
      TMUX=/tmp/s,1,0 STUB_OUTER=WezTerm get_chafa_format_args ghostty
    }
    When call named
    The output should equal "-f kitty
-f kitty --passthrough tmux --probe off"
  End

  It 'is the same code under bash'
    under_bash() {
      TERM_PROGRAM=rex bash -c '. "$1"; get_chafa_format_args; TMUX=x STUB_OUTER=WezTerm get_chafa_format_args; get_image_max_bytes; TMUX=x get_image_max_bytes' _ \
        "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/image-protocol-support.zsh"
    }
    When call under_bash
    The output should equal "-f kitty
-f sixel --passthrough none --probe off
0
1000000"
  End

  # The yazi shim draws tmux sixel itself and cannot source zsh: its chafa
  # arguments are a Lua literal that must stay this function's tmux-sixel form.
  It 'is what the yazi shim hard-codes for tmux sixel'
    in_shim() {
      local want; want="$(TMUX=/tmp/s,1,0 STUB_OUTER=WezTerm get_chafa_format_args)"
      grep -cF -- "chafa $want -s " "$SHELLSPEC_PROJECT_ROOT/home/dot_config/yazi/plugins/preview-shim.yazi/main.lua" || true
    }
    When call in_shim
    The output should equal "1"
  End
End

# get_image_max_bytes — the largest single image stream this terminal takes.
# tmux discards a string sequence past its input buffer; nothing else caps.
Describe 'get_image_max_bytes'
  Include home/dot_local/lib/image-protocol-support.zsh

  setup() {
    MB_TMP=$(mktemp -d)
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "${STUB_BUF:-}"' >"$MB_TMP/tmux"
    chmod +x "$MB_TMP/tmux"
    MB_PATH="$PATH"; PATH="$MB_TMP:$PATH"
    unset TMUX STUB_BUF
  }
  cleanup() { PATH="$MB_PATH"; rm -rf "$MB_TMP"; unset TMUX STUB_BUF; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'is 0 (no cap) outside tmux'
    When call get_image_max_bytes
    The output should equal "0"
  End

  It 'is 95% of the tmux input buffer, or 1 MB when tmux does not say'
    caps() {
      export TMUX=/tmp/s,1,0
      STUB_BUF=8000000 get_image_max_bytes
      STUB_BUF= get_image_max_bytes
      STUB_BUF=500 get_image_max_bytes
      STUB_BUF=nonsense get_image_max_bytes
    }
    When call caps
    The output should equal "7600000
1000000
1000000
1000000"
  End
End
