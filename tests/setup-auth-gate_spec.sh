# Tests for .setup.sh's interactive auth gates (HI-11).
#
# .setup.sh is the `curl -fsSL …/.setup.sh | bash` install entrypoint. Under
# that invocation stdin IS the piped script text, so a bare `read` inside the
# 1Password / gh auth loops would consume the rest of the script; under
# `set -e` the read's EOF then exits 1 silently, before `chezmoi apply` ever
# runs. The fix gates both loops on an interactive TTY and reads any prompt
# from /dev/tty, so a piped stdin can never be swallowed.
#
# The gate block has no functions to source, so instead of copying it we
# extract the *actual* two-gate block from the real file at test time and run
# it in a fresh `bash` whose stdin carries the block PLUS stand-ins for "the
# rest of the script" — exactly how bash reads a piped script. If the gate's
# read swallows the stream, those trailing lines never execute.
Describe '.setup.sh: interactive auth gates (HI-11)'
  SETUP="$SHELLSPEC_PROJECT_ROOT/.setup.sh"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/setup-gate.XXXXXX")"
    mkdir -p "$WORK/bin"
  }
  cleanup() { rm -rf "$WORK"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Write fake op/gh onto PATH. $1/$2 are their exit codes (1 == "not
  # authenticated / integration disabled", the fresh-Mac state).
  stub_clis() {
    printf '#!/bin/sh\nexit %s\n' "$1" > "$WORK/bin/op"
    printf '#!/bin/sh\nexit %s\n' "$2" > "$WORK/bin/gh"
    chmod +x "$WORK/bin/op" "$WORK/bin/gh"
  }

  # Run the real gate block the way `curl | bash` runs the whole script:
  # `set -eufo pipefail` + the extracted block + stand-ins for the remaining
  # script body, all fed to `bash -s` on one stdin stream. REACHED_APPLY
  # stands in for the later `chezmoi apply`; the SENTINEL_BODY lines stand in
  # for any further script text a runaway read would eat.
  run_gate() {
    awk '/^# Interactive auth gates\./{p=1} /^# Self-onboard/{p=0} p' \
      "$SETUP" > "$WORK/block.sh"
    {
      echo 'set -eufo pipefail'
      cat "$WORK/block.sh"
      echo 'echo REACHED_APPLY'
      echo 'echo SENTINEL_BODY_1'
    } > "$WORK/piped.sh"
    PATH="$WORK/bin:$PATH" bash -s < "$WORK/piped.sh"
  }

  Describe 'no TTY (curl | bash) with op/gh not authenticated'
    It 'skips the gates with an actionable hint instead of dying, and never eats the piped script body'
      stub_clis 1 1
      When call run_gate
      The status should be success
      # The bug: these never appeared because `read` ate them / set -e exited.
      The output should include 'REACHED_APPLY'
      The output should include 'SENTINEL_BODY_1'
      # Actionable, one-time hints for both gates.
      The output should include 'op signin'
      The output should include 'gh auth login'
      # The interactive prompt must NOT fire in the no-TTY path.
      The output should not include 'Press [Enter]'
    End

    It 'hints instead of looping when op and gh are not installed at all'
      # `When call` re-redirects stdin internally (to /dev/null or /dev/tty),
      # discarding an inline `< file` written on the `When` line itself —
      # so, like run_gate above, the redirection into `bash -s` has to
      # happen inside a wrapper function instead.
      run_gate_absent() {
        awk '/^# Interactive auth gates\./{p=1} /^# Self-onboard/{p=0} p' "$SETUP" > "$WORK/block.sh"
        { echo 'set -eufo pipefail'; cat "$WORK/block.sh"; echo 'echo REACHED_APPLY'; } > "$WORK/piped.sh"
        env PATH="/usr/bin:/bin" bash -s < "$WORK/piped.sh"
      }
      When call run_gate_absent
      The status should be success
      The output should include 'op signin'
      The output should include 'gh auth login'
      The output should include 'REACHED_APPLY'
    End
  End

  Describe 'checks already satisfied'
    It 'confirms both gates and proceeds without prompting or consuming stdin'
      stub_clis 0 0
      When call run_gate
      The status should be success
      The output should include '1Password CLI is already integrated'
      The output should include 'GitHub CLI is authenticated'
      The output should include 'REACHED_APPLY'
      The output should include 'SENTINEL_BODY_1'
    End
  End

  Describe 'source guard against regression'
    It 'reads the interactive prompt from /dev/tty, not stdin'
      When call grep -F 'read -r -p "Press [Enter]' "$SETUP"
      The status should be success
      The output should include '</dev/tty'
    End
  End
End

# The two-axis bootstrap: --profile replaces --work/--personal; platform
# (uname) picks the installers; kind (asked of the repo) picks the lifecycle.
# Blocks are extracted from the real file by their section markers and run
# under `bash -s`, exactly like `curl | bash`.
Describe '.setup.sh: --profile and the two-axis structure'
  SETUP="$SHELLSPEC_PROJECT_ROOT/.setup.sh"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/setup-axes.XXXXXX")"
    mkdir -p "$WORK/bin" "$WORK/home"
  }
  cleanup() { rm -rf "$WORK"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  stub_uname() {   # <Darwin|Linux>
    printf '#!/bin/sh\necho %s\n' "$1" >"$WORK/bin/uname"
    chmod +x "$WORK/bin/uname"
  }

  # run_args <args…> — the arguments block + a probe line, piped to bash -s.
  run_args() {
    awk '/^# --- arguments/{p=1} /^# --- platform prerequisites/{p=0} p' "$SETUP" >"$WORK/block.sh"
    { echo 'set -eufo pipefail'; cat "$WORK/block.sh"; echo 'echo "PROFILE=${CHEZMOI_PROFILE:-unset}"'; } >"$WORK/piped.sh"
    PATH="$WORK/bin:$PATH" bash -s -- "$@" <"$WORK/piped.sh"
  }

  Describe 'arguments'
    It 'exports the profile from --profile'
      stub_uname Darwin
      When call run_args --profile server
      The status should be success
      The output should include 'PROFILE=server'
    End

    It 'accepts the --profile=<p> form'
      stub_uname Darwin
      When call run_args --profile=work
      The status should be success
      The output should include 'PROFILE=work'
    End

    It 'rejects the retired --work flag'
      stub_uname Darwin
      When call run_args --work
      The status should be failure
      The stderr should include 'Unknown argument: --work'
    End

    It 'rejects any unknown flag'
      stub_uname Darwin
      When call run_args --bogus
      The status should be failure
      The stderr should include 'Unknown argument'
    End

    It 'keeps the documented personal default on darwin with no flag and no TTY'
      stub_uname Darwin
      When call run_args
      The status should be success
      The output should include 'PROFILE=personal'
    End

    It 'refuses on Linux with no flag and no TTY (a server must be explicit)'
      stub_uname Linux
      When call run_args
      The status should be failure
      The stderr should include 'must name its profile'
    End
  End

  # run_lifecycle <headless true|false> — the kind-lookup block through EOF,
  # with a stub chezmoi and NO op/gh/brew/system-onboard on PATH.
  run_lifecycle() {
    cat >"$WORK/bin/chezmoi" <<'STUB'
#!/bin/sh
case "$1" in
  execute-template)
    case "$2" in *includeTemplate*) echo "$STUB_HEADLESS" ;; *) echo "someprofile" ;; esac ;;
  apply) [ $# -eq 1 ] && echo APPLY_RAN ;;
esac
exit 0
STUB
    chmod +x "$WORK/bin/chezmoi"
    awk '/^# --- kind lookup/{p=1} p' "$SETUP" >"$WORK/block.sh"
    { echo 'set -eufo pipefail'; cat "$WORK/block.sh"; } >"$WORK/piped.sh"
    STUB_HEADLESS="$1" HOME="$WORK/home" PATH="$WORK/bin:/usr/bin:/bin" bash -s <"$WORK/piped.sh"
  }

  Describe 'lifecycle'
    It 'headless: stops with the operator command and never applies'
      When call run_lifecycle true
      The status should be success
      The output should include 'system-onboard --alias'
      The output should include '--profile someprofile'
      The output should not include 'APPLY_RAN'
    End

    It 'human: skips absent brew/op/gh with hints and reaches the apply'
      When call run_lifecycle false
      The status should be success
      The output should include 'op signin'
      The output should include 'gh auth login'
      The output should include 'APPLY_RAN'
      The output should not include 'Press [Enter]'
    End
  End

  Describe 'source guards'
    It 'never names dev-shell or server: the kind is asked of the repo, not tabulated here'
      When call grep -nE 'dev-shell|server' "$SETUP"
      The status should be failure
    End

    It 'names personal only on the two documented macOS no-TTY default lines'
      # The export and the echo right after it — the spec-sanctioned macOS
      # `curl | bash` default when there is no --profile and no TTY. Any
      # other count means either a regression (a profile name leaked into
      # prose again) or a legitimate new sanctioned line that this guard
      # must be updated to expect.
      When call grep -cw personal "$SETUP"
      The status should be success
      The output should equal '2'
    End

    It 'asks profile-traits.tmpl for the kind'
      When call grep -F 'includeTemplate "profile-traits.tmpl"' "$SETUP"
      The status should be success
      The output should include 'includeTemplate "profile-traits.tmpl"'
    End
  End
End
