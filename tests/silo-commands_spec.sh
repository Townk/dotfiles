# Tests for the shared /end-work slash command (prompt template).
#
# /end-work is the symmetric end command for every /work-on-<silo>: it loads
# the reconcile skill and lands the work-on-<silo>-<suffix> branch onto
# master. It is a prompt template (so it is /end-work in both pi and Claude
# Code), shared via the same symlink mechanism as the /work-on-* templates:
# one canonical docs/silo-commands/end-work.md symlinked into .pi/prompts/
# and .claude/commands/. This spec pins that sharing contract and that the
# template actually points at the reconcile skill.

Describe 'silo commands — /end-work sharing contract'
  # Resolve a frontmatter field from a markdown file. $1=file $2=field.
  frontmatter_field() {
    awk -v want="$2" '
      /^---$/ { c++; next }
      c == 1 && $0 ~ "^"want":" {
        sub("^"want":[[:space:]]*", "")
        print; exit
      }
      c == 2 { exit }
    ' "$1"
  }

  Describe 'canonical end-work.md template'
    It 'exists at docs/silo-commands/end-work.md'
      When call test -f docs/silo-commands/end-work.md
      The status should be success
    End

    It 'has a description (compatibility subset frontmatter)'
      When call test -n "$(frontmatter_field docs/silo-commands/end-work.md description)"
      The status should be success
    End

    It 'has an argument-hint (compatibility subset frontmatter)'
      When call test -n "$(frontmatter_field docs/silo-commands/end-work.md argument-hint)"
      The status should be success
    End

    It 'interpolates $ARGUMENTS (compatibility subset)'
      When call grep -q '$ARGUMENTS' docs/silo-commands/end-work.md
      The status should be success
    End

    It 'directs the agent to load the reconcile skill'
      When call grep -q 'the `reconcile` skill' docs/silo-commands/end-work.md
      The status should be success
    End

    It 'documents the /skill:reconcile (pi) and /reconcile (Claude Code) invocations'
      When call grep -q '/skill:reconcile' docs/silo-commands/end-work.md
      The status should be success
    End
  End

  Describe 'pi discovery (.pi/prompts/end-work.md)'
    It 'is discoverable by pi'
      When call test -f .pi/prompts/end-work.md
      The status should be success
    End

    It 'is a symlink to the canonical template (single source)'
      When call test -L .pi/prompts/end-work.md
      The status should be success
    End
  End

  Describe 'Claude Code discovery (.claude/commands/end-work.md)'
    It 'is discoverable by Claude Code'
      When call test -f .claude/commands/end-work.md
      The status should be success
    End

    It 'is a symlink to the canonical template (single source)'
      When call test -L .claude/commands/end-work.md
      The status should be success
    End
  End

  Describe 'README documents /end-work'
    It 'the command index lists /end-work'
      When call grep -q '`/end-work`' docs/silo-commands/README.md
      The status should be success
    End

    It 'the end-of-session symmetry section exists'
      When call grep -q 'End-of-session symmetry' docs/silo-commands/README.md
      The status should be success
    End
  End
End
