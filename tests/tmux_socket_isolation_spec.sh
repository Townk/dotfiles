# Regression guard: the tmux specs start real servers on -L sockets
# (kmspec, uespec, wtspec). Each must set its own TMUX_TMPDIR under
# SHELLSPEC_TMPBASE, so a run never adds an entry to the shared
# /tmp/tmux-$UID, where the user's real server lives. The specs run in a
# nested shellspec, isolated from this run's SHELLSPEC_* environment with
# `env -i`.
Describe 'tmux spec socket isolation'
  RUNNER="$PWD/tests/run-shellspec.sh"
  SOCK_DIR="/tmp/tmux-$(id -u)"

  # A missing directory snapshots as an empty list.
  snapshot() { ls -A "$SOCK_DIR" 2>/dev/null | sort; }
  # The specs render nerd-font glyphs, so the nested run needs a UTF-8 locale.
  inner() {
    (cd "$SHELLSPEC_PROJECT_ROOT" &&
      env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" "$@")
  }

  run_and_diff() {
    before=$(snapshot)
    inner "$RUNNER" tests/tmux_keymap_spec.sh tests/tmux_window_title_spec.sh \
      >/dev/null 2>&1
    rc=$?
    after=$(snapshot)
    echo "status=$rc"
    comm -13 <(print -r -- "$before") <(print -r -- "$after") | sed '/^$/d'
  }

  It 'leaves no new entries in /tmp/tmux-$UID'
    When call run_and_diff
    The output should eq 'status=0'
  End
End
