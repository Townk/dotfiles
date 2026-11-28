# Tests for run_onchange_after_61-rex-settings: on apply, the `settings_apply`
# action is run on every connected local Mac app — never starting a server,
# never failing the apply. Rendered and run for real against a stub `rex`.
Describe 'Rex settings hook'
  HOOK="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_61-rex-settings.sh.tmpl"

  # The template and the client list have no per-example input: rendered and
  # read once for the file (the hook hard-linked into each sandbox). The
  # fake rex an example writes runs from a pooled inode, exec'd once here.
  Include tests/exec_warm_helper.sh
  once() {
    SH_FIX="$SHELLSPEC_TMPBASE/sh-fix"; mkdir -p "$SH_FIX"
    spec_render_template "$HOOK" "$SH_FIX/hook.sh" 2>"$SH_FIX/render.err"
    SH_RENDER_ERR=$(<"$SH_FIX/render.err")
    cat >"$SH_FIX/clients.json" <<'EOS'
{"clients":[
 {"client_id":"client:mac","info":{"kind":"app","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"connected","session_ids":["session:a","session:b"]},
 {"client_id":"client:ipad","info":{"kind":"app","platform":"ios"},"principal":{"transport":"tailscale"},"connection_state":"connected","session_ids":["session:a"]},
 {"client_id":"client:remote-mac","info":{"kind":"app","platform":"macos"},"principal":{"transport":"tailscale"},"connection_state":"connected","session_ids":["session:a"]},
 {"client_id":"client:gone","info":{"kind":"app","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"lost","session_ids":["session:a"]},
 {"client_id":"client:idle","info":{"kind":"app","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"connected"},
 {"client_id":"client:cli","info":{"kind":"cli","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"connected"}]}
EOS
    SH_CLIENTS=$(<"$SH_FIX/clients.json")
    spec_exec_pool_warm 1
  }
  BeforeAll 'once'
  setup() {
    spec_sandbox; SH_TMP=$SANDBOX
    ln "$SH_FIX/hook.sh" "$SH_TMP/hook.sh"
    # A copy, not a link: examples replace the client list in place.
    print -r -- "$SH_CLIENTS" >"$SH_TMP/clients.json"
    print -rn -- "$SH_RENDER_ERR" >"$SH_TMP/render.err"
    # `client ls` answers from clients.json, or exits 4 with no server.
    spec_fake_rex "$SH_TMP" '*settings_apply*) [ "${STUB_DO:-ok}" = ok ] ;;'
  }
  BeforeEach 'setup'

  hook() { env HOME="$SH_TMP/home" MUX_REX_BIN="${1-$SH_TMP/rex}" sh "$SH_TMP/hook.sh"; print -r -- "rc=$?"; }
  calls() { spec_stub_calls "$SH_TMP" rex; }

  It 'renders'
    When call cat "$SH_TMP/render.err"
    The output should equal ""
  End

  It 'runs settings_apply on the local Mac app only, in a session it shows'
    run() { hook; calls | grep settings_apply; }
    When call run
    The output should equal "🎛️  Applied the Rex app settings.
rc=0
--autostart=false -C client:mac do -s session:a settings_apply"
  End

  It 'never calls rex without --autostart=false'
    run() { hook >/dev/null; calls | grep -c -v -- '--autostart=false' || true; }
    When call run
    The output should equal "0"
  End

  It 'is a silent no-op with no server'
    export STUB_SERVER=down
    When call hook
    The output should equal "rc=0"
  End

  It 'is a silent no-op on a machine without rex'
    When call hook "$SH_TMP/no-such-rex"
    The output should equal "rc=0"
  End

  It 'is a silent no-op when no local app is connected'
    print -r -- '{"clients":[{"client_id":"client:cli","info":{"kind":"cli"},"principal":{"transport":"unix"},"connection_state":"connected"}]}' >"$SH_TMP/clients.json"
    run() { hook; calls | grep -c settings_apply || true; }
    When call run
    The output should equal "rc=0
0"
  End

  It 'says how to apply by hand when the app refuses, without failing the apply'
    export STUB_DO=refused
    When call hook
    The output should equal "rc=0"
    The error should include "Apply Settings from Dotfiles"
  End

  It 'runs again when the settings list changes'
    hashed() { grep -c -E '^# settings: [0-9a-f]{64}$' "$SH_TMP/hook.sh"; }
    When call hashed
    The output should equal "1"
  End
End
