# The CLI front-end. Thin by design: parse, dispatch, print. Every behaviour it
# exposes is already covered by a library spec, so this file only pins the
# surface — subcommand routing, the bare-path shorthand, help, and the
# background flag.

Describe 'share CLI'
  setup() {
    SB="$SHELLSPEC_TMPBASE/share-cli"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    export SHARE_CONFIG_DIR="$SB"
    export SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    export SHARE_STATE_DIR="$SB/state"
    export SHARE_PROFILE=personal
    export SHARE_LIB_DIR="$PWD/home/dot_local/lib"
    printf '[drop]\nstore = "https://d.example.com"\nweb = true\nprofiles = ["personal"]\ndefault_for = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    printf 'x' >"$SB/Report.pdf"
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf 'https://d.example.com/s/abc#v1.KEY\ncroc-store-v1.b64.abc.KEY\n'
SH
    chmod +x "$SB/bin/croc"
    export PATH="$SB/bin:$PATH"
    SHARE_BIN="$PWD/home/dot_local/bin/executable_share"
  }
  BeforeEach 'setup'

  It 'prints help and exits zero'
    When run script "$SHARE_BIN" --help
    The status should be success
    The output should include 'share'
    The output should include 'revoke'
  End

  It 'lists endpoints'
    When run script "$SHARE_BIN" endpoints
    The status should be success
    The output should include 'drop'
    The output should include 'public'
  End

  It 'treats a bare path as a send'
    When run script "$SHARE_BIN" "$SB/Report.pdf"
    The status should be success
    The output should include 'd.example.com/s/abc'
    The stderr should include 'sending to d.example.com'
  End

  It 'accepts an explicit send subcommand'
    When run script "$SHARE_BIN" send "$SB/Report.pdf"
    The status should be success
    The output should include 'd.example.com/s/abc'
    The stderr should include 'sending to'
  End

  It 'prints an empty ledger as an empty array'
    When run script "$SHARE_BIN" list
    The status should be success
    The output should include '[]'
  End

  # The job-runner degradation path. Stubs share::jobs_available (our own
  # predicate) rather than trying to defeat job::_pueue's resolution, which has a
  # hardcoded fallback and no failure seam — see the note in share_job_spec.sh.
  It 'falls back to a foreground send when the job runner is unavailable'
    stub_unavailable() {
      SHARE_LIB_DIR="$PWD/home/dot_local/lib" zsh -c '
        source "$SHARE_LIB_DIR/share.zsh"
        share::jobs_available() { return 1 }
        share::send() { print -r -- "FOREGROUND-SEND"; }
        source "'"$SHARE_BIN"'" --background '"$SB"'/Report.pdf
      ' 2>&1
    }
    When call stub_unavailable
    The output should include 'FOREGROUND-SEND'
    The output should include 'job runner is unavailable'
  End

  It 'fails on an unknown subcommand'
    When run script "$SHARE_BIN" frobnicate
    The status should be failure
    The stderr should include 'unknown'
  End

  It 'requires an id for revoke'
    When run script "$SHARE_BIN" revoke
    The status should be failure
    The stderr should include 'an id is required'
  End

  # --- beyond the brief -------------------------------------------------

  It 'shows usage and exits zero with no arguments at all'
    When run script "$SHARE_BIN"
    The status should be success
    The output should include 'Usage'
  End

  It 'shows the same help for -h as for --help'
    When run script "$SHARE_BIN" -h
    The status should be success
    The output should include 'revoke'
  End

  # --help falls through to the library's option parser unless the CLI catches
  # it before dispatching: `send` and `get` each peel off their own flags, so a
  # bare --help must be recognized at that layer rather than reaching
  # share::send / share::get, which reject it as an unknown option.
  It 'shows usage and exits zero for send --help'
    When run script "$SHARE_BIN" send --help
    The status should be success
    The output should include 'Usage'
    The output should include 'revoke'
  End

  It 'shows usage and exits zero for get --help'
    When run script "$SHARE_BIN" get --help
    The status should be success
    The output should include 'Usage'
    The output should include 'revoke'
  End

  # The default-subcommand heuristic: a recognized subcommand word ALWAYS wins
  # over the bare-path shorthand, even when a same-named file sits in the
  # working directory — that is what stops `share list` from silently
  # uploading a stray file called `list`, and what stops `share get` from
  # trying to send a file named `get`. Sending a file that happens to share a
  # subcommand's name requires the explicit `send` subcommand.
  It 'prefers the list subcommand over a same-named file in the directory'
    printf 'not-a-real-ledger' >"$SB/list"
    When run script "$SHARE_BIN" list
    The status should be success
    The output should include '[]'
    The output should not include 'not-a-real-ledger'
  End

  It 'still sends a file named list when the send subcommand is explicit'
    printf 'x' >"$SB/list"
    cwd_send_list() { cd "$SB" && "$SHARE_BIN" send list; }
    When call cwd_send_list
    The status should be success
    The output should include 'd.example.com/s/abc'
    The stderr should include 'sending to'
  End

  # --background with a real (fake) pueue: prints a job id, and — this is the
  # part a broken degradation-check could get backwards — does NOT also run a
  # foreground send (the croc fake would print the blurb if it had).
  It 'sends in the background when the job runner is available'
    cat >"$SB/bin/pueue" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_PUEUE_CALLS"
case "$1" in
  add) printf '1\n' ;;
  *)   : ;;
esac
SH
    chmod +x "$SB/bin/pueue"
    # job::start unconditionally calls job::_statusbar_sync, which resolves
    # ${JOB_TMUX_BIN:-tmux} and runs `refresh-client -S` against the DEFAULT
    # socket — same house rule as tests/job_spec.sh,
    # tests/job_callback_spec.sh and tests/share_job_spec.sh: a test must
    # never touch the live server. Left unset here, this would repaint this
    # dev shell's real, attached tmux status bar.
    cat >"$SB/bin/tmux" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$SB/bin/tmux"
    export JOB_PUEUE_BIN="$SB/bin/pueue"
    export JOB_TMUX_BIN="$SB/bin/tmux"
    export JOB_STATE_ROOT="$SB/jobs"
    export SHARE_PUEUE_CALLS="$SB/pueue-calls"
    When run script "$SHARE_BIN" --background "$SB/Report.pdf"
    The status should be success
    The output should include 'queued as job'
    The output should not include 'd.example.com/s/abc'
  End
End
