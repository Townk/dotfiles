# Tests for the system-package dispatcher's sync fan-out (sync_all).
#
# ECOSYSTEMS is discovered alphabetically, so brew runs first: a single failing
# worker (a 404'd cask, cargo/go missing before mise provisions them) used to
# abort sync_all at the FIRST ecosystem under `set -e`, silently skipping every
# ecosystem that follows. sync_all must isolate each worker so one failure never
# aborts the rest, while still propagating an overall non-zero exit.
Describe 'system-package sync (dispatcher fan-out)'
  DISPATCHER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package"

  _mkworker() {
    cat >"$BIN/system-package-$1" <<EOF
#!/bin/sh
echo "$1" >>"$CALLLOG"
exit $2
EOF
    chmod +x "$BIN/system-package-$1"
  }

  setup() {
    STAGE=$(mktemp -d)
    BIN="$STAGE/.local/bin"
    mkdir -p "$STAGE/.local" "$BIN"
    # Real lib (palette + common.zsh resolve via THEME_PALETTE_FILE from
    # spec_helper); only the workers are stubbed.
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/.local/lib"
    cp "$DISPATCHER" "$BIN/system-package"
    chmod +x "$BIN/system-package"
    CALLLOG="$STAGE/calls"; : >"$CALLLOG"
    # Alphabetical order: the FIRST worker fails, the two after it succeed.
    _mkworker aaa 1
    _mkworker mmm 0
    _mkworker zzz 0
    OLD_HOME="${HOME:-}"; export HOME="$STAGE"
  }
  cleanup() { export HOME="$OLD_HOME"; rm -rf "$STAGE"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'runs every later ecosystem even when the first worker fails'
    When run command zsh "$BIN/system-package" sync
    The status should be failure
    The contents of file "$CALLLOG" should include "aaa"
    The contents of file "$CALLLOG" should include "mmm"
    The contents of file "$CALLLOG" should include "zzz"
    The stderr should include "aaa sync failed"
    The stdout should be present
  End

  It 'succeeds when every worker succeeds'
    _mkworker aaa 0
    When run command zsh "$BIN/system-package" sync
    The status should be success
    The contents of file "$CALLLOG" should include "aaa"
    The contents of file "$CALLLOG" should include "mmm"
    The contents of file "$CALLLOG" should include "zzz"
    The stdout should be present
  End
End
