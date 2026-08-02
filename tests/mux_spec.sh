# Regression test for home/dot_local/lib/zellij.zsh — mux::pick.
#
# `zellij action new-pane` prints the created pane id (e.g. "terminal_5") to
# stdout ("Returns: Created pane ID" in its --help). mux::pick spawns the float
# with that command and then prints the FIFO selection on its own stdout, so a
# caller that captures `$(mux::pick ...)` (ai-commit / ai-assist harness pickers)
# must receive ONLY the selection — never the leaked pane id prepended to it.
#
# Stub FIFO delivery: each stub writes the selection through an O_RDWR fd held
# open briefly (`exec 3<>fifo; printf …>&3; sleep; exec 3>&-`) instead of a
# blocking `> "$fifo" &` writer. The blocking-open writer could be lost before
# it rendezvoused with mux::pick's reader — leaving `cat "$fifo"` waiting forever
# and the captured stdout/stderr pipe held open (the suite hung here). An O_RDWR
# open never blocks, so the byte is buffered and the reader always drains it.
Describe 'mux.zsh — mux::pick'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    export ZELLIJ=1
    # Stub zellij: on `action new-pane`, reproduce the real behavior — emit a
    # pane id to stdout — and deliver the selection through the --capture FIFO,
    # standing in for the modal+picker child.
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "claude" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  print -- "terminal_99"'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'returns only the FIFO selection, not the leaked new-pane id'
    Data
      #|claude  Claude Code
    End
    When call mux::pick --output field:1 --header "Pick"
    The output should equal "claude"
    The status should be success
  End
End

Describe 'mux.zsh — mux::confirm borderless float'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "yes" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'spawns confirm in a borderless pane with the title on the widget'
    When call mux::confirm --title "Quit" "Really?"
    The output should equal "yes"
    The contents of file "$ZJ_ARGS" should include "--borderless true"
    The contents of file "$ZJ_ARGS" should include "--type confirm"
    The contents of file "$ZJ_ARGS" should include "--title Quit"
    The status should be success
  End

  It 'spawns confirm without --title when none given (no title duplication)'
    When call mux::confirm "Really?"
    The output should equal "yes"
    The contents of file "$ZJ_ARGS" should include "--type confirm"
    The contents of file "$ZJ_ARGS" should not include "--title"
    The status should be success
  End
End

# MED-1 regression: mux::confirm must FAIL CLOSED. The destructive callers
# that gate on it read a "yes" as consent to proceed, so a confirmation dialog
# that cannot even render (e.g. _mux::float returning 1 when mkfifo fails on a
# non-writable TMPDIR / inode exhaustion / name collision — both float backends
# return 1 there) must answer "no", never fall through to an unconditional
# "yes". Seam: stub _mux::float (defined after Include so it overrides the
# sourced dispatcher) and drive mux::confirm through the float path (ZELLIJ=1
# makes _mux::widgets_float true). mux::choose/form already propagate the
# failure; confirm was the one that inverted it.
Describe 'mux.zsh — mux::confirm fails closed (MED-1)'
  Include home/dot_local/lib/mux.zsh

  setup() { export ZELLIJ=1; unset TMUX; }
  BeforeEach 'setup'

  Context 'when _mux::float cannot render (mkfifo failure, rc 1)'
    _mux::float() { return 1; }
    It 'answers "no" and returns non-zero — never fails open to yes'
      When call mux::confirm --title "Delete" "Really delete everything?"
      The output should equal "no"
      The status should be failure
    End
  End

  Context 'when the user confirms (rc 0, prints "yes")'
    _mux::float() { print -rn -- "yes"; return 0; }
    It 'answers yes and succeeds'
      When call mux::confirm "Proceed?"
      The output should equal "yes"
      The status should be success
    End
  End

  Context 'when the user declines (rc 0, prints "no")'
    _mux::float() { print -rn -- "no"; return 0; }
    It 'answers no and returns 1'
      When call mux::confirm "Proceed?"
      The output should equal "no"
      The status should equal 1
    End
  End

  Context 'when the user cancels the modal (rc 130)'
    _mux::float() { return 130; }
    It 'propagates the 130 cancel and does not answer yes'
      When call mux::confirm "Proceed?"
      The output should not equal "yes"
      The status should equal 130
    End
  End
End

Describe 'mux.zsh — mux::choose borderless float'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "alpha" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'spawns choose in a borderless pane with --type choose'
    When call mux::choose --title "Pick one" "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--borderless true"
    The contents of file "$ZJ_ARGS" should include "--type choose"
    The status should be success
  End

  It 'passes --multi through to the float'
    When call mux::choose --title "Pick" "Select" --multi -- alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--multi"
    The status should be success
  End

  It 'passes --other through to the float'
    When call mux::choose --title "Pick" "Select" --other "Something else" -- alpha beta
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--other"
    The status should be success
  End
