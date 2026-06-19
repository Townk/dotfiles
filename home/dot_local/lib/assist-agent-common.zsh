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
  REQ_OVER_SSH=$(jq -r '.origin.over_ssh // false' "$file")
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
  # --close-on-exit: when the worker (ai-assist-render → pager) exits — e.g. the
  # user quits the pager with q/Esc — close the docked pane instead of parking it.
  "$zj" action new-pane --direction right --close-on-exit --name "ai-assist" \
    --cwd "${REQ_PROJECT_ROOT:-$PWD}" -- "$@"
  # zellij sizes only floating panes via --width; a tiled (--direction) pane opens
  # at 50%. Shrink the new (focused) pane toward ~40% so the original pane stays
  # the centerpiece. Best-effort: resize moves the shared border in fixed steps
  # (~5%/step here — 2 steps ≈ 40%).
  local _n
  for _n in 1 2; do "$zj" action resize decrease left 2>/dev/null || break; done
}

# ── Context capture (Phase B) ──────────────────────────────────────────────
: "${ATUIN_BIN:=atuin}"

# assist::capture_command — the last command run → CAP_CMD / CAP_EXIT /
# CAP_DIR / CAP_DURATION / CAP_KIND. (`atuin history last` is global and does
# NOT accept --session; the last global command is the one just run in this
# pane, so that's what we want anyway.)
assist::capture_command() {
  local row
  row="$("$ATUIN_BIN" history last \
        --format '{command}	{exit}	{directory}	{duration}' 2>/dev/null)" || row=""
  CAP_CMD="${row%%	*}"; row="${row#*	}"
  CAP_EXIT="${row%%	*}"; row="${row#*	}"
  CAP_DIR="${row%%	*}"; CAP_DURATION="${row#*	}"
  [[ "$CAP_CMD" == "$CAP_EXIT" ]] && CAP_EXIT=""   # single-field row guard
  if [[ -n "$CAP_EXIT" && "$CAP_EXIT" != 0 ]]; then CAP_KIND=error; else CAP_KIND=question; fi
}

# assist::capture_scrollback <cmd> — slice the dump-screen for the last run of
# <cmd>: from the last line containing <cmd> to the line before the trailing
# (just-rendered) prompt, capped to AI_ASSIST_SCROLLBACK_LINES.
assist::capture_scrollback() {
  local cmd="$1" max="${AI_ASSIST_SCROLLBACK_LINES:-200}"
  local zj; zj="$(assist::zellij_bin)" || { return 0; }
  local pane="${ZELLIJ_PANE_ID:+terminal_$ZELLIJ_PANE_ID}"
  local dump; dump="$(mktemp)"
  "$zj" action dump-screen ${pane:+-p "$pane"} > "$dump" 2>/dev/null || { rm -f "$dump"; return 0; }
  awk -v cmd="$cmd" -v max="$max" '
    { lines[NR] = $0; if (index($0, cmd)) start = NR }
    END {
      if (start == 0) start = (NR - max > 0 ? NR - max : 1)   # fallback: last max
      end = NR - 1                                            # drop trailing prompt
      if (end - start + 1 > max) start = end - max + 1
      for (i = start; i <= end; i++) print lines[i]
    }' "$dump"
  rm -f "$dump"
}

# assist::prefill_template — deterministic popup seed from CAP_*.
assist::prefill_template() {
  [[ "${CAP_KIND:-question}" == error ]] || { print -rn -- ""; return 0; }
  print -rn -- "Diagnose and fix why \`${CAP_CMD}\` failed (exit ${CAP_EXIT}) in ${CAP_PROJECT:-this directory}"
}

