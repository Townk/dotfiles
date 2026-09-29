# _share completion — routing and candidate sources.
# Spec: docs/superpowers/specs/2026-08-18-share-phase3-faces-design.md (F5)
#
# The completion system's entry points (_arguments, _describe, _files) are
# stubbed to record what _share hands them. That proves ROUTING and CANDIDATE
# SOURCES, not zsh's own matching; the Mode B retest covers the real TAB.
# Both defects below shipped because nothing exercised _share at all.

Describe '_share completion'
  COMP="$SHELLSPEC_PROJECT_ROOT/home/dot_local/share/zsh/site-functions/_share"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-comp"; rm -rf "$SB"; mkdir -p "$SB/state"
    export SHARE_STATE_DIR="$SB/state" SHARE_LIB_DIR="$LIB" COMP
  }
  BeforeEach 'setup'

  # comp <word>... — run _share as if the command line were those words, with
  # the cursor after the last one. Stubs print what they were handed.
  comp() {
    zsh -f -c '
      _arguments() { print -r -- "ARGS: $*"; }
      # `_describe [-t tag] descr array`: the array NAME is the last argument.
      _describe()  { local -a arr; arr=( ${(P)${@[-1]}} ); print -rl -- "DESCRIBE" "${arr[@]}"; }
      _files()     { print -r -- "FILES"; }
      words=("$@"); CURRENT=$#
      source "$COMP"
    ' _ "$@"
  }

  # `share --to <TAB>`: the implicit send. Before the fix the first word was
  # only ever matched as a subcommand, so options before one went nowhere.
  It 'routes options before any subcommand to the send options'
    When call comp share --to ''
    The output should include '--to[send through this endpoint]:endpoint:__share-endpoints'
    The output should not include ':->cmd'
  End

  It 'still offers subcommands for a bare first word'
    When call comp share ''
    The output should include ':->cmd'
  End

  # share::ledger_list prints ONE JSON ARRAY. The helper ran `select(...)` on
  # it as if it were a stream of objects; jq errored ("Cannot index array"),
  # the error was discarded, and `share revoke <TAB>` said "no matches".
  It 'offers stored receipts for revoke, and never live ones'
    zsh -f -c 'source "$SHARE_LIB_DIR/share.zsh"
      share::ledger_add stored1 croc drop "Report.pdf (1 B)" ref1 "https://x" 9999999999
      share::ledger_add live1 croc-live public "Live.pdf (1 B)" "" "aaaa-bbbb" 0'
    run_receipts() {
      zsh -f -c '
        _describe() { local -a arr; arr=( ${(P)${@[-1]}} ); print -rl -- "${arr[@]}"; }
        source "$COMP" 2>/dev/null <<<"" || :
        __share-receipts
      '
    }
    When call run_receipts
    The output should include 'stored1:Report.pdf (1 B)'
    The output should not include 'live1'
  End
End