End

Describe 'mux.zsh — mux::choose --measure-based pane height'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1

    # Stub ai-playbook input: when --measure is present, print a known height (9)
    # so we can assert the pane is spawned with --height 9.
    aii="$TEST_TMP/ai-playbook"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$*" == *"--measure"* ]]; then printf "9"; exit 0; fi'
      echo 'printf "%s" "${AII_OUT:-}"'
      echo 'exit ${AII_RC:-0}'
    } > "$aii"; chmod +x "$aii"
    export AI_PLAYBOOK_INPUT_BIN="$aii"

    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "alpha" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset AI_PLAYBOOK_INPUT_BIN AII_OUT; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'spawns the pane with --height equal to the measured value from the binary'
    When call mux::choose --title "Pick" "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--height 9"
    The status should be success
  End

  It 'does not contain any hardcoded vis+9 style height when binary returns a height'
    # The pane must carry --height matching the stub (9), not a formula result.
    # With 3 choices the old formula would yield min(3,8)+9=12; new must be 9.
    When call mux::choose --title "Pick" "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$ZJ_ARGS" should include "--height 9"
    The contents of file "$ZJ_ARGS" should not include "--height 12"
    The status should be success
  End
End

Describe 'mux.zsh — mux:: input drop-ins (off-Zellij fallback)'
  Include home/dot_local/lib/mux.zsh

  # Off-Zellij: mux::* must call the inline input::* with args intact. Stub the
  # input::* the wrappers delegate to (defined after Include → overrides).
  input::confirm() { printf 'confirm:%s' "$*"; }
  input::line()    { printf 'line:%s' "$*"; }
  input::choose()  { printf 'choose:%s' "$*"; }

  setup() { unset ZELLIJ; }   # force the non-Zellij path
  BeforeEach 'setup'

  It 'mux::confirm delegates to input::confirm with prompt only (no --title when none given)'
    When call mux::confirm "Proceed?"
    The output should include "Proceed?"
    The output should not include "--title"
    The status should be success
  End

  It 'mux::confirm forwards --title when explicitly given'
    When call mux::confirm --title "Confirm" "Proceed?"
    The output should include "--title Confirm"
    The output should include "Proceed?"
    The status should be success
  End

  It 'mux::confirm strips --pane-* before delegating'
    When call mux::confirm "Proceed?" --pane-width 40 --pane-height 7
    The output should not include "--pane-width"
    The output should include "Proceed?"
  End

  It 'mux::choose forwards choices'
    When call mux::choose "Pick" a b c
    The output should include "Pick"
    The output should include "a"
    The output should include "b"
    The output should include "c"
  End

  It 'mux::choose does not forward --title when none given'
    When call mux::choose "Pick" a b c
    The output should not include "--title"
    The status should be success
  End
End

Describe 'mux.zsh — mux::form borderless float'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == action && "$2" == new-pane ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/zj-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "form-result" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
    # Spec file for the form
    spec="$TEST_TMP/form.spec"
    printf 'name\x1fline\x1fYour name\x1esubscribe\x1fconfirm\x1fSubscribe?' > "$spec"
    FORM_SPEC="$spec"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'spawns form in a borderless pane with --type form'
    When call mux::form --title "Setup" --spec "$FORM_SPEC"
    The contents of file "$ZJ_ARGS" should include "--borderless true"
    The contents of file "$ZJ_ARGS" should include "--type form"
    The output should equal "form-result"
    The status should be success
  End
End

Describe 'mux.zsh — backend detection & knob'
  Include home/dot_local/lib/mux.zsh

  It 'detects zellij when $ZELLIJ is set'
    export ZELLIJ=0
    unset TMUX
    When call mux::backend
    The output should equal "zellij"
  End

  It 'detects tmux when only $TMUX is set'
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    When call mux::backend
    The output should equal "tmux"
  End

  It 'prefers zellij when both are set (nested zellij-in-tmux)'
    export ZELLIJ=0 TMUX=/tmp/sock,1,0
    When call mux::backend
    The output should equal "zellij"
  End

  It 'reports none outside any mux'
    unset ZELLIJ TMUX
    When call mux::backend
    The output should equal "none"
  End

  It 'default_backend honors the loose knob file'
    TEST_TMP=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEST_TMP"
    mkdir -p "$TEST_TMP/mux"
    printf 'tmux\n' >"$TEST_TMP/mux/backend"
    When call mux::default_backend
    The output should equal "tmux"
  End

  # Garbage in the loose pin falls back to the BAKED default, which Phase 7
  # flipped to tmux. Read it from chezmoi data rather than repeating the word:
  # this assertion existed to prove the knob rejects nonsense, and hard-coding
  # the value made it fail on the flip as if the rejection had broken.
  It 'default_backend falls back to the baked default on garbage'
    TEST_TMP=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEST_TMP"
    mkdir -p "$TEST_TMP/mux"
    printf 'screen\n' >"$TEST_TMP/mux/backend"
    When call mux::default_backend
    The output should equal "$(awk '/^muxBackend:/{print $2}' "$SHELLSPEC_PROJECT_ROOT/home/.chezmoidata/mux.yaml")"
  End
