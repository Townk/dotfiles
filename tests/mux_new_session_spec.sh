# mux-new-session — the session mode's `s`.
#
# The bind used to be a bare `new-session`, which works from a key table and
# does the wrong thing from the which-key panel: the panel is a POPUP and
# dispatches with `tmux source-file` from inside it, so the attaching
# new-session took the popup's pty and drew the new session in the panel.
# Detached-then-switch is the fix, and `-d` is what these fence.
Describe 'mux-new-session'
  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-new-session"

  setup() {
    NS_TMP=$(mktemp -d)
    STUB="$NS_TMP/tmux"
    { print '#!/bin/sh'; print 'echo "$*" >> '"$NS_TMP/calls"; } > "$STUB"
    GEN="$NS_TMP/random-name"
    { print '#!/bin/sh'; print 'echo lucky-lemur'; } > "$GEN"
    chmod +x "$STUB" "$GEN"
  }
  cleanup() { rm -rf "$NS_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # ns <command> [client] [cwd] -> the logged call to that tmux command
  ns() {
    MUX_TMUX_BIN="$STUB" MUX_RANDOM_NAME_BIN="$GEN" \
      zsh "$BIN" "${2-}" "${3-}" >/dev/null 2>&1
    grep "^$1" "$NS_TMP/calls"
  }

  It 'creates the session detached, under a name of its own'
    # The name is generated rather than left to tmux for the after-new-session
    # hook's sake: it renames numeric names the moment they appear, so a name
    # captured from the creation could be stale by the time we switch to it.
    When call ns new-session /dev/ttys9 /work/dir
    The output should eq "new-session -d -s lucky-lemur -c /work/dir"
  End

  It 'switches the client it was handed, not whichever one tmux picks'
    # run-shell has no client of its own; with a second terminal attached an
    # untargeted switch-client is free to move that one instead.
    When call ns switch-client /dev/ttys9 /work/dir
    The output should eq "switch-client -c /dev/ttys9 -t lucky-lemur"
  End

  It 'leaves the start directory to tmux when the pane path came back empty'
    When call ns new-session /dev/ttys9 ""
    The output should eq "new-session -d -s lucky-lemur"
  End

  It 'falls back to the current client when no tty was passed'
    When call ns switch-client "" ""
    The output should eq "switch-client -t lucky-lemur"
  End
End
