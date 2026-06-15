#!/usr/bin/env bats
# Tests for the shared base library (home/dot_local/lib/common.sh): the
# logging/dispatch/command-presence primitives every other library builds on.

setup() {
  source "$BATS_TEST_DIRNAME/../home/dot_local/lib/common.sh"
}

@test "log_info writes the message to stdout" {
  run log_info "hello world"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello world"* ]]
}

@test "log_warn / log_error write to stderr, not stdout" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../home/dot_local/lib/common.sh"; log_warn "warnmsg" 2>/dev/null'
  [ -z "$output" ]
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../home/dot_local/lib/common.sh"; log_warn "warnmsg" 2>&1 >/dev/null'
  [[ "$output" == *"warnmsg"* ]]
}

@test "die writes an error and exits non-zero" {
  run die "boom"
  [ "$status" -ne 0 ]
  [[ "$output" == *"boom"* ]]
}

@test "is_help recognizes -h, --help, and a bare help" {
  is_help -h
  is_help --help
  is_help help
}

@test "is_help rejects other tokens" {
  ! is_help list
  ! is_help --update
  ! is_help ""
}

@test "args_contain_help finds a help flag anywhere in the list" {
  args_contain_help --update --help
  args_contain_help -h
  args_contain_help --all -h --update
}

@test "args_contain_help ignores a bare help token and empty lists" {
  ! args_contain_help
  ! args_contain_help --update --all
  # bare `help` is NOT a flag at the args-list level (collides with positionals)
  ! args_contain_help help
}

@test "require_cmd passes when every command is present" {
  require_cmd awk sort sed
}

@test "require_cmd dies listing the missing command(s)" {
  run require_cmd awk definitely_missing_xyz sort
  [ "$status" -ne 0 ]
  [[ "$output" == *"definitely_missing_xyz"* ]]
}

@test "have_tty is callable and returns a boolean status" {
  # Under bats stdin is not a tty; /dev/tty may or may not exist, so we only
  # assert the function runs and yields a 0/1 status (never an error).
  run have_tty
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
