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

    # HOUSE RULE, and it now applies to every example here rather than the two
    # that used to opt in: a test must never touch a live service. Sending is
    # backgrounded BY DEFAULT since the live-first amendment, so an example
    # without these stubs enqueues real work against the running pueued (it
    # did: 14 tasks), repaints the attached tmux status bar, and overwrites the
    # user's clipboard via share::clip.
    cat >"$SB/bin/pueue" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${SHARE_PUEUE_CALLS:-/dev/null}"
case "$1" in
  add) printf '1\n' ;;
  *)   : ;;
esac
SH
    cat >"$SB/bin/tmux" <<'SH'
#!/bin/sh
exit 0
SH
    cat >"$SB/bin/pbcopy" <<'SH'
#!/bin/sh
cat >"${SHARE_FAKE_CLIP:-/dev/null}"
SH
    chmod +x "$SB/bin/pueue" "$SB/bin/tmux" "$SB/bin/pbcopy"
    export JOB_PUEUE_BIN="$SB/bin/pueue"
    export JOB_TMUX_BIN="$SB/bin/tmux"
    export JOB_STATE_ROOT="$SB/jobs"
    export SHARE_PUEUE_CALLS="$SB/pueue-calls"
    export SHARE_FAKE_CLIP="$SB/clip.txt"
    export SHARE_LIVE_DIR="$SB/live"

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
    When run script "$SHARE_BIN" --store --foreground "$SB/Report.pdf"
    The status should be success
    The output should include 'd.example.com/s/abc'
    The stderr should include 'sending to d.example.com'
  End

  It 'accepts an explicit send subcommand'
    When run script "$SHARE_BIN" send --store --foreground "$SB/Report.pdf"
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

  # F1 fix: pueue installed but the daemon down used to pass share::jobs_available
  # (job::_pueue only resolves the binary, never contacts the daemon), so
  # --background ran `job::start` → `pueue add` against a dead daemon and the
  # whole send died instead of degrading. This drives it through the REAL CLI
  # (not a stubbed share::jobs_available like the example above) with a fake
  # pueue whose `status` fails — the actual probe share::jobs_available now
  # performs — and asserts the send still completes, in the foreground.
  It 'falls back to a foreground send when pueue is installed but the daemon is down'
    cat >"$SB/bin/pueue" <<'SH'
#!/bin/sh
case "$1" in
  status) exit 1 ;;
  *)      exit 0 ;;
esac
SH
    chmod +x "$SB/bin/pueue"
    export JOB_PUEUE_BIN="$SB/bin/pueue"
    When run script "$SHARE_BIN" --background --store "$SB/Report.pdf"
    The status should be success
    The stderr should include 'job runner is unavailable'
    The output should include 'd.example.com/s/abc'
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
    cwd_send_list() { cd "$SB" && "$SHARE_BIN" send --store --foreground list; }
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
    When run script "$SHARE_BIN" --background --store "$SB/Report.pdf"
    The status should be success
    The output should include 'queued as job'
    The output should not include 'd.example.com/s/abc'
  End

  # --- F4 fix: --force needs BOTH the flag AND an interactive confirmation --
  # naming the host. Implemented at THIS layer (dispatch_send), not inside
  # share::resolve, because a --background send has no tty inside the job —
  # the gate has to run before enqueue. `script` (used by every `When run
  # script` example here) never leaves a real controlling terminal on
  # stderr, so these exercise the "no tty" refusal for free — no separate
  # stub needed to prove it.
  It 'refuses --force on a disallowed endpoint when there is no interactive terminal to confirm on'
    cat >>"$SHARE_ENDPOINTS_FILE" <<'TOML'

[corp]
store = "https://corp.example.com"
profiles = ["work"]
TOML
    When run script "$SHARE_BIN" --to corp --force --store --foreground "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'interactive terminal'
    The output should not include 'corp.example.com'
  End

  It 'sends immediately with --force on an already-allowed endpoint — no confirmation needed'
    When run script "$SHARE_BIN" --to drop --force --store --foreground "$SB/Report.pdf"
    The status should be success
    The output should include 'd.example.com/s/abc'
    The stderr should include 'sending to d.example.com'
  End
End
