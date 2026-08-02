# quick-launch: the `menu` dispatcher forwards --no-border to the picker on the
# command line (shared-lib Wave 2, group C5, Decision 1).
#
# quick-launch-pick already accepts --no-border and forwards it into its
# pick::start args; the missing half was the dispatcher, which used to rely on
# the QUICK_LAUNCH_NO_BORDER env var leaking through. With all four zellij
# picker adapters moving to the --no-border flag form, `quick-launch` must
# accept the flag (the adapter execs `quick-launch --no-border menu <kind>`)
# and pass it through to quick-launch-pick.
#
# Harness: copy the real dispatcher into a temp dir beside a FAKE
# quick-launch-pick that records its argv, with lib/ symlinked back to the real
# libraries. Running the copy makes ${0:A:h} resolve to the temp dir, so
# ql_menu execs the fake sibling — letting us assert exactly what argv the
# dispatcher hands the picker.
Describe 'quick-launch menu: --no-border forwarding'
  REAL_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts"

  setup() {
    QLM_TMP=$(mktemp -d)
    export REC="$QLM_TMP/pick-argv.txt"; rm -f "$REC"
    export QUICK_LAUNCH_DIR="$QLM_TMP/cfg"
    export XDG_CACHE_HOME="$QLM_TMP/cache"
    mkdir -p "$QUICK_LAUNCH_DIR" "$XDG_CACHE_HOME/quick-launch"
    cat > "$QUICK_LAUNCH_DIR/default.yaml" <<'YAML'
panes:
  - id: shell
    action:
      type: Shell
workspaces:
  - id: default
    name: Main
YAML

    # A runnable copy of the dispatcher next to a fake picker + a symlinked lib/.
    cp "$REAL_DIR/executable_quick-launch" "$QLM_TMP/quick-launch"
    chmod +x "$QLM_TMP/quick-launch"
    ln -s "$REAL_DIR/lib" "$QLM_TMP/lib"
    cat > "$QLM_TMP/quick-launch-pick" <<'ZSH'
#!/usr/bin/env zsh
# Record the exact argv the dispatcher forwarded, then cancel (exit 130) so the
# dispatcher takes its no-op path instead of trying to dispatch a target.
print -r -- "PICKARGV: $*" > "$REC"
exit 130
ZSH
    chmod +x "$QLM_TMP/quick-launch-pick"
  }
  cleanup() { rm -rf "$QLM_TMP"; unset REC QUICK_LAUNCH_DIR XDG_CACHE_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'forwards --no-border to the picker when passed before the subcommand'
    # This is the adapter's own form: `quick-launch --no-border menu <kind>`.
    When run zsh "$QLM_TMP/quick-launch" --no-border menu pane
    The status should be success
    The contents of file "$REC" should include "PICKARGV: pane --no-border"
  End

  It 'forwards --no-border when passed after the kind'
    When run zsh "$QLM_TMP/quick-launch" menu pane --no-border
    The status should be success
    The contents of file "$REC" should include "PICKARGV: pane --no-border"
  End

  It 'passes no border flag to the picker when --no-border is absent'
    When run zsh "$QLM_TMP/quick-launch" menu pane
    The status should be success
    The contents of file "$REC" should equal "PICKARGV: pane"
  End
End
