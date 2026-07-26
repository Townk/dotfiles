# Tests for the yazi Ctrl+Space Quick Look dispatcher.
#
# The script normally ends by running main "$@"; YAZI_QUICK_LOOK_NO_RUN=1 is
# the test-only escape hatch (same convention as PREVIEW_NO_RUN in
# executable_preview) that lets a test source the functions, prepend stub
# binaries to PATH, and call main directly. Stubs echo their argv, so the
# assertions read the dispatch decision straight from the output — nothing
# GUI-facing (open/pkill/zellij) ever really runs.
Describe 'yazi-quick-look: dispatch'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_yazi-quick-look"

  setup() {
    STUBS="$SHELLSPEC_TMPBASE/ql-stubs"
    mkdir -p "$STUBS"
    for tool in open pkill zellij tmux; do
      printf '#!/bin/sh\necho "%s $@"\n' "$tool" >"$STUBS/$tool"
      chmod +x "$STUBS/$tool"
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
    The output should not include "zellij"
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

  It 'local macOS session inside zellij: never opens the floating pane'
    [[ $OSTYPE == darwin* ]] || skip "LaunchServices branch is macOS-only"
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      export ZELLIJ=0 TMPDIR='$SHELLSPEC_TMPBASE/stage-root'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The line 2 should include "open -n"
    The output should not include "zellij"
  End

  It 'SSH session inside zellij: floats the unified preview instead of Quick Look'
    When run zsh -c "
      export SSH_TTY=/dev/ttys000 ZELLIJ=0
      export MUX_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'
      export ZELLIJ_BIN='$STUBS/zellij'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The output should include "zellij action new-pane"
    The output should include "--floating"
    The output should include "mux-preview-file $TARGET"
    The output should not include "qlmanage.app"
  End

  # Same UX on tmux: a popup at the same 90% geometry, deferred to the server
  # so it outlives this yazi task.
  It 'SSH session inside tmux: pops the unified preview up'
    When run zsh -c "
      export SSH_TTY=/dev/ttys000 TMUX=/tmp/sock,1,0
      unset ZELLIJ
      export MUX_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'
      export MUX_TMUX_BIN='$STUBS/tmux'
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The output should include "run-shell -b"
    The output should include "tmux-popup"
    The output should include "mux-preview-file"
    The output should not include "qlmanage.app"
  End

  It 'SSH session outside any mux: quiet no-op'
    When run zsh -c "
      export SSH_TTY=/dev/ttys000
      unset ZELLIJ TMUX
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
