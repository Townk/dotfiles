# The Rex app does not follow the server's active window: a tab opened or
# focused from a script stays in the background until the app is told to
# show it. _mux_rx_show_window runs the app's own `session.select`, and the
# verbs that open or focus a tab call it. Hermetic: `rex` is a stub.
Describe 'showing a tab in the Rex app'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    SW_TMP=$(mktemp -d)
    cat >"$SW_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$SW_TMP/rex.log"
case " \$* " in
  *" client ls "*) cat "$SW_TMP/clients.json" ;;
  *" session.view "*) echo '{"session_id":"session:main","windows":[{"window_id":"window:one"},{"window_id":"window:two"}]}' ;;
  *" window new "*) [ "\${STUB_NEW:-ok}" = ok ] || exit 1; echo '{"window_id":"window:new","block_ids":["block:new"]}' ;;
esac
exit 0
EOS
    chmod +x "$SW_TMP/rex"
    cat >"$SW_TMP/clients.json" <<'EOS'
{"clients":[
 {"client_id":"client:mac","info":{"kind":"app"},"connection_state":"connected","session_ids":["session:main","session:jobs"]},
 {"client_id":"client:ipad","info":{"kind":"app"},"connection_state":"connected","session_ids":["session:main"]},
 {"client_id":"client:elsewhere","info":{"kind":"app"},"connection_state":"connected","session_ids":["session:other"]},
 {"client_id":"client:gone","info":{"kind":"app"},"connection_state":"lost","session_ids":["session:main"]},
 {"client_id":"client:cli","info":{"kind":"cli"},"connection_state":"connected"}]}
EOS
    export MUX_REX_BIN="$SW_TMP/rex" REX_SESSION=session:main REX_BLOCK=block:here
    unset TMUX REX_CLIENT STUB_NEW
  }
  cleanup() { rm -rf "$SW_TMP"; unset MUX_REX_BIN REX_SESSION REX_BLOCK REX_CLIENT STUB_NEW; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  selects() { grep 'session.select' "$SW_TMP/rex.log" 2>/dev/null | sed 's/^--autostart=false --timeout 3s //' || true; }

  It 'selects the window on every connected app that has the session open'
    shown() { _mux_rx_show_window session:main window:two; selects; }
    When call shown
    The output should equal "-C client:mac do -s session:main session.select session_id=session:main window_id=window:two
-C client:ipad do -s session:main session.select session_id=session:main window_id=window:two"
  End

  It 'moves only the app that asked when it is known'
    export REX_CLIENT=client:ipad
    shown() { _mux_rx_show_window session:main window:two; selects; }
    When call shown
    The output should equal "-C client:ipad do -s session:main session.select session_id=session:main window_id=window:two"
  End

  It 'never starts a server'
    quiet() { _mux_rx_show_window session:main window:two; grep -c -v -- '--autostart=false' "$SW_TMP/rex.log" || true; }
    When call quiet
    The output should equal "0"
  End

  It 'fails, moving nothing, with no window to show or no app showing the session'
    nothing() {
      _mux_rx_show_window session:main ""; print -r -- "rc=$?"
      print -r -- '{"clients":[]}' >"$SW_TMP/clients.json"
      _mux_rx_show_window session:main window:two; print -r -- "rc=$?"
      selects | wc -l | tr -d ' '
    }
    When call nothing
    The output should equal "rc=1
rc=1
0"
  End

  It 'shows the tab mux::new_tab opens'
    opened() { mux::new_tab --name notes -- /bin/cat; print -r -- "rc=$?"; selects | grep -c 'window_id=window:new'; }
    When call opened
    The output should equal "rc=0
2"
  End

  It 'reports a tab that could not be opened, showing nothing'
    export STUB_NEW=fail
    failed() { mux::new_tab --name notes -- /bin/cat; print -r -- "rc=$?"; selects | wc -l | tr -d ' '; }
    When call failed
    The output should equal "rc=1
0"
  End

  It 'shows the tab mux::focus_tab focuses, by its position'
    focused() { mux::focus_tab 2; selects | grep -c 'window_id=window:two'; }
    When call focused
    The output should equal "2"
  End
End
