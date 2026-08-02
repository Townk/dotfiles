# Characterization + unit tests for group C4 (spec
# docs/superpowers/specs/2026-08-01-shared-lib-consolidation-design.md):
# the two shared resolvers added to home/dot_local/lib/mux-bootstrap.zsh —
#
#   mux::bin <zellij|tmux>  — the ONE public wrapper around _mux_zj_bin /
#                             _mux_tx_bin. Standalone scripts that used to
#                             re-implement the install-dir search (zellij-modal,
#                             command.zsh, edit-terminal-config) call it now.
#   mux::wezterm_panes       — the backend-neutral WezTerm pane probe, formerly
#                             triplicated in mux/zellij.zsh + mux/tmux.zsh.
#
# The install-dir fallbacks reach absolute paths (/opt/homebrew, /usr/local)
# this box can't clear, so — mirroring the existing `_mux_*_bin` tests in
# mux_spec.sh — machine-dependent cases are `Skip if`-guarded and assert
# structural properties; the fully hermetic cases carry the contract.

Describe 'mux-bootstrap.zsh — mux::bin (public binary resolver)'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() { unset MUX_TMUX_BIN ZELLIJ_BIN; }
  BeforeEach 'setup'

  no_tmux() { [[ ! -x /opt/homebrew/bin/tmux && ! -x /usr/local/bin/tmux && ! -x /usr/bin/tmux ]]; }
  no_zellij() { [[ ! -x /opt/homebrew/bin/zellij && ! -x /usr/local/bin/zellij ]]; }
  real_zellij() { [[ -x /opt/homebrew/bin/zellij || -x /usr/local/bin/zellij ]]; }

  # PATH-scrubbed subshells: command -v fails, so the install-dir list is walked
  # (the .zshrc-autostart / early-login case). The change must not leak out.
  zj_no_path() ( PATH=/nonexistent; mux::bin zellij )
  tx_no_path() ( PATH=/nonexistent; mux::bin tmux )

  It 'honours $ZELLIJ_BIN verbatim for zellij'
    export ZELLIJ_BIN=/some/stub/zellij
    When call mux::bin zellij
    The output should equal "/some/stub/zellij"
  End

  It 'honours $MUX_TMUX_BIN verbatim for tmux'
    export MUX_TMUX_BIN=/some/stub/tmux
    When call mux::bin tmux
    The output should equal "/some/stub/tmux"
  End

  It 'resolves zellij via command -v when it is on $PATH'
    dir=$(mktemp -d)
    printf '#!/bin/sh\n' >"$dir/zellij"; chmod +x "$dir/zellij"
    export PATH="$dir:$PATH"
    When call mux::bin zellij
    The output should equal "$dir/zellij"
    rm -rf "$dir"
  End

  It 'finds zellij at a known install location when $PATH lacks it'
    Skip if 'zellij is not installed where the shim looks' no_zellij
    When call zj_no_path
    The output should start with "/"
    The status should be success
  End

  It 'finds tmux at a known install location when $PATH lacks it'
    Skip if 'tmux is not installed where the shim looks' no_tmux
    When call tx_no_path
    The output should start with "/"
    The status should be success
  End

  # The exact case edit-terminal-config's degraded
  # `${commands[zellij]:-/opt/homebrew/bin/zellij}` used to miss: command -v
  # fails and zellij lives ONLY in the mise-shim dir. The shared resolver walks
  # past command -v through the full install list and finds it.
  It 'walks past command -v to the mise-shim dir (the edit-terminal-config gap)'
    Skip if 'a real zellij shadows the shim on this box' real_zellij
    fakehome=$(mktemp -d)
    mkdir -p "$fakehome/.local/share/mise/shims"
    printf '#!/bin/sh\n' >"$fakehome/.local/share/mise/shims/zellij"
    chmod +x "$fakehome/.local/share/mise/shims/zellij"
    resolve() ( HOME="$fakehome"; PATH=/nonexistent; mux::bin zellij )
    When call resolve
    The output should equal "$fakehome/.local/share/mise/shims/zellij"
    The status should be success
    rm -rf "$fakehome"
  End

  It 'returns non-zero for an unknown backend name'
    When call mux::bin frobnicate
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

Describe 'command.zsh — ql_zellij_bin routes through the shared resolver'
  setup() {
    export MUX_LIB="$PWD/home/dot_local/lib"
    unset ZELLIJ_BIN
  }
  cleanup() { unset MUX_LIB ZELLIJ_BIN; }
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

  It 'ql_zellij_bin honours $ZELLIJ_BIN through mux::bin'
    load
    export ZELLIJ_BIN=/some/stub/zellij
    When call ql_zellij_bin
    The output should equal "/some/stub/zellij"
  End
End

Describe 'zellij-modal — bin resolution via the shared resolver'
  SCRIPT="home/dot_config/zellij/scripts/executable_zellij-modal"
  setup() {
    TEST_TMP=$(mktemp -d)
    ZJ_LOG="$TEST_TMP/zj.log"
    export ZJ_LOG
    # Stub zellij: log every invocation's argv, succeed for everything.
    stub="$TEST_TMP/zellij"
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "$*" >> "$ZJ_LOG"'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export MUX_LIB="$PWD/home/dot_local/lib"
    export ZELLIJ=1
    # No ZELLIJ_PANE_ID → the deferred focus loop is skipped (no lingering bg
    # job holding the captured pipe); discover_target_pane still exercises the
    # resolved binary synchronously.
    unset ZELLIJ_PANE_ID ZELLIJ_BIN
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_LIB ZELLIJ ZELLIJ_PANE_ID ZELLIJ_BIN ZJ_LOG; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'honours $ZELLIJ_BIN'
    export ZELLIJ_BIN="$stub"
    When run zsh "$SCRIPT" --title T -- true
    The status should be success
    The contents of file "$ZJ_LOG" should include "list-panes"
    The output should include "▓▓▓ T"
  End

  It 'resolves the binary via command -v when $ZELLIJ_BIN is unset'
    export PATH="$TEST_TMP:$PATH"
    When run zsh "$SCRIPT" --title T -- true
    The status should be success
    The contents of file "$ZJ_LOG" should include "list-panes"
    The output should include "▓▓▓ T"
  End
End
