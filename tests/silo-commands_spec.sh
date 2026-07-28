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

  # The cross-silo DISPATCHER. `/work-on <a>+<b> <task>` is the entry point
  # for a feature whose substance is the seam between silos; the procedure
  # itself lives in the cross-silo skill, the same way every per-silo template
  # delegates validate/reconcile rather than inlining them.
  #
  # Note the filename: `work-on.md`, no suffix. It escapes a `work-on-*.md`
  # glob, so anything asserting "every template does X" has to be written
  # `work-on*.md` (see silo-skills_spec) or this file silently opts out.
  Describe 'cross-silo dispatcher (/work-on)'
    src() { cat docs/silo-commands/work-on.md; }

    It 'exists at docs/silo-commands/work-on.md'
      When call test -f docs/silo-commands/work-on.md
      The status should be success
    End

    It 'has frontmatter naming the plus-joined argument shape'
      When call test -n "$(frontmatter_field docs/silo-commands/work-on.md argument-hint)"
      The status should be success
    End

    It 'interpolates $ARGUMENTS'
      When call grep -q '$ARGUMENTS' docs/silo-commands/work-on.md
      The status should be success
    End

    # Silo names are ordinary English words (theme, pick, preview, shell, pi,
    # cursor, utils, secrets), so a space-separated set cannot be told from
    # the start of a task description. The `+` is what removes the guess —
    # and it matches the branch name the skill generates.
    It 'takes the silo set as ONE plus-joined token'
      When call src
      # single quotes: backticks in a double-quoted assertion are a command
      # substitution, and the shell runs `+` before the matcher ever sees it
      The output should include '`+`-joined'
      The output should include "cannot be told from"
    End

    It 'echoes the parse back before acting on it'
      When call src
      The output should include "Say what you parsed before doing anything"
    End

    It 'delegates the procedure to the cross-silo skill'
      When call src
      The output should include "cross-silo"
      The output should include "/skill:cross-silo"
    End

    # A single name is better served by the per-silo template, which carries
    # the owner area and contracts INLINE — something a parameterized command
    # cannot do for 210 pairs.
    It 'redirects a single-silo invocation to the specific command'
      When call src
      The output should include "Only one name"
    End

    It 'sends the agent to read each silos map section, since it cannot inline them'
      When call src
      The output should include "chezmoi-silo-map.md"
      The output should include "they are not in this file"
    End

    It 'stops on an unknown silo name rather than claiming nothing'
      When call src
      The output should include "Unknown name"
    End
  End

  Describe 'cross-silo dispatcher discovery'
    It 'is discoverable by pi as a symlink'
      When call test -L .pi/prompts/work-on.md
      The status should be success
    End

    It 'is discoverable by Claude Code as a symlink'
      When call test -L .claude/commands/work-on.md
      The status should be success
    End
  End

End
