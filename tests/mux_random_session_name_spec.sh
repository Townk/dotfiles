# Tests for mux-random-session-name: generation is non-mutating by default,
# while explicit application routes through the shared mux API on both backends.
Describe 'mux-random-session-name'
  setup() {
    MSN_TMP=$(mktemp -d)
    MSN_SCRIPT="$PWD/home/dot_local/bin/executable_mux-random-session-name"
    MSN_COMPLETION="$PWD/home/dot_local/share/zsh/site-functions/_mux-random-session-name"
    MSN_LIB="$PWD/home/dot_local/lib"
    export MSN_LOG="$MSN_TMP/mux.log"
    export STUB_SESSIONS=old-name
    : >"$MSN_LOG"

    cat >"$MSN_TMP/tmux" <<'ZSH'
#!/usr/bin/env zsh
[[ "$1" == -S ]] && shift 2
case "$1" in
  display)
    print -r -- old-name
    ;;
  list-sessions)
    print -l -- "${(@f)STUB_SESSIONS}"
    ;;
  rename-session)
    print -r -- "$*" >>"$MSN_LOG"
    if [[ -n "${STUB_COLLIDE_ONCE:-}" && ! -e "$MSN_LOG.collided" ]]; then
      : >"$MSN_LOG.collided"
      exit 1
    fi
    ;;
  list-clients)
    [[ -n "${STUB_CLIENT_TTY:-}" ]] && print -r -- "$STUB_CLIENT_TTY"
    true
    ;;
  refresh-client)
    print -r -- "$*" >>"$MSN_LOG"
    ;;
esac
ZSH
    chmod +x "$MSN_TMP/tmux"

    cat >"$MSN_TMP/zellij" <<'ZSH'
#!/usr/bin/env zsh
case "$*" in
  "list-sessions -s")
    print -l -- "${(@f)STUB_SESSIONS}"
    ;;
  *"action rename-session "*)
    print -r -- "$*" >>"$MSN_LOG"
    ;;
