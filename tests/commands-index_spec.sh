# Tests for the welcome screen's data: zsh/commands.tsv (the curated command
# index) and zsh/keys.tsv (the key bindings people forget).
#
# commands.tsv is consumed two ways: ~/.local/libexec/pick-command offers every
# row, and functions.d/commands.sh prints the rows flagged WELCOME as the
# MANAGE THIS MACHINE column of the cockpit under macchina; keys.tsv is the
# AT THE PROMPT column. The screen half is a hard budget — nothing below
# macchina past 78 columns — and nothing at runtime complains when a row breaks
# it: an over-long blurb just wraps the screen on an 80-column terminal. This
# pins the budget and the alignment, that every command listed still exists
# (the list rots silently as tools are installed and removed) and that every
# key listed is really bound.
Describe 'zsh/commands.tsv and keys.tsv — the welcome screen data'
  # The source is a template gated per profile, so the subject is what chezmoi
  # renders for THIS machine: the rows for other profiles name commands that are
  # legitimately absent here, and asserting on the raw source would fail on the
  # template directives themselves. --source points chezmoi at this checkout so
  # the shared .chezmoitemplates helpers come from the tree under test, not from
  # the machine's live source; the config (and so the profile) stays the
  # machine's own.
  template="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/commands.tsv.tmpl"
  index="$SHELLSPEC_TMPBASE/commands-index.tsv"
  keys_template="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/keys.tsv.tmpl"
  keys="$SHELLSPEC_TMPBASE/keys.tsv"
  keys_off="$SHELLSPEC_TMPBASE/keys-no-ai.tsv"
  keybindings="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/keybindings.sh"
  tmux_keymap="$SHELLSPEC_PROJECT_ROOT/home/dot_config/tmux/keymap-base.conf.tmpl"
  functions_d="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/functions.d"
  aliases_file="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/aliases.d/personal.sh"
  picker="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-command"

  render_index() {
    chezmoi --source "$SHELLSPEC_PROJECT_ROOT/home" execute-template <"$template" >"$index" &&
      chezmoi --source "$SHELLSPEC_PROJECT_ROOT/home" execute-template <"$keys_template" >"$keys" &&
      # appliance is the profile with aiTooling off
      chezmoi --source "$SHELLSPEC_PROJECT_ROOT/home" execute-template \
        --override-data '{"profile": "appliance"}' <"$keys_template" >"$keys_off"
  }
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
          [[ "$field[3]" == (0|1) ]] || { print -r -- "bad welcome flag: $field[1] -> $field[3]"; (( bad++ )) }
          [[ -n "${field[5]// /}" ]] || { print -r -- "empty description: $field[1]"; (( bad++ )) }
          (( ${seen[(Ie)$field[1]]} )) && { print -r -- "duplicate command: $field[1]"; (( bad++ )) }
          seen+=("$field[1]")
        done < "'"$index"'"
        (( n > 0 )) || print -r -- "index is empty"
        print -r -- "violations: $bad"
      '
    }

    It 'gives every entry five fields, a 0/1 welcome flag, a description, and a unique name'
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
    # Left cell: a 14-wide name, two spaces, up to 22 of blurb. Right cell: a
    # key of up to 9 display cells, then up to 26 of blurb.
    budget() {
      zsh -f -c '
        integer bad=0 n=0 m=0
        local line
        local -a field
        while IFS= read -r line; do
          [[ -z "$line" || "$line" == \#* ]] && continue
          field=("${(@ps:\t:)line}")
          if [[ "$field[3]" == 0 ]]; then
            [[ -z "$field[4]" ]] || { print -r -- "picker-only row carries a blurb: $field[1]"; (( bad++ )) }
            continue
          fi
          (( n++ ))
          (( ${#field[1]} <= 14 )) || { print -r -- "name over 14 chars: $field[1] (${#field[1]})"; (( bad++ )) }
          (( ${#field[4]} >= 1 && ${#field[4]} <= 22 )) ||
            { print -r -- "blurb not 1..22 chars: $field[1] -> [$field[4]]"; (( bad++ )) }
        done < "'"$index"'"
        while IFS= read -r line; do
          [[ -z "$line" || "$line" == \#* ]] && continue
          (( m++ ))
          field=("${(@ps:\t:)line}")
          (( ${#field} == 3 )) || { print -r -- "keys row not 3 fields: $field[1]"; (( bad++ )); continue }
          local pua="${field[1]//[^$'"'"'\uE000'"'"'-$'"'"'\uF8FF'"'"'$'"'"'\U000F0000'"'"'-$'"'"'\U000FFFFD'"'"']/}"
          (( ${(m)#field[1]} + ${#pua} <= 9 )) || { print -r -- "keys over 9 cells: $field[1]"; (( bad++ )) }
          (( ${#field[2]} >= 1 && ${#field[2]} <= 26 )) ||
            { print -r -- "key blurb not 1..26 chars: $field[1] -> [$field[2]]"; (( bad++ )) }
        done < "'"$keys"'"
        (( n > 0 )) || { print -r -- "no welcome rows in commands.tsv"; (( bad++ )) }
        (( m > 0 )) || { print -r -- "no rows in keys.tsv"; (( bad++ )) }
        print -r -- "violations: $bad"
      '
    }

    It 'keeps names within 14 chars and blurbs within their cells'
      When call budget
      The output should equal 'violations: 0'
    End

    It 'lists the front doors and no backend'
      listed() { awk -F'\t' '$3 == 1 { printf "%s ", $1 }' "$index"; }
      When call listed
      The output should not include 'system-package-brew'
      The output should not include 'system-service-launchd'
      The output should include 'system-update system-package system-service system-secrets'
      The output should include 'share '
      The output should include 'y '
    End

    It 'lists system-images only on macOS'
      images() { awk -F'\t' '$1 == "system-images" && $3 == 1 { print "listed" }' "$index"; }
      When call images
      if [ "$(uname -s)" = Darwin ]; then
        The output should equal 'listed'
      else
        The output should equal ''
      fi
    End
  End

  Describe 'the cockpit under macchina'
    # The rendered screen, not just the data behind it: this is what actually
    # reaches the terminal, escapes and multi-cell glyphs included. macchina is
    # a stub so the spec depends on nothing installed, and chezmoi is a no-op
    # so motd's background drift refresh touches nothing. Colour escapes are
    # stripped; a Nerd Font glyph is 2 cells (tmux), so widths add one per
    # private-use character on top of the codepoint count.
    screen() { # $1 = keys file, $2 = drift stamp contents
      local cache="$SHELLSPEC_TMPBASE/cache-$$"
      mkdir -p "$cache"
      printf '%s' "$2" >"$cache/chezmoi-drift"
      _CMDS_INDEX="$index" _KEYS_INDEX="$1" XDG_CACHE_HOME="$cache" zsh -f -c '
        setopt extended_glob
        source "'"$functions_d"'/_lib.sh"
        function compdef() { :; }
        source "'"$functions_d"'/commands.sh"
        function macchina() { print -r -- "MACCHINA-STUB"; }
        function chezmoi() { :; }
        motd
      ' 2>/dev/null | sed $'s/\e\\[[0-9;]*m//g'
    }
    screen_ok() { screen "$keys" ''; }
    screen_no_ai() { screen "$keys_off" ''; }
    screen_drift() { screen "$keys" 'M .zshrc'; }

    # $1 = a screen function; prints "<n> <cells>" for each line after macchina.
    widths() {
      "$1" | zsh -f -c '
        local line pua
        integer n=0
        read -r line   # the stub
        while IFS= read -r line; do
          pua="${line//[^$'\'''\''-$'\'''\''$'\''\U000F0000'\''-$'\''\U000FFFFD'\'']/}"
          print -r -- "$(( ++n )) $(( ${(m)#line} + ${#pua} ))"
        done'
    }

    It 'prints macchina first'
      When call screen_ok
      The line 1 of output should equal 'MACCHINA-STUB'
    End

    It 'follows macchina with the rule, 78 heavy columns wide'
      When call screen_ok
      The line 2 of output should equal '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    End

    It 'keeps every line after macchina within 78 columns'
      over() { widths screen_ok | awk '$2 > 78 { print "line " $1 " is " $2 }'; }
      When call over
      The output should equal ''
    End

    It 'underlines each header as wide as the header, glyph as 2 cells'
      # Lines 3 and 4 (after the stub and the rule) are the headers and their
      # underlines. Each header is a glyph, a space and a title; the glyph is 2
      # cells, so a header is the title's length plus 3.
      underlines() {
        screen_ok | sed -n '3p;4p' | zsh -f -c '
          setopt extended_glob
          read -r head; read -r under
          local lh="${head##  }"; lh="${lh%%MACHINE*}MACHINE"
          local rh="${head##*MACHINE}"; rh="${rh##[[:space:]]#}"
          local lu="${${under##  }%% *}" ru="${under##* }"
          print -r -- "left $(( ${#lh} + 1 )) ${#lu}"
          print -r -- "right $(( ${#rh} + 1 )) ${#ru}"
        '
      }
      When call underlines
      The line 1 of output should equal 'left 22 22'
      The line 2 of output should equal 'right 16 16'
    End

    It 'has no ❖ divider and no terminal_commands'
      absent() {
        screen_ok | grep -c '❖'
        zsh -f -c 'source "'"$functions_d"'/_lib.sh"; function compdef() { :; }; source "'"$functions_d"'/commands.sh"; whence -w terminal_commands || true'
      }
      When call absent
      The line 1 of output should equal '0'
      The line 2 of output should include 'none'
    End

    It 'shows no drift line when the stamp is empty'
      When call screen_ok
      The output should not include 'chezmoi drift'
    End

    It 'shows the drift line between macchina and the rule when the stamp is non-empty'
      When call screen_drift
      The line 1 of output should equal 'MACCHINA-STUB'
      The line 2 of output should equal '↻ chezmoi drift: $HOME differs from source — run chezmoi diff --exclude=scripts'
      The line 3 of output should start with '━━━━'
    End

    It 'shows the ai-assist and playbook keys where aiTooling is on'
      When call screen_ok
      The output should include 'ask ai-assist'
      The output should include 'run a saved playbook'
    End

    It 'hides the ai-assist and playbook keys where aiTooling is off'
      When call screen_no_ai
      The output should not include 'ask ai-assist'
      The output should not include 'run a saved playbook'
      The output should include 'pick a curated command'
    End
  End

  Describe 'every key listed is bound'
    # Each WIDGET named in keys.tsv must be the target of a bindkey line in
    # keybindings.sh (or a `bind -n` in the tmux keymap for tmux:<key>), or the screen advertises a key that does nothing.
    bound() {
      zsh -f -c '
        integer bad=0
        local line w
        local -a field
        while IFS= read -r line; do
          [[ -z "$line" || "$line" == \#* ]] && continue
          field=("${(@ps:\t:)line}")
          for w in ${=field[3]}; do
            if [[ "$w" == tmux:* ]]; then
              grep -Eq "^bind -n ${w#tmux:} " "'"$tmux_keymap"'" ||
                { print -r -- "not bound in the tmux keymap: $field[1] -> $w"; (( bad++ )) }
              continue
            fi
            grep -Eq "^(command -v [a-z]+ >/dev/null && )?bindkey +.+ +${w}( |\$)" "'"$keybindings"'" ||
              { print -r -- "not bound in keybindings.sh: $field[1] -> $w"; (( bad++ )) }
          done
        done < "'"$keys"'"
        print -r -- "violations: $bad"
      '
    }
    It 'finds a bindkey for every widget in keys.tsv'
      When call bound
      The output should equal 'violations: 0'
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
