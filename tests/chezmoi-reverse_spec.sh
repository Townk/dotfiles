# Tests for home/dot_local/bin/executable_chezmoi-reverse: propagate edits made
# to a chezmoi-managed destination back into its source. Runs the script as a
# subprocess against an isolated $HOME with a stub merge tool.
Describe 'chezmoi-reverse'
  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME CHEZMOI_CONFIG_FILE CHEZMOI_SOURCE_DIR CHEZMOI_HOME_DIR
    mkdir -p "$HOME" "$HOME/.config/chezmoi" "$TEST_TMP/src"

    # Stub merge tool that records its arguments to a sentinel file.
    {
      echo '#!/usr/bin/env bash'
      echo 'printf "%s\n" "$@" > "'"$TEST_TMP"'/merge-invoked"'
    } > "$TEST_TMP/stub-merge"
    chmod +x "$TEST_TMP/stub-merge"

    # chezmoi config: source dir, merge stub, a data value for templates.
    {
      echo "sourceDir = \"$TEST_TMP/src\""
      echo ''
      echo '[merge]'
      echo "  command = \"$TEST_TMP/stub-merge\""
      echo '  args = ["{{ .Destination }}", "{{ .Source }}", "{{ .Target }}"]'
      echo ''
      echo '[data]'
      echo '  role = "engineer"'
    } > "$HOME/.config/chezmoi/chezmoi.toml"

    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_chezmoi-reverse"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'usage: no args exits 2 with usage on stderr'
    When run script "$SCRIPT"
    The status should eq 2
    The stderr should include "usage: chezmoi-reverse"
  End

  It 'clean: unchanged destination reports clean and exits 0'
    printf 'name = thiago\n' > "$TEST_TMP/src/dot_foo.tmpl"
    chezmoi apply
    When run script "$SCRIPT" "$HOME/.foo"
    The status should be success
    The output should include "clean"
    The output should include ".foo"
  End

  It 'applied: a change to a literal line is patched into the template'
    # The literal line sits clear (>3 lines) of the `{{ .role }}` directive, so
    # the -U3 context is all literal text that matches the source verbatim and
    # the hunk patches cleanly. (An edit within three lines of a directive whose
    # render differs from its source form instead defers to merge — see the
    # 'merged' example below.)
    printf 'name = thiago\nline a\nline b\nline c\nline d\nrole = {{ .role }}\n' > "$TEST_TMP/src/dot_foo.tmpl"
    chezmoi apply
    sed -i.bak 's/^name = thiago$/name = alice/' "$HOME/.foo"; rm "$HOME/.foo.bak"
    When run script "$SCRIPT" "$HOME/.foo"
    The status should be success
    The output should include "applied"
    The contents of file "$TEST_TMP/src/dot_foo.tmpl" should include "name = alice"
    The contents of file "$TEST_TMP/src/dot_foo.tmpl" should include "role = {{ .role }}"
    The path "$TEST_TMP/merge-invoked" should not be exist
  End

  It 'applied: an inserted line lands on the correct source line despite a template guard shifting line numbers'
    # `{{ if true -}}` trims its trailing newline, so the rendered body sits one
    # line ABOVE the same content in the source. An insertion-only hunk carries
    # no context under diff -U0, so patch applies it at the rendered line number
    # — the WRONG source line — and still exits 0 with no .rej. diff -U3 anchors
    # the hunk on surrounding content so it lands where it belongs.
    printf '{{ if true -}}\nalpha\nbeta\ngamma\ndelta\n{{- end }}\n' > "$TEST_TMP/src/dot_foo.tmpl"
    chezmoi apply
    awk '{ print } /^beta$/ { print "INSERTED" }' "$HOME/.foo" > "$HOME/.foo.new"
    mv "$HOME/.foo.new" "$HOME/.foo"
    When run script "$SCRIPT" "$HOME/.foo"
    The status should be success
    The output should include "applied"
    The line 3 of contents of file "$TEST_TMP/src/dot_foo.tmpl" should equal "beta"
    The line 4 of contents of file "$TEST_TMP/src/dot_foo.tmpl" should equal "INSERTED"
    The path "$TEST_TMP/src/dot_foo.tmpl.rej" should not be exist
    The path "$TEST_TMP/merge-invoked" should not be exist
  End

  It 'merged: a change to a templated line restores the template and invokes merge'
    printf 'name = thiago\nrole = {{ .role }}\n' > "$TEST_TMP/src/dot_foo.tmpl"
    chezmoi apply
    sed -i.bak 's/^role = engineer$/role = manager/' "$HOME/.foo"; rm "$HOME/.foo.bak"
    When run script "$SCRIPT" "$HOME/.foo"
    The status should be success
    The output should include "merged"
    The path "$TEST_TMP/merge-invoked" should be exist
    The contents of file "$TEST_TMP/src/dot_foo.tmpl" should include "role = {{ .role }}"
    The contents of file "$TEST_TMP/src/dot_foo.tmpl" should not include "manager"
    The path "$TEST_TMP/src/dot_foo.tmpl.rej" should not be exist
    The path "$TEST_TMP/src/dot_foo.tmpl.orig" should not be exist
    The path "$TEST_TMP/src/dot_foo.tmpl.bak" should not be exist
  End

  It 'applied: a non-template file is re-added via chezmoi re-add'
    printf 'literal one\nliteral two\n' > "$TEST_TMP/src/dot_bar"
    chezmoi apply
    printf 'literal one\nliteral CHANGED\n' > "$HOME/.bar"
    When run script "$SCRIPT" "$HOME/.bar"
    The status should be success
    The output should include "applied"
    The contents of file "$TEST_TMP/src/dot_bar" should include "literal CHANGED"
    The path "$TEST_TMP/merge-invoked" should not be exist
  End

  It 'multi: clean + applied across two files exits 0 with both statuses'
    printf 'unchanged\n' > "$TEST_TMP/src/dot_a.tmpl"
    printf 'before\n'    > "$TEST_TMP/src/dot_b.tmpl"
    chezmoi apply
    printf 'after\n' > "$HOME/.b"
    When run script "$SCRIPT" "$HOME/.a" "$HOME/.b"
    The status should be success
    The output should include "clean"
    The output should include "applied"
    The output should include ".a"
    The output should include ".b"
  End

  It 'clean: an unchanged non-template destination reports clean'
    printf 'literal one\nliteral two\n' > "$TEST_TMP/src/dot_baz"
    chezmoi apply
    When run script "$SCRIPT" "$HOME/.baz"
    The status should be success
    The output should include ".baz"
    The output should include "clean"
  End

  It 'multi: an unmanaged file causes non-zero exit but other files still process'
    printf 'x\n' > "$TEST_TMP/src/dot_a.tmpl"
    chezmoi apply
    When run script "$SCRIPT" "$HOME/does-not-exist" "$HOME/.a"
    The status should not be success
    The output should include "failed"
    The output should include "clean"
    The stderr should not be blank
  End

  It 'needs-merge: --no-merge skips the merge tool and reports needs-merge'
    printf 'name = thiago\nrole = {{ .role }}\n' > "$TEST_TMP/src/dot_foo.tmpl"
    chezmoi apply
    sed -i.bak 's/^role = engineer$/role = manager/' "$HOME/.foo"; rm "$HOME/.foo.bak"
    When run script "$SCRIPT" --no-merge "$HOME/.foo"
    The status should not be success
    The output should include "needs-merge"
    The path "$TEST_TMP/merge-invoked" should not be exist
    The contents of file "$TEST_TMP/src/dot_foo.tmpl" should include "role = {{ .role }}"
    The contents of file "$TEST_TMP/src/dot_foo.tmpl" should not include "manager"
  End

  It 'usage: an unknown flag exits 2'
    When run script "$SCRIPT" --bogus "$HOME/.foo"
    The status should eq 2
    The stderr should not be blank
  End

  It 'skipped: a symlink template is skipped without touching the source'
    printf '/tmp/some-target\n' > "$TEST_TMP/src/symlink_dot_mylink"
    chezmoi apply
    When run script "$SCRIPT" "$HOME/.mylink"
    The status should not be success
    The output should include "skipped"
    The output should include ".mylink"
    The contents of file "$TEST_TMP/src/symlink_dot_mylink" should include "/tmp/some-target"
  End
End
