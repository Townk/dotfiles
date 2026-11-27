# Tests for rex-edit-scrollback — the Rex twin of tmux's copy-mode `V`: the
# pane's scrollback, captured to a temp file and opened in the editor in a new
# tab. Hermetic: `rex` is a stub that logs its argv and plays the capture.
Describe 'rex-edit-scrollback'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_rex-edit-scrollback"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    ES_TMP=$(mktemp -d)
    cat >"$ES_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >>"$ES_TMP/rex.log"
case " \$* " in
  *" capture "*) [ "\${STUB_CAPTURE:-ok}" = fail ] && exit 1; printf '%s' "\${STUB_TEXT-line one
line two
}"; exit 0 ;;
  *" block call "*" process"*) echo '{"foreground":{"cwd":"$ES_TMP","name":"zsh"}}'; exit 0 ;;
  *" window new "*)
    [ "\${STUB_WINDOW:-ok}" = ok ] || exit 1
    # Run what the tab would run, with a fake editor, so the examples see it.
    while [ "\$1" != "--" ]; do shift; done; shift
    VISUAL= EDITOR="\${STUB_EDITOR:-$ES_TMP/nvim}" "\$@"; exit 0 ;;
esac
exit 0
EOS
    chmod +x "$ES_TMP/rex"
    for ed in nvim nano; do
      printf '%s\n' '#!/bin/sh' "{ echo \"args=\$*\"; for a; do f=\$a; done; echo \"text=\$(cat \"\$f\" | tr '\\n' '|')\"; } >\"$ES_TMP/editor.log\"" >"$ES_TMP/$ed"
      chmod +x "$ES_TMP/$ed"
    done
  }
  cleanup() { rm -rf "$ES_TMP"; unset STUB_CAPTURE STUB_TEXT STUB_WINDOW STUB_EDITOR; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  edit() {
    env -u TMUX REX_SESSION=session:s REX_BLOCK="${ES_BLOCK-block:origin}" TMPDIR="$ES_TMP" \
      MUX_REX_BIN="$ES_TMP/rex" MUX_LIB="$LIB" zsh "$SCRIPT" 2>"$ES_TMP/err"
    print -r -- "rc=$?"
  }
  leftovers() { ls "$ES_TMP" | grep -c '^rex-scrollback\.' || true; }

  It 'opens the captured scrollback at its end, in a tab named scrollback'
    run() { edit; sed -e "s|$ES_TMP/rex-scrollback\.[A-Za-z0-9]*|FILE|" "$ES_TMP/editor.log"; grep -c 'window new -s block:origin -c .* scrollback -- ' "$ES_TMP/rex.log"; }
    When call run
    The output should equal "rc=0
args=+\$ FILE
text=line one|line two|
1"
  End

  It 'captures the calling pane whole: trimmed, soft wraps joined, no server started'
    run() { edit >/dev/null; grep -c -- '--autostart=false capture -s block:origin -b block:origin --trim --unwrap' "$ES_TMP/rex.log"; grep -c -v -- '--autostart=false' "$ES_TMP/rex.log" || true; }
    When call run
    The output should equal "1
0"
  End

  It 'removes the temp file when the editor exits'
    run() { edit >/dev/null; leftovers; }
    When call run
    The output should equal "0"
  End

  It 'gives an editor outside the vi family the file alone'
    export STUB_EDITOR="$ES_TMP/nano"
    run() { edit >/dev/null; sed -n 1p "$ES_TMP/editor.log" | sed -e "s|$ES_TMP/rex-scrollback\.[A-Za-z0-9]*|FILE|"; }
    When call run
    The output should equal "args=FILE"
  End

  It 'fails, leaving nothing behind, when the pane cannot be captured'
    export STUB_CAPTURE=fail
    run() { edit; leftovers; grep -c 'window new' "$ES_TMP/rex.log" || true; }
    When call run
    The output should equal "rc=1
0
0"
  End

  It 'fails on an empty capture instead of opening an empty file'
    export STUB_TEXT=""
    run() { edit; leftovers; }
    When call run
    The output should equal "rc=1
0"
  End

  It 'fails, leaving nothing behind, when no tab can be opened'
    export STUB_WINDOW=fail
    run() { edit; leftovers; }
    When call run
    The output should equal "rc=1
0"
  End

  It 'refuses to run outside a Rex pane'
    ES_BLOCK=""
    run() { edit; cat "$ES_TMP/err"; }
    When call run
    The output should include "rc=1"
    The output should include "REX_BLOCK is not set"
  End
End
