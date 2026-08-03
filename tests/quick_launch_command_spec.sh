# quick-launch command builder (lib/command.zsh): the Edit action's file list
# and the cd prefix are flattened into a shell string that is later executed
# by a shell ($SHELL -c on tmux, zellij `args "-c" …` — both eval it). The
# flatten must therefore quote each path: an unquoted "${files[*]}" turns a
# spaced path into two argv entries and a bracketed path into a glob that
# aborts the whole command line under zsh's NOMATCH.
#
# The editor itself is deliberately NOT quoted — tools.editor may legitimately
# be multi-word ("code --wait").
Describe 'quick-launch command builder — Edit quoting'
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/lib"
  MUXLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  It 'produces a command that survives eval with spaced and glob paths'
    When run zsh -c '
      set -u
      lib="$1"; MUX_LIB="$2"
      export HOME="$(mktemp -d)" || exit 90
      mkdir -p "$HOME/my notes"
      export EDITOR=nvim
      export QL_JSON="{}"
      source "$lib/config.zsh"
      source "$lib/command.zsh"
      action="{\"type\":\"Edit\",\"cwd\":\"~/my notes\",\"args\":[\"My File.md\",\"draft[1].md\"]}"
      cmd="$(ql_action_command "$action")"
      nvim() {
        (( $# == 2 ))                                  && print -r -- ok-argc
        [[ ${1:-} == "$HOME/my notes/My File.md" ]]    && print -r -- ok-file1
        [[ ${2:-} == "$HOME/my notes/draft[1].md" ]]   && print -r -- ok-file2
        return 0
      }
      eval "$cmd"                                      && print -r -- ok-eval
      [[ $PWD == "$HOME/my notes" ]]                   && print -r -- ok-cwd
      rm -rf -- "$HOME"
    ' _ "$LIB" "$MUXLIB"
    The output should equal 'ok-argc
ok-file1
ok-file2
ok-eval
ok-cwd'
    The status should be success
  End

  It 'keeps a multi-word tools.editor unquoted'
    When run zsh -c '
      set -u
      lib="$1"; MUX_LIB="$2"
      export QL_JSON="{\"tools\":{\"editor\":\"code --wait\"}}"
      source "$lib/config.zsh"
      source "$lib/command.zsh"
      action="{\"type\":\"Edit\",\"args\":[\"/tmp/plain.md\"]}"
      cmd="$(ql_action_command "$action")"
      code() {
        [[ ${1:-} == --wait && ${2:-} == /tmp/plain.md ]] && print -r -- ok-editor
        return 0
      }
      eval "$cmd"
    ' _ "$LIB" "$MUXLIB"
    The output should equal 'ok-editor'
    The status should be success
  End
End
