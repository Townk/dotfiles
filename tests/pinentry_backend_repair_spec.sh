# Tests for home/dot_local/libexec/executable_pinentry-backend-repair — the one
# copy of "is pinentry-touchid's backend pinentry-mac, and if not, fix it" —
# and for the apply hook that calls it,
# home/.chezmoiscripts/run_after_26-fix-pinentry-touchid-symlink.sh.tmpl.
# (system-update's use of it is in system-update_spec.sh.)
#
# Nothing here reaches the real GPG prompt chain: gpgconf, brew,
# pinentry-touchid, pinentry-mac, timeout and defaults are all stubs on a PATH
# that otherwise holds only /usr/bin and /bin, and the "backend link" is a
# symlink in a scratch directory. Running the real `pinentry-touchid -fix`
# would re-point the machine's own pinentry; the real `defaults write` would
# change a preference.
Describe 'pinentry backend repair'
  HELPER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pinentry-backend-repair"
  HOOK_TMPL="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_after_26-fix-pinentry-touchid-symlink.sh.tmpl"

  Skip if "realpath(1) is needed to compare the links" [ ! -x /bin/realpath ] && [ ! -x /usr/bin/realpath ]

  # The stubs, the helper's installed copy and the rendered hook are the same
  # for every example: made once, each run once (macOS charges an inode's
  # first exec), then hard-linked into the example's own directories, where
  # an example may remove or replace any of them. The stubs find the
  # example's link, log and switches through the exported P_* variables.
  fixtures() {
    PB_FIX="$SHELLSPEC_TMPBASE/pb-fix"
    mkdir -p "$PB_FIX/bin" "$PB_FIX/ctl"
    spec_stub "$PB_FIX/bin" pinentry-mac
    spec_stub "$PB_FIX/bin" pinentry-curses
    # -fix repairs only when told to, and exits as told to.
    cat >"$PB_FIX/bin/pinentry-touchid" <<'SH'
#!/bin/sh
echo "pinentry-touchid $*" >>"$P_LOG"
[ "$1" = "-fix" ] || exit 0
[ -f "$P_CTL/repair" ] && ln -sf "$P_MAC" "$P_LINK"
[ -f "$P_CTL/fix-rc" ] && exit "$(cat "$P_CTL/fix-rc")"
exit 0
SH
    # gpgconf names the link unless told it cannot.
    cat >"$PB_FIX/bin/gpgconf" <<'SH'
#!/bin/sh
[ -f "$P_CTL/no-gpgconf" ] && exit 1
printf 'gpg:OpenPGP:/x/gpg\npinentry:Passphrase Entry:%s\n' "$P_LINK"
SH
    spec_stub "$PB_FIX/bin" brew 'echo "$P_KEG"'
    # Both spellings of timeout: log the limit, then run the command.
    cat >"$PB_FIX/bin/gtimeout" <<'SH'
#!/bin/sh
echo "${0##*/} $1" >>"$P_LOG"
shift
exec "$@"
SH
    cp "$PB_FIX/bin/gtimeout" "$PB_FIX/bin/timeout"
    cat >"$PB_FIX/bin/defaults" <<'SH'
#!/bin/sh
echo "defaults $*" >>"$P_LOG"
[ "$1" = read ] && { [ -f "$P_CTL/keychain-off" ] && echo 1; exit 0; }
exit 0
SH
    cp "$HELPER" "$PB_FIX/pinentry-backend-repair"
    chmod +x "$PB_FIX/bin"/* "$PB_FIX/pinentry-backend-repair"
    ( export P_MAC="$PB_FIX/bin/pinentry-mac" P_LINK="$PB_FIX/link" P_CTL="$PB_FIX/ctl" P_LOG=/dev/null P_KEG="$PB_FIX/keg"
      for stub in "$PB_FIX/bin"/*; do
        case ${stub:t} in *.log) ;; *timeout) "$stub" 0 true ;; *) "$stub" ;; esac
      done
      PATH="$PB_FIX/bin:/usr/bin:/bin" "$PB_FIX/pinentry-backend-repair" check
      rm -f "$PB_FIX/link" ) >/dev/null 2>&1
    [ "$(uname -s)" != Darwin ] || spec_render_template "$HOOK_TMPL" "$PB_FIX/hook.sh"
  }
  BeforeAll 'fixtures'

  setup() {
    spec_sandbox; PB_TMP=$SANDBOX
    PB_BIN="$PB_TMP/bin"
    PB_HOME="$PB_TMP/home"
    mkdir -p "$PB_BIN" "$PB_HOME/.local/libexec" "$PB_TMP/ctl" "$PB_TMP/keg/opt/pinentry/bin"
    export P_MAC="$PB_BIN/pinentry-mac" P_LINK="$PB_TMP/link" P_CTL="$PB_TMP/ctl" P_LOG="$PB_TMP/log" P_KEG="$PB_TMP/keg"
    : >"$P_LOG"
    ln "$PB_FIX/bin"/{pinentry-mac,pinentry-curses,pinentry-touchid,gpgconf,brew,gtimeout,timeout,defaults} "$PB_BIN/"
    ln -s "$PB_BIN/pinentry-curses" "$P_LINK"
    ln "$PB_FIX/pinentry-backend-repair" "$PB_HOME/.local/libexec/pinentry-backend-repair"
  }
  BeforeEach 'setup'

  helper() {
    env HOME="$PB_HOME" PATH="$PB_BIN:/usr/bin:/bin" sh "$HELPER" "$@"
    print -r -- "rc=$?"
  }
  log() { cat "$P_LOG"; }
  target() { print -r -- "${$(readlink "$P_LINK"):t}"; }

  Describe 'check'
    It 'is 1 when the link points at another pinentry'
      When call helper check
      The output should equal "rc=1"
    End

    It 'is 0 when the link resolves to pinentry-mac'
      ln -sf "$P_MAC" "$P_LINK"
      When call helper check
      The output should equal "rc=0"
    End

    It 'is 1 when the link is missing'
      rm -f "$P_LINK"
      When call helper check
      The output should equal "rc=1"
    End

    It 'falls back to the Homebrew keg path when gpgconf cannot say'
      touch "$P_CTL/no-gpgconf"
      ln -s "$P_MAC" "$P_KEG/opt/pinentry/bin/pinentry"
      When call helper check
      The output should equal "rc=0"
    End

    It 'is 2 without pinentry-touchid'
      rm -f "$PB_BIN/pinentry-touchid"
      When call helper check
      The output should equal "rc=2"
    End

    It 'is 2 without pinentry-mac'
      rm -f "$P_MAC"
      When call helper check
      The output should equal "rc=2"
    End

    It 'never runs pinentry-touchid'
      run() { helper check >/dev/null; log; }
      When call run
      The output should equal ""
    End
  End

  Describe 'fix'
    It 'runs -fix under a 20 s limit, preferring gtimeout'
      run() { helper fix; log; }
      When call run
      The output should equal "rc=0
gtimeout 20
pinentry-touchid -fix"
    End

    It 'uses timeout when there is no gtimeout'
      rm -f "$PB_BIN/gtimeout"
      run() { helper fix; log; }
      When call run
      The output should equal "rc=0
timeout 20
pinentry-touchid -fix"
    End

    # /usr/bin and /bin have no timeout on macOS; elsewhere this is the case
    # above again.
    It 'runs -fix unbounded when there is no timeout at all'
      rm -f "$PB_BIN/gtimeout" "$PB_BIN/timeout"
      run() { helper fix; log | grep -v '^timeout'; }
      When call run
      The output should equal "rc=0
pinentry-touchid -fix"
    End

    It 'passes on the exit status of -fix'
      print 3 >"$P_CTL/fix-rc"
      When call helper fix
      The output should equal "rc=3"
    End
  End

  It 'rejects anything else'
    When call helper
    The output should equal "rc=64"
    The error should include "usage: pinentry-backend-repair check|fix"
  End

  Describe 'the apply hook'
    Skip if "the hook renders to nothing off macOS" [ "$(uname -s)" != Darwin ]

    hook() {
      # Rendered once, in fixtures: the template has no per-example input.
      [ -s "$PB_FIX/hook.sh" ] && ln "$PB_FIX/hook.sh" "$PB_TMP/hook.sh" || return 1
      env HOME="$PB_HOME" PATH="$PB_BIN:/usr/bin:/bin" sh "$PB_TMP/hook.sh"
      print -r -- "rc=$? link=$(target)"
    }

    It 'repairs a wrong backend and says so'
      Skip if 'complete-only: the whole apply hook down its repair path: check, -fix under timeout, check again (some twenty-five processes)' spec_complete_only
      spec_complete_only && return 0
      touch "$P_CTL/repair" "$P_CTL/keychain-off"
      When call hook
      The output should equal "rc=0 link=pinentry-mac"
      The error should equal "pinentry-touchid: backend pinentry is not pinentry-mac; repairing symlink
pinentry-touchid: backend repaired -> pinentry-mac"
    End

    It 'reports a repair that did not take, without failing the apply'
      Skip if 'complete-only: the whole apply hook down its repair path: check, -fix under timeout, check again (some twenty-five processes)' spec_complete_only
      spec_complete_only && return 0
      touch "$P_CTL/keychain-off"
      print 1 >"$P_CTL/fix-rc"
      When call hook
      The output should equal "rc=0 link=pinentry-curses"
      The error should include "could not repair backend; run 'pinentry-touchid -fix' manually"
    End

    It 'leaves a correct backend alone, silently'
      touch "$P_CTL/keychain-off"
      ln -sf "$P_MAC" "$P_LINK"
      run() { hook; log; }
      When call run
      The output should equal "rc=0 link=pinentry-mac
defaults read org.gpgtools.common DisableKeychain"
    End

    It 'still turns off pinentry-mac keychain saving itself'
      ln -sf "$P_MAC" "$P_LINK"
      run() { hook 2>&1; log; }
      When call run
      The output should equal "pinentry-touchid: disabled pinentry-mac's own keychain saving
rc=0 link=pinentry-mac
defaults read org.gpgtools.common DisableKeychain
defaults write org.gpgtools.common DisableKeychain -bool yes"
    End

    It 'does nothing at all without pinentry-touchid'
      rm -f "$PB_BIN/pinentry-touchid"
      run() { hook; log; }
      When call run
      The output should equal "rc=0 link=pinentry-curses"
    End

    # Missing helper: the hook says so and leaves the link alone; it does not
    # run an unbounded -fix of its own.
    It 'skips the repair, with one line, when the helper is missing'
      rm -f "$PB_HOME/.local/libexec/pinentry-backend-repair"
      touch "$P_CTL/repair" "$P_CTL/keychain-off"
      run() { hook; grep -c 'pinentry-touchid' "$P_LOG" || true; }
      When call run
      The output should equal "rc=0 link=pinentry-curses
0"
      The error should equal "pinentry-touchid: $PB_HOME/.local/libexec/pinentry-backend-repair is missing; backend not checked"
    End
  End
End
