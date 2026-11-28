# Tests for the yazi Ctrl+Space Quick Look dispatcher.
#
# The script normally ends by running main "$@"; YAZI_QUICK_LOOK_NO_RUN=1 is
# the test-only escape hatch (same convention as PREVIEW_NO_RUN in
# executable_preview) that lets a test source the functions, prepend stub
# binaries to PATH, and call main directly. Stubs echo their argv, so the
# assertions read the dispatch decision straight from the output — nothing
# GUI-facing (open/pkill/tmux) ever really runs.
Describe 'yazi-quick-look: dispatch'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_yazi-quick-look"

  setup() {
    STUBS="$SHELLSPEC_TMPBASE/ql-stubs"
    mkdir -p "$STUBS"
    for tool in open pkill tmux term-quick-view; do
      spec_stub "$STUBS" "$tool" "echo \"$tool \$@\""
    done
    TARGET="$SHELLSPEC_TMPBASE/ql-target.txt"
    echo hello >"$TARGET"
  }
  BeforeEach 'setup'

  It 'local macOS session: replaces any open panel, then Quick Looks the TMPDIR-staged hardlink'
    [[ $OSTYPE == darwin* ]] || skip "LaunchServices branch is macOS-only"
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      export TMPDIR='$SHELLSPEC_TMPBASE/stage-root'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The line 1 should equal "pkill -f qlmanage -p "
    The line 2 should equal "open -n /System/Library/Frameworks/QuickLook.framework/Versions/A/Resources/qlmanage.app --args -p $SHELLSPEC_TMPBASE/stage-root/yazi-quick-look/ql-target.txt"
    The output should not include "term-quick-view"
  End

  It 'local macOS session: stages every selected file, deduping basename collisions'
    [[ $OSTYPE == darwin* ]] || skip "LaunchServices branch is macOS-only"
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      export TMPDIR='$SHELLSPEC_TMPBASE/stage-root'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET' '$TARGET'"
    The status should be success
    The line 2 should equal "open -n /System/Library/Frameworks/QuickLook.framework/Versions/A/Resources/qlmanage.app --args -p $SHELLSPEC_TMPBASE/stage-root/yazi-quick-look/ql-target.txt $SHELLSPEC_TMPBASE/stage-root/yazi-quick-look/2-ql-target.txt"
  End

  It 'staged hardlink shares the source inode (no data copy)'
    [[ $OSTYPE == darwin* ]] || skip "LaunchServices branch is macOS-only"
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      export TMPDIR='$SHELLSPEC_TMPBASE/stage-root'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      ( main '$TARGET' ) >/dev/null
      zmodload zsh/stat
      zstat -A a +inode '$TARGET'
      zstat -A b +inode \"\$TMPDIR/yazi-quick-look/ql-target.txt\"
      [[ \$a == \$b ]] && print same-inode"
    The status should be success
    The output should equal "same-inode"
  End

  It 'non-regular targets (directories) pass through unstaged'
    [[ $OSTYPE == darwin* ]] || skip "LaunchServices branch is macOS-only"
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      export TMPDIR='$SHELLSPEC_TMPBASE/stage-root'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$SHELLSPEC_TMPBASE'"
    The status should be success
    The line 2 should equal "open -n /System/Library/Frameworks/QuickLook.framework/Versions/A/Resources/qlmanage.app --args -p $SHELLSPEC_TMPBASE"
  End

  # One viewer for every entry point now: yazi hands off to term-quick-view,
  # which owns the tab-or-float choice per backend.
  # In Rex the terminal viewer wins everywhere — at the desk too, where the
  # macOS panel would otherwise open.
  It 'Rex pane on the local Mac: the terminal viewer, not the macOS panel'
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY TMUX
      export REX_BLOCK=block:here
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The output should equal "term-quick-view $TARGET"
  End

  It 'Rex pane over SSH: the terminal viewer too'
    When run zsh -c "
      unset TMUX
      export REX_BLOCK=block:here SSH_CONNECTION='1.2.3.4 1 5.6.7.8 22'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The output should equal "term-quick-view $TARGET"
  End

  It 'SSH session inside tmux: hands off to the shared terminal viewer'
    When run zsh -c "
      export SSH_TTY=/dev/ttys000 TMUX=/tmp/sock,1,0
      export MUX_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'
      export MUX_TMUX_BIN='$STUBS/tmux'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The output should include "term-quick-view $TARGET"
    The output should not include "qlmanage.app"
  End

  It 'SSH session outside any mux: quiet no-op'
    When run zsh -c "
      export SSH_TTY=/dev/ttys000
      unset TMUX
      export MUX_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The output should equal ""
  End

  It 'no arguments: quiet no-op'
    When run zsh -c "
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main"
    The status should be success
    The output should equal ""
  End
End