# assist::build_request <user_request> <out_file> — Phase A request.json.
assist::build_request() {
  local user_request="$1" out="$2"
  require_cmd jq
  local root; root="$(git -C "${CAP_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || root="${CAP_DIR:-$PWD}"
  local over_ssh="false"
  [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] && over_ssh="true"
  jq -n \
    --arg kind "${CAP_KIND:-question}" \
    --arg session "${ZELLIJ_SESSION_NAME:-}" \
    --arg pane "${ZELLIJ_PANE_ID:+terminal_$ZELLIJ_PANE_ID}" \
    --arg atuin "${ATUIN_SESSION:-}" \
    --arg cwd "${CAP_DIR:-$PWD}" \
    --arg root "$root" \
    --arg cmd "${CAP_CMD:-}" \
    --arg exit "${CAP_EXIT:-}" \
    --arg dur "${CAP_DURATION:-}" \
    --arg scrollback "${CAP_SCROLLBACK:-}" \
    --arg user "$user_request" \
    --arg project "${CAP_PROJECT:-}" \
    --arg branch "${CAP_BRANCH:-}" \
    --argjson over_ssh "$over_ssh" \
    '{version:1, kind:$kind,
      origin:{zellij_session:$session, pane_id:$pane, atuin_session:$atuin, cwd:$cwd, project_root:$root, over_ssh:$over_ssh},
      command:{text:$cmd, exit:($exit|tonumber? // null), duration_ms:$dur},
      scrollback:$scrollback, user_request:$user,
      project:{name:$project, branch:$branch}}' > "$out"
}

# ── Triage (Phase A stub) ──────────────────────────────────────────────────
# Returns 0 = "escalate to the chosen harness". The real KB-aware classifier
# lands in Phase D; until then every request escalates.
assist::triage() { return 0; }

# ── Worker engine ──────────────────────────────────────────────────────────
# assist::worker_main <label> <build_fn> [--request FILE] [-- guidance...]
# Shared flow for every ai-assist-<harness> worker. <build_fn> is a function
# the worker defines; it must populate the array ASSIST_PANE_CMD with the
# harness command to run in the docked pane, reading ASSIST_PROMPT / ASSIST_MODEL
# and the REQ_* globals.
assist::worker_main() {
  local label="$1" build_fn="$2"; shift 2
  local request_file=""
  ASSIST_GUIDANCE=""
  while (($#)); do
    case "$1" in
      --request) request_file="${2:-}"; shift 2 ;;
      --request=*) request_file="${1#*=}"; shift ;;
      -h|--help) print -r -- "Usage: ai-assist-<harness> --request <file> [-- guidance...]"; return 0 ;;
      --) shift; ASSIST_GUIDANCE="$*"; break ;;
      *) ASSIST_GUIDANCE="$*"; break ;;
    esac
  done
  [[ -n "$request_file" ]] || die "missing --request <file>"

  assist::request_read "$request_file"
  local kb; kb="$(assist::kb_ensure "${REQ_PROJECT_ROOT:-$PWD}")"
  ASSIST_PROMPT="$(assist::system_prompt "$kb")"
  [[ -n "$ASSIST_GUIDANCE" ]] && ASSIST_PROMPT+=$'\n\nAdditional guidance from the caller:\n'"$ASSIST_GUIDANCE"

  assist::triage || true   # Phase A: always escalates

  ASSIST_PANE_CMD=()
  "$build_fn"
  [[ ${#ASSIST_PANE_CMD[@]} -gt 0 ]] || die "worker '$label' produced no command"

  # Wrap the harness in ai-assist-render so the docked pane shows a title block +
  # spinner and renders the reply through glow (Phase B-render). Reached by
  # absolute path — the docked pane's PATH lacks ~/.local/libexec. Set
  # AI_ASSIST_RENDER=0 to run the harness bare (raw output, for debugging).
  local render="$HOME/.local/libexec/ai-assist-render"
  if [[ "${AI_ASSIST_RENDER:-1}" == 1 && -x "$render" ]]; then
    # Build the render flags as an array: zsh does NOT word-split an unquoted
    # ${VAR:+--flag "$VAR"}, so the inline form passed "--origin-pane <id>" as a
    # SINGLE argument (which render then tried to exec). An array keeps the flag
    # and its value as separate words.
    local -a render_flags=()
    [[ -n "$REQ_PANE_ID" ]] && render_flags+=(--origin-pane "$REQ_PANE_ID")
    [[ "$REQ_OVER_SSH" == true ]] && render_flags+=(--over-ssh)
    assist::spawn_pane "$render" --harness "$label" "${render_flags[@]}" -- "${ASSIST_PANE_CMD[@]}"
  else
    assist::spawn_pane "${ASSIST_PANE_CMD[@]}"
  fi
  log_ok "ai-assist (${label}) working in a docked pane"
}
