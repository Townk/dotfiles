# pick::start temp-source cleanup.
#
# A stdin-fed pick::start materializes stdin into $TMPDIR/pick-start.XXXXXX
# and arms an EXIT/INT/TERM trap to remove it. The trap used to dereference
# the LOCAL tmp_source at fire time — but zsh pops a function's locals
# BEFORE running its function-scoped EXIT trap, so the handler saw an empty
# path and every cancelled pick (Esc → pick::run's `exit 130`) leaked one
# temp file. The path must be baked into the trap string at install time.
#
# Both paths run the real pick::start against a stub fzf, in a subshell so
# the cancel path's `exit 130` doesn't kill the spec shell.
Describe 'pick::start — stdin temp-file cleanup'
  pick_harness() {
    zsh -c '
      set -eu
      scratch="$(mktemp -d)" || exit 90
      mkdir -p "$scratch/bin" "$scratch/tmp"
      printf "%s\n" "#!/bin/sh" "$1" > "$scratch/bin/fzf"
      chmod +x "$scratch/bin/fzf"
      export TMPDIR="$scratch/tmp"
      export PATH="$scratch/bin:$PATH"
      ( source home/dot_local/lib/pick-common.zsh
        out="$(print -l one two | pick::start)" ) && rc=0 || rc=$?
      leftover=( "$TMPDIR"/pick-start.*(N) )
      print -r -- "rc=$rc leftover=${#leftover}"
      rm -rf -- "$scratch"
    ' harness "$1"
  }

  It 'removes the temp source when the picker is cancelled (Esc)'
    When call pick_harness 'exit 1'
    The output should equal 'rc=130 leftover=0'
    The status should be success
  End

  It 'removes the temp source on accept'
    # fzf output contract: line 1 query, line 2 expect-key, rest selection.
    When call pick_harness 'cat >/dev/null; printf "\n\none\n"'
    The output should equal 'rc=0 leftover=0'
    The status should be success
  End
End
