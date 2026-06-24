# Tests for home/dot_local/libexec/executable_ai-assist-triage: the detached
# triage orchestrator/router. It reads one framed record off the OUT fifo the
# float writes (submit␟<value>␞ / cancel␞), finalizes the request, resolves the
# harness non-interactively, runs the harness's cheap `--triage` pass, classifies
# the result, drives the float's spinner via status␟…␞ / close␞ on the IN fifo,
# then routes three ways:
#   command  → zellij action write-chars --pane-id P (no trailing CR)
#   answer   → docked pane via ai-assist-render reusing the same fifos
#   escalate → docked pane via ai-assist-render running the capable worker
#
# Stubs: zellij (records argv), the dispatcher + a worker whose `--triage`
# emits a chosen sentinel, and ai-assist-render (records argv).
Describe 'ai-assist-triage'
  US=$'\x1f'
  RS=$'\x1e'

  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export XDG_DATA_HOME="$TEST_TMP/data"
    export AI_ASSIST_SESSION="testsess"
    export AI_ASSIST_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export ZELLIJ=1
    mkdir -p "$HOME"

    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-triage"

    # The fifos the float would have created (summon's job). The orchestrator
    # opens OUT read-side early, so we can write to it without blocking.
    OUT_FIFO="$TEST_TMP/out.fifo"
    IN_FIFO="$TEST_TMP/in.fifo"
    mkfifo -m 600 "$OUT_FIFO" "$IN_FIFO"

    # Stub zellij: record the full argument vector.
    zjstub="$TEST_TMP/zjstub"
    {
      echo '#!/usr/bin/env zsh'
      echo "printf '%s\\n' \"\$*\" >> \"$TEST_TMP/zj-args\""
    } > "$zjstub"; chmod +x "$zjstub"
    export ZELLIJ_BIN="$zjstub"

    # Stub ai-assist-render: record argv (so we can assert the reused fifos and
    # the capable-worker command on the escalate/answer paths).
    renderstub="$TEST_TMP/ai-assist-render"
    {
      echo '#!/usr/bin/env zsh'
      echo "printf '%s\\n' \"\$*\" >> \"$TEST_TMP/render-args\""
    } > "$renderstub"; chmod +x "$renderstub"
    export AI_ASSIST_RENDER_BIN="$renderstub"

    # A private bin dir holding a stub dispatcher + a single stub worker, so the
    # orchestrator resolves the harness non-interactively (sole available).
    mkdir -p "$TEST_TMP/bin"
    export AI_ASSIST_BIN_DIR="$TEST_TMP/bin"

    # make_worker <harness> <triage-output> <triage-exit>
    # --probe → available; --triage → prints the chosen sentinel, exits given.
    # The capable path mimics a real worker: it spawns a docked pane via the
    # (stub) zellij running the (stub) ai-assist-render wrapping the harness
    # command — so escalate's "new-pane / ai-assist-render / ai-assist-<h>"
    # assertions hold without depending on a real render under $HOME.
    make_worker() {
      local h="$1" tout="$2" texit="${3:-0}"
      {
        echo '#!/usr/bin/env zsh'
        echo "[[ \"\${1:-}\" == --probe ]] && { print -r -- '$h available'; exit 0; }"
        echo "if [[ \"\${1:-}\" == --triage ]]; then"
        echo "  printf '%s' \"$tout\""
        echo "  exit $texit"
        echo "fi"
        # Capable path: docked pane = zellij new-pane → ai-assist-render -- ai-assist-<h> …
        echo "\"\$ZELLIJ_BIN\" action new-pane --direction right --close-on-exit --name ai-assist -- \"\$AI_ASSIST_RENDER_BIN\" --harness $h -- ai-assist-$h --print"
      } > "$TEST_TMP/bin/ai-assist-$h"
      chmod +x "$TEST_TMP/bin/ai-assist-$h"
    }

    # A minimal request.json (summon would have built this partial).
    REQ="$TEST_TMP/request.json"
    cat > "$REQ" <<'JSON'
{
  "version": 1,
  "kind": "question",
  "origin": {"cwd":"/tmp/proj","project_root":"/tmp/proj","pane_id":"terminal_7"},
  "command": {"text":"","exit":null},
  "scrollback":"",
  "user_request":"",
  "project":{"name":"proj","branch":"main"}
}
JSON

    # feed_submit <value> — push a submit record onto the OUT fifo in the
    # background (the orchestrator opens OUT for reading, then we write).
    feed() {  # feed <record-without-trailing-RS>
      printf '%s%s' "$1" "$RS" > "$OUT_FIFO" &
    }
    # drain_in — keep a reader on the IN fifo so the orchestrator's status/close
    # writes never block, and record them.
    drain_in() {
      ( cat "$IN_FIFO" > "$TEST_TMP/in.log" ) &
    }
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'routes __COMMAND__ to write-chars on the origin pane with no trailing CR'
    make_worker claude "__COMMAND__"$'\n'"mogrify -resize 50% *.png" 0
    drain_in
    feed "submit${US}resize images"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/zj-args" should include "write-chars --pane-id terminal_7"
    The contents of file "$TEST_TMP/zj-args" should include "mogrify -resize 50%"
    # Bracketed paste: ESC[200~ (27 91 50 48 48 126) opens it; ESC[201~ closes it,
    # so the command lands as one editable buffer and embedded newlines can't run.
    The contents of file "$TEST_TMP/zj-args" should include "write --pane-id terminal_7 27 91 50 48 48 126"
    The contents of file "$TEST_TMP/zj-args" should include "27 91 50 48 49 126"
    # No CR write (the broker's `play` uses `action write … 13`; COMMAND must NOT).
    The contents of file "$TEST_TMP/zj-args" should not include "write 13"
    # No docked pane for a command.
    The contents of file "$TEST_TMP/zj-args" should not include "new-pane"
    # A close␞ dismisses the float before routing.
    The contents of file "$TEST_TMP/in.log" should include "close"
  End

  It 'routes __ANSWER__ to a docked pane via ai-assist-render reusing the fifos'
    make_worker claude "__ANSWER__"$'\n'"Use mogrify from ImageMagick." 0
    drain_in
    feed "submit${US}how to resize"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    # render is the docked command, handed the SAME fifo pair.
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-render"
    The contents of file "$TEST_TMP/zj-args" should include "--input-fifo $IN_FIFO"
    The contents of file "$TEST_TMP/zj-args" should include "--actions-fifo $OUT_FIFO"
    # render must receive --shell-cwd so it spawns an agent shell (enabling `run`).
    The contents of file "$TEST_TMP/zj-args" should include "--shell-cwd /tmp/proj"
    # Not a write-chars to the prompt.
    The contents of file "$TEST_TMP/zj-args" should not include "write-chars"
    The contents of file "$TEST_TMP/in.log" should include "close"
  End

  It 'routes __ESCALATE__ to a docked pane running the capable worker via render'
    make_worker claude "__ESCALATE__: needs multi-step work" 0
    drain_in
    feed "submit${US}rewrite the build"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-render"
    # The docked render runs the capable worker (resolved harness → ai-assist-claude).
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-claude"
    The contents of file "$TEST_TMP/in.log" should include "close"
  End

  It 'escalates when triage just echoes the failed command back (no re-run)'
    # A failed command is in the request; the cheap pass unhelpfully returns it as
    # a command. The orchestrator must escalate, never type the failed command back
    # onto the prompt (which would just re-run the failure).
    cat > "$TEST_TMP/req-failed.json" <<'JSON'
{
  "version": 1,
  "kind": "error",
  "origin": {"cwd":"/tmp/proj","project_root":"/tmp/proj","pane_id":"terminal_7"},
  "command": {"text":"gg build","exit":1},
  "scrollback":"BUILD FAILED",
  "user_request":"",
  "project":{"name":"proj","branch":"main"}
}
JSON
    make_worker claude "__COMMAND__"$'\n'"gg build" 0
    drain_in
    feed "submit${US}why did this fail?"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-failed.json" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-claude"
    The contents of file "$TEST_TMP/zj-args" should not include "write-chars"
    The contents of file "$TEST_TMP/in.log" should include "close"
  End

  It 'escalates when the harness --triage exits 3 (no cheap pass)'
    make_worker claude "" 3
    drain_in
    feed "submit${US}do something"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-render"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-claude"
  End

  It 'cancel closes the float and routes nothing'
    make_worker claude "__COMMAND__"$'\n'"ls" 0
    drain_in
    feed "cancel"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/in.log" should include "close"
    The path "$TEST_TMP/zj-args" should not be exist
    The path "$TEST_TMP/render-args" should not be exist
  End

  It 'falls back to a docked render of the command when the origin pane is missing'
    make_worker claude "__COMMAND__"$'\n'"echo hi" 0
    # A request with NO pane id anywhere (neither flag nor request.origin.pane_id).
    NOPANE="$TEST_TMP/nopane.json"
    cat > "$NOPANE" <<'JSON'
{
  "version": 1,
  "kind": "question",
  "origin": {"cwd":"/tmp/proj","project_root":"/tmp/proj"},
  "command": {"text":"","exit":null},
  "scrollback":"","user_request":"",
  "project":{"name":"proj","branch":"main"}
}
JSON
    drain_in
    feed "submit${US}print hi"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$NOPANE"
    The status should be success
    # No prompt write (no origin pane) → docked render instead.
    The contents of file "$TEST_TMP/zj-args" should not include "write-chars"
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-render"
  End

  It 'escalates via the dispatcher when several harnesses are available and none is pinned'
    make_worker claude "__COMMAND__"$'\n'"ls" 0
    make_worker pi "__COMMAND__"$'\n'"ls" 0
    # A stub dispatcher: the detached orchestrator must NOT run the interactive
    # picker itself — it hands off to `ai-assist`, which (in real life) spawns its
    # picker as a zellij FLOAT and then escalates. The stub records the handoff by
    # spawning the docked render pane via stub zellij.
    {
      echo '#!/usr/bin/env zsh'
      echo "\"\$ZELLIJ_BIN\" action new-pane --direction right --close-on-exit --name ai-assist -- \"\$AI_ASSIST_RENDER_BIN\" --harness claude -- ai-assist-claude --print"
    } > "$TEST_TMP/bin/ai-assist"; chmod +x "$TEST_TMP/bin/ai-assist"
    drain_in
    feed "submit${US}list files"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    # No cheap pass possible non-interactively → escalate via the dispatcher.
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-render"
    The contents of file "$TEST_TMP/zj-args" should not include "write-chars"
  End

  It 'escalate route removes the float OUT/IN fifo pair (orchestrator owns them)'
    # The escalate worker uses its own fifos — the float pair is free, so the
    # orchestrator must clean it up on every escalate branch (no orphans).
    make_worker claude "__ESCALATE__: needs full help" 0
    drain_in
    feed "submit${US}do the thing"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/in.log" should include "close"
    # Both fifos must be gone after the orchestrator exits.
    The path "$OUT_FIFO" should not be exist
    The path "$IN_FIFO" should not be exist
  End

  It 'answer route passes --cleanup-fifos to ai-assist-render and does not rm the pair itself'
    # The docked render pane outlives the orchestrator and must clean the fifos
    # when it exits. The orchestrator must NOT rm them (would yank them from
    # under the running render). Instead it delegates via --cleanup-fifos.
    make_worker claude "__ANSWER__"$'\n'"Use mogrify." 0
    drain_in
    feed "submit${US}how to resize images"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$REQ" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/in.log" should include "close"
    # render must be invoked with --cleanup-fifos so the pane cleans up on exit.
    The contents of file "$TEST_TMP/zj-args" should include "--cleanup-fifos"
    # The orchestrator must NOT have removed the fifos (render owns them now).
    The path "$OUT_FIFO" should be exist
    The path "$IN_FIFO" should be exist
  End

  # ── Cache lookup + replay tests (Stage 3) ─────────────────────────────────

  # seed_cache <kind> <body> — store a cache entry using the real ai-assist-cache
  # helper. Uses the same request.json context + a fixed request text so the
  # triage lookup will find it.
  seed_cache() {
    local kind="$1" body_text="$2"
    local cache_script="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-cache"
    local body_tmp="$TEST_TMP/seed-body.txt"
    printf '%s\n' "$body_text" > "$body_tmp"
    # Use the same REQ_* env the triage will see so context-hash matches.
    # For a general question (no failed command), context = project_root only.
    export REQ_PROJECT_ROOT="/tmp/proj"
    unset REQ_COMMAND_TEXT REQ_COMMAND_EXIT REQ_SCROLLBACK 2>/dev/null || true
    ctx="$("$cache_script" context-hash 2>/dev/null)"
    req="$("$cache_script" request-hash "cache hit test" 2>/dev/null)"
    export AI_ASSIST_DATA_DIR="$TEST_TMP/cache-data"
    mkdir -p "$AI_ASSIST_DATA_DIR"
    "$cache_script" store "$ctx" "$req" "$kind" "$body_tmp" \
      "request=cache hit test" "project_root=/tmp/proj" "harness=claude" >/dev/null 2>&1
    unset REQ_PROJECT_ROOT 2>/dev/null || true
    # Symlink the real cache script into stub bin dir AND the expected libexec
    # path (HOME is overridden to $TEST_TMP/home in setup, so triage's fallback
    # $HOME/.local/libexec/ai-assist-cache resolves to that location).
    ln -sf "$cache_script" "$TEST_TMP/bin/ai-assist-cache" 2>/dev/null || true
    mkdir -p "$TEST_TMP/home/.local/libexec"
    ln -sf "$cache_script" "$TEST_TMP/home/.local/libexec/ai-assist-cache" 2>/dev/null || true
  }

  # make_classify_recorder — replace the worker's --triage path with a stub that
  # records when the cheap model was called (we assert it is NOT called on a hit).
  make_classify_recorder() {
    local h="${1:-claude}"
    {
      echo '#!/usr/bin/env zsh'
      echo "[[ \"\${1:-}\" == --probe ]] && { print -r -- '$h available'; exit 0; }"
      echo "if [[ \"\${1:-}\" == --triage ]]; then"
      echo "  printf 'CLASSIFY_CALLED' >> \"$TEST_TMP/classify-calls\""
      echo "  printf '__ANSWER__\nfallback answer'"
      echo "  exit 0"
      echo "fi"
    } > "$TEST_TMP/bin/ai-assist-$h"
    chmod +x "$TEST_TMP/bin/ai-assist-$h"
  }

  # REQ_JSON with the request pre-filled to "cache hit test" (matching seed_cache).
  # jq must update user_request so the hash matches; we inject it statically.
  make_hit_req() {
    cat > "$TEST_TMP/req-hit.json" <<'JSON'
{
  "version": 1,
  "kind": "question",
  "origin": {"cwd":"/tmp/proj","project_root":"/tmp/proj","pane_id":"terminal_7"},
  "command": {"text":"","exit":null},
  "scrollback":"",
  "user_request":"cache hit test",
  "project":{"name":"proj","branch":"main"}
}
JSON
  }

  It 'cache HIT (command kind): re-stages the body via bracketed paste without invoking classify'
    make_classify_recorder claude
    # seed_cache exports AI_ASSIST_DATA_DIR to $TEST_TMP/cache-data; When run
    # inherits it since it's exported in the enclosing shell.
    seed_cache command "cached-cmd --opt value"
    make_hit_req
    drain_in
    # Submit the same request text that was seeded.
    feed "submit${US}cache hit test"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-hit.json" --origin-pane terminal_7
    The status should be success
    # Must have dismissed the float.
    The contents of file "$TEST_TMP/in.log" should include "close"
    # Bracketed paste must carry the cached body.
    The contents of file "$TEST_TMP/zj-args" should include "write-chars --pane-id terminal_7"
    The contents of file "$TEST_TMP/zj-args" should include "cached-cmd --opt value"
    # ESC[200~ open bracket.
    The contents of file "$TEST_TMP/zj-args" should include "27 91 50 48 48 126"
    # The cheap classify must NOT have been invoked.
    The path "$TEST_TMP/classify-calls" should not be exist
  End

  It 'cache HIT (answer kind): spawns render with -- <cache-bin> body <entry> and --cached flag'
    make_classify_recorder claude
    seed_cache answer "This is a cached answer."
    make_hit_req
    drain_in
    feed "submit${US}cache hit test"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-hit.json" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/in.log" should include "close"
    # render must be invoked with the cache body emitter.
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-render"
    # The body subcommand must appear in the render command.
    The contents of file "$TEST_TMP/zj-args" should include "body"
    # --cached flag must be forwarded.
    The contents of file "$TEST_TMP/zj-args" should include "--cached"
    # Stage 4: --regen-ctx and --regen-req must be forwarded so the broker can
    # invoke ai-assist-regenerate when the user clicks the cached pill.
    The contents of file "$TEST_TMP/zj-args" should include "--regen-ctx"
    The contents of file "$TEST_TMP/zj-args" should include "--regen-req"
    # The cheap classify must NOT have been invoked.
    The path "$TEST_TMP/classify-calls" should not be exist
  End

  It 'cache HIT (playbook kind): spawns render with -- <cache-bin> body <entry> and --cached flag'
    make_classify_recorder claude
    seed_cache playbook "## Cached Playbook\nstep 1"
    make_hit_req
    drain_in
    feed "submit${US}cache hit test"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-hit.json" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/in.log" should include "close"
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "body"
    The contents of file "$TEST_TMP/zj-args" should include "--cached"
    The path "$TEST_TMP/classify-calls" should not be exist
  End

  It 'cache MISS (no entry): falls through to the normal classify path'
    make_worker claude "__ANSWER__"$'\n'"A fresh answer." 0
    # Ensure cache data dir exists but does NOT contain an entry for this request.
    export AI_ASSIST_DATA_DIR="$TEST_TMP/cache-data"
    mkdir -p "$AI_ASSIST_DATA_DIR"
    make_hit_req
    drain_in
    # Different request text → no entry in the cache → miss.
    feed "submit${US}this request has no cache entry"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-hit.json" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/in.log" should include "close"
    # Normal answer route: render is spawned without "body" (uses printf payload).
    The contents of file "$TEST_TMP/zj-args" should include "new-pane"
    The contents of file "$TEST_TMP/zj-args" should include "ai-assist-render"
  End

  It 'cache MISS persists the regenerate sidecar (request.json) next to the entry'
    make_worker claude "__ANSWER__"$'\n'"A fresh answer." 0
    export AI_ASSIST_DATA_DIR="$TEST_TMP/cache-data"
    mkdir -p "$AI_ASSIST_DATA_DIR"
    # Symlink the real cache helper so store actually runs (mirrors seed_cache).
    cache_script="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-cache"
    ln -sf "$cache_script" "$TEST_TMP/bin/ai-assist-cache" 2>/dev/null || true
    mkdir -p "$TEST_TMP/home/.local/libexec"
    ln -sf "$cache_script" "$TEST_TMP/home/.local/libexec/ai-assist-cache" 2>/dev/null || true
    # Compute the (ctx, req) this submit produces (project-only ctx; request text).
    export REQ_PROJECT_ROOT="/tmp/proj"
    unset REQ_COMMAND_TEXT REQ_COMMAND_EXIT REQ_SCROLLBACK 2>/dev/null || true
    ctx="$("$cache_script" context-hash 2>/dev/null)"
    req="$("$cache_script" request-hash "sidecar persist test" 2>/dev/null)"
    unset REQ_PROJECT_ROOT 2>/dev/null || true
    make_hit_req
    drain_in
    feed "submit${US}sidecar persist test"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-hit.json" --origin-pane terminal_7
    The status should be success
    The path "$TEST_TMP/cache-data/cache/$ctx/$req.request.json" should be file
  End

  It 'AI_ASSIST_NO_CACHE=1 forces a miss and invokes the classify path'
    make_classify_recorder claude
    seed_cache answer "Cached answer that should be bypassed."
    make_hit_req
    drain_in
    feed "submit${US}cache hit test"
    # Export AI_ASSIST_NO_CACHE before When run so the subprocess inherits it.
    export AI_ASSIST_NO_CACHE=1
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-hit.json" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/in.log" should include "close"
    # Classify was called (no-cache forced the miss).
    The path "$TEST_TMP/classify-calls" should be file
  End

  # A failed command whose scrollback could not be captured has an unreliable
  # cache key — triage must DISABLE the cache (no false hit across different
  # errors of the same command).
  It 'disables the cache for a failure with empty scrollback'
    make_classify_recorder claude
    export AI_ASSIST_DEBUG_LOG="$TEST_TMP/dbg.log"
    cat > "$TEST_TMP/req-fail.json" <<'JSON'
{
  "version": 1,
  "kind": "question",
  "origin": {"cwd":"/tmp/proj","project_root":"/tmp/proj","pane_id":"terminal_7"},
  "command": {"text":"make all","exit":2},
  "scrollback": "",
  "user_request": "why did make fail",
  "project": {"name":"proj","branch":"main"}
}
JSON
    drain_in
    feed "submit${US}why did make fail"
    When run script "$SCRIPT" --out-fifo "$OUT_FIFO" --in-fifo "$IN_FIFO" \
      --request "$TEST_TMP/req-fail.json" --origin-pane terminal_7
    The status should be success
    The contents of file "$TEST_TMP/dbg.log" should include "cache: DISABLED"
  End
End
