# cagent::validate_plan — the shared AI-commit plan-shape contract.
#
# claude and cursor each carried a byte-identical private `validate_plan`
# enforcing that `.commits` is a non-empty array and every group has a
# non-empty `files` array and a non-empty `message` string. Hoisting it into
# `commit-agent-common.zsh` collapses the two copies (and, in a following
# change, gives the pi worker the predicate it was missing). These specs pin
# the contract so the hoisted function is a faithful replacement.

Describe 'cagent::validate_plan'
  Include home/dot_local/lib/commit-agent-common.zsh

  It 'rejects a group with no message key'
    plan="$SHELLSPEC_TMPBASE/no-message.json"
    printf '%s' '{"commits":[{"files":["a.txt"]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be failure
  End

  It 'rejects a group with an empty message string'
    plan="$SHELLSPEC_TMPBASE/empty-message.json"
    printf '%s' '{"commits":[{"message":"","files":["a.txt"]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be failure
  End

  It 'rejects a group with an empty files array'
    plan="$SHELLSPEC_TMPBASE/no-files.json"
    printf '%s' '{"commits":[{"message":"feat: x","files":[]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be failure
  End

  It 'accepts a well-formed plan'
    plan="$SHELLSPEC_TMPBASE/good.json"
    printf '%s' '{"commits":[{"message":"feat: x","files":["a.txt"]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be success
  End
End
