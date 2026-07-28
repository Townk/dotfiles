# pick-common: --select-1 and the launcher opt-out.
#
# fzf's --select-1 accepts a ONE-ROW list without ever drawing it. For a
# symbol picker that is a courtesy; for a LAUNCHER it is a trap — the work
# laptop renders exactly one quick-launch workspace (the other three are
# gated on personal project dirs that only exist on the personal machine),
# so opening the picker connected to that entry instantly, with no list and
# no way to choose anything else. Launchers now opt out.
Describe 'pick-common — auto-accept of a single row'
  Include home/dot_local/lib/pick-common.zsh

  # build_fzf_args reads the parsed pick_ui state and fills $fzf_args; drive
  # it directly so no tty or fzf process is involved.
  build() {
    typeset -gA pick_ui
    pick_ui=()
    [[ -n "${1:-}" ]] && pick_ui[no_auto_single]=1
    typeset -ga fzf_args
    pick::build_fzf_args >/dev/null 2>&1
    printf '%s\n' "${fzf_args[@]}"
  }

  It 'keeps --select-1 by default (a lone symbol needs no prompt)'
    When call build
    The output should include "--select-1"
    The status should be success
  End

  It 'drops --select-1 when the caller opts out'
    When call build optout
    The output should not include "--select-1"
    The status should be success
  End

  It 'still drops the companion --exit-0 when opted out'
    # --exit-0 quits on an EMPTY list, which is the same invisible failure:
    # a launcher with nothing to show must say so, not vanish.
    When call build optout
    The output should not include "--exit-0"
    The status should be success
  End
End

Describe 'quick-launch-pick — launchers never auto-fire'
  PICKER="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_quick-launch-pick"

  It 'passes the opt-out for every kind it can launch'
    When run grep -c -- "--no-auto-single" "$PICKER"
    The output should not equal "0"
    The status should be success
  End
End
