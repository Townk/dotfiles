# The fzf key bindings several surfaces share are spelled once, in
# home/dot_local/lib/fzf-bindings.zsh, and rendered by three consumers:
# FZF_DEFAULT_OPTS and the fzf-tab zstyles (zsh/completion.sh), and
# pick::build_fzf_args (pick-common.zsh). The Ctrl+Space binding used to be
# written in all three; the fzf-tab copy broke alone, because fzf-tab splits
# its fzf-flags on spaces.
Describe 'shared fzf bindings'
  ROOT="$SHELLSPEC_PROJECT_ROOT"
  BINDINGS="$ROOT/home/dot_local/lib/fzf-bindings.zsh"
  COMPLETION="$ROOT/home/dot_config/zsh/completion.sh"

  It 'has no space in any value (a spaced flag reaches fzf cut in two)'
    spaced() {
      zsh -f -c 'source "$1"; for n in ${(k)parameters[(I)FZF_BIND_*]}; do for v in "${(@P)n}"; do [[ $v == *" "* ]] && print -r -- "$n: $v"; done; done; print -r -- "${#parameters[(I)FZF_BIND_*]} checked"' _ "$BINDINGS"
    }
    When call spaced
    The output should equal "4 checked"
  End

  # The zstyle statement itself is evaluated, so quoting mistakes show up as
  # they would in the shell — a grep of the source cannot see those.
  ftb_style() {
    zsh -f -c '
      source "$1"
      eval "$(awk -v s="$3" '"'"'$0 ~ "zstyle .:fzf-tab:\\*. " s " " {p=1} p{print} p&&!/\\$/{p=0}'"'"' "$2")"
      zstyle -a ":fzf-tab:x" "$3" v; print -rl -- "${v[@]}"
    ' _ "$BINDINGS" "$COMPLETION" "$1"
  }

  It 'gives fzf-tab flags with no space in any of them'
    When call ftb_style fzf-flags
    The output should equal '--height=~40%
--preview-window=hidden
--bind=ctrl-space:execute-silent($HOME/.local/libexec/preview-wipe-images)+toggle-preview'
    The output should not include ' '
  End

  It 'keeps fzf-tab'"'"'s Ctrl+O resolving the display key, not the raw row'
    When call ftb_style fzf-bindings
    The output should equal 'ctrl-o:execute-silent($HOME/.local/libexec/fzf-tab-preview-open --fzf-tab-desc {2})'
  End

  It 'spells the Ctrl+Space preview toggle in the shared file and nowhere else'
    elsewhere() {
      # Comment lines may describe it; code may not spell it.
      grep -rnE 'ctrl-space:.*toggle-preview' "$ROOT/home" 2>/dev/null |
        grep -v "^$BINDINGS:" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|--)' | sed "s|^$ROOT/||" || true
    }
    When call elsewhere
    The output should equal ""
  End

  Describe 'in a picker'
    Include home/dot_local/lib/pick-common.zsh

    # build_fzf_args reads the parsed pick_ui state and fills $fzf_args.
    binds() {
      typeset -gA pick_ui; pick_ui=("$@")
      typeset -ga fzf_args
      pick::build_fzf_args >/dev/null 2>&1
      local i
      for (( i = 1; i < ${#fzf_args}; i++ )); do
        [[ "${fzf_args[i]}" == --bind ]] && print -r -- "${fzf_args[i+1]}"
      done
      return 0
    }

    It 'toggles and scrolls a preview with the keys the shell fzf uses'
      When call binds preview 'cat {}' expect enter
      The output should equal 'ctrl-f:page-down
ctrl-b:page-up
ctrl-space:execute-silent($HOME/.local/libexec/preview-wipe-images)+toggle-preview
shift-up:preview-up
shift-down:preview-down
alt-up:preview-page-up
alt-down:preview-page-down
alt-page-up:preview-page-up
alt-page-down:preview-page-down
alt-home:preview-top
alt-end:preview-bottom'
    End

    It 'binds none of them when the picker has no preview'
      When call binds expect enter
      The output should equal 'ctrl-f:page-down
ctrl-b:page-up'
    End

    It 'keeps Ctrl+Space as the marker toggle under --multi'
      When call binds preview 'cat {}' multi 1 expect enter
      The output should include 'ctrl-space:toggle'
      The output should not include 'toggle-preview'
      The output should include 'alt-end:preview-bottom'
    End

    It 'leaves a scroll key alone when the picker accepts on it'
      When call binds preview 'cat {}' expect enter,alt-up
      The output should not include 'alt-up:'
      The output should include 'alt-down:preview-page-down'
    End
  End
End
