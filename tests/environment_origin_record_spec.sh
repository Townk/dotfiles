# environment.sh's peer-alias recorder (peer-alias spec H4): at the top of the
# over-SSH branch, a valid LC_ORIGIN_HOST + LC_ORIGIN_ALIAS pair is written to
# $XDG_STATE_HOME/hosts/aliases — one line per key, only when new or changed.
# Sourced under /bin/sh with env -i and a temp $HOME, like environment_spec.sh,
# so the real state dir is never touched.
Describe 'environment.sh peer-alias recorder'
  ENV_SH="home/dot_config/zsh/environment.sh"

  setup() {
    ISO_HOME="$(mktemp -d)"
    MAP="$ISO_HOME/.local/state/hosts/aliases"
  }
  cleanup() { rm -rf "$ISO_HOME"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # login <ssh-connection> <origin-host> <origin-alias> — one login shell.
  # Arguments are built with `set --` so a value containing spaces stays ONE
  # env assignment (an unquoted ${2:+…} would split 'a b' into a command).
  login() {
    _c=$1 _h=$2 _a=$3
    set -- PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$ISO_HOME" TMPDIR="$ISO_HOME/tmp" SSH_CONNECTION="$_c"
    [ -n "$_h" ] && set -- "$@" "LC_ORIGIN_HOST=$_h"
    [ -n "$_a" ] && set -- "$@" "LC_ORIGIN_ALIAS=$_a"
    [ -n "${LOGIN_LOCALE:-}" ] && set -- "$@" "LC_ALL=$LOGIN_LOCALE"
    env -i "$@" sh -c 'mkdir -p "$TMPDIR" 2>/dev/null; . '"$ENV_SH"
  }
  login_q() { login "$@" >/dev/null 2>&1; }
  SSHC="192.0.2.10 50000 192.0.2.20 22"

  It 'records a valid pair on an SSH login'
    login_q "$SSHC" peer-key-01 peer-laptop
    When call cat "$MAP"
    The output should equal 'peer-key-01 peer-laptop'
  End

  It 'writes the map with mode 600'
    login_q "$SSHC" peer-key-01 peer-laptop
    When call sh -c 'ls -l "$1" | cut -c1-10' _ "$MAP"
    The output should equal '-rw-------'
  End

  It 'replaces the line when the alias changes, keeping one line per key'
    login_q "$SSHC" peer-key-01 old-name
    login_q "$SSHC" peer-key-01 new-name
    When call cat "$MAP"
    The output should equal 'peer-key-01 new-name'
  End

  It 'keeps other machines when one changes'
    login_q "$SSHC" peer-key-01 peer-laptop
    login_q "$SSHC" build-7.lan build-box
    When call sort "$MAP"
    The line 1 of output should equal 'build-7.lan build-box'
    The line 2 of output should equal 'peer-key-01 peer-laptop'
  End

  # Review Focus: tmux panes re-run this on every shell.
  It 'leaves the map untouched on an identical login'
    login_q "$SSHC" peer-key-01 peer-laptop
    touch -t 200001010000 "$MAP"
    touch -t 200001010001 "$ISO_HOME/ref"
    login_q "$SSHC" peer-key-01 peer-laptop
    When call find "$MAP" -newer "$ISO_HOME/ref"
    The output should equal ''
  End

  Describe 'invalid pairs'
    Parameters
      'a b'   peer-laptop
      'x;rm'  peer-laptop
      peer-key-01 'bad alias'
      peer-key-01 "quo'te"
      kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk peer-laptop
    End
    It "rejects an invalid pair ($1 / $2)"
      login_q "$SSHC" "$1" "$2"
      When call test -e "$MAP"
      The status should be failure
    End
  End

  # Under a UTF-8 locale bash 3.2 (macOS /bin/sh) matches [A-Za-z] by collation,
  # so accented letters slipped through the value rule.
  It 'rejects non-ASCII letters under a UTF-8 locale'
    LOGIN_LOCALE=en_US.UTF-8
    login_q "$SSHC" 'péer-key' peer-laptop
    login_q "$SSHC" peer-key-01 'Ärger'
    LOGIN_LOCALE=
    When call test -e "$MAP"
    The status should be failure
  End

  # grep would read a key starting with '-' as an option without -e.
  It 'leaves the map untouched on an identical login with a dash-leading key'
    login_q "$SSHC" -v-key peer-laptop
    touch -t 200001010000 "$MAP"
    touch -t 200001010001 "$ISO_HOME/ref"
    login_q "$SSHC" -v-key peer-laptop
    When call find "$MAP" -newer "$ISO_HOME/ref"
    The output should equal ''
  End

  It 'ignores a lone LC_ORIGIN_HOST'
    login_q "$SSHC" peer-key-01 ''
    When call test -e "$MAP"
    The status should be failure
  End

  # Review Focus: a console shell inheriting LC_ORIGIN_* from an SSH-born tmux
  # server, with the SSH_* markers gone, is local — nothing to learn.
  It 'writes nothing in a local shell even with LC_ORIGIN_* set'
    login_q '' peer-key-01 peer-laptop
    When call test -e "$MAP"
    The status should be failure
  End

  # Review Focus: an unwritable state dir must not break or pollute the login,
  # even for a sourcing shell running under `set -e`.
  It 'stays silent and non-fatal when the map cannot be written'
    mkdir -p "$ISO_HOME/.local/state"
    : >"$ISO_HOME/.local/state/hosts"
    When call env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$ISO_HOME" \
      SSH_CONNECTION="$SSHC" LC_ORIGIN_HOST=peer-key-01 LC_ORIGIN_ALIAS=peer-laptop \
      sh -c 'set -e; . '"$ENV_SH"'; echo reached'
    The status should be success
    The output should equal 'reached'
    The stderr should equal ''
  End
End
