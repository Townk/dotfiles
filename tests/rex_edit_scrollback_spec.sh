# Tests for rex-edit-scrollback — the Rex twin of tmux's copy-mode `V`: the
# pane's scrollback, captured to a temp file and opened in the editor in a new
# tab. Hermetic: `rex` is a stub that logs its argv and plays the capture.
Describe 'rex-edit-scrollback'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_rex-edit-scrollback"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    spec_sandbox; ES_TMP=$SANDBOX
    # Two arms of its own: the capture it plays, and a `window new` that runs
    # what the tab would run, with a fake editor, so the examples see it. The
    # pane's process (cwd: the sandbox), `session.view` and `client ls` are
    # the canned answers, the last two from the fixtures below.
    spec_fake_rex "$ES_TMP" \
      '*" capture "*)' \
      '  [ "${STUB_CAPTURE:-ok}" = fail ] && exit 1' \
      '  printf "%s" "${STUB_TEXT-line one
line two
}" ;;' \
      '*" window new "*)' \
      '  [ "${STUB_WINDOW:-ok}" = ok ] || exit 1' \
      '  while [ "$1" != "--" ]; do shift; done; shift' \
      '  VISUAL= EDITOR="${STUB_EDITOR:-$STUB_DIR/nvim}" "$@" >/dev/null' \
      '  cat "$STUB_DIR/window.json" ;;'
    print -r -- '{"window_id":"window:new","block_ids":["block:new"]}' >"$ES_TMP/window.json"
    print -r -- '{"session_id":"session:s","windows":[]}' >"$ES_TMP/view.json"
    print -r -- '{"clients":[{"client_id":"client:mac","info":{"kind":"app"},"connection_state":"connected","session_ids":["session:s"]}]}' >"$ES_TMP/clients.json"
    # The editors report their argv and the text of the file they were given.
    for ed in nvim nano; do
      spec_stub "$ES_TMP" "$ed" \
        '{ echo "args=$*"; for a; do f=$a; done; echo "text=$(cat "$f" | tr "\n" "|")"; } >"$STUB_DIR/editor.log"'
    done
  }
  # Three stubs per example (rex, nvim, nano): their pooled inodes are
  # exec'd once here, not inside the first examples.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 3'
  BeforeEach 'setup'

  edit() {
    env -u TMUX REX_SESSION=session:s REX_BLOCK="${ES_BLOCK-block:origin}" TMPDIR="$ES_TMP" \
      MUX_REX_BIN="$ES_TMP/rex" MUX_LIB="$LIB" zsh -f "$SCRIPT" 2>"$ES_TMP/err"
    print -r -- "rc=$?"
  }
  leftovers() { ls "$ES_TMP" | grep -c '^rex-scrollback\.' || true; }

  It 'opens the captured scrollback at its end, in a tab named scrollback'
    Skip if 'complete-only: a whole rex-edit-scrollback run: capture, new tab, the editor through a zsh -c, the app told to show it (a dozen processes)' spec_complete_only
    run() { edit; sed -e "s|$ES_TMP/rex-scrollback\.[A-Za-z0-9]*|FILE|" "$ES_TMP/editor.log"; grep -c 'window new -s block:origin --json -c .* scrollback -- ' "$ES_TMP/rex.log"; }
    When call run
    The output should equal "rc=0
args=+\$ FILE
text=line one|line two|
1"
  End

  It 'makes the app show the new tab'
    Skip if 'complete-only: a whole rex-edit-scrollback run: capture, new tab, the editor through a zsh -c, the app told to show it (a dozen processes)' spec_complete_only
    run() { edit >/dev/null; grep -c -- '-C client:mac do -s session:s session.select session_id=session:s window_id=window:new' "$ES_TMP/rex.log"; }
    When call run
    The output should equal "1"
  End

  It 'captures the calling pane whole: trimmed, soft wraps joined, no server started'
    Skip if 'complete-only: a whole rex-edit-scrollback run: capture, new tab, the editor through a zsh -c, the app told to show it (a dozen processes)' spec_complete_only
    run() { edit >/dev/null; grep -c -- '--autostart=false capture -s block:origin -b block:origin --trim --unwrap' "$ES_TMP/rex.log"; grep -c -v -- '--autostart=false' "$ES_TMP/rex.log" || true; }
    When call run
    The output should equal "1
0"
  End

  It 'removes the temp file when the editor exits'
    Skip if 'complete-only: a whole rex-edit-scrollback run: capture, new tab, the editor through a zsh -c, the app told to show it (a dozen processes)' spec_complete_only
    run() { edit >/dev/null; leftovers; }
    When call run
    The output should equal "0"
  End

  It 'gives an editor outside the vi family the file alone'
    Skip if 'complete-only: a whole rex-edit-scrollback run: capture, new tab, the editor through a zsh -c, the app told to show it (a dozen processes)' spec_complete_only
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
