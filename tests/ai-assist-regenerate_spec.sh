# Tests for home/dot_local/libexec/executable_ai-assist-regenerate.
#
# The helper re-runs a cached request fresh (AI_ASSIST_NO_CACHE=1), classifies
# the result via the cheap triage pass, and routes by kind:
#   command  → bracketed-paste into --origin-pane + quit-sentinel on input "fifo"
#   answer   → answer text written to input "fifo" + entry stored
#   escalate → worker --stream output piped to input "fifo" + playbook entry stored
#
# FIFO note: we pass a regular temp-file path as --input-fifo in the tests.
# The regenerate script simply writes to the path (> or tee); no FIFO kernel
# rendezvous needed in tests.  The pager (a later stage) uses an actual named
# pipe in production; for the helper's unit tests a regular file is simpler and
# avoids open-for-write blocking entirely.
#
# Stubs: zellij (records argv), ai-assist-<h> worker (records --stream, prints
# chosen sentinel), and the real ai-assist-cache helper for storage assertions.
Describe 'ai-assist-regenerate'
  US=$'\x1f'

  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export XDG_DATA_HOME="$TEST_TMP/data"
    export AI_ASSIST_SESSION="testsess"
    export AI_ASSIST_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export ZELLIJ=1
    mkdir -p "$HOME"

    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-regenerate"

    # Real ai-assist-cache helper — symlinked so `store`, `field`, `lookup`,
    # `request-file`, and `log` work correctly in the tests.
    cache_script="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-cache"
    mkdir -p "$TEST_TMP/home/.local/libexec"
    ln -sf "$cache_script" "$TEST_TMP/home/.local/libexec/ai-assist-cache"
    # Wire via AI_ASSIST_CACHE_BIN for test environments.
    export AI_ASSIST_CACHE_BIN="$cache_script"
    export AI_ASSIST_DATA_DIR="$TEST_TMP/cache-data"
    mkdir -p "$AI_ASSIST_DATA_DIR"

    # Stub zellij: record the full argument vector.
    zjstub="$TEST_TMP/zjstub"
    {
      printf '#!/usr/bin/env zsh\n'
      printf 'printf "%%s\\n" "$*" >> "%s/zj-args"\n' "$TEST_TMP"
    } > "$zjstub"; chmod +x "$zjstub"
    export ZELLIJ_BIN="$zjstub"

    # A private bin dir holding a single stub worker.
    mkdir -p "$TEST_TMP/bin"
    export AI_ASSIST_BIN_DIR="$TEST_TMP/bin"

    # make_worker <harness> <triage-output> <stream-output> [<triage-exit>]
    # --probe → available; --triage → prints triage sentinel; --stream → prints stream-output.
    # --stream also records AI_ASSIST_NO_CACHE to env-log (for test (d)).
    make_worker() {
      local h="$1" tout="$2" sout="$3" texit="${4:-0}"
      {
        printf '#!/usr/bin/env zsh\n'
        printf '[[ "${1:-}" == --probe ]] && { print -r -- "%s available"; exit 0; }\n' "$h"
        printf 'if [[ "${1:-}" == --triage ]]; then\n'
        printf '  printf "%%s" "%s"\n' "$tout"
        printf '  exit %s\n' "$texit"
        printf 'fi\n'
        printf 'if [[ "${1:-}" == --stream ]]; then\n'
        printf '  printf "NO_CACHE=%%s\\n" "${AI_ASSIST_NO_CACHE:-unset}" >> "%s/env-log"\n' "$TEST_TMP"
        printf '  printf "%%s" "%s"\n' "$sout"
        printf '  exit 0\n'
        printf 'fi\n'
      } > "$TEST_TMP/bin/ai-assist-$h"
      chmod +x "$TEST_TMP/bin/ai-assist-$h"
    }

    # A minimal request.json fixture.
    REQ="$TEST_TMP/request.json"
    cat > "$REQ" <<'JSON'
{
  "version": 1,
  "kind": "question",
  "origin": {"cwd":"/tmp/proj","project_root":"/tmp/proj","pane_id":"terminal_7"},
  "command": {"text":"","exit":null},
  "scrollback":"",
  "user_request":"regen test request",
  "project":{"name":"proj","branch":"main"}
}
JSON

    # Compute ctx + req hashes (general-question context = project_root only).
    export REQ_PROJECT_ROOT="/tmp/proj"
    unset REQ_COMMAND_TEXT REQ_COMMAND_EXIT REQ_SCROLLBACK 2>/dev/null || true
    CTX="$("$cache_script" context-hash 2>/dev/null)"
    REQ_HASH="$("$cache_script" request-hash "regen test request" 2>/dev/null)"
    unset REQ_PROJECT_ROOT 2>/dev/null || true

    # Seed a cache entry so the helper can look up ctx/req front matter.
    seed_entry() {
      local kind="$1" body_text="$2"
      local body_tmp="$TEST_TMP/seed-body.txt"
      printf '%s\n' "$body_text" > "$body_tmp"
      "$cache_script" store "$CTX" "$REQ_HASH" "$kind" "$body_tmp" \
        "request=regen test request" "project_root=/tmp/proj" "project_name=proj" \
        "command=" "exit=" "harness=claude" \
        --request-file "$REQ" >/dev/null 2>&1
    }

    # Use a regular temp file as the --input-fifo argument. The helper writes to
    # this path with '>' and 'tee'; a regular file works without open-for-write
    # blocking (no FIFO kernel rendezvous needed in unit tests).
    INPUT_FILE="$TEST_TMP/input-sink.txt"
    : > "$INPUT_FILE"
  }

  cleanup() {
    rm -rf "$TEST_TMP"
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # ── (a) command kind ────────────────────────────────────────────────────────
  It '(a) command kind: bracketed-paste into origin pane, quit-sentinel on fifo, command entry stored'
    make_worker claude "__COMMAND__"$'\n'"git status" "unused-stream-output"
    seed_entry command "git status"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --origin-pane terminal_7
    The status should be success
    # Bracketed paste: ESC[200~ written, then the command, then ESC[201~.
    The contents of file "$TEST_TMP/zj-args" should include "write --pane-id terminal_7 27 91 50 48 48 126"
    The contents of file "$TEST_TMP/zj-args" should include "write-chars --pane-id terminal_7"
    The contents of file "$TEST_TMP/zj-args" should include "git status"
    The contents of file "$TEST_TMP/zj-args" should include "27 91 50 48 49 126"
    # No trailing CR.
    The contents of file "$TEST_TMP/zj-args" should not include "write 13"
    # Quit sentinel (DLE 'q' DLE = 0x10 0x71 0x10) was written to the input file.
    fifo_hex="$(xxd -p "$INPUT_FILE" 2>/dev/null || od -A n -t x1 "$INPUT_FILE" 2>/dev/null | tr -d ' \n')"
    The value "$fifo_hex" should include "107110"
    # A command entry must now exist for ctx/req.
    The path "$AI_ASSIST_DATA_DIR/cache/$CTX/$REQ_HASH.md" should be file
    entry_kind="$("$cache_script" field "$AI_ASSIST_DATA_DIR/cache/$CTX/$REQ_HASH.md" kind 2>/dev/null)"
    The value "$entry_kind" should equal "command"
  End

  # ── (b) answer kind ─────────────────────────────────────────────────────────
  It '(b) answer kind: answer text on input file, answer entry stored'
    make_worker claude "__ANSWER__"$'\n'"Use mogrify to resize images." "unused-stream-output"
    seed_entry answer "Use mogrify to resize images."
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --origin-pane terminal_7
    The status should be success
    # The answer text must have been written to the input file.
    The contents of file "$INPUT_FILE" should include "Use mogrify"
    # No write to zellij (no bracketed paste, no new-pane).
    The path "$TEST_TMP/zj-args" should not be exist
    # An answer entry must now be stored.
    The path "$AI_ASSIST_DATA_DIR/cache/$CTX/$REQ_HASH.md" should be file
    entry_kind="$("$cache_script" field "$AI_ASSIST_DATA_DIR/cache/$CTX/$REQ_HASH.md" kind 2>/dev/null)"
    The value "$entry_kind" should equal "answer"
  End

  # ── (c) escalate kind ───────────────────────────────────────────────────────
  It '(c) escalate kind: worker --stream output on input file, playbook entry stored'
    make_worker claude "__ESCALATE__: needs full agent" "## Playbook step 1: run make"
    seed_entry playbook "## Playbook step 1: run make"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --origin-pane terminal_7
    The status should be success
    # The worker's --stream output must appear on the input file.
    The contents of file "$INPUT_FILE" should include "Playbook"
    # No bracketed paste.
    The path "$TEST_TMP/zj-args" should not be exist
    # A playbook entry must now be stored.
    The path "$AI_ASSIST_DATA_DIR/cache/$CTX/$REQ_HASH.md" should be file
    entry_kind="$("$cache_script" field "$AI_ASSIST_DATA_DIR/cache/$CTX/$REQ_HASH.md" kind 2>/dev/null)"
    The value "$entry_kind" should equal "playbook"
  End

  # ── (d) AI_ASSIST_NO_CACHE exported during the run ──────────────────────────
  It '(d) AI_ASSIST_NO_CACHE=1 is exported to the worker during escalate'
    make_worker claude "__ESCALATE__: needs full agent" "output"
    seed_entry playbook "output"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE"
    The status should be success
    # The stub worker recorded AI_ASSIST_NO_CACHE into env-log.
    The contents of file "$TEST_TMP/env-log" should include "NO_CACHE=1"
  End
End
