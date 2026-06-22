# Tests for home/dot_local/libexec/executable_ai-assist-summon: the interactive
# entry point behind the Ctrl+Alt+A trigger. It captures context, builds the
# partial request.json, then — only inside Zellij — creates the framed fifo pair
# and spawns the float + detached orchestrator.
#
# These cover the OFF-Zellij early-exit path, which is the live Ctrl+Alt+A path
# the headless suites otherwise stub past. summon runs under `set -eu -o
# pipefail` and calls `zj::available`, defined in lib/zellij.zsh; if that lib is
# not sourced the call aborts with `command not found`. And the fifo pair must
# be created only AFTER the guard, so the off-Zellij exit leaks nothing.
Describe 'ai-assist-summon'
  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export XDG_DATA_HOME="$TEST_TMP/data"
    export AI_ASSIST_SESSION="testsess"
    export AI_ASSIST_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    mkdir -p "$HOME"

    # summon sources libs by the literal "$HOME/.local/lib/..." path, so mirror
    # the real layout into the test HOME.
    mkdir -p "$HOME/.local/lib"
    cp "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/"*.zsh "$HOME/.local/lib/"

    # A dedicated TMPDIR so we can assert the fifo pair never appears here on the
    # off-Zellij path. summon mints fifo names under "${TMPDIR:-/tmp}".
    export TMPDIR="$TEST_TMP/tmp"
    mkdir -p "$TMPDIR"

    # Off-Zellij: ZELLIJ unset (spec_helper already unsets it, but be explicit).
    unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME

    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-summon"

    # Stub atuin so assist::capture_command resolves to a benign question row
    # (command / exit / directory / duration) without touching the real history.
    atuinstub="$TEST_TMP/atuin"
    {
      echo '#!/usr/bin/env zsh'
      echo 'printf "%s\t%s\t%s\t%s\n" "echo hi" "0" "/tmp/proj" "12"'
    } > "$atuinstub"; chmod +x "$atuinstub"
    export ATUIN_BIN="$atuinstub"

    # Ensure no zellij binary resolves (ZELLIJ unset already short-circuits
    # zj::available, but keep the env hermetic).
    unset ZELLIJ_BIN
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'exits 0 cleanly off-Zellij (zj::available guard fires, no command-not-found)'
    When run script "$SCRIPT"
    The status should be success
    # The bug symptom: zj::available unresolved → `command not found` on stderr.
    The stderr should not include "command not found"
    The stderr should not include "zj::available"
  End

  It 'leaves NO leftover fifos in TMPDIR on the off-Zellij path'
    When run script "$SCRIPT"
    The status should be success
    # Fifos are created only AFTER the in-Zellij guard, so the early-exit path
    # must mint none. Assert the TMPDIR holds no ai-assist fifo artifacts.
    The path "$TMPDIR" should be exist
    leftover_fifos() { print -r -- "$TMPDIR"/ai-assist-*(N); }
    The result of function leftover_fifos should equal ""
  End

  It 'spawns the float as a BORDERLESS pane (in-Zellij)'
    # Regression guard: the orchestrated float must pass `--borderless true` (the
    # widget draws its own frame); a missing flag reintroduces the Zellij border.
    export ZELLIJ=1 ZELLIJ_PANE_ID=0 ZELLIJ_SESSION_NAME=s
    capture="$TEST_TMP/newpane.args"

    # Fake zellij: record the `new-pane` invocation's args.
    zjstub="$TEST_TMP/zellij"
    { print -r -- '#!/usr/bin/env zsh'; print -r -- "print -r -- \"\$*\" >> \"$capture\""; } > "$zjstub"
    chmod +x "$zjstub"; export ZELLIJ_BIN="$zjstub"

    # Fake the input binary: --measure must yield a plain integer.
    aiistub="$TEST_TMP/ai-assist-input"
    { print -r -- '#!/usr/bin/env zsh'; print -r -- 'print -r -- 9'; } > "$aiistub"
    chmod +x "$aiistub"; export AI_ASSIST_INPUT_BIN="$aiistub"

    # Run a COPY of summon from a temp libexec so its sibling orchestrator is a
    # no-op stub (the real ai-assist-triage would block on the OUT fifo).
    libexec="$HOME/.local/libexec"; mkdir -p "$libexec"
    cp "$SCRIPT" "$libexec/ai-assist-summon"
    { print -r -- '#!/usr/bin/env zsh'; print -r -- 'exit 0'; } > "$libexec/ai-assist-triage"
    chmod +x "$libexec/ai-assist-triage"

    When run script "$libexec/ai-assist-summon"
    The status should be success
    cap() { cat "$capture" 2>/dev/null; }
    The result of function cap should include "new-pane"
    The result of function cap should include "--borderless true"
  End

  It 'pre-fills the float with a ready-to-submit request after a failed command'
    # After an error, the box should carry a request the user can submit with one
    # Enter (e.g. "Diagnose and fix why `gg build` failed …") — not be empty.
    export ZELLIJ=1 ZELLIJ_PANE_ID=0 ZELLIJ_SESSION_NAME=s
    capture="$TEST_TMP/newpane.args"

    # atuin reports a FAILED command → CAP_KIND=error → prefill_template fires.
    atuinerr="$TEST_TMP/atuin-err"
    { print -r -- '#!/usr/bin/env zsh'
      print -r -- 'printf "%s\t%s\t%s\t%s\n" "gg build" "1" "/tmp/SandboxApp" "42"'
    } > "$atuinerr"; chmod +x "$atuinerr"; export ATUIN_BIN="$atuinerr"

    zjstub="$TEST_TMP/zellij"
    { print -r -- '#!/usr/bin/env zsh'; print -r -- "print -r -- \"\$*\" >> \"$capture\""; } > "$zjstub"
    chmod +x "$zjstub"; export ZELLIJ_BIN="$zjstub"
    aiistub="$TEST_TMP/ai-assist-input"
    { print -r -- '#!/usr/bin/env zsh'; print -r -- 'print -r -- 9'; } > "$aiistub"
    chmod +x "$aiistub"; export AI_ASSIST_INPUT_BIN="$aiistub"
    libexec="$HOME/.local/libexec"; mkdir -p "$libexec"
    cp "$SCRIPT" "$libexec/ai-assist-summon"
    { print -r -- '#!/usr/bin/env zsh'; print -r -- 'exit 0'; } > "$libexec/ai-assist-triage"
    chmod +x "$libexec/ai-assist-triage"

    When run script "$libexec/ai-assist-summon"
    The status should be success
    cap() { cat "$capture" 2>/dev/null; }
    The result of function cap should include "--value"
    The result of function cap should include "Diagnose and fix why"
    The result of function cap should include "gg build"
  End
End
