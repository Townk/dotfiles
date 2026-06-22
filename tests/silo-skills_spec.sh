# Tests for the shared silo skills (reconcile, validate).
#
# The canonical skill directories live in docs/silo-commands/<name>/SKILL.md
# and are symlinked into both harness skill trees (.pi/skills/<name> and
# .claude/skills/<name>). The work-on-<silo>.md templates direct agents to
# LOAD these skills (not read a bare markdown path), so this spec pins both
# the skill structure and that the templates reference the skills by name.

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

  Describe 'templates direct agents to the skills, not bare markdown paths'
    # Every work-on-<silo>.md Validate & integrate block must reference the
    # `validate` skill by name and direct the agent to STOP without
    # integrating (pointing at /end-work, not at the reconcile skill as the
    # integration step). It must NOT carry the dead docs/silo-commands/<name>.md
    # path (those compat symlinks were removed once the templates were
    # rewired to load the skills).
    #
    # `grep -ql` over many files returns success if ANY file matches, so to
    # assert "every template references X" we count the files that match and
    # compare against the total count.
    n_templates=$(ls docs/silo-commands/work-on-*.md | wc -l | tr -d ' ')
    n_validate=$(grep -l 'the `validate` skill' docs/silo-commands/work-on-*.md | wc -l | tr -d ' ')
    n_endwork=$(grep -l '`/end-work`' docs/silo-commands/work-on-*.md | wc -l | tr -d ' ')
    n_stop=$(grep -l 'Stop here — do not integrate' docs/silo-commands/work-on-*.md | wc -l | tr -d ' ')
    # The old auto-integrate bullet must be gone from every template.
    n_oldint=$(grep -l 'Integrate (non-UX work):' docs/silo-commands/work-on-*.md | wc -l | tr -d ' ')

    It 'every template references the validate skill'
      When call test "$n_validate" -eq "$n_templates"
      The status should be success
    End

    It 'every template points the human at /end-work to close the session'
      When call test "$n_endwork" -eq "$n_templates"
      The status should be success
    End

    It 'every template tells the agent to stop without integrating'
      When call test "$n_stop" -eq "$n_templates"
      The status should be success
    End

    It 'no template carries the old auto-integrate bullet'
      When call test "$n_oldint" -eq 0
      The status should be success
    End

    It 'no template references the removed validate.md path'
      n=$(grep -l 'docs/silo-commands/validate\.md' docs/silo-commands/work-on-*.md | wc -l | tr -d ' ')
      When call test "$n" -eq 0
      The status should be success
    End

    It 'no template references the removed reconcile.md path'
      n=$(grep -l 'docs/silo-commands/reconcile\.md' docs/silo-commands/work-on-*.md | wc -l | tr -d ' ')
      When call test "$n" -eq 0
      The status should be success
    End
  End

  Describe 'no dead compat symlinks left behind'
    It 'docs/silo-commands/reconcile.md does not exist'
      When call test ! -e docs/silo-commands/reconcile.md
      The status should be success
    End

    It 'docs/silo-commands/validate.md does not exist'
      When call test ! -e docs/silo-commands/validate.md
      The status should be success
    End
  End
End
