#!/usr/bin/env bats
# Tests for the wait-until bin (home/dot_local/bin/executable_wait-until):
# poll a command until it succeeds or a timeout elapses.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_wait-until"
}

@test "succeeds immediately when the condition is already true" {
  run sh "$SCRIPT" --timeout 2s -- true
  [ "$status" -eq 0 ]
}

@test "times out and exits 1 when the condition never holds" {
  run sh "$SCRIPT" --timeout 0.3s --quiet -- false
  [ "$status" -eq 1 ]
}

@test "exits 2 on a usage error (no command given)" {
  run sh "$SCRIPT" --timeout 1s
  [ "$status" -eq 2 ]
}

@test "returns as soon as the condition becomes true" {
  flag="$BATS_TEST_TMPDIR/flag"
  rm -f "$flag"
  ( sleep 0.3; : > "$flag" ) &
  run sh "$SCRIPT" --timeout 3s --interval 0.05 -- test -f "$flag"
  [ "$status" -eq 0 ]
}

@test "accepts a bare-number (seconds) timeout" {
  run sh "$SCRIPT" --timeout 1 --interval 0.05 -- true
  [ "$status" -eq 0 ]
}

@test "--help exits 0 and prints usage" {
  run sh "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}