End

Describe 'mux.zsh — tmux float backend (Phase 2)'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    TX_ARGS="$TEST_TMP/tx-args.txt"
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    # Stub tmux: record display-popup argv and deliver the answer through the
    # --capture FIFO (O_RDWR trick — see the zellij stubs above), standing in
    # for the popup + tmux-modal + widget chain.
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo 'if [[ "$1" == display-popup ]]; then'
      echo "  echo \"\$*\" > \"$TEST_TMP/tx-args.txt\""
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  [[ -n "$fifo" ]] && { { exec 3<>"$fifo"; printf "%s" "${TX_ANSWER:-yes}" >&3; sleep 0.5; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN TX_ANSWER; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'mux::confirm floats via display-popup and returns the captured answer'
    When call mux::confirm --title "Quit" "Really?"
    The output should equal "yes"
    The contents of file "$TX_ARGS" should include "display-popup"
    The contents of file "$TX_ARGS" should include "--type confirm"
    The status should be success
  End

  It 'mux::pick floats via a borderless popup and returns the selection'
    export TX_ANSWER="claude"
    Data
      #|claude  Claude Code
    End
    When call mux::pick --output field:1 --header "Pick"
    The output should equal "claude"
    The contents of file "$TX_ARGS" should include "-B"
    The contents of file "$TX_ARGS" should include "--no-chrome"
    The status should be success
  End

  It 'mux::choose floats with --type choose'
    export TX_ANSWER="alpha"
    When call mux::choose --title "Pick one" "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$TX_ARGS" should include "--type choose"
    The status should be success
  End

  It 'forwards --title to tmux-modal so it renders the header block'
    export TX_ANSWER="alpha"
    When call mux::choose --title "Pick one" "Select" alpha beta gamma
    The output should equal "alpha"
    # The modal invocation carries the title (modal_args = --title … --capture …),
    # not just the widget after the `--`; assert on that exact adjacency.
    The contents of file "$TX_ARGS" should include "--title Pick one --capture"
    The status should be success
  End

  It 'passes no stray --title to tmux-modal when none given'
    export TX_ANSWER="alpha"
    When call mux::choose "Select" alpha beta gamma
    The output should equal "alpha"
    The contents of file "$TX_ARGS" should not include "--title"
    The status should be success
  End
End

Describe 'mux.zsh — zj:: permanent aliases'
  Include home/dot_local/lib/mux.zsh
  input::confirm() { printf 'confirm:%s' "$*"; }

  It 'zj::confirm is mux::confirm'
    unset ZELLIJ TMUX
    When call zj::confirm "Proceed?"
    The output should include "Proceed?"
  End

  It 'zj::available is false outside zellij'
    unset ZELLIJ TMUX
    When call zj::available
    The status should be failure
  End
End

Describe 'mux.zsh — pane/tab/info API (Phase 6.0, zellij backend)'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_ARGS="$TEST_TMP/zj-args.txt"
    export ZELLIJ=1
    unset TMUX
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo "echo \"\$*\" >> \"$TEST_TMP/zj-args.txt\""
      echo 'if [[ "$*" == *"list-tabs"* ]]; then'
      # list-tabs -s columns, as both existing consumers read them:
      # $1 tab id, $2 position (0-based), $4 is_active.
      echo '  print -- "ID  POSITION  NAME  ACTIVE"'
      echo '  print -- "0  0  first  false"'
      echo '  print -- "1  1  second  true"'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'mux::split runs a directional pane with name and close-on-exit'
    When call mux::split right --size 40 --name "tm lens" --close-on-exit -- /bin/echo hi
    The status should be success
    The contents of file "$ZJ_ARGS" should include "run --close-on-exit --direction right --name tm lens"
    The contents of file "$ZJ_ARGS" should include "-- /bin/echo hi"
  End

  It 'mux::popup floats a borderless pinned pane at the given percentages'
    When call mux::popup 90% 90% --name preview -- /bin/echo hi
    The status should be success
    The contents of file "$ZJ_ARGS" should include "new-pane --floating"
    The contents of file "$ZJ_ARGS" should include "--width 90%"
    The contents of file "$ZJ_ARGS" should include "--height 90%"
    The contents of file "$ZJ_ARGS" should include "--borderless true"
  End

  It 'mux::new_tab opens a named tab with a cwd and a command'
    When call mux::new_tab --name "edit" --cwd /tmp -- nvim foo
    The status should be success
    The contents of file "$ZJ_ARGS" should include "new-tab"
    The contents of file "$ZJ_ARGS" should include "--name edit"
    The contents of file "$ZJ_ARGS" should include "--cwd /tmp"
    The contents of file "$ZJ_ARGS" should include "-- nvim foo"
  End

  It 'mux::new_tab targets an explicit session when asked'
    When call mux::new_tab --session Main --name edit -- nvim
    The status should be success
    The contents of file "$ZJ_ARGS" should include "--session Main"
  End

  It 'mux::send_text writes the literal text'
    When call mux::send_text "hello world"
    The status should be success
    The contents of file "$ZJ_ARGS" should include "write-chars -- hello world"
  End

  It 'mux::send_key writes the escape sequence for a named key'
    When call mux::send_key s-up
    The status should be success
    The contents of file "$ZJ_ARGS" should include "write-chars"
  End

  It 'mux::current_tab reports the active tab, 1-based'
    When call mux::current_tab
    The output should equal "2"
  End

  It 'mux::focus_tab selects that 1-based index'
    When call mux::focus_tab 2
    The status should be success
    The contents of file "$ZJ_ARGS" should include "go-to-tab 2"
  End
End

Describe 'mux.zsh — pane/tab/info API (Phase 6.0, tmux backend)'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    TX_ARGS="$TEST_TMP/tx-args.txt"
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo "echo \"\$*\" >> \"$TEST_TMP/tx-args.txt\""
      echo 'case "$1" in'
      echo '  display) case "$*" in'
      echo '    *window_index*)      print -- "2" ;;'
      echo '    *pane_current_path*) print -- "/tmp/here" ;;'
      echo '    *client_width*)      print -- "120 40" ;;'
      echo '    *pane_current_command*) print -- "nvim" ;;'
      echo '  esac ;;'
      echo '  split-window) print -- "%7" ;;'
      echo 'esac'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'mux::split sizes the pane at split time (no resize convergence)'
    When call mux::split right --size 40 --name "tm lens" --close-on-exit -- /bin/echo hi
    The status should be success
    The output should equal "%7"
    The contents of file "$TX_ARGS" should include "split-window -h -l 40"
    The contents of file "$TX_ARGS" should include "/bin/echo hi"
  End

  It 'mux::split maps left/up to the -b (before) flag'
    When call mux::split left -- /bin/echo hi
    The status should be success
    The output should equal "%7"
    The contents of file "$TX_ARGS" should include "-h -b"
  End

  It 'mux::split titles the new pane when given a name'
    When call mux::split down --name "tm lens" -- /bin/echo hi
    The status should be success
    The output should equal "%7"
    The contents of file "$TX_ARGS" should include "select-pane -t %7 -T tm lens"
  End

  It 'mux::popup defers to the server so it outlives the caller'
    When call mux::popup 90% 90% --name preview -- /bin/echo hi
    The status should be success
    The contents of file "$TX_ARGS" should include "run-shell -b"
    The contents of file "$TX_ARGS" should include "tmux-popup' 90 90"
  End

  It 'mux::popup in CELLS goes straight to display-popup (no percent math)'
    When call mux::popup 54 18 -- /bin/echo hi
    The status should be success
    The contents of file "$TX_ARGS" should include "run-shell -b"
    The contents of file "$TX_ARGS" should include "display-popup -w 54 -h 18"
    The contents of file "$TX_ARGS" should include "-E"
    The contents of file "$TX_ARGS" should not include "tmux-popup"
  End

  # `display-popup -E` exits with its command's status and run-shell paints any
  # non-zero one over the client. 130 is the clean-cancel convention, so ESC on
  # a modal used to leave a "returned 130" error overlay behind.
  It 'mux::popup swallows a 130 cancel but not a real failure'
    When call mux::popup 54 18 -- /bin/echo hi
    The status should be success
    The contents of file "$TX_ARGS" should include '|| [ $? -eq 130 ]'
  End

  It 'mux::new_tab opens a named window with a cwd and a command'
    When call mux::new_tab --name "edit" --cwd /tmp -- nvim foo
    The status should be success
    The contents of file "$TX_ARGS" should include "new-window -n edit -c /tmp"
    The contents of file "$TX_ARGS" should include "nvim foo"
  End

  It 'mux::new_tab targets an explicit session when asked'
    When call mux::new_tab --session Main --name edit -- nvim
    The status should be success
    The contents of file "$TX_ARGS" should include "-t =Main:"
  End

  # --singleton: one window of that name, reused. The image previewer wants
  # a second Cmd+click to land in the window already open, not stack another.
  It 'mux::new_tab --singleton respawns and selects an existing window'
    # the stub lists a window already called Previewer
    printf '#!/usr/bin/env zsh\necho "$*" >> %s\ncase "$1 $2" in\n  "list-windows -F") print -- "Previewer" ;;\nesac\nexit 0\n' "$TX_ARGS" > "$TEST_TMP/tmux"
    chmod +x "$TEST_TMP/tmux"
    When call mux::new_tab --singleton --name Previewer -- viewer img.png
    The status should be success
    The contents of file "$TX_ARGS" should include "respawn-window -k"
    The contents of file "$TX_ARGS" should include "select-window"
    The contents of file "$TX_ARGS" should not include "new-window"
  End

  It 'mux::new_tab --singleton creates the window when none exists'
    When call mux::new_tab --singleton --name Previewer -- viewer img.png
    The status should be success
    The contents of file "$TX_ARGS" should include "new-window"
    The contents of file "$TX_ARGS" should not include "respawn-window"
  End

  It 'mux::send_text sends the text literally'
    When call mux::send_text "hello world"
    The status should be success
    The contents of file "$TX_ARGS" should include "send-keys -l -- hello world"
  End

  It 'mux::send_key sends the tmux key name'
    When call mux::send_key s-up
    The status should be success
    The contents of file "$TX_ARGS" should include "send-keys S-Up"
  End

  It 'mux::current_tab reports the window index'
    When call mux::current_tab
    The output should equal "2"
  End

  It 'mux::focus_tab selects that window'
    When call mux::focus_tab 2
    The status should be success
    The contents of file "$TX_ARGS" should include "select-window -t"
  End

  It 'mux::pane_cwd reads the pane path'
    When call mux::pane_cwd
    The output should equal "/tmp/here"
  End

  It 'mux::terminal_size reports cols rows'
    When call mux::terminal_size
    The output should equal "120 40"
  End

  It 'mux::focused_command reports the active pane command'
    When call mux::focused_command
    The output should equal "nvim"
  End
End

Describe 'mux.zsh — pane/tab API outside any mux'
  Include home/dot_local/lib/mux.zsh

  setup() { unset ZELLIJ TMUX; }
  BeforeEach 'setup'

  It 'mux::split fails rather than guessing'
    When call mux::split right -- /bin/echo hi
    The status should be failure
  End

  It 'mux::send_text fails rather than guessing'
    When call mux::send_text hi
    The status should be failure
  End
End

Describe 'mux.zsh — session resolvers dispatch (tmux)'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo 'case "$1" in'
      echo '  list-clients)  print -- "999 Main-tmux" ;;'
      echo '  list-sessions) print -- "1 Main-tmux"; print -- "0 scratch" ;;'
      echo '  capture-pane)  print -- "screen-line" ;;'
      echo '  display*)      print -- "Main-tmux" ;;'
      echo 'esac'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'mux::resolve_session maps a client pid via list-clients'
    When call mux::resolve_session 999
    The output should equal "Main-tmux"
  End

  It 'mux::attached_sessions lists only attached sessions'
    When call mux::attached_sessions
    The output should equal "Main-tmux"
  End

  It 'mux::dump_screen captures the pane'
    When call mux::dump_screen
    The output should equal "screen-line"
  End
End

Describe 'mux.zsh — dump_screen / send_text targeting (tmux)'
  Include home/dot_local/lib/mux.zsh

  # The stub ECHOES its argv, so each example asserts on the command the shim
  # actually built rather than on a canned reply.
  setup() {
    TEST_TMP=$(mktemp -d)
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "tmux $*"'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # zellij's dump-screen has always returned the viewport; tmux's side used to
  # return the whole scrollback, so the one verb meant two things.
  It 'mux::dump_screen captures the VIEWPORT by default'
    When call mux::dump_screen
    The output should equal "tmux capture-pane -p"
  End

  It 'mux::dump_screen --full adds the scrollback'
    When call mux::dump_screen --full
    The output should equal "tmux capture-pane -p -S -"
  End

  It 'mux::send_text writes to the focused pane with no --pane'
    When call mux::send_text 'ls -la'
    The output should equal "tmux send-keys -l -- ls -la"
  End

  # Without a target the write lands wherever focus happens to be — which is
  # the closing float, not the pane the caller meant.
  It 'mux::send_text --pane targets that pane'
    When call mux::send_text --pane '%3' 'ls -la'
    The output should equal "tmux send-keys -t %3 -l -- ls -la"
  End
End

Describe 'mux.zsh — live session/tab state (tmux)'
  Include home/dot_local/lib/mux.zsh

  # An ARG-AWARE stub: the point of these verbs is which tmux format they ask
  # for, so a stub that ignores its arguments would assert nothing.
  setup() {
    TEST_TMP=$(mktemp -d)
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo 'case "$1" in'
      echo '  list-sessions)'
      echo '    case "$*" in'
      echo '      *session_attached*) print -- "1 Main-tmux"; print -- "0 scratch" ;;'
      echo '      *) print -- "Main-tmux"; print -- "scratch" ;;'
      echo '    esac ;;'
      echo '  display)'
      echo '    case "$*" in'
      echo '      *window_name*)   print -- "editor" ;;'
      echo '      *session_name*)  print -- "Main-tmux" ;;'
      echo '    esac ;;'
      echo 'esac'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'mux::current_session names the session we are in'
    When call mux::current_session
    The output should equal "Main-tmux"
  End

  # quick-launch scopes tab-nested entries by TITLE, so the index will not do.
  It 'mux::current_tab_name reports the title, not the index'
    When call mux::current_tab_name
    The output should equal "editor"
  End

  # The workspace picker asks "which sessions exist" — every one, not just the
  # attached ones it separately asks mux::attached_sessions about.
  It 'mux::list_sessions lists every session'
    When call mux::list_sessions
    The lines of output should equal 2
    The line 1 of output should equal "Main-tmux"
    The line 2 of output should equal "scratch"
  End
End

Describe 'mux.zsh — kill_session'
  Include home/dot_local/lib/mux.zsh

  # Both stubs LOG their argv rather than echo it: the zellij side swallows
  # its own output, so an echoing stub would assert nothing there.
  setup() {
    TEST_TMP=$(mktemp -d)
    KILL_LOG="$TEST_TMP/calls.log"
    unset ZELLIJ ZELLIJ_SESSION_NAME TMUX MUX_BACKEND
    local b
    for b in tmux zellij; do
      {
        echo '#!/usr/bin/env zsh'
        echo "print -r -- \"\$*\" >> \"$KILL_LOG\""
      } > "$TEST_TMP/$b"
      chmod +x "$TEST_TMP/$b"
    done
    export MUX_TMUX_BIN="$TEST_TMP/tmux" ZELLIJ_BIN="$TEST_TMP/zellij"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN ZELLIJ_BIN ZELLIJ ZELLIJ_SESSION_NAME TMUX; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A bare `-t Main` prefix-matches, so "Main2" would answer for "Main".
  It 'tmux kills the named session by EXACT name'
    export TMUX=/tmp/sock,1,0
    When call mux::kill_session Main
    The contents of file "$KILL_LOG" should include "kill-session -t =Main"
  End

  # `kill-session` alone would leave an EXITED, resurrectable record that
  # mux::list_sessions still reports — so the session picker's row, which is
  # derived from that list, would never clear.
  It 'zellij DELETES the session rather than merely killing it'
    export ZELLIJ=1 ZELLIJ_SESSION_NAME=spec
    When call mux::kill_session Main
    The contents of file "$KILL_LOG" should include "delete-session Main -f"
    The contents of file "$KILL_LOG" should not include "kill-session"
  End
End

Describe 'mux.zsh — dump_screen (zellij)'
  Include home/dot_local/lib/mux.zsh

  # The stub ECHOES its argv so the assertions are about the command SHAPE.
  # This verb had NO zellij coverage, which is how it survived being written
  # against an older CLI: it passed the dump path as a POSITIONAL, but zellij
  # takes `--path <PATH>` and prints to stdout when it is omitted — so the
  # real call was rejected and the verb returned nothing at all.
  setup() {
    TEST_TMP=$(mktemp -d)
    unset TMUX
    export ZELLIJ=1 ZELLIJ_SESSION_NAME=spec
    stub="$TEST_TMP/zellij"
    { echo '#!/usr/bin/env zsh'; echo 'print -r -- "zellij $*"'; } > "$stub"
    chmod +x "$stub"
    export ZELLIJ_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset ZELLIJ_BIN ZELLIJ ZELLIJ_SESSION_NAME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'dumps the viewport to stdout, with no path argument'
    When call mux::dump_screen
    The output should equal "zellij action dump-screen"
  End

  It 'adds --full for the whole scrollback'
    When call mux::dump_screen --full
    The output should equal "zellij action dump-screen --full"
  End

  # The regression guard: a positional path is what broke it.
  It 'never passes the dump target positionally'
    When call mux::dump_screen
    The output should not include "/muxdump"
    The output should not include "--path"
  End
End

Describe 'mux.zsh — mux::available honours a PINNED backend'
  Include home/dot_local/lib/mux.zsh

  # mux::backend already honours $MUX_BACKEND — that is how callers outside any
  # session (mux-open, from WezTerm's GUI) say which mux to drive. Availability
  # used to re-derive from $ZELLIJ/$TMUX instead, so it disagreed with the
  # dispatch it guards: term-quick-view took its "no mux" arm and rendered
  # inline into a terminal nobody was looking at, on BOTH backends.
  setup() {
    TEST_TMP=$(mktemp -d)
    unset ZELLIJ ZELLIJ_SESSION_NAME TMUX
    for b in zellij tmux; do
      { echo '#!/usr/bin/env zsh'; echo 'exit 0'; } > "$TEST_TMP/$b"
      chmod +x "$TEST_TMP/$b"
    done
    export ZELLIJ_BIN="$TEST_TMP/zellij" MUX_TMUX_BIN="$TEST_TMP/tmux"
    PATH="$TEST_TMP:$PATH"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset ZELLIJ_BIN MUX_TMUX_BIN MUX_BACKEND; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'is available for a pinned zellij with no $ZELLIJ in the environment'
    export MUX_BACKEND=zellij
    When call mux::available
    The status should be success
  End

  It 'is available for a pinned tmux with no $TMUX in the environment'
    export MUX_BACKEND=tmux
    When call mux::available
    The status should be success
  End

  It 'is still unavailable with no session and no pin'
    unset MUX_BACKEND
    When call mux::available
    The status should be failure
  End
End

# mux::pane_count backs the .zshrc welcome screen, which shows itself only in a
# session's lone pane. It was a raw `zellij action list-tabs` call in .zshrc
# until the tmux migration, so under the (default) tmux backend the whole
# welcome screen silently stopped rendering. Include the BOOTSTRAP flavor
# here, not mux.zsh: that is the one .zshrc sources, so this also pins that the
# lean half can answer the question on its own.
Describe 'mux-bootstrap.zsh — mux::pane_count (zellij)'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    unset TMUX MUX_BACKEND
    export ZELLIJ=1
  }
  cleanup() { rm -rf "$TEST_TMP"; unset ZELLIJ_BIN ZELLIJ; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Emit the `list-tabs -p --json` shape with the given per-tab counts.
  zj_tabs() {
    { echo '#!/usr/bin/env zsh'; echo "print -r -- '$1'"; } > "$TEST_TMP/zellij"
    chmod +x "$TEST_TMP/zellij"
    export ZELLIJ_BIN="$TEST_TMP/zellij"
  }

  It 'counts 1 for a fresh single-pane session'
    zj_tabs '[{"selectable_tiled_panes_count":1,"selectable_floating_panes_count":0}]'
    When call mux::pane_count
    The output should equal "1"
  End

  It 'sums tiled and floating panes across every tab'
    zj_tabs '[{"selectable_tiled_panes_count":2,"selectable_floating_panes_count":1},{"selectable_tiled_panes_count":3,"selectable_floating_panes_count":0}]'
    When call mux::pane_count
    The output should equal "6"
  End

  # `add` on an empty array is null, which would compare as neither 1 nor >1.
  It 'reports 0 rather than null when there are no tabs'
    zj_tabs '[]'
    When call mux::pane_count
    The output should equal "0"
  End
End

Describe 'mux-bootstrap.zsh — mux::pane_count (tmux)'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    unset ZELLIJ MUX_BACKEND
    export TMUX=/tmp/sock,1,0
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN TMUX; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  tx_panes() {
    { echo '#!/usr/bin/env zsh'
      echo "echo \"\$*\" >> \"$TEST_TMP/tx-args.txt\""
      echo "[[ \"\$1\" == list-panes ]] && printf '%s' '$1'"
      echo 'exit 0'
    } > "$TEST_TMP/tmux"
    chmod +x "$TEST_TMP/tmux"
    export MUX_TMUX_BIN="$TEST_TMP/tmux"
  }

  It 'counts 1 for a fresh single-pane session'
    tx_panes '%0
'
    When call mux::pane_count
    The output should equal "1"
  End

  # -s is the whole session, not just the current window: a second window is as
  # much proof of an existing session as a second pane, and the welcome screen
  # must stay quiet for both.
  It 'counts panes across every window of the session'
    tx_panes '%0
%1
%2
'
    When call mux::pane_count
    The output should equal "3"
    The contents of file "$TEST_TMP/tx-args.txt" should include "list-panes -s"
  End

  # BSD wc pads its count with leading blanks, which broke a numeric compare.
  It 'emits a bare integer with no padding'
    tx_panes '%0
%1
'
    When call mux::pane_count
    The output should equal "2"
  End

  It 'reads 0 when the server answers nothing'
    tx_panes ''
    When call mux::pane_count
    The output should equal "0"
  End
End

# The split exists so a shell STARTUP path can load the shim: pick-common runs
# `require_cmd fzf` at source time and die()s the shell when fzf is missing,
# and the three *-common libraries cost ~50ms. Pin the boundary so a later
# edit cannot quietly drag the widget stack back into the lean flavor.
Describe 'mux-bootstrap.zsh — flavor boundary'
  Include home/dot_local/lib/mux-bootstrap.zsh

  It 'defines the query verbs'
    When call whence -w mux::pane_count
    The output should include "function"
  End

  It 'does not pull in the widget layer'
    When call whence -w mux::pick
    The output should equal "mux::pick: none"
    The status should be failure
  End

  It 'does not pull in pick-common'
    When call whence -w pick::start
    The output should equal "pick::start: none"
    The status should be failure
  End
End

Describe 'mux-bootstrap.zsh — mux::in_session'
  Include home/dot_local/lib/mux-bootstrap.zsh

  It 'is true inside zellij'
    export ZELLIJ=1
    unset TMUX
    When call mux::in_session
    The status should be success
  End

  It 'is true inside tmux'
    unset ZELLIJ
    export TMUX=/tmp/sock,1,0
    When call mux::in_session
    The status should be success
  End

  It 'is false outside any session'
    unset ZELLIJ TMUX MUX_BACKEND
    When call mux::in_session
    The status should be failure
  End

  # Why this is not `[[ "$(mux::backend)" != none ]]`: mux-open exports
  # MUX_BACKEND from the terminal's GUI, where no session exists. Reading that
  # as "already nested" would make .zshrc's autostart gate decline to launch a
  # multiplexer at all, leaving the terminal with a bare shell.
  It 'is false when only MUX_BACKEND is pinned'
    unset ZELLIJ TMUX
    export MUX_BACKEND=tmux
    When call mux::in_session
    The status should be failure
  End
End

Describe 'mux-bootstrap.zsh — mux::default_backend fallback argument'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEST_TMP"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # .zshrc passes chezmoi's .muxBackend here, which is what keeps the data file
  # the single source of the baked default instead of a second copy of it.
  It 'takes the caller fallback when no loose pin exists'
    When call mux::default_backend zellij
    The output should equal "zellij"
  End

  It 'lets the loose pin beat the caller fallback'
    mkdir -p "$XDG_CONFIG_HOME/mux"
    print -r -- tmux >"$XDG_CONFIG_HOME/mux/backend"
    When call mux::default_backend zellij
    The output should equal "tmux"
  End

  It 'ignores an unrecognised fallback rather than obeying it'
    When call mux::default_backend nonsense
    The output should equal "tmux"
  End
End

# .zshrc's autostart runs BEFORE it extends $PATH and before mise activates,
# so the backends must find their binary unaided. That property is precisely
# what let the launch dance move behind mux::*; without it the block would
# still need to carry its own hard-coded search loops.
Describe 'mux-bootstrap.zsh — binary resolution without $PATH'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() { unset MUX_TMUX_BIN ZELLIJ_BIN; }
  BeforeEach 'setup'

  # Subshell bodies: the PATH change must not leak into the example.
  tx_no_path() ( PATH=/nonexistent; _mux_tx_bin )
  zj_no_path() ( PATH=/nonexistent; _mux_zj_bin )

  no_tmux() { [[ ! -x /opt/homebrew/bin/tmux && ! -x /usr/local/bin/tmux && ! -x /usr/bin/tmux ]]; }
  no_zellij() { [[ ! -x /opt/homebrew/bin/zellij && ! -x /usr/local/bin/zellij ]]; }

  It 'finds tmux at a known install location'
    Skip if 'tmux is not installed where the shim looks' no_tmux
    When call tx_no_path
    The output should start with "/"
    The status should be success
  End

  It 'finds zellij at a known install location'
    Skip if 'zellij is not installed where the shim looks' no_zellij
    When call zj_no_path
    The output should start with "/"
    The status should be success
  End

  # The override seam the specs inject stubs through still wins over both.
  It 'honours the explicit binary override'
    export MUX_TMUX_BIN=/some/stub/tmux
    When call tx_no_path
    The output should equal "/some/stub/tmux"
  End
End

Describe 'mux.zsh — full flavor still exposes everything'
  Include home/dot_local/lib/mux.zsh

  It 'has the widget layer'
    When call whence -w mux::pick
    The output should include "function"
  End

  It 'has the bootstrap query verbs too'
    When call whence -w mux::pane_count
    The output should include "function"
  End
End
