# Tests for the Phase 7 linux-headless store backend + the portable core
# helpers (spec 2026-07-14 §2–§3). Everything runs against a temp DB with
# CLIPBOARD_PLATFORM forced, so no test touches the real store or pasteboard.
Describe 'clipboard-store-core: portable helpers'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"
  CORE="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/clipboard-store-core.zsh"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    export PICK_CLIPBOARD_DB="$SHELLSPEC_TMPBASE/store/history.db"
    mkdir -p "$XDG_STATE_HOME/clipboard" "$SHELLSPEC_TMPBASE/store"
    # local_options nullglob: this setup runs under shellspec's zsh (see
    # .shellspec's --shell zsh), where an unmatched glob is a hard error
    # (NOMATCH) by default -- and on the FIRST run of any test here (or any
    # test before --init-store has created the DB) "$PICK_CLIPBOARD_DB"* has
    # nothing to match yet. nullglob makes a no-match glob expand to nothing
    # instead, scoped to this function only.
    setopt local_options nullglob
    rm -f "$PICK_CLIPBOARD_DB"*
  }
  BeforeEach 'setup'

  # -f skips ~/.zshenv (would clobber the XDG sandbox overrides -- same
  # empirically-confirmed reason as tests/clipboard-bridge_spec.sh).
  It 'clip::sha256 matches shasum -a 256'
    expected=$(printf 'hello' | shasum -a 256 | awk '{print $1}')
    When run command sh -c 'printf hello | zsh -f -c "source \"$1\"; clip::sha256"' _ "$CORE"
    The output should equal "$expected"
  End

  It 'clip::self_host prefers a valid self-name file'
    printf 'cruise-box' > "$XDG_STATE_HOME/clipboard/self-name"
    When run command sh -c 'zsh -f -c "source \"$1\"; clip::self_host"' _ "$CORE"
    The output should equal "cruise-box"
  End

  It 'clip::self_host rejects a garbage self-name first line'
    printf -- '-bad;name\n' > "$XDG_STATE_HOME/clipboard/self-name"
    When run command sh -c 'zsh -f -c "source \"$1\"; clip::self_host"' _ "$CORE"
    The output should not equal "-bad;name"
    The output should not equal ""
  End

  It '--init-store creates the schema'
    When run command sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" --init-store' _ "$DISPATCH"
    The status should be success
    result=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
    The variable result should include "clip_types"
    The variable result should include "clips"
  End

  It '--init-store is idempotent'
    When run command sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" --init-store && zsh -f "$1" --init-store' _ "$DISPATCH"
    The status should be success
  End
End
