# Tests for harness-neutral skills deployed to Cursor, Pi, and Claude Code.

Describe 'shared agent skills'
  frontmatter_name() {
    awk '
      /^---$/ { section++; next }
      section == 1 && /^name:/ {
        sub(/^name:[[:space:]]*/, "")
        print
        exit
      }
    ' "$1"
  }

  canonical_definitions_are_valid() {
    for skill in code-commit code-review code-simplifier confluence-acli handoff jira-acli; do
      file="home/dot_config/agent-skills/$skill/SKILL.md"
      test -f "$file" || return 1
      test "$(frontmatter_name "$file")" = "$skill" || return 1
    done
  }

  harness_adapters_are_valid() {
    for root in dot_cursor/skills dot_pi/agent/skills dot_claude/skills; do
      for skill in code-commit code-review code-simplifier confluence-acli handoff jira-acli; do
        adapter="home/$root/$skill/symlink_SKILL.md.tmpl"
        expected='{{ .chezmoi.homeDir }}/.config/agent-skills/'"$skill"'/SKILL.md'
        test -f "$adapter" || return 1
        test "$(cat "$adapter")" = "$expected" || return 1
      done
    done
  }

  Describe 'canonical definitions'
    It 'has one canonical SKILL.md per shared skill with matching names'
      When call canonical_definitions_are_valid
      The status should be success
    End

    It 'portable skills do not pin a harness model'
      When call grep -R -q '^model:' home/dot_config/agent-skills
      The status should be failure
    End
  End

  Describe 'harness adapters'
    It 'exposes every shared skill through each harness symlink template'
      When call harness_adapters_are_valid
      The status should be success
    End
  End

  Describe 'review delegation'
    It 'the shared code-review skill delegates to reviewer'
      When call grep -q 'dedicated `reviewer` subagent' home/dot_config/agent-skills/code-review/SKILL.md
      The status should be success
    End

    It 'Claude Code has a reviewer adapter'
      When call test "$(frontmatter_name home/dot_claude/agents/reviewer.md)" = reviewer
      The status should be success
    End
  End

  Describe 'commit rename'
    It 'pi no longer carries the old commit skill'
      When call test ! -e home/dot_pi/agent/skills/commit/SKILL.md
      The status should be success
    End

    It 'chezmoi prunes the old pi commit path'
      When call grep -q '^\.pi/agent/skills/commit$' home/.chezmoiremove
      The status should be success
    End
  End
End
