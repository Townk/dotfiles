# Tests for mux::exec_attach → _mux_zj_exec_attach (mux/zellij.zsh).
#
# C-1 regression fence. The autostart's `idle` arm runs
# `mux::exec_attach Main`, which on zellij must REATTACH the session — and, if
# that attach fails (Main was killed or re-grabbed between the state probe and
# the attach), SELF-HEAL by sweeping the stale record and starting a fresh
# session, rather than letting the failed attach kill the login shell.
#
# The defect: the recovery was written as
#     exec "$bin" attach "$name" || { ...recovery... }
# but `exec` replaces the process image, so the `|| { }` runs ONLY when exec
# itself cannot launch the binary — NEVER when `zellij attach` runs and exits
# non-zero. Since _mux_zj_bin already proved the binary executable, the
# recovery was dead code and a failed attach took the shell down with it.
#
# Testing an exec-ing function: mirror tests/mux_autostart_spec.sh — run the
# verb in a FRESH zsh that sources the bootstrap and lets it exec into a stub
# multiplexer. The stub logs every argv it is called with (so the recovery
# steps can be asserted on) and prints "EXEC: <argv>" for the launch it is
# finally replaced by. $ATTACH_RC controls whether the stubbed `attach`
# succeeds or fails.
Describe 'mux::exec_attach (zellij) — failed-attach recovery'
  setup_all() {
    EA_TMP=$(mktemp -d)
    # Empty config tree: _mux_zj_ensure_plugins looks for
    # $XDG_CONFIG_HOME/zellij/ensure-plugins and no-ops when it is absent, so
    # the stub can never reach the real ~/.config.
    mkdir -p "$EA_TMP/cfg"

    # Stub zellij. Logs each invocation, then:
    #   attach Main                                   -> exit $ATTACH_RC
    #   delete-session Main -f                        -> exit 0 (record sweep)
    #   --session Main --new-session-with-layout ...  -> print EXEC:, exit 0
    cat >"$EA_TMP/zellij" <<'EOS'
#!/usr/bin/env zsh
print -r -- "$*" >>"${0:h}/argv.log"
case "$*" in
  "attach Main")                                 exit "${ATTACH_RC:-0}" ;;
  "delete-session Main -f")                      exit 0 ;;
  "--session Main --new-session-with-layout default")
    print -r -- "EXEC: $*"; exit 0 ;;
esac
print -r -- "EXEC: $*"
EOS
    chmod +x "$EA_TMP/zellij"
  }
  cleanup_all() { [ -n "$EA_TMP" ] && rm -rf "$EA_TMP"; }
  BeforeAll setup_all
  AfterAll cleanup_all

  # run_attach <attach-rc> — source the shim in a fresh zsh and drive the real
  # public verb into the stub. Fresh process because the verb execs and does
  # not return. Prints whatever the stub is exec'd into; leaves the per-call
  # argv in $EA_TMP/argv.log.
  run_attach() {
    rm -f "$EA_TMP/argv.log"
    ATTACH_RC=$1 zsh -c "
      ZELLIJ_BIN=$EA_TMP/zellij
      XDG_CONFIG_HOME=$EA_TMP/cfg
      source $PWD/home/dot_local/lib/mux-bootstrap.zsh
      mux::exec_attach Main zellij
    " 2>&1 | grep '^EXEC:' || :
  }

  It 'sweeps the stale record and starts a fresh session when attach fails'
    When call run_attach 1
    The output should eq 'EXEC: --session Main --new-session-with-layout default'
    The contents of file "$EA_TMP/argv.log" should include 'attach Main'
    The contents of file "$EA_TMP/argv.log" should include 'delete-session Main -f'
    The contents of file "$EA_TMP/argv.log" should include '--session Main --new-session-with-layout default'
  End

  It 'does not sweep or recreate when attach succeeds'
    When call run_attach 0
    The output should equal ''
    The contents of file "$EA_TMP/argv.log" should include 'attach Main'
    The contents of file "$EA_TMP/argv.log" should not include 'delete-session Main -f'
    The contents of file "$EA_TMP/argv.log" should not include '--new-session-with-layout default'
  End
End
