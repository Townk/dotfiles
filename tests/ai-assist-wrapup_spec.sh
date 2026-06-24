# Tests for home/dot_local/libexec/executable_ai-assist-wrapup.
#
# The helper mirrors ai-assist-regenerate: given a stub worker that handles
# --stream --prompt-file, it must:
#   - stream the wrap-up output to --input-fifo
#   - write a solution artifact under the solutions dir
#   - tolerate a missing run log (best-effort)
#   - use --request-file when provided (skipping the sidecar lookup)
#
# FIFO note: we pass a regular temp-file path as --input-fifo in the tests.
# The wrapup script writes to the path with '>'; no FIFO kernel rendezvous
# needed in unit tests. See ai-assist-regenerate_spec.sh for the same pattern.
Describe 'ai-assist-wrapup'

  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export XDG_DATA_HOME="$TEST_TMP/data"
    export AI_ASSIST_SESSION="testsess"
    export AI_ASSIST_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export ZELLIJ=1
    mkdir -p "$HOME"

    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-wrapup"

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

    # make_wrapup_worker <harness> <stream-output>
    # The stub records whether --prompt-file was passed and prints stream-output.
    # --probe → available; --stream → record prompt-file path + print output.
    make_wrapup_worker() {
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
  "user_request":"wrapup test request",
  "project":{"name":"proj","branch":"main"}
}
JSON

    # Compute ctx + req hashes (general-question context = project_root only).
    export REQ_PROJECT_ROOT="/tmp/proj"
    unset REQ_COMMAND_TEXT REQ_COMMAND_EXIT REQ_SCROLLBACK 2>/dev/null || true
    CTX="$("$cache_script" context-hash 2>/dev/null)"
    REQ_HASH="$("$cache_script" request-hash "wrapup test request" 2>/dev/null)"
    unset REQ_PROJECT_ROOT 2>/dev/null || true

    # Seed a playbook entry so the helper can look up ctx/req front matter.
    seed_entry() {
      local kind="$1" body_text="$2"
      local body_tmp="$TEST_TMP/seed-body.txt"
      printf '%s\n' "$body_text" > "$body_tmp"
      "$cache_script" store "$CTX" "$REQ_HASH" "$kind" "$body_tmp" \
        "request=wrapup test request" "project_root=/tmp/proj" "project_name=proj" \
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

  # ── (a) streams to input-fifo and writes solution artifact ─────────────────
  It '(a) streams wrap-up output to input-fifo and writes a solution artifact'
    make_wrapup_worker claude "## Solution: run make clean first"
    seed_entry playbook "## Playbook step 1: run make"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE"
    The status should be success
    # The worker stream output must appear in the input sink.
    The contents of file "$INPUT_FILE" should include "Solution"
    # A solution artifact must have been written under the solutions dir.
    The path "$AI_ASSIST_DATA_DIR/solutions" should be directory
    artifact="$(ls "$AI_ASSIST_DATA_DIR/solutions"/*.md 2>/dev/null | head -1)"
    The path "$artifact" should be file
  End

  # ── (b) tolerates an absent run log ────────────────────────────────────────
  It '(b) tolerates a missing run log (no --run-dir)'
    make_wrapup_worker claude "## Solution: build with make"
    seed_entry playbook "## Playbook step 1"
    # No --run-dir passed — helper must not error.
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE"
    The status should be success
    The contents of file "$INPUT_FILE" should include "Solution"
  End

  # ── (c) uses --request-file when provided ──────────────────────────────────
  It '(c) uses --request-file when provided instead of sidecar'
    make_wrapup_worker claude "## Solution: use --request-file path"
    # Do NOT seed a cache entry — the helper must use the provided request file.
    When run script "$SCRIPT" \
      --ctx "nonexistent-ctx" --req "nonexistent-req" \
      --input-fifo "$INPUT_FILE" \
      --request-file "$REQ"
    The status should be success
    The contents of file "$INPUT_FILE" should include "Solution"
  End

  # ── (d) the custom prompt includes the original request ────────────────────
  It '(d) the wrap-up prompt passed to the worker contains the original request'
    make_wrapup_worker claude "## Solution: done"
    seed_entry playbook "## step"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE"
    The status should be success
    # The stub worker logged PROMPT_FILE_CONTENT; it must include the request.
    The contents of file "$TEST_TMP/worker-log" should include "wrapup test request"
  End

  # ── (d2) no-worker: error message written, pane kept open (no quit-sentinel) ──
  It '(d2) no-worker: writes an error message to input-fifo, does NOT write the quit-sentinel'
    # No worker in bin dir — all resolve_harness probes fail.
    seed_entry playbook "## Playbook step 1"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE"
    The status should be success
    # Must contain the warning marker (kept pane open).
    The contents of file "$INPUT_FILE" should include "⚠"
    The contents of file "$INPUT_FILE" should include "no assistant available"
    # Must NOT contain the quit-sentinel bytes (DLE 'q' DLE = 0x10 0x71 0x10).
    fifo_hex="$(xxd -p "$INPUT_FILE" 2>/dev/null || od -A n -t x1 "$INPUT_FILE" 2>/dev/null | tr -d ' \n')"
    The value "$fifo_hex" should not include "107110"
  End

  # ── (d3) no-entry: error message written, pane kept open (no quit-sentinel) ──
  It '(d3) no-entry (fresh playbook, no cache): writes an error message, does NOT write the quit-sentinel'
    make_wrapup_worker claude "unused"
    # Do NOT seed a cache entry; pass a non-existent ctx/req so resolution fails.
    When run script "$SCRIPT" \
      --ctx "nonexistent-ctx" --req "nonexistent-req" \
      --input-fifo "$INPUT_FILE"
    The status should be success
    # Must contain the warning marker.
    The contents of file "$INPUT_FILE" should include "⚠"
    The contents of file "$INPUT_FILE" should include "could not load"
    # Must NOT contain the quit-sentinel bytes.
    fifo_hex="$(xxd -p "$INPUT_FILE" 2>/dev/null || od -A n -t x1 "$INPUT_FILE" 2>/dev/null | tr -d ' \n')"
    The value "$fifo_hex" should not include "107110"
  End

  # ── (e) solution artifact includes front-matter header ─────────────────────
  It '(e) solution artifact starts with a front-matter header'
    make_wrapup_worker claude "## Solution: done"
    seed_entry playbook "## step"
    When run script "$SCRIPT" \
      --ctx "$CTX" --req "$REQ_HASH" --input-fifo "$INPUT_FILE"
    The status should be success
    artifact="$(ls "$AI_ASSIST_DATA_DIR/solutions"/*.md 2>/dev/null | head -1)"
    The contents of file "$artifact" should include "request:"
    The contents of file "$artifact" should include "created_at:"
  End

End
