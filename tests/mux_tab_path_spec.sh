# mux-tab-path — the tmux port of zj-hud's render_path_body /
# abbreviated_project_path (src/bar/tabs/mod.rs).
#
# A long cwd in a tab pill is not truncated blindly: the segments ABOVE the
# project root shrink to their initial first, one at a time, so the project
# and what you are doing inside it stay legible. Only when that is not enough
# do the leading segments collapse into a single ellipsis. The root is found
# by walking up for a marker, the same list zj-hud defaults to.
Describe 'mux-tab-path'
  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-tab-path"

  setup() {
    FIX=$(mktemp -d)
    # ~/Projects/apps/zellij/zj-hud is a project (has .git); src/bar/tabs is deep in it
    mkdir -p "$FIX/Projects/apps/zellij/zj-hud/.git"
    mkdir -p "$FIX/Projects/apps/zellij/zj-hud/src/bar/tabs"
    mkdir -p "$FIX/plain/deep/nested/dir"
  }
  cleanup() { rm -rf "$FIX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  path() { HOME="$FIX" zsh "$BIN" "$1" "$2"; }
  # width is part of the contract, and shellspec has no length matcher:
  # print the result and a verdict on the line below it.
  path_fit() {
    local out; out="$(HOME="$FIX" zsh "$BIN" "$1" "$2")"
    print -r -- "$out"
    (( ${#out} <= $2 )) && print -r -- "FITS" || print -r -- "TOO-WIDE(${#out}>$2)"
  }

  It 'leaves a path that fits completely alone'
    When call path "$FIX/Projects" 40
    The output should equal "~/Projects"
    The status should be success
  End

  It 'collapses $HOME to ~'
    When call path "$FIX" 40
    The output should equal "~"
  End

  It 'abbreviates the segments above the project root before touching it'
    # ~/Projects/apps/zellij/zj-hud/src/bar/tabs is 38 wide; at 30 the
    # leading segments shrink but zj-hud and what follows stay whole.
    When call path_fit "$FIX/Projects/apps/zellij/zj-hud/src/bar/tabs" 30
    The output should include "zj-hud/src/bar/tabs"
    The output should include "P…"
    The output should include "FITS"
  End

  It 'collapses the head into one ellipsis when abbreviating is not enough'
    When call path_fit "$FIX/Projects/apps/zellij/zj-hud/src/bar/tabs" 22
    The output should include "…/zj-hud"
    The output should include "FITS"
  End

  It 'falls back to plain truncation with no project root in sight'
    When call path_fit "$FIX/plain/deep/nested/dir" 14
    The output should include "FITS"
    The output should include "…"
  End

  # A dotfile segment keeps two characters, so .config does not become "."
  It 'keeps two characters when abbreviating a dot segment'
    mkdir -p "$FIX/.config/apps/thing/.git" 2>/dev/null
    mkdir -p "$FIX/.config/apps/thing/src/deep"
    When call path_fit "$FIX/.config/apps/thing/src/deep" 24
    The output should include ".c…"
    The output should include "FITS"
  End

  # tmux does not run #() inside window-status-format, so the value is pushed
  # onto the window as @win_path (by the shell's chpwd hook and tmux's
  # pane-focus-in). --stamp is that push.
  Describe '--stamp'
    It 'parks the rendered body on the window option the pill reads'
      stamp() {
        export TMUX_TMPDIR="$FIX/sock"; mkdir -p "$TMUX_TMPDIR"
        tmux -f /dev/null new-session -d -s st -x 80 -y 20 'sh -i' 2>/dev/null
        HOME="$FIX" zsh "$BIN" --stamp "$(tmux display -p '#{window_id}')" \
          "$FIX/Projects/apps/zellij/zj-hud/src/bar"
        tmux show -wv @win_path
        tmux kill-server 2>/dev/null
      }
      When call stamp
      The output should include "zj-hud/src/bar"
      The status should be success
    End

    It 'does nothing outside tmux instead of erroring'
      quiet() { HOME="$FIX" TMUX= zsh "$BIN" --stamp "" "$FIX"; }
      When call quiet
      The status should be success
      The output should equal ""
    End
  End
End