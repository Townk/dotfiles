# Tests for home/dot_local/libexec/executable_pinentry-auto — gpg-agent's
# `pinentry-program` dispatcher.
#
# Scope is the USE_CURSES lane, the one this repo changed when the mux float
# landed: it goes to pinentry-ui, which decides in turn between a float (agent
# pane) and the in-pane prompt (everyone else). The regression that matters is
# a host that has the dotfiles but not the binary — pinentry-ui is compiled by
# `make -C custom-builds/pinentry-ui install` and nothing in this repo builds
# automatically, so "dispatcher present, binary absent" is the NORMAL state of
# a freshly provisioned machine. It must sign rather than exec a missing file.
# That same fall-through is the last line of the blast-radius rule in
# docs/pinentry-ui-design.md: no front-end may become the only way to
# authenticate.
#
# The VNC and Touch ID branches are deliberately NOT exercised. Reaching either
# means getting `viewing_over_vnc` to answer a chosen way, and it probes
# /usr/sbin/netstat by absolute path with no seam — while running
# pinentry-touchid for real would raise a biometric prompt on the machine
# running the suite. Adding seams to production code that exist only for a test
# would be a wider change than the change under test.
#
# The VNC lane now prefers pinentry-ui too, with the same `[ -x ]` guard and the
# same pinentry-mac fall-through, so what the cases below prove about the guard
# holds for it as well. What is genuinely untested here is the choice pinentry-ui
# then makes with no terminal in hand; that lives in its own suite, as
# `a_getpin_with_no_terminal_is_handed_to_the_gui`.
Describe 'pinentry-auto dispatch'
  PA="home/dot_local/libexec/executable_pinentry-auto"

  setup() {
    PA_HOME=$(mktemp -d)
    mkdir -p "$PA_HOME/.local/libexec"
  }
  cleanup() { rm -rf "$PA_HOME"; unset PA_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  install_ui() {
    cat >"$PA_HOME/.local/libexec/pinentry-ui" <<'EOS'
#!/bin/sh
echo "UI ARGS:$*"
EOS
    chmod +x "$PA_HOME/.local/libexec/pinentry-ui"
  }

  # BYE on stdin so that the branches which reach a REAL pinentry answer and
  # exit instead of waiting on a terminal that is not there.
  dispatch() { printf 'BYE\n' | env HOME="$PA_HOME" PINENTRY_USER_DATA="$1" sh "$PA" "${@:2}"; }

  It 'sends an SSH session to pinentry-ui'
    install_ui
    When call dispatch "USE_CURSES=1"
    The output should include "UI ARGS:"
    The status should be success
  End

  It 'forwards its arguments to pinentry-ui untouched'
    install_ui
    When call dispatch "USE_CURSES=1" --display :0 --lc-ctype UTF-8
    The output should include "UI ARGS:--display :0 --lc-ctype UTF-8"
  End

  # Not a fallback shim for a path that no longer exists: pinentry-ui is a
  # compiled artefact and the dispatcher is a chezmoi target, so "dotfiles
  # applied, nothing built" is where every new host starts. Signing has to
  # survive it.
  It 'falls back to the real curses pinentry when the binary is not built'
    When call dispatch "USE_CURSES=1"
    The output should include "closing connection"
    The status should be success
  End
End

# The second personality. Invoked through the `askpass-auto` symlink it serves
# sudo, ssh and git instead of gpg-agent: prompt in argv, secret on stdout,
# non-zero for no answer (docs/askpass-design.md).
#
# Unlike the lanes above it is reachable in a test, because the branch is on
# `$0` and needs no VNC probe and no biometric prompt. Both cases here are the
# whole of it: this personality deliberately decides nothing else, leaving float
# versus GUI to pinentry-ui, which is the only one that can see whether a pane
# exists.
Describe 'askpass-auto dispatch'
  PA="home/dot_local/libexec/executable_pinentry-auto"

  setup() {
    PA_HOME=$(mktemp -d)
    mkdir -p "$PA_HOME/.local/libexec"
    # Invoked the way chezmoi installs it: a symlink whose basename is the
    # personality. Copied rather than linked to the source, so $0's basename is
    # the only thing under test.
    cp "$PA" "$PA_HOME/.local/libexec/pinentry-auto"
    chmod +x "$PA_HOME/.local/libexec/pinentry-auto"
    ln -s "$PA_HOME/.local/libexec/pinentry-auto" "$PA_HOME/askpass-auto"
  }
  cleanup() { rm -rf "$PA_HOME"; unset PA_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  ask() { env HOME="$PA_HOME" "$PA_HOME/askpass-auto" "$@"; }

  It 'hands the prompt to pinentry-ui in askpass mode'
    cat >"$PA_HOME/.local/libexec/pinentry-ui" <<'EOS'
#!/bin/sh
echo "UI ARGS:$*"
EOS
    chmod +x "$PA_HOME/.local/libexec/pinentry-ui"
    When call ask "Password:"
    The output should equal "UI ARGS:--askpass Password:"
    The status should be success
  End

  # Fails closed, and that is a cost rather than a nicety: with `sudo -A` there
  # is no prompt underneath, so this is sudo refusing to authenticate until you
  # type `\sudo`. Printing anything at all here would be worse — an empty line
  # on stdout is an empty password, which is an auth failure instead of a
  # retry.
  It 'says nothing and fails when pinentry-ui is not built'
    When call ask "Password:"
    The output should equal ""
    The status should be failure
  End
End
