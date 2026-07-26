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

  It 'default_backend falls back to zellij on garbage'
    TEST_TMP=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEST_TMP"
    mkdir -p "$TEST_TMP/mux"
    printf 'screen\n' >"$TEST_TMP/mux/backend"
    When call mux::default_backend
    The output should equal "zellij"
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