esac
ZSH
    chmod +x "$MSN_TMP/zellij"
  }
  cleanup() {
    rm -rf "$MSN_TMP"
    unset MSN_LOG STUB_SESSIONS STUB_COLLIDE_ONCE STUB_CLIENT_TTY
  }
  BeforeEach setup
  AfterEach cleanup

  generate() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND=tmux MUX_TMUX_BIN="$MSN_TMP/tmux" \
      zsh "$MSN_SCRIPT"
  }
  apply_tmux_current() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND=tmux MUX_TMUX_BIN="$MSN_TMP/tmux" \
      TMUX=/tmp/tmux-test.sock,1,0 zsh "$MSN_SCRIPT" --apply-current
  }
  apply_tmux_target() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND=tmux MUX_TMUX_BIN="$MSN_TMP/tmux" \
      MUX_TMUX_SOCKET="$MSN_TMP/socket" zsh "$MSN_SCRIPT" --apply "$1"
  }
  apply_zellij_current() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND=zellij ZELLIJ_BIN="$MSN_TMP/zellij" \
      ZELLIJ=1 ZELLIJ_SESSION_NAME=old-name zsh "$MSN_SCRIPT" --apply-current
  }
  apply_zellij_target() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND=zellij ZELLIJ_BIN="$MSN_TMP/zellij" \
      zsh "$MSN_SCRIPT" --apply "$1"
  }
  rename_calls() { grep -c 'rename-session' "$MSN_LOG" || true; }
  short_help_matches() {
    [[ "$(zsh "$MSN_SCRIPT" -h)" == "$(zsh "$MSN_SCRIPT" --help)" ]]
  }
  completed_sessions() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND=tmux MUX_TMUX_BIN="$MSN_TMP/tmux" \
      zsh -f -c '
        _arguments() { :; }
        _describe() {
          local array_name="${@[-1]}"
          print -l -- "${(@P)array_name}"
        }
        source "$1"
        __mux-random-session-name-sessions
      ' zsh "$MSN_COMPLETION"
  }

  It 'documents generation, mutation, backend selection, output, and failures'
    When call zsh "$MSN_SCRIPT" --help
    The status should be success
    The output should include "DESCRIPTION"
    The output should include "MUTATING MODES"
    The output should include "BACKEND SELECTION"
    The output should include "OUTPUT"
    The output should include "EXIT STATUS"
    The output should include "EXAMPLES"
    The output should include "--apply-current"
    The output should include "--apply SESSION"
    The output should include "no session is changed"
  End

  It 'provides identical short and long help'
    When call short_help_matches
    The status should be success
  End

  It 'ships zsh completion for every option'
    When call zsh -n "$MSN_COMPLETION"
    The status should be success
    The contents of file "$MSN_COMPLETION" should include "#compdef mux-random-session-name"
    The contents of file "$MSN_COMPLETION" should include "--apply-current"
    The contents of file "$MSN_COMPLETION" should include "--apply["
    The contents of file "$MSN_COMPLETION" should include "{-h,--help}"
  End

  It 'completes named application from live mux sessions'
    When call completed_sessions
    The status should be success
    The output should equal "old-name"
  End

  It 'prints an unused adjective-noun name without mutating a session'
    When call generate
    The status should be success
    The output should match pattern "*-*"
    The output should not equal "old-name"
    The contents of file "$MSN_LOG" should equal ""
  End

  # MUX_LIB is a DIRECTORY everywhere else (mux-rename's Alt+r roll,
  # mux-new-session export it as the lib dir). Treating it as a file here made
  # an inherited directory-shaped MUX_LIB source nothing, so the first mux::*
  # call died with `command not found: mux::backend`.
  It 'loads the library when MUX_LIB is the directory it is elsewhere'
    generate_dir_lib() {
      env MUX_LIB="$PWD/home/dot_local/lib" MUX_BACKEND=tmux \
        MUX_TMUX_BIN="$MSN_TMP/tmux" zsh "$MSN_SCRIPT"
    }
    When call generate_dir_lib
    The status should be success
    The output should match pattern "*-*"
    The error should not include "command not found"
  End

  It 'renames the current tmux session only with explicit mutation'
    When call apply_tmux_current
    The status should be success
    The output should match pattern "*-*"
    The contents of file "$MSN_LOG" should match pattern "rename-session *-*"
    The contents of file "$MSN_LOG" should not include "rename-session -t"
  End

  It 'renames a specified tmux session through an explicit socket'
    When call apply_tmux_target 0
    The status should be success
    The output should match pattern "*-*"
    The contents of file "$MSN_LOG" should match pattern "rename-session -t =0 *-*"
  End

  It 'retries when the backend reports a racing name collision'
    export STUB_COLLIDE_ONCE=1
    When call apply_tmux_target old-name
    The status should be success
    The result of function rename_calls should equal 2
  End

  It 'refreshes attached tmux clients after applying a name'
    export STUB_CLIENT_TTY=/dev/ttys001
    When call apply_tmux_target old-name
    The status should be success
    The output should match pattern "*-*"
    The contents of file "$MSN_LOG" should include "refresh-client -S -t /dev/ttys001"
  End

  It 'rejects current-session mutation outside a mux'
    When call env MUX_LIB="$MSN_LIB" zsh "$MSN_SCRIPT" --apply-current
    The status should be failure
    The error should include "requires a mux session"
  End

  It 'renames the current Zellij session through the mux API'
    When call apply_zellij_current
    The status should be success
    The output should match pattern "*-*"
    The contents of file "$MSN_LOG" should match pattern "action rename-session *-*"
    The contents of file "$MSN_LOG" should not include "--session"
  End

  It 'targets a named Zellij session through the global selector'
    When call apply_zellij_target old-name
    The status should be success
    The output should match pattern "*-*"
    The contents of file "$MSN_LOG" should match pattern "--session old-name action rename-session *-*"
  End

  It 'installs a numeric-only automatic tmux naming hook'
    When call sh -c "chezmoi execute-template <home/dot_config/tmux/tmux.conf.tmpl | grep 'set-hook -g after-new-session'"
    The status should be success
    The output should include "m/r:^[0-9]+$"
    The output should include ".local/bin/mux-random-session-name --apply"
    The output should not include ".local/bin/mux-session-name"
  End
End
