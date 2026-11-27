# Characterization + unit tests for group C4 (spec
# docs/superpowers/specs/2026-08-01-shared-lib-consolidation-design.md):
# the two shared resolvers added to home/dot_local/lib/mux-bootstrap.zsh —
#
#   mux::bin <tmux|rex>     — the ONE public wrapper around the backend
#                             resolvers (_mux_tx_bin, _mux_rx_bin), so
#                             standalone scripts do not re-implement the
#                             install-dir search.
#   mux::wezterm_panes       — the backend-neutral WezTerm pane probe.
#
# The install-dir fallbacks reach absolute paths (/opt/homebrew, /usr/local)
# this box can't clear, so — mirroring the existing `_mux_*_bin` tests in
# mux_spec.sh — machine-dependent cases are `Skip if`-guarded and assert
# structural properties; the fully hermetic cases carry the contract.

Describe 'mux-bootstrap.zsh — mux::bin (public binary resolver)'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() { unset MUX_TMUX_BIN; }
  BeforeEach 'setup'

  no_tmux() { [[ ! -x /opt/homebrew/bin/tmux && ! -x /usr/local/bin/tmux && ! -x /usr/bin/tmux ]]; }
  real_tmux() { [[ -x /opt/homebrew/bin/tmux || -x /usr/local/bin/tmux ]]; }

  # PATH-scrubbed subshells: command -v fails, so the install-dir list is walked
  # (the .zshrc-autostart / early-login case). The change must not leak out.
  tx_no_path() ( PATH=/nonexistent; mux::bin tmux )

  It 'honours $MUX_TMUX_BIN verbatim for tmux'
    export MUX_TMUX_BIN=/some/stub/tmux
    When call mux::bin tmux
    The output should equal "/some/stub/tmux"
  End

  It 'finds tmux at a known install location when $PATH lacks it'
    Skip if 'tmux is not installed where the shim looks' no_tmux
    When call tx_no_path
    The output should start with "/"
    The status should be success
  End

  # command -v fails and tmux lives ONLY in the mise-shim dir (the dev-shell
  # at login). The shared resolver walks past command -v through the full
  # install list and finds it.
  It 'walks past command -v to the mise-shim dir'
    Skip if 'a real tmux shadows the shim on this box' real_tmux
    fakehome=$(mktemp -d)
    mkdir -p "$fakehome/.local/share/mise/shims"
    printf '#!/bin/sh\n' >"$fakehome/.local/share/mise/shims/tmux"
    chmod +x "$fakehome/.local/share/mise/shims/tmux"
    resolve() ( HOME="$fakehome"; PATH=/nonexistent; mux::bin tmux )
    When call resolve
    The output should equal "$fakehome/.local/share/mise/shims/tmux"
    The status should be success
    rm -rf "$fakehome"
  End

  It 'returns non-zero for an unknown backend name'
    When call mux::bin frobnicate
    The status should be failure
  End

  It 'no longer knows zellij'
    When call mux::bin zellij
    The status should be failure
  End
End

Describe 'mux-bootstrap.zsh — mux::wezterm_panes'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    WEZ_ENV_LOG="$TEST_TMP/wez-env.log"
    export WEZ_ENV_LOG
    # Stub wezterm: records whether the scrubbed vars leaked into its env, then
    # emits sample `cli list` JSON (a null tty exercises the `// ""` guard).
    stub="$TEST_TMP/wezterm"
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "SOCK=[${WEZTERM_UNIX_SOCKET:-}] PANE=[${WEZTERM_PANE:-}]" > "$WEZ_ENV_LOG"'
      echo 'cat <<JSON'
      echo '[{"tty_name":"/dev/ttys004","window_id":0,"pane_id":3},{"tty_name":null,"window_id":2,"pane_id":9}]'
      echo 'JSON'
    } > "$stub"
    chmod +x "$stub"
    export WEZTERM_BIN="$stub"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset WEZTERM_BIN WEZ_ENV_LOG; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'emits the exact TSV — tty, window_id, pane_id — with null tty as empty'
    When call mux::wezterm_panes
    The output should equal "$(printf '/dev/ttys004\t0\t3\n\t2\t9')"
    The status should be success
  End

  It 'scrubs WEZTERM_UNIX_SOCKET and WEZTERM_PANE from the probe env'
    export WEZTERM_UNIX_SOCKET=/tmp/should-be-gone
    export WEZTERM_PANE=99
    When call mux::wezterm_panes
    The contents of file "$WEZ_ENV_LOG" should equal "SOCK=[] PANE=[]"
    The output should include "/dev/ttys004"
  End

  It 'emits nothing when wezterm reports no panes'
    # A wezterm that errors / emits nothing → the probe degrades to empty output
    # (Ghostty, headless, or a CLI that cannot reach the GUI).
    printf '#!/bin/sh\nexit 1\n' >"$TEST_TMP/wezterm-empty"
    chmod +x "$TEST_TMP/wezterm-empty"
    export WEZTERM_BIN="$TEST_TMP/wezterm-empty"
    When call mux::wezterm_panes
    The output should equal ""
    The status should be success
  End
End

Describe 'command.zsh — loads the shared resolver'
  setup() {
    export MUX_LIB="$PWD/home/dot_local/lib"
  }
  cleanup() { unset MUX_LIB; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  load() {
    source home/dot_config/mux/scripts/lib/config.zsh
    source home/dot_config/mux/scripts/lib/command.zsh
  }

  It 'exposes mux::bin after sourcing (command.zsh loads mux-bootstrap)'
    load
    When call whence -w mux::bin
    The output should include "function"
  End
End
