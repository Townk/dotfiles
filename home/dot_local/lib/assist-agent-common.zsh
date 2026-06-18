#!/usr/bin/env zsh
# assist-agent-common.zsh — shared engine for the AI terminal assistant
# (ai-assist + ai-assist-<harness> workers). SOURCED, never executed.
#
# Sibling to commit-agent-common.zsh: the dispatcher and every worker source
# THIS file, which in turn pulls in the base (common.zsh) relative to itself.

_assist_self="${(%):-%x}"
source "$(dirname "$_assist_self")/common.zsh"
unset _assist_self

# Per-machine state (session pins) and data (knowledge base).
ASSIST_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ai-assist"
ASSIST_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ai-assist"

# ── Session pin ────────────────────────────────────────────────────────────
# The chosen harness is pinned per Zellij session so a session picks once.
assist::session_name() {
  print -r -- "${AI_ASSIST_SESSION:-${ZELLIJ_SESSION_NAME:-default}}"
}

assist::session_dir() {
  print -r -- "$ASSIST_STATE_DIR/sessions/$(assist::session_name)"
}

assist::pin_read() {
  local f="$(assist::session_dir)/harness"
  [[ -s "$f" ]] && cat "$f" || true
}

assist::pin_write() {
  local dir; dir="$(assist::session_dir)"
  mkdir -p "$dir"
  print -r -- "$1" > "$dir/harness"
}

assist::pin_clear() {
  rm -f -- "$(assist::session_dir)/harness" 2>/dev/null || true
}

# ── Request file ───────────────────────────────────────────────────────────
# Parse request.json into REQ_* globals. Tolerates partial requests (Phase A
# is exercised with hand-written fixtures; B/C populate the rest).
assist::request_read() {
  local file="$1"
  [[ -f "$file" ]] || die "request file not found: $file"
  require_cmd jq
  REQ_KIND=$(jq -r '.kind // "question"' "$file")
  REQ_SESSION=$(jq -r '.origin.zellij_session // empty' "$file")
  REQ_PANE_ID=$(jq -r '.origin.pane_id // empty' "$file")
  REQ_CWD=$(jq -r '.origin.cwd // empty' "$file")
  REQ_PROJECT_ROOT=$(jq -r '.origin.project_root // .origin.cwd // empty' "$file")
  REQ_COMMAND_TEXT=$(jq -r '.command.text // empty' "$file")
  REQ_COMMAND_EXIT=$(jq -r '.command.exit // empty' "$file")
  REQ_SCROLLBACK=$(jq -r '.scrollback // empty' "$file")
  REQ_USER_REQUEST=$(jq -r '.user_request // empty' "$file")
  REQ_PROJECT_NAME=$(jq -r '.project.name // empty' "$file")
  REQ_BRANCH=$(jq -r '.project.branch // empty' "$file")
}

# ── Knowledge base paths (created here, populated in Phase D) ───────────────
assist::project_key() {
  print -rn -- "$1" | shasum -a 1 | awk '{print $1}'
}

assist::kb_path() {
  print -r -- "$ASSIST_DATA_DIR/projects/$(assist::project_key "$1")/knowledge.md"
}

assist::kb_ensure() {
  local key kb_path
  key=$(assist::project_key "$1")
  # Note: variable named 'path' must NOT be used here — it shadows zsh's
  # special 'path' array (the array form of PATH), which would clear PATH
  # inside any nested command substitution.
  kb_path="$ASSIST_DATA_DIR/projects/$key/knowledge.md"
  mkdir -p "${kb_path:h}"
  [[ -e "$kb_path" ]] || : > "$kb_path"
  print -r -- "$kb_path"
}

# ── System prompt ──────────────────────────────────────────────────────────
# Assemble the standing prompt from the REQ_* globals + the project KB. Phase A
# is read-only diagnosis: command execution and user questions arrive with the
# helper tools in Phase C, so this prompt asks the agent to reason from the
# given context and finish with a summary.
assist::system_prompt() {
  local kb_path="$1" kb_block="" cmd_block=""
  if [[ -s "$kb_path" ]]; then
    kb_block=$'\n\n## What we already know about this project\n\n'"$(cat "$kb_path")"
  fi
  if [[ -n "${REQ_COMMAND_TEXT:-}" ]]; then
    cmd_block=$'\nFailed command: `'"${REQ_COMMAND_TEXT}"$'`'
    [[ -n "${REQ_COMMAND_EXIT:-}" ]] && cmd_block+=$' (exit '"${REQ_COMMAND_EXIT}"$')'
  fi

  cat <<EOF
You are a terminal assistant helping with a single, self-contained request.

Work within a bounded context: rely only on the information below plus a
focused look at the project — do not crawl the whole repository or restate
history. The goal is one fresh, tightly-scoped pass that ends in a clear answer.

Project: ${REQ_PROJECT_NAME:-${REQ_PROJECT_ROOT:-unknown}} (${REQ_PROJECT_ROOT:-?})${REQ_BRANCH:+ on branch ${REQ_BRANCH}}
Request kind: ${REQ_KIND:-question}${cmd_block}

What the user is trying to do:
${REQ_USER_REQUEST:-(no description given)}

Relevant terminal output (scrollback of the last command):
${REQ_SCROLLBACK:-(none captured)}${kb_block}

Diagnose the situation and explain what is going on and how to fix or proceed.
Finish with a short summary of the cause and the recommended next step.
EOF
}

# ── Docked pane ────────────────────────────────────────────────────────────
assist::zellij_bin() {
  local z="${ZELLIJ_BIN:-${commands[zellij]:-}}"
  [[ -n "$z" && -x "$z" ]] && { print -r -- "$z"; return 0; }
  for z in /opt/homebrew/bin/zellij /usr/local/bin/zellij /snap/bin/zellij "$HOME/.local/bin/zellij"; do
    [[ -x "$z" ]] && { print -r -- "$z"; return 0; }
  done
  return 1
}

# Open the agent's read-only display pane: a tiled split to the right, cwd at
# the project root, running <cmd...>. We deliberately do NOT pass
# --close-on-exit, so the pane PARKS with the transcript for review when the
# agent finishes.
assist::spawn_pane() {
  local zj; zj="$(assist::zellij_bin)" || die "zellij binary not found"
  [[ -n "${ZELLIJ:-}" ]] || die "not inside a Zellij session"
  "$zj" action new-pane --direction right --name "ai-assist" \
    --cwd "${REQ_PROJECT_ROOT:-$PWD}" -- "$@"
}
