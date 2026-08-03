# Tests for prompt-common.zsh — masked secret entry tty lifecycle.
Describe 'prompt-common.zsh'

  Describe 'prompt::secret tty restore traps (MED-15)'
    # prompt::secret puts the controlling terminal into `-echo -icanon` and must
    # restore it on ANY exit — not only ^C. The buggy version trapped INT only,
    # so a TERM/HUP/QUIT (kill/timeout) or a normal EXIT at the masked prompt
    # left the tty with echo off, forcing the user to blind-type `stty sane`.
    #
    # The masked path hard-codes `</dev/tty`, so it is only reachable with a
    # real controlling terminal. We spawn the function under a zsh/zpty pty and
    # stub `stty` so that the moment the code flips the tty to `-echo` we (a)
    # dump the installed signal traps, then (b) send ourselves a real SIGTERM —
    # exactly the kill/timeout case from the bug. The restore then runs from the
    # TERM handler while `$__saved` is still in scope; the stub records that call
    # (its arg is the saved-modes token). Deterministic — the signal is raised
    # synchronously against a process we control, no timing sleep.
    #
    # (EXIT is also trapped for the same restore, but a per-function EXIT trap
    # fires at shell-exit when the function's locals are gone, so it is neither
    # visible in a nested `trap` dump nor able to expand `$__saved`; the signal
    # dispositions are what actually restore the tty on kill/timeout.)

    setup() {
      TEST_TMP="$(mktemp -d)"
      TRAPFILE="$TEST_TMP/traps"
      RESTOREFILE="$TEST_TMP/restore"
      inner="$TEST_TMP/inner.zsh"
      runner="$TEST_TMP/runner.zsh"

      {
        printf 'source "%s/home/dot_local/lib/prompt-common.zsh"\n' "$SHELLSPEC_PROJECT_ROOT"
        printf 'have_tty() { return 0; }\n'
        printf 'stty() {\n'
        printf '  case "$1" in\n'
        printf '    -g)         print -r -- "SAVEDMODES"; return 0 ;;\n'
        printf '    -echo)      trap > "%s"; kill -TERM $$; exit 0 ;;\n' "$TRAPFILE"
        printf '    SAVEDMODES) print -r -- "RESTORE-CALLED" >> "%s"; return 0 ;;\n' "$RESTOREFILE"
        printf '    *)          return 0 ;;\n'
        printf '  esac\n'
        printf '}\n'
        printf 'prompt::secret SECRETVAR "Secret:"\n'
      } > "$inner"

      {
        printf 'zmodload zsh/zpty || exit 3\n'
        printf 'zpty T "zsh -f %s"\n' "$inner"
        printf 'while zpty -r T _l; do :; done\n'
        printf 'zpty -d T 2>/dev/null\n'
        printf 'print -r -- "===TRAPS==="\n'
        printf 'cat "%s" 2>/dev/null\n' "$TRAPFILE"
        printf 'print -r -- "===RESTORE==="\n'
        printf 'cat "%s" 2>/dev/null\n' "$RESTOREFILE"
      } > "$runner"
    }
    cleanup() { rm -rf "$TEST_TMP"; }
    BeforeEach 'setup'
    AfterEach 'cleanup'

    It 'traps every terminating signal and restores the tty on exit'
      When run timeout 10 zsh -f "$runner"
      The status should be success
      # Signal dispositions installed (not INT-only).
      The output should include "INT"
      The output should include "TERM"
      The output should include "HUP"
      The output should include "QUIT"
      # Each disposition restores the saved termios (bodies stored unexpanded).
      The output should include 'stty "$__saved"'
      # A real SIGTERM at the masked prompt ran the restore (the reported bug).
      The output should include "RESTORE-CALLED"
    End
  End

  Describe 'prompt::secret preserves caller traps (follow-up)'
    # prompt::secret must not clobber a trap the CALLER set. The old code cleared
    # its own traps with a global `trap - INT EXIT TERM HUP QUIT` on return, which
    # (zsh traps are not function-local by default) also wiped the caller's TERM
    # handler. The fix sets `local_options local_traps` so its traps auto-restore
    # the caller's prior disposition on return. Drive the full masked path to a
    # NORMAL return (feed a secret + newline via the pty; stub stty without the
    # kill), then dump the caller-scope traps and assert the caller's survived.
    setup() {
      TEST_TMP="$(mktemp -d)"
      TRAPFILE="$TEST_TMP/traps-after"
      inner="$TEST_TMP/inner.zsh"
      runner="$TEST_TMP/runner.zsh"
      {
        printf 'source "%s/home/dot_local/lib/prompt-common.zsh"\n' "$SHELLSPEC_PROJECT_ROOT"
        printf 'have_tty() { return 0; }\n'
        printf 'stty() { case "$1" in -g) print -r -- SAVEDMODES ;; *) return 0 ;; esac }\n'
        printf 'trap "print -r -- CALLER_TERM_FIRED" TERM\n'
        printf 'prompt::secret SECRETVAR "Secret:"\n'
        printf 'trap > "%s"\n' "$TRAPFILE"
      } > "$inner"
      {
        printf 'zmodload zsh/zpty || exit 3\n'
        printf 'zpty T "zsh -f %s"\n' "$inner"
        printf 'zpty -w T "hunter2"\n'
        printf 'zpty -w -n T $'"'"'\\n'"'"'\n'
        printf 'while zpty -r T _l; do :; done\n'
        printf 'zpty -d T 2>/dev/null\n'
        printf 'print -r -- "===TRAPS-AFTER==="\n'
        printf 'cat "%s" 2>/dev/null\n' "$TRAPFILE"
      } > "$runner"
    }
    cleanup() { rm -rf "$TEST_TMP"; }
    BeforeEach 'setup'
    AfterEach 'cleanup'

    It 'restores the caller trap disposition on return (no clobber)'
      When run timeout 10 zsh -f "$runner"
      The status should be success
      # The caller's TERM handler is still installed after prompt::secret returns.
      The output should include "CALLER_TERM_FIRED"
    End
  End
End
