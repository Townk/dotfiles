# Tests for the ai-assist-<harness> workers. Each worker is run as a subprocess
# with a stub harness binary and a stub zellij; the library is pointed at the
# repo via AI_ASSIST_LIB_DIR.
Describe 'ai-assist workers'
  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export XDG_DATA_HOME="$TEST_TMP/data"
    export AI_ASSIST_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export ZELLIJ=1
    mkdir -p "$HOME"

    # Stub zellij: record the full argument vector.
    zjstub="$TEST_TMP/zjstub"
    {
      echo '#!/usr/bin/env zsh'
      echo "printf '%s\\n' \"\$*\" >> \"$TEST_TMP/zj-args\""
    } > "$zjstub"; chmod +x "$zjstub"
    export ZELLIJ_BIN="$zjstub"

    # A request fixture.
    cat > "$TEST_TMP/req.json" <<'JSON'
{
  "version": 1,
  "kind": "error",
  "origin": {"cwd":"/tmp/proj","project_root":"/tmp/proj"},
  "command": {"text":"make","exit":2},
  "scrollback":"No rule to make target 'all'.",
  "user_request":"Diagnose why make failed",
  "project":{"name":"proj","branch":"main"}
}
JSON
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'assist::system_prompt'
    check_prompt_tools() {
      source "$AI_ASSIST_LIB_DIR/assist-agent-common.zsh"
      kb="$(mktemp)"
      prompt="$(assist::system_prompt "$kb")"
      case "$prompt" in
        *ai-assist-run*) ;; (*) echo "missing ai-assist-run" >&2; return 1 ;;
      esac
      case "$prompt" in
        *ai-assist-ask*) ;; (*) echo "missing ai-assist-ask" >&2; return 1 ;;
      esac
      case "$prompt" in
        *ai-assist-remember*) ;; (*) echo "missing ai-assist-remember" >&2; return 1 ;;
      esac
      case "$prompt" in
        *secret*|*secrets*) ;; (*) echo "missing secrets rule" >&2; return 1 ;;
      esac
    }

    It 'tells the agent about the helper tools and the secrets rule'
      When run check_prompt_tools
      The status should be success
    End
  End

  Describe 'ai-assist-claude'
    SCRIPT() { echo "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_ai-assist-claude"; }

    It 'probe succeeds when claude is on PATH'
      stubdir="$TEST_TMP/pathbin"; mkdir -p "$stubdir"
      printf '#!/bin/sh\n' > "$stubdir/claude"; chmod +x "$stubdir/claude"
      export PATH="$stubdir:$PATH"
      When run script "$(SCRIPT)" --probe
      The status should be success
      The output should include "Claude Code"
    End

    It 'probe fails when claude is absent'
      export AI_ASSIST_CLAUDE_BIN="definitely-not-a-real-binary-xyz"
      When run script "$(SCRIPT)" --probe
      The status should be failure
    End

    It 'spawns a docked pane running claude with the model and the prompt'
      export AI_ASSIST_CLAUDE_BIN="claude"
      When run script "$(SCRIPT)" --request "$TEST_TMP/req.json"
      The status should be success
      The stdout should include "ai-assist"
      The contents of file "$TEST_TMP/zj-args" should include "action new-pane"
      The contents of file "$TEST_TMP/zj-args" should include "--cwd /tmp/proj"
      The contents of file "$TEST_TMP/zj-args" should include "claude --print"
      The contents of file "$TEST_TMP/zj-args" should include "--model sonnet"
      The contents of file "$TEST_TMP/zj-args" should include "Diagnose why make failed"
    End

    It 'dies without a --request file'
      When run script "$(SCRIPT)"
      The status should be failure
      The stderr should include "request"
    End

    It 'accepts --request=FILE (equals-sign form)'
      export AI_ASSIST_CLAUDE_BIN="claude"
      When run script "$(SCRIPT)" --request="$TEST_TMP/req.json"
      The status should be success
      The stdout should include "ai-assist"
      The contents of file "$TEST_TMP/zj-args" should include "action new-pane"
      The contents of file "$TEST_TMP/zj-args" should include "claude --print"
      The contents of file "$TEST_TMP/zj-args" should include "Diagnose why make failed"
    End

    It 'passes trailing guidance to the prompt'
      export AI_ASSIST_CLAUDE_BIN="claude"
      When run script "$(SCRIPT)" --request "$TEST_TMP/req.json" -- please check the Makefile
      The status should be success
      The stdout should include "ai-assist"
      The contents of file "$TEST_TMP/zj-args" should include "Additional guidance from the caller:"
      The contents of file "$TEST_TMP/zj-args" should include "please check the Makefile"
    End

    It 'passes the agent-shell env + cwd to ai-assist-render and snapshots the env'
      # Create a stub render so the worker takes the AI_ASSIST_RENDER=1 branch;
      # it just needs to be executable — zellij is also stubbed, so it never runs.
      render_dir="$TEST_TMP/home/.local/libexec"
      mkdir -p "$render_dir"
      printf '#!/usr/bin/env zsh\n' > "$render_dir/ai-assist-render"; chmod +x "$render_dir/ai-assist-render"
      REQFILE="$TEST_TMP/req.json"
      export AI_ASSIST_CLAUDE_BIN="claude"
      export AI_ASSIST_RENDER=1
      When run script "$(SCRIPT)" --request "$REQFILE"
      The status should be success
      The stdout should include "ai-assist"
      The contents of file "$TEST_TMP/zj-args" should include "--shell-env"
      The contents of file "$TEST_TMP/zj-args" should include "--shell-cwd"
      The path "${REQFILE:h}/request.env" should be exist
    End
  End

  Describe 'ai-assist-pi'
    SCRIPT() { echo "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_ai-assist-pi"; }

    It 'probe succeeds when pi is on PATH'
      stubdir="$TEST_TMP/pathbin"; mkdir -p "$stubdir"
      printf '#!/bin/sh\n' > "$stubdir/pi"; chmod +x "$stubdir/pi"
      export PATH="$stubdir:$PATH"
      When run script "$(SCRIPT)" --probe
      The status should be success
      The output should include "Pi Coding Agent"
    End

    It 'spawns a docked pane running pi with a capable model and the prompt'
      When run script "$(SCRIPT)" --request "$TEST_TMP/req.json"
      The status should be success
      The stdout should include "ai-assist"
      The contents of file "$TEST_TMP/zj-args" should include "pi --print"
      The contents of file "$TEST_TMP/zj-args" should include "--no-session"
      The contents of file "$TEST_TMP/zj-args" should include "--model opencode-go/kimi-k2.6"
      The contents of file "$TEST_TMP/zj-args" should include "Diagnose why make failed"
    End
  End

  Describe 'ai-assist-cursor'
    SCRIPT() { echo "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_ai-assist-cursor"; }

    It 'probe succeeds when cursor-agent is on PATH'
      stubdir="$TEST_TMP/pathbin"; mkdir -p "$stubdir"
      printf '#!/bin/sh\n' > "$stubdir/cursor-agent"; chmod +x "$stubdir/cursor-agent"
      export PATH="$stubdir:$PATH"
      When run script "$(SCRIPT)" --probe
      The status should be success
      The output should include "Cursor Agent"
    End

    It 'spawns a docked pane running cursor-agent with the prompt'
      export AI_ASSIST_CURSOR_BIN="cursor-agent"
      When run script "$(SCRIPT)" --request "$TEST_TMP/req.json"
      The status should be success
      The stdout should include "ai-assist"
      The contents of file "$TEST_TMP/zj-args" should include "cursor-agent --print"
      The contents of file "$TEST_TMP/zj-args" should include "--trust"
      The contents of file "$TEST_TMP/zj-args" should include "Diagnose why make failed"
    End

    It 'adds --model only when one is set'
      export AI_ASSIST_CURSOR_BIN="cursor-agent"
      export AI_ASSIST_MODEL="some-capable-model"
      When run script "$(SCRIPT)" --request "$TEST_TMP/req.json"
      The status should be success
      The stdout should include "ai-assist"
      The contents of file "$TEST_TMP/zj-args" should include "--model some-capable-model"
    End
  End
End
