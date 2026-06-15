#!/usr/bin/env bats
# Tests for the platform:: module (home/dot_local/lib/platform.sh + the
# platform-<os>.sh implementations). PLATFORM_OS forces the branch, and stub
# GUI commands on PATH capture what each function would invoke.

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/dot_local/lib"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  for cmd in open osascript setsid hyprctl swaymsg wmctrl xdotool; do
    printf '#!/bin/sh\necho "%s $*"\n' "$cmd" > "$STUB/$cmd"
    chmod +x "$STUB/$cmd"
  done
  PATH="$STUB:$PATH"
}

@test "Darwin branch defines the platform:: interface" {
  run env PLATFORM_OS=Darwin bash -c "source '$LIB/platform.sh'
    type platform::launch_gui >/dev/null && type platform::raise_app >/dev/null && echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "Linux branch defines the platform:: interface" {
  run env PLATFORM_OS=Linux bash -c "source '$LIB/platform.sh'
    type platform::launch_gui >/dev/null && type platform::raise_app >/dev/null && echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "unsupported OS dies with a clear message" {
  run env PLATFORM_OS=Plan9 bash -c "source '$LIB/platform.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported OS: Plan9"* ]]
}

@test "macOS launch_gui routes through open -a with the argv after --" {
  run env PLATFORM_OS=Darwin PATH="$STUB:$PATH" bash -c "source '$LIB/platform.sh'
    platform::launch_gui WezTerm /usr/bin/wezterm -- start --cwd /x -- nvim foo"
  [[ "$output" == "open -a WezTerm --args start --cwd /x -- nvim foo" ]]
}

@test "macOS raise_app activates the named app" {
  # raise_app silences osascript (>/dev/null), so capture via a file, not stdout.
  rec="$BATS_TEST_TMPDIR/osa"
  printf '#!/bin/sh\necho "$*" > "%s"\n' "$rec" > "$STUB/osascript"
  chmod +x "$STUB/osascript"
  env PLATFORM_OS=Darwin PATH="$STUB:$PATH" bash -c "source '$LIB/platform.sh'
    platform::raise_app WezTerm"
  [[ "$(cat "$rec")" == *'tell application "WezTerm" to activate'* ]]
}

@test "Linux launch_gui execs the linux binary detached with the argv after --" {
  rec="$BATS_TEST_TMPDIR/rec"
  printf '#!/bin/sh\necho "setsid $*" > "%s"\n' "$rec" > "$STUB/setsid"
  chmod +x "$STUB/setsid"
  env PLATFORM_OS=Linux PATH="$STUB:$PATH" bash -c "source '$LIB/platform.sh'
    platform::launch_gui WezTerm wezterm -- start --cwd /x -- nvim foo; wait"
  [[ "$(cat "$rec")" == "setsid wezterm start --cwd /x -- nvim foo" ]]
}

@test "Linux raise_app is best-effort and never fails" {
  run env PLATFORM_OS=Linux PATH="$STUB:$PATH" bash -c "source '$LIB/platform.sh'
    platform::raise_app WezTerm org.wezfurlong.wezterm; echo rc=\$?"
  [[ "$output" == *"rc=0"* ]]
}
