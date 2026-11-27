# Tests for home/.chezmoiscripts/run_after_60-rex-main-session.sh — the apply
# step that names Rex's default session "Main".
#
# Rex names the session it creates at first launch itself (wandering-glade),
# and shows the current session's label in the tab bar once there is a second
# session. The step renames the OLDEST session with such a generated-looking
# label to "Main" when no session has that name. It is run for real against a
# stub `rex` that logs its argv and answers `ls --json` from a fixture.
Describe 'Rex Main session hook'
  HOOK="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_after_60-rex-main-session.sh"

  setup() {
    MS_TMP=$(mktemp -d)
    MS_HOME="$MS_TMP/home"
    mkdir -p "$MS_HOME/.config/mux/quick-launch"
    cat >"$MS_TMP/rex" <<EOS
#!/bin/sh
echo "\$*" >>"$MS_TMP/rex.log"
case "\$*" in
  *"ls --json"*) [ "\${STUB_SERVER:-up}" = up ] || exit 4; cat "$MS_TMP/sessions.json" ;;
  *) exit 0 ;;
esac
EOS
    chmod +x "$MS_TMP/rex"
  }
  cleanup() { rm -rf "$MS_TMP"; unset STUB_SERVER; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # sessions <label>... — the fixture, in `rex ls` order; ids are s1, s2, …
  sessions() {
    local n=0 label out=""
    for label in "$@"; do
      n=$((n + 1))
      out="$out${out:+,}{\"session_id\":\"session:s$n\",\"label\":\"$label\"}"
    done
    print -r -- "{\"sessions\":[$out]}" >"$MS_TMP/sessions.json"
  }
  hook() {
    env HOME="$MS_HOME" MUX_REX_BIN="${MS_REX-$MS_TMP/rex}" PATH=/usr/bin:/bin:/opt/homebrew/bin sh "$HOOK"
    print -r -- "rc=$?"
  }
  renames() { grep 'session rename' "$MS_TMP/rex.log" 2>/dev/null || true; }
  calls_without_guard() { grep -v -c -- '--autostart=false' "$MS_TMP/rex.log" 2>/dev/null || true; }

  It 'renames the oldest generated-looking session to Main'
    run() { sessions wandering-glade quiet-river; hook; renames; }
    When call run
    The output should equal "rc=0
--autostart=false session rename session:s1 Main"
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
