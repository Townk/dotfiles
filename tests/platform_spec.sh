# Tests for the platform:: module (home/dot_local/lib/platform.zsh + the
# platform-<os>.sh implementations). PLATFORM_OS forces the branch, and stub
# GUI commands on PATH capture what each function would invoke.
Describe 'platform.zsh'
  setup() {
    LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    STUB=$(mktemp -d)
    for cmd in open osascript setsid hyprctl swaymsg wmctrl xdotool; do
      printf '#!/bin/sh\necho "%s $*"\n' "$cmd" > "$STUB/$cmd"
      chmod +x "$STUB/$cmd"
    done
    PATH="$STUB:$PATH"
  }
  cleanup() { rm -rf "$STUB"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'Darwin branch defines the platform:: interface'
    darwin_iface() {
      export PLATFORM_OS=Darwin
      . "$LIB/platform.zsh"
      type platform::launch_gui >/dev/null && type platform::raise_app >/dev/null && echo ok
    }
    When run darwin_iface
    The status should be success
    The output should include "ok"
  End

  It 'Linux branch defines the platform:: interface'
    linux_iface() {
      export PLATFORM_OS=Linux
      . "$LIB/platform.zsh"
      type platform::launch_gui >/dev/null && type platform::raise_app >/dev/null && echo ok
    }
    When run linux_iface
    The status should be success
    The output should include "ok"
  End

  It 'unsupported OS dies with a clear message'
    bad_os() { export PLATFORM_OS=Plan9; . "$LIB/platform.zsh"; }
    When run bad_os
    The status should be failure
    The stderr should include "unsupported OS: Plan9"
  End

  It 'macOS launch_gui routes through open -a with the argv after --'
    darwin_launch() {
      export PLATFORM_OS=Darwin
      . "$LIB/platform.zsh"
      platform::launch_gui WezTerm /usr/bin/wezterm -- start --cwd /x -- nvim foo
    }
    When run darwin_launch
    The output should equal "open -a WezTerm --args start --cwd /x -- nvim foo"
  End

  It 'macOS raise_app activates the named app'
    darwin_raise() {
      rec="$STUB/osa-rec"
      printf '#!/bin/sh\necho "$*" > "%s"\n' "$rec" > "$STUB/osascript"
      chmod +x "$STUB/osascript"
      export PLATFORM_OS=Darwin
      . "$LIB/platform.zsh"
      platform::raise_app WezTerm
      cat "$rec"
    }
    When run darwin_raise
    The output should include 'tell application "WezTerm" to activate'
  End

  It 'Linux launch_gui execs the linux binary detached with the argv after --'
    linux_launch() {
      rec="$STUB/setsid-rec"
      printf '#!/bin/sh\necho "setsid $*" > "%s"\n' "$rec" > "$STUB/setsid"
      chmod +x "$STUB/setsid"
      export PLATFORM_OS=Linux
      . "$LIB/platform.zsh"
      platform::launch_gui WezTerm wezterm -- start --cwd /x -- nvim foo
      wait
      cat "$rec"
    }
    When run linux_launch
    The output should equal "setsid wezterm start --cwd /x -- nvim foo"
  End

  It 'Linux raise_app is best-effort and never fails'
    linux_raise() {
      export PLATFORM_OS=Linux
      . "$LIB/platform.zsh"
      platform::raise_app WezTerm org.wezfurlong.wezterm
    }
    When run linux_raise
    The status should be success
  End
End
