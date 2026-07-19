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
    for tool in open pkill zellij; do
      printf '#!/bin/sh\necho "%s $@"\n' "$tool" >"$STUBS/$tool"
      chmod +x "$STUBS/$tool"
    done
    TARGET="$SHELLSPEC_TMPBASE/ql-target.txt"
    echo hello >"$TARGET"
  }
  BeforeEach 'setup'

  It 'local macOS session: replaces any open panel, then Quick Looks via LaunchServices'
    [[ $OSTYPE == darwin* ]] || skip "LaunchServices branch is macOS-only"
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The line 1 should equal "pkill -x qlmanage"
    The line 2 should equal "open -n /System/Library/Frameworks/QuickLook.framework/Versions/A/Resources/qlmanage.app --args -p $TARGET"
  End

  It 'local macOS session: passes every selected file to qlmanage'
    [[ $OSTYPE == darwin* ]] || skip "LaunchServices branch is macOS-only"
    When run zsh -c "
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET' '$TARGET'"
    The status should be success
    The line 2 should equal "open -n /System/Library/Frameworks/QuickLook.framework/Versions/A/Resources/qlmanage.app --args -p $TARGET $TARGET"
  End

  It 'SSH session inside zellij: floats the unified preview instead of Quick Look'
    When run zsh -c "
      export SSH_TTY=/dev/ttys000 ZELLIJ=0
      YAZI_QUICK_LOOK_NO_RUN=1 source '$SCRIPT'
      PATH='$STUBS':\$PATH
      main '$TARGET'"
    The status should be success
    The output should include "zellij action new-pane"
    The output should include "--floating"
    The output should include "zellij-preview-file $TARGET"
    The output should not include "qlmanage"
  End

  It 'SSH session outside zellij: quiet no-op'
    When run zsh -c "
      export SSH_TTY=/dev/ttys000
      unset ZELLIJ
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
