Describe 'ai-assist-cache'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-cache"

  setup() {
    TEST_TMP="$(mktemp -d)"
    export AI_ASSIST_DATA_DIR="$TEST_TMP/ai-assist"
    mkdir -p "$AI_ASSIST_DATA_DIR"
    # Ensure REQ_* vars are clean.
    unset REQ_PROJECT_ROOT REQ_CWD REQ_COMMAND_TEXT REQ_COMMAND_EXIT REQ_SCROLLBACK 2>/dev/null || true
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset AI_ASSIST_DATA_DIR REQ_PROJECT_ROOT REQ_CWD REQ_COMMAND_TEXT REQ_COMMAND_EXIT REQ_SCROLLBACK 2>/dev/null || true
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # ── context-hash ─────────────────────────────────────────────────────────────

  Describe 'context-hash'
    It 'produces the same hash for identical REQ_* inputs'
      export REQ_PROJECT_ROOT=/tmp/proj
      export REQ_COMMAND_TEXT='make build'
      export REQ_COMMAND_EXIT=1
      export REQ_SCROLLBACK='error: build failed'
      hash1="$("$SCRIPT" context-hash)"
      hash2="$("$SCRIPT" context-hash)"
      The value "$hash1" should equal "$hash2"
    End

    It 'without a command, changing REQ_SCROLLBACK does NOT change the hash (project-only)'
      export REQ_PROJECT_ROOT=/tmp/proj
      unset REQ_COMMAND_TEXT 2>/dev/null || true
      export REQ_SCROLLBACK='noise line 1'
      hash1="$("$SCRIPT" context-hash)"
      export REQ_SCROLLBACK='completely different noise'
      hash2="$("$SCRIPT" context-hash)"
      The value "$hash1" should equal "$hash2"
    End

    It 'with a command, ANSI-stripped scrollback matches plain scrollback'
      export REQ_PROJECT_ROOT=/tmp/proj
      export REQ_COMMAND_TEXT='make build'
      export REQ_COMMAND_EXIT=2
      # Plain scrollback.
      export REQ_SCROLLBACK='error: build failed'
      hash_plain="$("$SCRIPT" context-hash)"
      # Same scrollback wrapped with ANSI escape sequences.
      export REQ_SCROLLBACK=$'\x1b[31merror: build failed\x1b[0m'
      hash_ansi="$("$SCRIPT" context-hash)"
      The value "$hash_plain" should equal "$hash_ansi"
    End

    It 'with a command, trailing whitespace differences in scrollback normalize to same hash'
      export REQ_PROJECT_ROOT=/tmp/proj
      export REQ_COMMAND_TEXT='make build'
      export REQ_COMMAND_EXIT=2
      export REQ_SCROLLBACK='error: build failed'
      hash_clean="$("$SCRIPT" context-hash)"
      export REQ_SCROLLBACK='error: build failed   '
      hash_trailing="$("$SCRIPT" context-hash)"
      The value "$hash_clean" should equal "$hash_trailing"
    End

    It 'a different REQ_COMMAND_TEXT produces a different hash'
      export REQ_PROJECT_ROOT=/tmp/proj
      export REQ_COMMAND_EXIT=1
      export REQ_SCROLLBACK='error'
      export REQ_COMMAND_TEXT='make build'
      hash1="$("$SCRIPT" context-hash)"
      export REQ_COMMAND_TEXT='make test'
      hash2="$("$SCRIPT" context-hash)"
      The value "$hash1" should not equal "$hash2"
    End

    It 'falls back to REQ_CWD when REQ_PROJECT_ROOT is absent'
      unset REQ_PROJECT_ROOT 2>/dev/null || true
      export REQ_CWD=/tmp/fallback
      hash1="$("$SCRIPT" context-hash)"
      export REQ_PROJECT_ROOT=/tmp/fallback
      unset REQ_CWD 2>/dev/null || true
      hash2="$("$SCRIPT" context-hash)"
      The value "$hash1" should equal "$hash2"
    End
  End

  # ── request-hash ─────────────────────────────────────────────────────────────

  Describe 'request-hash'
    It 'is deterministic'
      hash1="$("$SCRIPT" request-hash 'how do I resize images')"
      hash2="$("$SCRIPT" request-hash 'how do I resize images')"
      The value "$hash1" should equal "$hash2"
    End

    It 'trims leading and trailing whitespace before hashing'
      hash_plain="$("$SCRIPT" request-hash 'how do I resize images')"
      hash_padded="$("$SCRIPT" request-hash '  how do I resize images  ')"
      The value "$hash_plain" should equal "$hash_padded"
    End

    It 'differs for different inputs'
      hash1="$("$SCRIPT" request-hash 'foo')"
      hash2="$("$SCRIPT" request-hash 'bar')"
      The value "$hash1" should not equal "$hash2"
    End
  End

  # ── store → lookup round-trip ─────────────────────────────────────────────────

  Describe 'store and lookup'
    # Store an entry in setup so both store + lookup tests share it cleanly.
    store_entry() {
      body_file="$TEST_TMP/body.txt"
      printf 'echo hello world\n' > "$body_file"
      ctx="$("$SCRIPT" context-hash)"
      req="$("$SCRIPT" request-hash 'list files')"
      stored_entry="$("$SCRIPT" store "$ctx" "$req" command "$body_file" 2>/dev/null)"
    }

    It 'store creates the entry file'
      store_entry
      The path "$stored_entry" should be file
    End

    It 'lookup returns the entry path and exits 0'
      store_entry
      When run "$SCRIPT" lookup "$ctx" "$req"
      The status should be success
      The output should equal "$stored_entry"
    End

    It 'lookup returns exit 1 on a miss'
      When run "$SCRIPT" lookup "deadbeef0000000000000000000000000000000000000000000000000000cafe" "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      The status should eq 1
      The output should equal ''
    End
  End

  # ── store writes correct front matter and body ────────────────────────────────

  Describe 'store content'
    It 'writes front matter with kind and extra k=v pairs'
      body_file="$TEST_TMP/body.txt"
      printf '## My Playbook\nstep 1\n' > "$body_file"
      entry="$("$SCRIPT" store "abc123" "def456" playbook "$body_file" \
        "request=fix the build" "project_root=/tmp/proj" "harness=claude" 2>/dev/null)"
      The path "$entry" should be file
      The contents of file "$entry" should include 'schema: ai-assist-cache/v1'
      The contents of file "$entry" should include 'kind: playbook'
      The contents of file "$entry" should include 'context_hash: abc123'
      The contents of file "$entry" should include 'request_hash: def456'
      The contents of file "$entry" should include 'project_root: /tmp/proj'
      The contents of file "$entry" should include 'harness: claude'
      The contents of file "$entry" should include 'created_at:'
    End

    It 'includes the body after the front matter'
      body_file="$TEST_TMP/body.txt"
      printf '## My Playbook\nstep 1\n' > "$body_file"
      entry="$("$SCRIPT" store "aaa" "bbb" playbook "$body_file" 2>/dev/null)"
      The contents of file "$entry" should include '## My Playbook'
      The contents of file "$entry" should include 'step 1'
    End

    It 'body strips the front matter and returns only the body'
      body_file="$TEST_TMP/body.txt"
      printf 'original body content\n' > "$body_file"
      entry="$("$SCRIPT" store "ccc" "ddd" answer "$body_file" 2>/dev/null)"
      When run "$SCRIPT" body "$entry"
      The status should be success
      The output should include 'original body content'
      The output should not include 'schema:'
      The output should not include '---'
    End

    It 'body prints the file as-is when there is no front matter'
      plain_file="$TEST_TMP/plain.md"
      printf 'no front matter here\n' > "$plain_file"
      When run "$SCRIPT" body "$plain_file"
      The status should be success
      The output should equal 'no front matter here'
    End
  End

  # ── prompts.jsonl ─────────────────────────────────────────────────────────────

  Describe 'prompts.jsonl'
    It 'store appends a well-formed JSONL line'
      body_file="$TEST_TMP/body.txt"
      printf 'body\n' > "$body_file"
      "$SCRIPT" store "ctx1" "req1" command "$body_file" "request=how to list files" >/dev/null 2>&1
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      The path "$prompts" should be file
      The contents of file "$prompts" should include '"ts"'
      The contents of file "$prompts" should include '"context":"ctx1"'
      The contents of file "$prompts" should include '"kind":"command"'
      The contents of file "$prompts" should include '"request":"how to list files"'
    End

    It 'store appends multiple lines on successive calls'
      body_file="$TEST_TMP/body.txt"
      printf 'body\n' > "$body_file"
      "$SCRIPT" store "ctx1" "req1" command "$body_file" "request=first" >/dev/null 2>&1
      "$SCRIPT" store "ctx1" "req2" answer  "$body_file" "request=second" >/dev/null 2>&1
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      line_count="$(wc -l < "$prompts" | tr -d ' ')"
      The value "$line_count" should eq 2
    End

    It 'JSON-escapes double-quotes in the request field'
      body_file="$TEST_TMP/body.txt"
      printf 'body\n' > "$body_file"
      "$SCRIPT" store "ctx1" "req1" answer "$body_file" 'request=say "hello"' >/dev/null 2>&1
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      # The JSON value should have backslash-escaped quotes: \"hello\"
      The contents of file "$prompts" should include '\"hello\"'
    End
  End

  # ── history ────────────────────────────────────────────────────────────────────

  Describe 'history'
    skip_if_no_jq() { command -v jq >/dev/null 2>&1 || Skip 'jq not available'; }
    BeforeEach 'skip_if_no_jq'

    It 'returns empty output when there is no prompts.jsonl'
      When run "$SCRIPT" history "somecontext"
      The status should be success
      The output should equal ''
    End

    It 'dedups by request, keeping the latest ts'
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      # Two entries for the same request text, different ts.
      printf '{"ts":"2026-01-01T10:00:00Z","context":"ctx1","kind":"command","request":"how to list"}\n' >> "$prompts"
      printf '{"ts":"2026-01-01T11:00:00Z","context":"ctx1","kind":"answer","request":"how to list"}\n' >> "$prompts"
      result="$("$SCRIPT" history "ctx1")"
      # Should be exactly one result — use grep -c for reliable counting.
      count="$(printf '%s\n' "$result" | grep -c '"request"' || true)"
      The value "$count" should eq 1
      # Should keep the latest ts.
      The value "$result" should include '2026-01-01T11:00:00Z'
    End

    It 'ranks context-match entries first'
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      # An older context-match entry and a newer non-matching entry.
      printf '{"ts":"2026-01-01T09:00:00Z","context":"TARGET","kind":"answer","request":"context question"}\n' >> "$prompts"
      printf '{"ts":"2026-01-01T10:00:00Z","context":"OTHER","kind":"command","request":"other question"}\n' >> "$prompts"
      result="$("$SCRIPT" history "TARGET")"
      first_request="$(printf '%s\n' "$result" | head -1 | jq -r '.request')"
      The value "$first_request" should equal 'context question'
    End

    It 'context_match is true for matching context and false for others'
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      printf '{"ts":"2026-01-01T09:00:00Z","context":"TARGET","kind":"answer","request":"mine"}\n' >> "$prompts"
      printf '{"ts":"2026-01-01T10:00:00Z","context":"OTHER","kind":"command","request":"theirs"}\n' >> "$prompts"
      result="$("$SCRIPT" history "TARGET")"
      match_val="$(printf '%s\n' "$result" | jq -r 'select(.request=="mine") | .context_match')"
      other_val="$(printf '%s\n' "$result" | jq -r 'select(.request=="theirs") | .context_match')"
      The value "$match_val" should equal 'true'
      The value "$other_val" should equal 'false'
    End

    It 'caps to N results'
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      local i
      for i in $(seq 1 10); do
        printf '{"ts":"2026-01-01T%02d:00:00Z","context":"ctx","kind":"answer","request":"question %d"}\n' "$i" "$i" >> "$prompts"
      done
      result="$("$SCRIPT" history "ctx" 3)"
      count="$(printf '%s\n' "$result" | grep -c '"request"' || true)"
      The value "$count" should eq 3
    End

    It 'honors AI_ASSIST_PROMPT_CAP env variable'
      prompts="$AI_ASSIST_DATA_DIR/prompts.jsonl"
      local i
      for i in $(seq 1 10); do
        printf '{"ts":"2026-01-01T%02d:00:00Z","context":"ctx","kind":"answer","request":"q%d"}\n' "$i" "$i" >> "$prompts"
      done
      export AI_ASSIST_PROMPT_CAP=2
      result="$("$SCRIPT" history "ctx")"
      count="$(printf '%s\n' "$result" | grep -c '"request"' || true)"
      The value "$count" should eq 2
    End
  End

  # ── unknown subcommand ────────────────────────────────────────────────────────

  Describe 'error handling'
    It 'exits 2 on unknown subcommand'
      When run "$SCRIPT" frob
      The status should eq 2
      The stderr should include 'unknown subcommand'
    End

    It 'exits 2 with usage when no subcommand given'
      When run "$SCRIPT"
      The status should eq 2
      The stderr should include 'usage'
    End
  End
End
