# Tests for home/.chezmoiscripts/run_after_08-ensure-ssh-config-include.sh.tmpl:
# the every-apply self-heal that guarantees ~/.ssh/config carries a TOP-LEVEL
#
#   Match all
#   Include ~/.ssh/config.d/*
#
# The invariant is BOTH lines: an Include nested inside a non-matching `Host`
# block (how work SSH tooling writes its section) is inert, so grepping for the
# Include alone is not enough -- a top-level `Match all` must also be present.
# The template renders to a plain `#!/bin/sh` script with no data dependencies,
# so setup renders it once and each example runs it against an isolated $HOME.
Describe 'ensure-ssh-config-include'
  setup() {
    TEST_TMP=$(mktemp -d "$SHELLSPEC_TMPBASE/ssh-include.XXXXXX")
    export HOME="$TEST_TMP/home"
    mkdir -p "$HOME/.ssh"

    RENDERED="$TEST_TMP/ensure-include.sh"
    chezmoi execute-template \
      < "$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_after_08-ensure-ssh-config-include.sh.tmpl" \
      > "$RENDERED"
    chmod +x "$RENDERED"
    export RENDERED
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'appends the pair when the Include is nested in a Host block and no top-level Match all exists'
    # The bug: the old guard grepped for the Include ANYWHERE and matched this
    # nested (inert) copy, so it never appended a working top-level pair.
    printf 'Host work-jump\n  HostName jump.example.com\n  Include ~/.ssh/config.d/*\n' \
      > "$HOME/.ssh/config"
    When run script "$RENDERED"
    The status should be success
    The stderr should include "added 'Match all + Include"
    # A top-level Match all now precedes a top-level Include.
    The contents of file "$HOME/.ssh/config" should include "$(printf 'Match all\nInclude ~/.ssh/config.d/*')"
  End

  It 'appends the pair when a top-level Include exists but the Match all was dropped'
    printf 'Include ~/.ssh/config.d/*\n' > "$HOME/.ssh/config"
    When run script "$RENDERED"
    The status should be success
    The stderr should include "added 'Match all + Include"
    The contents of file "$HOME/.ssh/config" should include "$(printf 'Match all\nInclude ~/.ssh/config.d/*')"
  End

  It 'is idempotent when both top-level Match all and Include are already present'
    printf 'Match all\nInclude ~/.ssh/config.d/*\n' > "$HOME/.ssh/config"
    When run script "$RENDERED"
    The status should be success
    # The guard skipped: it neither logged the append nor grew the file beyond
    # the single pre-existing pair.
    The stderr should not include "added 'Match all + Include"
    The value "$(grep -c '^Match all$' "$HOME/.ssh/config")" should equal 1
    The value "$(grep -c '^Include ~/.ssh/config.d/\*$' "$HOME/.ssh/config")" should equal 1
  End

  It 'seeds the pair on a machine with no ssh config at all'
    rm -f "$HOME/.ssh/config"
    When run script "$RENDERED"
    The status should be success
    The stderr should include "added 'Match all + Include"
    The contents of file "$HOME/.ssh/config" should include "$(printf 'Match all\nInclude ~/.ssh/config.d/*')"
  End
End
