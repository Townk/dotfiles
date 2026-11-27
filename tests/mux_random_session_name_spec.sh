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
    [[ -z "${STUB_LIST_FAILS:-}" ]] || exit 1
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

    # Rex: `ls --json` answers from STUB_SESSIONS (labels), or fails the way
    # the CLI does with no server to talk to.
    cat >"$MSN_TMP/rex" <<'ZSH'
#!/usr/bin/env zsh
print -r -- "$*" >>"$MSN_LOG"
case "$*" in
  *"ls --json"*)
    [[ -z "${STUB_LIST_FAILS:-}" ]] || exit 4
    print -l -- "${(@f)STUB_SESSIONS}" | jq -R '{label: .}' | jq -s '{sessions: .}'
    ;;
esac
ZSH
    chmod +x "$MSN_TMP/rex"
  }
  cleanup() {
    rm -rf "$MSN_TMP"
    unset MSN_LOG STUB_SESSIONS STUB_COLLIDE_ONCE STUB_CLIENT_TTY STUB_LIST_FAILS
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

  generate_title() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND=tmux MUX_TMUX_BIN="$MSN_TMP/tmux" \
      zsh "$MSN_SCRIPT" --title "$@"
  }
  # Every Title Case name the script can produce, one per line, read from the
  # script's own word lists so the two cannot drift.
  all_title_names() {
    zsh -f -c '
      src=$(<"$1")
      adjectives=(${=${${src#*adjectives=\(}%%\)*}})
      nouns=(${=${${src#*nouns=\(}%%\)*}})
      for a in $adjectives; do for n in $nouns; do print -r -- "${(C)a} ${(C)n}"; done; done
    ' zsh "$MSN_SCRIPT"
  }

  It 'prints a Title Case name with --title'
    When call generate_title
    The status should be success
    The output should match pattern '[A-Z][a-z]* [A-Z][a-z]*'
    The lines of output should equal 1
  End

  It 'changes no session with --title'
    title_then_calls() { generate_title >/dev/null; rename_calls; }
    When call title_then_calls
    The output should equal "0"
  End

  # Review focus: "unused" is checked against the form that is printed. With
  # every Title Case name taken except the Zippy ones, a Zippy one is the only
  # possible answer. (One adjective in 65 is left free rather than one name in
  # 4,000: the script gives up after 1,000 draws.)
  It 'skips a name whose Title Case form is taken'
    only_zippy_free() {
      export STUB_SESSIONS="$(all_title_names | grep -v '^Zippy ')"
      generate_title
    }
    When call only_zippy_free
    The status should be success
    The output should start with "Zippy "
  End

  It 'still treats a hyphenated name as free when only --title names are taken'
    lower_free() {
      export STUB_SESSIONS="$(all_title_names)"
      generate
    }
    When call lower_free
    The status should be success
    The output should match pattern '[a-z]*-[a-z]*'
  End

  # Rex accepts two sessions with the same label, so there the check against
  # the listing is the only thing that keeps a name unique. A listing that
  # FAILED is not an empty one: the script must say it could not check
  # (status 3, no name) rather than print a name it never compared.
  generate_rex() {
    env MUX_LIB="$MSN_LIB" MUX_BACKEND= TMUX= REX_SESSION=session:here \
      MUX_REX_BIN="$MSN_TMP/rex" zsh "$MSN_SCRIPT" "$@"
  }
  unguarded_rex_calls() { grep -v -c -- '--autostart=false' "$MSN_LOG" || true; }

  It 'prints no name, with status 3, when --title cannot list the sessions'
    export STUB_LIST_FAILS=1
    When call generate_title
    The status should equal 3
    The output should equal ""
    The stderr should include "could not list the sessions"
  End

  It 'prints no name, with status 3, when a Rex listing fails'
    export STUB_LIST_FAILS=1
    When call generate_rex --title
    The status should equal 3
    The output should equal ""
    The stderr should include "could not list the sessions"
  End

  It 'does the same for a hyphenated name on Rex'
    export STUB_LIST_FAILS=1
    When call generate_rex
    The status should equal 3
    The output should equal ""
    The stderr should include "could not list the sessions"
  End

  It 'checks a --title name against the Rex listing when it can be read'
    only_zippy_free() {
      export STUB_SESSIONS="$(all_title_names | grep -v '^Zippy ')"
      generate_rex --title
    }
    When call only_zippy_free
    The status should be success
    The output should start with "Zippy "
  End

  It 'never calls rex without --autostart=false'
    calls() { generate_rex --title >/dev/null; unguarded_rex_calls; grep -c . "$MSN_LOG"; }
    When call calls
    The output should equal "0
1"
  End

  # tmux refuses a duplicate name itself, and a listing that
  # fails there is the ordinary "no server, so no sessions" — still a name.
  It 'still prints a hyphenated name when a tmux listing fails'
    export STUB_LIST_FAILS=1
    When call generate
    The status should be success
    The output should match pattern '[a-z]*-[a-z]*'
  End

  It 'documents the could-not-check status'
    When call zsh "$MSN_SCRIPT" --help
    The output should include "3  The sessions could not be listed"
  End

  It 'rejects --title with --apply-current'
    When call generate_title --apply-current
    The status should equal 2
    The stderr should include "--title"
  End

  It 'documents --title'
    When call zsh "$MSN_SCRIPT" --help
    The output should include "--title"
    The output should include "Wandering Glade"
  End

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

  It 'installs a numeric-only automatic tmux naming hook'
    When call sh -c "chezmoi execute-template <home/dot_config/tmux/tmux.conf.tmpl | grep 'set-hook -g after-new-session'"
    The status should be success
    The output should include "m/r:^[0-9]+$"
    The output should include ".local/bin/mux-random-session-name --apply"
    The output should not include ".local/bin/mux-session-name"
  End
End
