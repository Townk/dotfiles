# Directory-ring navigation (Shift+arrow widgets, functions.d/widgets.sh).
#
# A back/forward jump onto a ring entry whose directory has since been deleted
# fails the cd — so no chpwd fires, the armed _dir_ring_nav flag survives, and
# the NEXT legitimate cd is swallowed by the hook instead of recorded (and
# _dir_ring_pos is left pointing at the directory that was never reached).
# The widgets run headless here: zle is stubbed, cd/chpwd are the real thing.
Describe 'widgets.sh — dir ring survives a failed jump'
  It 'keeps recording and stays in sync after a back-jump onto a deleted dir'
    When run zsh -c '
      set -u
      zle() { :; }
      widget_lib="$PWD/home/dot_config/zsh/functions.d/widgets.sh"
      base="$(mktemp -d)" || exit 90
      mkdir -p "$base/a" "$base/b" "$base/gone"
      builtin cd -- "$base"
      source "$widget_lib"
      builtin cd -- "$base/gone"
      builtin cd -- "$base/a"
      rmdir -- "$base/gone"
      cd-back                     # target ring entry is gone: must fail cleanly
      builtin cd -- "$base/b"     # must still be recorded
      [[ ${_dir_ring[-1]} == "$base/b" ]]        && print -r -- ok-recorded
      (( _dir_ring_pos == ${#_dir_ring} ))       && print -r -- ok-pos
      cd-back                     # must land on the previous REAL dir: a
      [[ $PWD == "$base/a" ]]                    && print -r -- ok-back
      builtin cd -- /
      rm -rf -- "$base"
    '
    The output should equal 'ok-recorded
ok-pos
ok-back'
    The status should be success
  End
End
