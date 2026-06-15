# Tests for the shared base library (home/dot_local/lib/common.zsh): the
# logging/dispatch/command-presence primitives every other library builds on.
Describe 'common.zsh'
  Include home/dot_local/lib/common.zsh

  Describe 'log_info'
    It 'writes the message to stdout'
      When call log_info "hello world"
      The output should include "hello world"
      The status should be success
    End
  End

  Describe 'log_warn / log_error'
    It 'write to stderr, not stdout'
      When call log_warn "warnmsg"
      The error should include "warnmsg"
      The output should equal ""
      The status should be success
    End
  End

  Describe 'die'
    It 'writes an error and exits non-zero'
      When run die "boom"
      The status should be failure
      The stderr should include "boom"
    End
  End

  Describe 'is_help accepts help tokens'
    Parameters
      -h
      --help
      help
    End
    It "recognizes [$1]"
      When call is_help "$1"
      The status should be success
    End
  End

  Describe 'is_help rejects non-help tokens'
    Parameters
      list
      --update
    End
    It "rejects [$1]"
      When call is_help "$1"
      The status should be failure
    End

    It 'rejects an empty token'
      When call is_help ""
      The status should be failure
    End
  End

  Describe 'args_contain_help'
    It 'finds a help flag anywhere in the list'
      When call args_contain_help --update --help
      The status should be success
    End
    It 'finds a lone -h'
      When call args_contain_help -h
      The status should be success
    End
    It 'finds -h among other args'
      When call args_contain_help --all -h --update
      The status should be success
    End
    It 'returns failure for an empty list'
      When call args_contain_help
      The status should be failure
    End
    It 'returns failure when no help flag is present'
      When call args_contain_help --update --all
      The status should be failure
    End
    It 'ignores a bare help token (collides with positionals)'
      When call args_contain_help help
      The status should be failure
    End
  End

  Describe 'require_cmd'
    It 'passes when every command is present'
      When call require_cmd awk sort sed
      The status should be success
    End
    It 'dies listing the missing command(s)'
      When run require_cmd awk definitely_missing_xyz sort
      The status should be failure
      The stderr should include "definitely_missing_xyz"
    End
  End

  Describe 'for_each'
    ok_one() { return 0; }
    act() { [ "$1" = bad ] && return 1; return 0; }

    It 'runs the action per non-empty line and returns 0 when all pass'
      Data
        #|a
        #|
        #|b
        #|c
      End
      When call for_each demo ok_one
      The status should be success
    End

    It 'tallies failures, warns, and returns the failure count'
      Data
        #|good
        #|bad
        #|good
        #|bad
      End
      When call for_each demo act
      The status should eq 2
      The stderr should include "demo: 2 of 4 failed"
    End

    It "exposes the caller's locals to the action via dynamic scope"
      need_ctx() { [ "$PREFIX" = ctx ] || return 1; return 0; }
      outer() { local PREFIX=ctx; printf 'x\n' | for_each demo need_ctx; }
      When call outer
      The status should be success
    End
  End

  Describe 'have_tty'
    It 'is callable and yields a boolean (0/1) status'
      yields_boolean() { have_tty; rc=$?; [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; }
      When call yields_boolean
      The status should be success
    End
  End
End
