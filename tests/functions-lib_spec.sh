# Tests for functions.d/_lib.sh — the zsh PROMPT-escape palette.
#
# _lib.sh defines a Catppuccin palette as zsh PROMPT escapes (`%F{…}` / `%f`),
# consumed by interactive functions in commands.sh via `print -P` and `die`.
# These MUST live under the P_* namespace, NOT the C_* names common.zsh uses for
# its RAW SGR palette: a scope sourcing both would otherwise get one vocabulary
# under the other's names — `printf '%s' "$C_RED"` emitting a literal `%F{…}`,
# or a prompt escape resolving to a raw SGR sequence. This pins the rename so
# the collision cannot silently recur.
Describe 'functions.d/_lib.sh — prompt-escape palette (P_*)'
  _lib="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/functions.d/_lib.sh"

  # Source _lib.sh in a clean `zsh -f` child (rcfiles skipped, THEME_PALETTE_FILE
  # inherited from spec_helper) and dump both the new P_* tokens and whether the
  # old C_* names got defined. `${VAR-UNSET}` distinguishes unset from empty.
  probe() {
    zsh -f -c '
      source "'"$_lib"'"
      print -r -- "P_RED=$P_RED"
      print -r -- "P_YEL=$P_YEL"
      print -r -- "P_BLU=$P_BLU"
      print -r -- "P_BBL=$P_BBL"
      print -r -- "P_BWH=$P_BWH"
      print -r -- "P_RES=$P_RES"
      print -r -- "C_RED=${C_RED-UNSET}"
      print -r -- "C_YEL=${C_YEL-UNSET}"
      print -r -- "C_BLU=${C_BLU-UNSET}"
      print -r -- "C_BBL=${C_BBL-UNSET}"
      print -r -- "C_BWH=${C_BWH-UNSET}"
      print -r -- "C_RES=${C_RES-UNSET}"
    '
  }

  It 'defines the P_* set as %F{…}/%f prompt tokens'
    When call probe
    The output should include 'P_RED=%F{'
    The output should include 'P_YEL=%F{'
    The output should include 'P_BLU=%F{'
    The output should include 'P_BBL=%F{'
    The output should include 'P_BWH=%F{'
    The output should include 'P_RES=%f'
  End

  It 'does NOT define any of common.zsh raw-SGR C_* names (no collision)'
    When call probe
    The output should include 'C_RED=UNSET'
    The output should include 'C_YEL=UNSET'
    The output should include 'C_BLU=UNSET'
    The output should include 'C_BBL=UNSET'
    The output should include 'C_BWH=UNSET'
    The output should include 'C_RES=UNSET'
  End

  # The whole point of a PROMPT escape is that `print -P` expands it to a real
  # terminal SGR sequence. Render one and confirm it turns into an ESC-[ escape
  # (cat -v shows ESC as `^[`), not the literal `%F{…}` text.
  render() {
    zsh -f -c 'source "'"$_lib"'"; print -nP -- "${P_RED}X${P_RES}"' | cat -v
  }

  It 'renders P_* through print -P as an ANSI SGR escape'
    When call render
    The output should include '^[['
    The output should not include '%F{'
  End

  # die is _lib.sh's own: return 1 (never exit) so it is safe inside the
  # interactive cd wrappers in commands.sh — an `exit 1` there would kill the
  # user's login shell. common.zsh's die (exit 1) must never reach this scope.
  Describe 'die returns 1 (does not exit the shell)'
    check_die() {
      zsh -f -c '
        source "'"$_lib"'"
        die "boom" 2>/dev/null
        print -r -- "rc=$?; survived"
      '
    }
    It 'returns non-zero yet the shell keeps running'
      When call check_die
      The output should include 'rc=1; survived'
    End
  End
End
