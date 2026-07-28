# Tests for mux-open — the script behind "open the thing under the pointer".
#
# Two callers with different knowledge reach it, which is the whole reason its
# argument handling is shaped the way it is:
#
#   * WezTerm's `open-uri` Lua hook, from the GUI, where $TMUX/$ZELLIJ say
#     nothing. It knows the mux CLIENT pid and nothing else, so the script
#     derives backend + session from that process.
#   * tmux's ⌥+click binding, which runs inside the server and already knows
#     both. It CANNOT supply a useful pid — #{pane_pid} is the pane's shell,
#     whose parent is the server rather than a client, and backend_for_pid
#     answers "none" for it (measured). So it passes the pair in the
#     environment and a placeholder pid.
#
# Stubbing note: mux-open exports its own PATH up front (it runs from a GUI
# environment where lsof/file/git may be missing), which overrides anything a
# test exports. Stubs therefore go in $HOME/.local/bin with HOME pointed at a
# scratch dir — that entry is first in the PATH the script sets. Getting this
# wrong does not fail loudly: it silently runs the REAL `open` and launches a
# browser.
Describe 'mux-open'
  setup() {
    MO_TMP=$(mktemp -d)
    MO_SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-open"
    export HOME="$MO_TMP/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/lib"
    # Stub the system opener so a non-file scheme cannot reach a real browser.
    { echo '#!/bin/sh'; echo 'echo "OPEN: $*" >>"'"$MO_TMP"'/opened"'; } >"$HOME/.local/bin/open"
    chmod +x "$HOME/.local/bin/open"
    # Stub shim: records what the dispatch asked for, and makes the pid-probing
    # path distinguishable from the environment path.
    cat >"$HOME/.local/lib/mux.zsh" <<EOS
mux::backend_for_pid() { echo "probed:\$1" >>"$MO_TMP/probed"; print -r -- none }
mux::resolve_session() { print -r -- "" }
mux::new_tab() {
  print -r -- "NEW_TAB: \$*" >>"$MO_TMP/tabs"
  print -r -- "\$PATH" >>"$MO_TMP/path"
}
EOS
  }
  cleanup() { [ -n "$MO_TMP" ] && rm -rf "$MO_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  opened() { cat "$MO_TMP/opened" 2>/dev/null; }
  tabs()   { cat "$MO_TMP/tabs" 2>/dev/null; }
  probed() { cat "$MO_TMP/probed" 2>/dev/null; }
  path_seen() { cat "$MO_TMP/path" 2>/dev/null; }
  path_first() { cut -d: -f1 "$MO_TMP/path" 2>/dev/null; }

  Describe 'scheme dispatch'
    # Once Ghostty's own link handling is off (mouse-shift-capture = always),
    # this is the ONLY thing that will open an http link there — so a non-file
    # scheme must reach the system opener rather than being dropped.
    It 'hands http(s) to the system opener'
      When run zsh "$MO_SCRIPT" 0 "https://example.com/x"
      The result of function opened should include "OPEN: -- https://example.com/x"
      The status should be success
    End

    It 'hands any other scheme to the system opener too'
      When run zsh "$MO_SCRIPT" 0 "mailto:someone@example.com"
      The result of function opened should include "OPEN: -- mailto:someone@example.com"
    End

    # Bare text under the pointer is not a link. Silently ignored, and in
    # particular NOT handed to `open`.
    It 'ignores something that is not a URI at all'
      When run zsh "$MO_SCRIPT" 0 "just-some-text"
      The status should be success
      The result of function opened should not include "OPEN:"
    End

    It 'ignores a file:// link whose target does not exist'
      When run zsh "$MO_SCRIPT" 0 "file://$MO_TMP/nope"
      The status should be success
      The result of function opened should not include "OPEN:"
    End
  End

  Describe 'argument contract'
    It 'reports usage when called with nothing'
      When run zsh "$MO_SCRIPT"
      The status should equal 2
      The stderr should include "usage: mux-open"
      The stderr should include "MUX_BACKEND"
    End
  End

  Describe 'backend/session resolution'
    # The tmux ⌥+click path: both known up front, pid meaningless.
    It 'trusts MUX_BACKEND/MUX_SESSION and never probes the pid'
      export MUX_BACKEND=tmux MUX_SESSION=Main
      mkdir -p "$MO_TMP/adir"
      When run zsh "$MO_SCRIPT" 0 "file://$MO_TMP/adir"
      The result of function tabs should include "--session Main"
      The result of function tabs should include "yazi"
      # The probe is what would have answered "none" and aborted the open.
      The result of function probed should not include "probed:"
    End

    # The WezTerm path is unchanged: no environment, so derive from the pid —
    # and a pid that resolves to no mux is a no-op rather than a wrong guess.
    It 'falls back to probing the pid when the environment says nothing'
      mkdir -p "$MO_TMP/adir"
      When run zsh "$MO_SCRIPT" 4242 "file://$MO_TMP/adir"
      The result of function probed should include "probed:4242"
      The status should be success
      The result of function tabs should not include "NEW_TAB"
    End

    # Half a pair is not an answer — a session with no backend must not be
    # taken as permission to skip the probe.
    It 'still probes when only one of the two is set'
      export MUX_SESSION=Main
      mkdir -p "$MO_TMP/adir"
      When run zsh "$MO_SCRIPT" 77 "file://$MO_TMP/adir"
      The result of function probed should include "probed:77"
    End

    It 'keeps tool-manager paths supplied by the caller'
      export MUX_BACKEND=tmux MUX_SESSION=Main
      export PATH="$MO_TMP/tool-shims:$PATH"
      mkdir -p "$MO_TMP/adir"
      When run zsh "$MO_SCRIPT" 0 "file://$MO_TMP/adir"
      The result of function path_seen should include "$MO_TMP/tool-shims"
      The result of function path_first should equal "$HOME/.local/share/mise/shims"
      The status should be success
    End
  End
End
