# Tests for run_onchange_after_61-rex-settings: on apply, the `settings_apply`
# action is run on every connected local Mac app — never starting a server,
# never failing the apply. Rendered and run for real against a stub `rex`.
Describe 'Rex settings hook'
  HOOK="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_61-rex-settings.sh.tmpl"

  setup() {
    SH_TMP=$(mktemp -d)
    chezmoi -S "$SHELLSPEC_PROJECT_ROOT" execute-template <"$HOOK" >"$SH_TMP/hook.sh" 2>"$SH_TMP/render.err"
    cat >"$SH_TMP/rex" <<EOS
#!/bin/sh
echo "\$*" >>"$SH_TMP/rex.log"
case "\$*" in
  *"client ls"*) [ "\${STUB_SERVER:-up}" = up ] || exit 4; cat "$SH_TMP/clients.json" ;;
  *settings_apply*) [ "\${STUB_DO:-ok}" = ok ] ;;
esac
EOS
    chmod +x "$SH_TMP/rex"
    cat >"$SH_TMP/clients.json" <<'EOS'
{"clients":[
 {"client_id":"client:mac","info":{"kind":"app","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"connected","session_ids":["session:a","session:b"]},
 {"client_id":"client:ipad","info":{"kind":"app","platform":"ios"},"principal":{"transport":"tailscale"},"connection_state":"connected","session_ids":["session:a"]},
 {"client_id":"client:remote-mac","info":{"kind":"app","platform":"macos"},"principal":{"transport":"tailscale"},"connection_state":"connected","session_ids":["session:a"]},
 {"client_id":"client:gone","info":{"kind":"app","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"lost","session_ids":["session:a"]},
 {"client_id":"client:idle","info":{"kind":"app","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"connected"},
 {"client_id":"client:cli","info":{"kind":"cli","platform":"macos"},"principal":{"transport":"unix"},"connection_state":"connected"}]}
EOS
  }
  cleanup() { rm -rf "$SH_TMP"; unset STUB_SERVER STUB_DO; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  hook() { env HOME="$SH_TMP/home" MUX_REX_BIN="${1-$SH_TMP/rex}" sh "$SH_TMP/hook.sh"; print -r -- "rc=$?"; }
  calls() { cat "$SH_TMP/rex.log" 2>/dev/null || true; }

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
