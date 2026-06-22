# Tests for the shared silo skills (reconcile, validate).
#
# The canonical skill directories live in docs/silo-commands/<name>/SKILL.md
# and are symlinked into both harness skill trees (.pi/skills/<name> and
# .claude/skills/<name>) plus a compat symlink at docs/silo-commands/<name>.md
# so the work-on-*.md templates' `follow docs/silo-commands/<name>.md` refs
# keep resolving. This spec pins that contract.

Describe 'silo skills — reconcile & validate'
  # Resolve a frontmatter field from a SKILL.md. $1=file $2=field.
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

  Describe 'canonical SKILL.md files'
    It 'reconcile/SKILL.md exists and has required frontmatter'
      When call test -f docs/silo-commands/reconcile/SKILL.md
      The status should be success
    End

    It 'validate/SKILL.md exists and has required frontmatter'
      When call test -f docs/silo-commands/validate/SKILL.md
      The status should be success
    End

    It 'reconcile has a name field matching its directory'
      When call test "$(frontmatter_field docs/silo-commands/reconcile/SKILL.md name)" = "reconcile"
      The status should be success
    End

    It 'validate has a name field matching its directory'
      When call test "$(frontmatter_field docs/silo-commands/validate/SKILL.md name)" = "validate"
      The status should be success
    End

    It 'reconcile has a non-empty description under 1024 chars'
      desc=$(frontmatter_field docs/silo-commands/reconcile/SKILL.md description)
      When call test -n "$desc" -a ${#desc} -le 1024
      The status should be success
    End

    It 'validate has a non-empty description under 1024 chars'
      desc=$(frontmatter_field docs/silo-commands/validate/SKILL.md description)
      When call test -n "$desc" -a ${#desc} -le 1024
      The status should be success
    End

    It 'names use only lowercase letters (Agent Skills standard)'
      When call test "$(frontmatter_field docs/silo-commands/reconcile/SKILL.md name)$(frontmatter_field docs/silo-commands/validate/SKILL.md name)" = "reconcilevalidate"
      The status should be success
    End
  End

  Describe 'compat symlinks (preserve docs/silo-commands/<name>.md refs)'
    It 'reconcile.md resolves to the canonical SKILL.md'
      When call test -f docs/silo-commands/reconcile.md
      The status should be success
    End

    It 'validate.md resolves to the canonical SKILL.md'
      When call test -f docs/silo-commands/validate.md
      The status should be success
    End

    It 'reconcile.md is a symlink (not a duplicate real file)'
      When call test -L docs/silo-commands/reconcile.md
      The status should be success
    End

    It 'validate.md is a symlink (not a duplicate real file)'
      When call test -L docs/silo-commands/validate.md
      The status should be success
    End
  End

  Describe 'pi skill discovery (.pi/skills/<name>/SKILL.md)'
    It 'reconcile is discoverable by pi'
      When call test -f .pi/skills/reconcile/SKILL.md
      The status should be success
    End

    It 'validate is discoverable by pi'
      When call test -f .pi/skills/validate/SKILL.md
      The status should be success
    End
  End

  Describe 'Claude Code skill discovery (.claude/skills/<name>/SKILL.md)'
    It 'reconcile is discoverable by Claude Code'
      When call test -f .claude/skills/reconcile/SKILL.md
      The status should be success
    End

    It 'validate is discoverable by Claude Code'
      When call test -f .claude/skills/validate/SKILL.md
      The status should be success
    End
  End

  Describe 'single canonical source — harness skills are symlinks, not copies'
    It '.pi/skills/reconcile is a symlink'
      When call test -L .pi/skills/reconcile
      The status should be success
    End

    It '.claude/skills/validate is a symlink'
      When call test -L .claude/skills/validate
      The status should be success
    End
  End
End
