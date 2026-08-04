# Tests for zsh/commands.tsv — the curated command index.
#
# The index is data consumed two ways: ~/.local/libexec/pick-command offers every
# row, and functions.d/commands.sh prints the rows flagged for the welcome
# screen. The screen half is a hard budget — 7 lines by 78 columns, three cells
# of 26 (a 9-wide name, a space, a 16-wide blurb) — and nothing at runtime
# complains when a row breaks it: an over-long blurb or a seventh entry in a
# column just wraps the screen on an 80-column terminal. This pins the budget,
# and pins that every command listed still exists, since the list rots silently
# as tools are installed and removed.
Describe 'zsh/commands.tsv — the curated command index'
  # The source is a template gated per profile, so the subject is what chezmoi
  # renders for THIS machine: the rows for other profiles name commands that are
  # legitimately absent here, and asserting on the raw source would fail on the
  # template directives themselves.
  template="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/commands.tsv.tmpl"
  index="$SHELLSPEC_TMPBASE/commands-index.tsv"
  functions_d="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/functions.d"
  aliases_file="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/aliases.d/personal.sh"
  picker="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-command"

  render_index() { chezmoi execute-template <"$template" >"$index"; }
  BeforeAll 'render_index'

  # Every probe reports its violations and then a count, so a failure shows
  # which rows are wrong rather than just that something is.
  #
  # Tab is an IFS whitespace character, so `read` collapses runs of tabs and
  # would hide an empty blurb; these probes split with (@ps) for the same
  # reason _cmds_read does.

  Describe 'file structure'
    structure() {
      zsh -f -c '
        integer bad=0 n=0
        local line
        local -a field seen
        while IFS= read -r line; do
          [[ -z "$line" || "$line" == \#* ]] && continue
          (( n++ ))
          field=("${(@ps:\t:)line}")
          if (( ${#field[@]} != 5 )); then
            print -r -- "not 5 fields (${#field[@]}): $field[1]"; (( bad++ )); continue
          fi
          [[ "$field[3]" == (0|1|2|3) ]] || { print -r -- "bad column: $field[1] -> $field[3]"; (( bad++ )) }
          [[ -n "${field[5]// /}" ]] || { print -r -- "empty description: $field[1]"; (( bad++ )) }
          (( ${seen[(Ie)$field[1]]} )) && { print -r -- "duplicate command: $field[1]"; (( bad++ )) }
          seen+=("$field[1]")
        done < "'"$index"'"
        (( n > 0 )) || print -r -- "index is empty"
        print -r -- "violations: $bad"
      '
    }

    It 'gives every entry five fields, a valid column, a description, and a unique name'
      When call structure
      The output should equal 'violations: 0'
    End
  End

  Describe 'group keys the picker knows'
    # The GROUP field only means something through pick-command's icon/colour
    # table, and an unknown key is fatal there (it `die`s rather than picking a
    # fallback icon, so a typo cannot ship as a silently wrong glyph). Read the
    # table out of the script's source: sourcing it would launch fzf.
    groups() {
      zsh -f -c '
        integer bad=0
        local -a known
        known=( ${(f)"$(awk "/^typeset -A GROUP_ICON=\(/ {inside=1; next}
                            inside && /^\)/ {exit}
                            inside {print \$1}" "'"$picker"'")"} )
        (( ${#known[@]} > 0 )) || print -r -- "found no GROUP_ICON keys in the picker"
        local line
        local -a field
        while IFS= read -r line; do
          [[ -z "$line" || "$line" == \#* ]] && continue
          field=("${(@ps:\t:)line}")
          (( ${known[(Ie)$field[2]]} )) ||
            { print -r -- "group not in the picker table: $field[1] -> $field[2]"; (( bad++ )) }
        done < "'"$index"'"
        print -r -- "violations: $bad"
      '
    }

    It 'gives every row a group pick-command has an icon for'
      When call groups
      The output should equal 'violations: 0'
    End
  End

  Describe 'welcome-screen budget'
    budget() {
      zsh -f -c '
        integer bad=0
        local -a count=(0 0 0)
        local line
        local -a field
        while IFS= read -r line; do
          [[ -z "$line" || "$line" == \#* ]] && continue
          field=("${(@ps:\t:)line}")
          if [[ "$field[3]" == 0 ]]; then
            [[ -z "$field[4]" ]] || { print -r -- "picker-only row carries a blurb: $field[1]"; (( bad++ )) }
            continue
          fi
          (( count[field[3]]++ ))
          (( ${#field[1]} <= 9 )) || { print -r -- "name over 9 chars: $field[1] (${#field[1]})"; (( bad++ )) }
          (( ${#field[4]} >= 1 && ${#field[4]} <= 16 )) ||
            { print -r -- "blurb not 1..16 chars: $field[1] -> [$field[4]]"; (( bad++ )) }
        done < "'"$index"'"
        local col
        for col in 1 2 3; do
          (( count[col] == 6 )) || { print -r -- "column $col has $count[col] entries, want 6"; (( bad++ )) }
        done
        print -r -- "violations: $bad"
      '
    }

    It 'keeps three columns of six, names within 9 chars and blurbs within 16'
      When call budget
      The output should equal 'violations: 0'
    End
  End

  Describe 'rendered output'
    # The rendered geometry, not just the data behind it: this is what actually
    # reaches the terminal, escapes and multi-cell glyphs included.
    render() {
      _CMDS_INDEX="$index" zsh -f -c '
        setopt extended_glob
        source "'"$functions_d"'/_lib.sh"
        source "'"$functions_d"'/commands.sh"
        integer lines=0 widest=0 w
        local line plain
        while IFS= read -r line; do
          (( lines++ ))
          plain="${line//$'\''\e'\''\[[0-9;]##m/}"
          w=${#plain}
          (( w > widest )) && widest=$w
        done < <(terminal_commands)
        print -r -- "lines: $lines"
        # A full 78 would wrap a terminal exactly that wide, so the render has
        # to stay strictly under the budget. The width is reported either way,
        # so a failure says how far over it went.
        print -r -- "widest: $widest of 78"
        (( widest < 78 )) && print -r -- "within budget"
      ' 2>/dev/null
    }

    It 'prints exactly 7 lines'
      When call render
      The line 1 of output should equal 'lines: 7'
    End

    It 'never reaches 78 columns'
      When call render
      The output should include 'within budget'
    End
  End

  Describe 'every listed command resolves'
    # `whence` in a shell that has sourced the function and alias files, because
    # the index deliberately lists shell functions (y, g, take, tm) and one
    # alias (tv) alongside real binaries.
    resolves() {
      zsh -f -c '
        setopt null_glob
        local f
        for f in "'"$functions_d"'"/*.sh; do source "$f"; done
        source "'"$aliases_file"'"
        integer bad=0
        local line
        local -a field
        while IFS= read -r line; do
          [[ -z "$line" || "$line" == \#* ]] && continue
          field=("${(@ps:\t:)line}")
          whence -- "$field[1]" >/dev/null 2>&1 ||
            { print -r -- "does not resolve: $field[1]"; (( bad++ )) }
        done < "'"$index"'"
        print -r -- "violations: $bad"
      ' 2>/dev/null
    }

    It 'finds every command, function and alias the index names'
      When call resolves
      The output should equal 'violations: 0'
    End
  End
End
