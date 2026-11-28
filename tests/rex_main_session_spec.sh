# Tests for home/.chezmoiscripts/run_after_60-rex-main-session.sh.tmpl — the apply
# step that names Rex's default session "Main".
#
# Rex names the session it creates at first launch itself (wandering-glade),
# and shows the current session's label in the tab bar once there is a second
# session. The step renames the OLDEST session with such a generated-looking
# label to "Main" when no session has that name. It is run for real, rendered
# (its "find rex" preamble is the shared .chezmoitemplates/rex-bin.sh.tmpl),
# against a stub `rex` that logs its argv and answers `ls --json` from a
# fixture.
Describe 'Rex Main session hook'
  HOOK_TMPL="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_after_60-rex-main-session.sh.tmpl"

  setup() {
    spec_sandbox; MS_TMP=$SANDBOX
    HOOK="$MS_TMP/hook.sh"
    spec_render_template "$HOOK_TMPL" "$HOOK" 2>"$MS_TMP/render.err"
    MS_HOME="$MS_TMP/home"
    mkdir -p "$MS_HOME/.config/mux/quick-launch"
    # `ls --json` answers from sessions.json, or exits 4 with no server.
    spec_fake_rex "$MS_TMP"
  }
  BeforeEach 'setup'

  # sessions <label>... — the fixture, in `rex ls` order; ids are s1, s2, …
  sessions() {
    local n=0 label out=""
    for label in "$@"; do
      n=$((n + 1))
      out="$out${out:+,}{\"session_id\":\"session:s$n\",\"label\":\"$label\"}"
    done
    print -r -- "{\"sessions\":[$out]}" >"$MS_TMP/sessions.json"
  }
  # sessions_by_id <uuid>=<label>... — the same, with real session ids, in
  # the order given (which is then NOT necessarily creation order).
  sessions_by_id() {
    local pair out=""
    for pair in "$@"; do
      out="$out${out:+,}{\"session_id\":\"session:${pair%%=*}\",\"label\":\"${pair#*=}\"}"
    done
    print -r -- "{\"sessions\":[$out]}" >"$MS_TMP/sessions.json"
  }
  hook() {
    env HOME="$MS_HOME" MUX_REX_BIN="${MS_REX-$MS_TMP/rex}" PATH=/usr/bin:/bin:/opt/homebrew/bin sh "$HOOK"
    print -r -- "rc=$?"
  }
  renames() { grep 'session rename' "$MS_TMP/rex.log" 2>/dev/null || true; }
  calls_without_guard() { grep -v -c -- '--autostart=false' "$MS_TMP/rex.log" 2>/dev/null || true; }

  It 'renders'
    When call cat "$MS_TMP/render.err"
    The output should equal ""
    The contents of file "$HOOK" should include 'rex="${MUX_REX_BIN:-}"'
  End

  It 'renames the oldest generated-looking session to Main'
    run() { sessions wandering-glade quiet-river; hook; renames; }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:s1 Main"
  End

  # "Oldest" must not depend on the order of the listing. A Rex session id is
  # a UUIDv7, whose first 48 bits are the creation time in milliseconds, so
  # the ids sort in creation order as plain text (seen on a live server:
  # session:01a21e20-35a5-7be6-9cd5-bd1c13a944dd, created 2026-11-27).
  OLD_ID=01a21e20-35a5-7be6-9cd5-bd1c13a944dd
  MID_ID=01a21e20-4c11-7a02-8f3e-0d5b7c9e1a24
  NEW_ID=01a21e3b-0001-7c44-b1aa-63f0e2d4c8b6

  It 'renames the oldest generated-looking session whatever the listing order'
    run() { sessions_by_id "$NEW_ID=quiet-river" "$OLD_ID=wandering-glade" "$MID_ID=jumping-yak"; hook; renames; }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:$OLD_ID Main"
  End

  It 'takes the oldest generated-looking one when the oldest session has a chosen name'
    run() { sessions_by_id "$NEW_ID=quiet-river" "$MID_ID=jumping-yak" "$OLD_ID=Work"; hook; renames; }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:$MID_ID Main"
  End

  # Ids of any other shape say nothing about age: the listing order stands.
  It 'keeps the listing order when a session id is not a UUIDv7'
    run() { sessions_by_id "zzzz=quiet-river" "$OLD_ID=wandering-glade"; hook; renames; }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:zzzz Main"
  End

  It 'skips sessions with a chosen name to reach the generated one'
    run() { sessions Work "Kind Triceratops" quiet-river; hook; renames; }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:s3 Main"
  End

  It 'does nothing when a Main session exists'
    run() { sessions wandering-glade Main; hook; renames; }
    When call run
    The output should equal "rc=0"
  End

  # The owner types the name by hand once; however it is capitalised, it is
  # the Main session, and a second one must not appear beside it.
  Describe 'a Main session in another case'
    Parameters
      main
      MAIN
      mAiN
    End
    It "does nothing when a session is called $1"
      run() { sessions wandering-glade "$1"; hook; renames; }
      When call run "$1"
      The output should equal "rc=0"
    End
  End

  It 'still renames when a label only contains the word'
    run() { sessions "main work" Maintenance wandering-glade; hook; renames; }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:s3 Main"
  End

  It 'does nothing when no label looks generated'
    run() { sessions Work Jobs "Kind Triceratops" abc v1-2 Two-Words; hook; renames; }
    When call run
    The output should equal "rc=0"
  End

  # Review focus: a Quick Launch workspace may be named like a generated
  # session. It is the owner's name and must not be renamed.
  It 'does not rename a Quick Launch workspace'
    run() {
      print -r -- 'workspace:' >"$MS_HOME/.config/mux/quick-launch/proj.yaml"
      print -r -- '  session:' >>"$MS_HOME/.config/mux/quick-launch/proj.yaml"
      print -r -- '    name: my-project' >>"$MS_HOME/.config/mux/quick-launch/proj.yaml"
      sessions my-project; hook; renames
    }
    When call run
    The output should equal "rc=0"
  End

  # The shapes a workspace's name takes in the Quick Launch YAML: `name:` may
  # be the first key of a list item, may carry a comment or quotes, and may be
  # absent altogether — the name then defaults to the `id`.
  ql_keeps() {  # ql_keeps <yaml line> — one session my-project, no Main
    print -r -- "$1" >"$MS_HOME/.config/mux/quick-launch/proj.yaml"
    sessions my-project; hook; renames
  }

  It 'does not rename a workspace named in the first key of a list item'
    When call ql_keeps '  - name: my-project'
    The output should equal "rc=0"
  End

  It 'does not rename a workspace whose name line carries a comment'
    When call ql_keeps '    name: my-project   # the firmware tree'
    The output should equal "rc=0"
  End

  It 'does not rename a workspace with a quoted name'
    When call ql_keeps "    name: 'my-project'"
    The output should equal "rc=0"
  End

  It 'does not rename a workspace known only by its id'
    When call ql_keeps '  - id: my-project'
    The output should equal "rc=0"
  End

  It 'reads a Quick Launch fragment in a subdirectory'
    nested() {
      mkdir -p "$MS_HOME/.config/mux/quick-launch/launch.d"
      print -r -- 'id: my-project' >"$MS_HOME/.config/mux/quick-launch/launch.d/p.yaml"
      sessions my-project; hook; renames
    }
    When call nested
    The output should equal "rc=0"
  End

  It 'still renames a generated session beside a Quick Launch workspace'
    run() {
      print -r -- '    name: my-project' >"$MS_HOME/.config/mux/quick-launch/proj.yaml"
      sessions my-project wandering-glade; hook; renames
    }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:s2 Main"
  End

  # Review focus: no server during an apply is the normal case on most runs.
  It 'is a silent no-op with no server'
    run() { sessions wandering-glade; STUB_SERVER=down hook; renames; }
    When call run
    The output should equal "rc=0"
    The stderr should equal ""
  End

  It 'is a silent no-op with no rex binary'
    run() { MS_REX=/nonexistent/rex hook; }
    When call run
    The output should equal "rc=0"
    The stderr should equal ""
  End

  It 'never calls rex without --autostart=false'
    run() { sessions wandering-glade; hook >/dev/null; calls_without_guard; }
    When call run
    The output should equal "0"
  End
End
