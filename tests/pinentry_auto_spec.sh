# Tests for home/dot_local/libexec/executable_pinentry-auto — gpg-agent's
# `pinentry-program` dispatcher.
#
# Scope is the USE_CURSES lane, the one this repo changed when the mux float
# landed: it now goes to pinentry-mux, which decides in turn between a float
# (agent pane) and the in-pane prompt (everyone else). The regression that
# matters is a half-applied dotfiles tree — pinentry-auto present, pinentry-mux
# not yet written — which must still sign rather than exec a missing file.
#
# The VNC and Touch ID branches are deliberately NOT exercised. They exec
# absolute /opt/homebrew paths with no test seam, and running pinentry-touchid
# for real would raise a biometric prompt on the machine running the suite.
# They are also untouched by this work; adding seams to them to satisfy a test
# would be a wider change than the change under test.
Describe 'pinentry-auto dispatch'
  PA="home/dot_local/libexec/executable_pinentry-auto"

  setup() {
    PA_HOME=$(mktemp -d)
    mkdir -p "$PA_HOME/.local/libexec"
  }
  cleanup() { rm -rf "$PA_HOME"; unset PA_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  install_mux() {
    cat >"$PA_HOME/.local/libexec/pinentry-mux" <<'EOS'
#!/bin/sh
echo "MUX ARGS:$*"
EOS
    chmod +x "$PA_HOME/.local/libexec/pinentry-mux"
  }

  # BYE on stdin so that the branches which reach a REAL pinentry answer and
  # exit instead of waiting on a terminal that is not there.
  dispatch() { printf 'BYE\n' | env HOME="$PA_HOME" PINENTRY_USER_DATA="$1" sh "$PA" "${@:2}"; }

  It 'sends an SSH session to pinentry-mux'
    install_mux
    When call dispatch "USE_CURSES=1"
    The output should include "MUX ARGS:"
    The status should be success
  End

  It 'forwards its arguments to pinentry-mux untouched'
    install_mux
    When call dispatch "USE_CURSES=1" --display :0 --lc-ctype UTF-8
    The output should include "MUX ARGS:--display :0 --lc-ctype UTF-8"
  End

  # Not a fallback shim for a path that no longer exists — the two files are
  # separate chezmoi targets, so "one applied, one not" is a state a real
  # machine can be in, and signing should survive it.
  It 'falls back to the real curses pinentry when the wrapper is missing'
    When call dispatch "USE_CURSES=1"
    The output should include "closing connection"
    The status should be success
  End
End
