# Tests for home/dot_local/libexec/executable_ai-assist-followup.
#
# The helper mirrors ai-assist-wrapup: given a stub worker that handles
# --stream --prompt-file, it must:
#   - stream the follow-up output to --input-fifo
#   - build a prompt that includes the failed command and the captured output
#   - tolerate a missing run log (best-effort)
#   - use --request-file when provided (skipping the sidecar lookup)
#
# FIFO note: we pass a regular temp-file path as --input-fifo in the tests.
# The followup script writes to the path with '>'; no FIFO kernel rendezvous
# needed in unit tests. See ai-assist-wrapup_spec.sh for the same pattern.
Describe 'ai-assist-followup'

  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export XDG_DATA_HOME="$TEST_TMP/data"
    export AI_ASSIST_SESSION="testsess"
    export AI_ASSIST_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export ZELLIJ=1
    mkdir -p "$HOME"

    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-followup"

    # Real ai-assist-cache helper — symlinked for store/field/lookup/request-file.
    cache_script="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-cache"
    mkdir -p "$TEST_TMP/home/.local/libexec"
    ln -sf "$cache_script" "$TEST_TMP/home/.local/libexec/ai-assist-cache"
    export AI_ASSIST_CACHE_BIN="$cache_script"
    export AI_ASSIST_DATA_DIR="$TEST_TMP/cache-data"
    mkdir -p "$AI_ASSIST_DATA_DIR"

    # A private bin dir holding a stub worker.
    mkdir -p "$TEST_TMP/bin"
    export AI_ASSIST_BIN_DIR="$TEST_TMP/bin"

    # make_followup_worker <harness> <stream-output>
    # The stub records whether --prompt-file was passed and prints stream-output.
    # --probe → available; --stream → record prompt-file content + print output.
    make_followup_worker() {
      local h="$1" sout="$2"
      {
        printf '#!/usr/bin/env zsh\n'
        printf '[[ "${1:-}" == --probe ]] && { print -r -- "%s available"; exit 0; }\n' "$h"
        printf 'if [[ "${1:-}" == --stream ]]; then\n'
        # Record the --prompt-file argument if present.
        printf '  pf=""; while (($#)); do [[ "$1" == "--prompt-file" ]] && { pf="${2:-}"; break; }; shift; done\n'
        printf '  [[ -n "$pf" ]] && printf "PROMPT_FILE_CONTENT=%%s\\n" "$(cat -- "$pf")" >> "%s/worker-log"\n' "$TEST_TMP"
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
  "user_request":"followup test request",
  "project":{"name":"proj","branch":"main"}
}
JSON

    # Compute ctx + req hashes (general-question context = project_root only).
    export REQ_PROJECT_ROOT="/tmp/proj"
    unset REQ_COMMAND_TEXT REQ_COMMAND_EXIT REQ_SCROLLBACK 2>/dev/null || true
    CTX="$("$cache_script" context-hash 2>/dev/null)"
    REQ_HASH="$("$cache_script" request-hash "followup test request" 2>/dev/null)"
    unset REQ_PROJECT_ROOT 2>/dev/null || true

    # Seed a playbook entry so the helper can look up ctx/req front matter.
    seed_entry() {
      local kind="$1" body_text="$2"
      local body_tmp="$TEST_TMP/seed-body.txt"
      printf '%s\n' "$body_text" > "$body_tmp"
      "$cache_script" store "$CTX" "$REQ_HASH" "$kind" "$body_tmp" \
        "request=followup test request" "project_root=/tmp/proj" "project_name=proj" \
        "command=" "exit=" "harness=claude" \
        --request-file "$REQ" >/dev/null 2>&1
    }

    # Use a regular temp file as the --input-fifo argument.
    INPUT_FILE="$TEST_TMP/input-sink.txt"
    : > "$INPUT_FILE"
  }

  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # ── (a) streams to input-fifo ──────────────────────────────────────────────
  It '(a) streams follow-up output to input-fifo'
    make_followup_worker claude "## Revised fix: try a different approach"
    seed_entry playbook "## Playbook step 1: run make"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --block-id "verify" --failed-cmd "make test"
    The status should be success
    The contents of file "$INPUT_FILE" should include "Revised fix"
  End

  # ── (b) tolerates an absent run log ────────────────────────────────────────
  It '(b) tolerates a missing run log (no --run-dir)'
    make_followup_worker claude "## Revised fix: no runlog"
    seed_entry playbook "## Playbook step 1"
    # No --run-dir passed — helper must not error.
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --block-id "verify" --failed-cmd "make test"
    The status should be success
    The contents of file "$INPUT_FILE" should include "Revised fix"
  End

  # ── (c) uses --request-file when provided ──────────────────────────────────
  It '(c) uses --request-file when provided instead of sidecar'
    make_followup_worker claude "## Revised fix: use --request-file path"
    # Do NOT seed a cache entry — the helper must use the provided request file.
    When run script "$SCRIPT" \
      --ctx "nonexistent-ctx" --req "nonexistent-req" \
      --input-fifo "$INPUT_FILE" \
      --block-id "verify" --failed-cmd "make test" \
      --request-file "$REQ"
    The status should be success
    The contents of file "$INPUT_FILE" should include "Revised fix"
  End

  # ── (d) the prompt includes the failed command ─────────────────────────────
  It '(d) the follow-up prompt passed to the worker contains the failed command'
    make_followup_worker claude "## Revised fix: done"
    seed_entry playbook "## step"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --block-id "verify" --failed-cmd "make test"
    The status should be success
    # The stub worker logged PROMPT_FILE_CONTENT; it must include the failed cmd.
    The contents of file "$TEST_TMP/worker-log" should include "make test"
  End

  # ── (e) the prompt includes the original request ───────────────────────────
  It '(e) the follow-up prompt passed to the worker contains the original request'
    make_followup_worker claude "## Revised fix: done"
    seed_entry playbook "## step"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --block-id "verify" --failed-cmd "make test"
    The status should be success
    The contents of file "$TEST_TMP/worker-log" should include "followup test request"
  End

  # ── (e2) no-worker: error message written, pane kept open (no quit-sentinel) ──
  It '(e2) no-worker: writes an error message to input-fifo, does NOT write the quit-sentinel'
    # No worker in bin dir — all resolve_harness probes fail.
    seed_entry playbook "## Playbook step 1"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --block-id "verify" --failed-cmd "make test"
    The status should be success
    # Must contain the warning marker (kept pane open).
    The contents of file "$INPUT_FILE" should include "⚠"
    The contents of file "$INPUT_FILE" should include "no assistant available"
    # Must NOT contain the quit-sentinel bytes (DLE 'q' DLE = 0x10 0x71 0x10).
    fifo_hex="$(xxd -p "$INPUT_FILE" 2>/dev/null || od -A n -t x1 "$INPUT_FILE" 2>/dev/null | tr -d ' \n')"
    The value "$fifo_hex" should not include "107110"
  End

  # ── (e3) no-entry: error message written, pane kept open (no quit-sentinel) ──
  It '(e3) no-entry (fresh playbook, no cache): writes an error message, does NOT write the quit-sentinel'
    make_followup_worker claude "unused"
    # Do NOT seed a cache entry; pass a non-existent ctx/req so resolution fails.
    When run script "$SCRIPT" \
      --ctx "nonexistent-ctx" --req "nonexistent-req" \
      --input-fifo "$INPUT_FILE" \
      --block-id "verify" --failed-cmd "make test"
    The status should be success
    # Must contain the warning marker.
    The contents of file "$INPUT_FILE" should include "⚠"
    The contents of file "$INPUT_FILE" should include "could not load"
    # Must NOT contain the quit-sentinel bytes.
    fifo_hex="$(xxd -p "$INPUT_FILE" 2>/dev/null || od -A n -t x1 "$INPUT_FILE" 2>/dev/null | tr -d ' \n')"
    The value "$fifo_hex" should not include "107110"
  End

  # ── (f) the prompt includes output read from the runlog logpath ─────────────
  It '(f) the prompt includes the failed command output read from runlog logpath'
    make_followup_worker claude "## Revised fix: done"
    seed_entry playbook "## step"
    # Create a run-dir with a runlog.jsonl that has a log entry for "verify".
    run_dir="$TEST_TMP/run-dir"; mkdir -p "$run_dir"
    log_file="$TEST_TMP/captured-output.txt"
    printf 'Error: connection refused on port 5432\n' > "$log_file"
    # Write a runlog line with the log path (plain file — no JSON escaping needed
    # since the temp path has no special chars).
    printf '{"id":"verify","exit":1,"ts":"2026-01-01T00:00:00Z","log":"%s"}\n' \
      "$log_file" > "$run_dir/runlog.jsonl"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE" \
      --run-dir "$run_dir" \
      --block-id "verify" --failed-cmd "make test" \
      --request-file "$REQ"
    The status should be success
    # The stub worker logged PROMPT_FILE_CONTENT; it must include the captured output.
    The contents of file "$TEST_TMP/worker-log" should include "connection refused"
  End

End
