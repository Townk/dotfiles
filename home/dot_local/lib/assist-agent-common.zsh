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
  local kb_path="$1" kb_block="" cmd_block="" output_block="" task_line="" structure=""
  if [[ -s "$kb_path" ]]; then
    kb_block=$'\n\n## What we already know about this project\n\n'"$(cat "$kb_path")"
  fi

  # Failure vs general request. ONLY a non-zero last-command exit is a failure to
  # diagnose. A successful or absent last command means this is a general
  # question — there is almost always *some* last command, so do NOT frame a
  # general request as troubleshooting or invent an error from the last command.
  local is_failure=0
  [[ -n "${REQ_COMMAND_EXIT:-}" && "${REQ_COMMAND_EXIT}" != "0" ]] && is_failure=1

  if (( is_failure )); then
    cmd_block=$'\nFailed command: `'"${REQ_COMMAND_TEXT}"$'` (exit '"${REQ_COMMAND_EXIT}"$')'
    output_block=$'\n\nRelevant terminal output (the failure):\n'"${REQ_SCROLLBACK:-(none captured)}"
    task_line="Diagnose the failure: explain what is going on and how to fix it."
    structure=$'Write your answer as a LITERATE TROUBLESHOOTING PLAYBOOK — a document a teammate\nwithout the full context can follow — in three parts:\n\n1. Goal & error — what the user was trying to do and the error they saw (concise).\n2. Why it happens — the root cause (concise).\n3. Fix steps — prose that walks through the fix, with the runnable steps woven in\n   as fenced code blocks. Do NOT just dump a list of commands.\n\nVERIFY (outcome-check): after the fix block, ALWAYS add a SEPARATE final block\ntagged {id=verify needs=<fix-id>} whose only job is to re-run the original failed\ncommand exactly: `'"${REQ_COMMAND_TEXT}"$' — a clean exit (0) is the proof the fix\nworked. Use the literal id `verify` so the runner can detect a failed verification\nand offer to try another fix. Do NOT fold the re-run into the fix block or prose.'
  else
    # General request: do not invent an error, do not diagnose the last command.
    task_line="Answer the user's request directly. This is a general request, NOT a troubleshooting case: there is no failure here — do NOT invent or diagnose an error, and do NOT treat the last command as a problem."
    structure=$'Write your answer as a LITERATE HOW-TO PLAYBOOK — a document a teammate can\nfollow — in two parts:\n\n1. Goal — what the user wants to accomplish (one line).\n2. How — prose that walks through it, with the runnable steps woven in as fenced\n   code blocks. Do NOT just dump a list of commands.'
  fi

  cat <<EOF
You are a terminal assistant helping with a single, self-contained request.

Work within a bounded context: rely only on the information below plus a
focused look at the project — do not crawl the whole repository or restate
history. The goal is one fresh, tightly-scoped pass that ends in a clear answer.

Project: ${REQ_PROJECT_NAME:-${REQ_PROJECT_ROOT:-unknown}} (${REQ_PROJECT_ROOT:-?})${REQ_BRANCH:+ on branch ${REQ_BRANCH}}
Request kind: ${REQ_KIND:-question}${cmd_block}

What the user is trying to do:
${REQ_USER_REQUEST:-(no description given)}${output_block}${kb_block}

${task_line}

You have these helper tools on PATH — prefer them over your own raw shell:
- \`ai-assist-run "<cmd>"\` runs a command in the user's real shell (their cwd
  and environment). Use it to verify; keep those commands read-only or
  idempotent. It returns the command's output and exit code.
- \`ai-assist-ask --type free|line|confirm|choose "<question>" [choices...]\`
  asks the user and returns their answer. It is the only way to get input.
- \`ai-assist-remember "<fact>"\` saves a durable, distilled fact about this
  project for future requests.

${structure}

Each runnable step is a fenced code block. EVERY runnable block MUST carry a
unique short id, e.g. a bash block tagged {id=fix} — the runner keys run/diff/
apply, output capture, and needs-gating on that id. Use:
  - bash/sh/zsh blocks for shell steps (the user can run them in their shell or
    the assistant's),
  - python/node/etc. blocks for scripts,
  - diff blocks for file changes (the user views/applies them). A diff block
    MUST be a complete, applyable unified diff — include the \`--- a/<path>\`
    and \`+++ b/<path>\` file headers and at least one \`@@ … @@\` hunk header,
    with paths relative to the project root (a leading
    \`diff --git a/<path> b/<path>\` line is ideal). It must be valid for
    \`git apply\`. Do NOT emit a bare fragment of changed lines, and do NOT put
    the target filename only in prose — the file headers ARE how the viewer and
    apply know the target.
Shell blocks run under \`set -e\`: a block FAILS at its FIRST failing command, so
a later command cannot mask an earlier failure. If a non-zero exit is expected
(a probe like \`command -v foo\` or \`grep …\`), guard it with \`|| true\`.
If a step uses a previous step's output, tag it {id=next needs=fix} and reference
the earlier output via \$AAS_OUT_fix / \$AAS_ERR_fix / \$AAS_EXIT_fix.
Show captured error output or sample output as a console block (or tag it
{static}) so it is NOT treated as runnable.
For example, an illustrative block starts with: \`\`\`console {static}

Do NOT apply changes yourself — the user reviews and runs each step from the
playbook. Keep the preamble short; spend your words on the steps.

Never write secrets, credentials, or raw environment dumps into a remembered
fact or into your answer.

Finish with a short summary and the recommended next step.
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

# assist::capture_command — the last command run IN THIS PANE → CAP_CMD / CAP_EXIT
# / CAP_DIR / CAP_DURATION / CAP_KIND. Uses `atuin history list --session`, which
# filters to the CURRENT session (the inherited ATUIN_SESSION) and lists oldest→
# newest, so the LAST line is this pane's most recent command — and a fresh tab
# that has run nothing yields no command. (`history last` is GLOBAL and would
# surface a command from another pane, producing a phantom "last command".)
assist::capture_command() {
  local row
  row="$("$ATUIN_BIN" history list --session \
        --format '{command}	{exit}	{directory}	{duration}' 2>/dev/null | tail -1)" || row=""
  CAP_CMD="${row%%	*}"; row="${row#*	}"
  CAP_EXIT="${row%%	*}"; row="${row#*	}"
  CAP_DIR="${row%%	*}"; CAP_DURATION="${row#*	}"
  [[ "$CAP_CMD" == "$CAP_EXIT" ]] && CAP_EXIT=""   # single-field/empty row guard
  if [[ -n "$CAP_EXIT" && "$CAP_EXIT" != 0 ]]; then CAP_KIND=error; else CAP_KIND=question; fi
}

# assist::capture_scrollback <cmd> — slice the dump-screen for the last run of
# <cmd>: from the last line containing <cmd> to the line before the trailing
# (just-rendered) prompt, capped to AI_ASSIST_SCROLLBACK_LINES.
assist::capture_scrollback() {
  local cmd="$1" max="${AI_ASSIST_SCROLLBACK_LINES:-200}"
  # Gated debug helper (AI_ASSIST_DEBUG_LOG): trace why a capture comes back empty.
  _cap_dbg() { [[ -n "${AI_ASSIST_DEBUG_LOG:-}" ]] && print -r -- "$(date +%H:%M:%S) [capture] $*" >> "$AI_ASSIST_DEBUG_LOG" 2>/dev/null || true; }
  local zj; zj="$(assist::zellij_bin)" || { _cap_dbg "no zellij bin → empty"; return 0; }
  local pane="${ZELLIJ_PANE_ID:+terminal_$ZELLIJ_PANE_ID}"
  local dump; dump="$(mktemp)"
  # Viewport only (NOT --full): the error normally prints just above the returned
  # prompt and is on-screen; --full would dump the entire (possibly multi-MB)
  # scrollback for no gain.
  "$zj" action dump-screen ${pane:+-p "$pane"} > "$dump" 2>/dev/null || { _cap_dbg "dump-screen FAILED pane=${pane:-<focused>} → empty"; rm -f "$dump"; return 0; }
  # Anchor the slice at the most recent run of the command that ACTUALLY HAS
  # output after it. The naive "last line containing <cmd>" is wrong when the
  # command appears again at the very bottom with nothing below it (a build still
  # running, the command captured before its output rendered, or a re-typed
  # command) — that gave start=NR, end=NR-1 → start>end → an EMPTY capture, which
  # collapsed the cache key to project+command+exit and replayed a stale playbook
  # for a genuinely different error.
  local out
  out="$(awk -v cmd="$cmd" -v max="$max" '
    { lines[NR] = $0; if (index($0, cmd)) m[++mc] = NR }
    END {
      if (NR == 0) exit
      start = 0
      for (i = mc; i >= 1; i--) if (m[i] < NR) { start = m[i]; break }  # last match with output
      if (start > 0) { end = NR - 1; if (end < start) end = NR }        # drop the trailing prompt
      else { start = (NR - max + 1 > 0 ? NR - max + 1 : 1); end = NR }  # no anchor: last max lines
      if (end - start + 1 > max) start = end - max + 1
      for (i = start; i <= end; i++) print lines[i]
    }' "$dump")"
  [[ -n "${AI_ASSIST_DEBUG_LOG:-}" ]] && \
    print -r -- "$(date +%H:%M:%S) [capture] dump_lines=$(wc -l < "$dump" | tr -d ' ') cmd='${cmd}' result_len=${#out}" \
    >> "$AI_ASSIST_DEBUG_LOG" 2>/dev/null
  rm -f "$dump"
  print -r -- "$out"
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
# assist::worker_main <label> <build_fn> [--triage] [--request FILE] [-- guidance...]
# Shared flow for every ai-assist-<harness> worker. <build_fn> is a function
# the worker defines; it must populate the array ASSIST_PANE_CMD with the
# harness command to run in the docked pane, reading ASSIST_PROMPT / ASSIST_MODEL
# and the REQ_* globals.
#
# When --triage is given: builds ASSIST_TRIAGE_PROMPT via assist::triage_prompt,
# calls the worker's assist_build_triage_cmd (if defined; else exits 3), runs the
# cheap command in ${REQ_PROJECT_ROOT:-$PWD}, and exits with its status. The
# capable (non-triage) path is unchanged.
assist::worker_main() {
  local label="$1" build_fn="$2"; shift 2
  local request_file="" triage_mode=0 stream_mode=0 prompt_file=""
  ASSIST_GUIDANCE=""
  while (($#)); do
    case "$1" in
      --triage)       triage_mode=1; shift ;;
      --stream)       stream_mode=1; shift ;;
      --request)      request_file="${2:-}"; shift 2 ;;
      --request=*)    request_file="${1#*=}"; shift ;;
      --prompt-file)  prompt_file="${2:-}"; shift 2 ;;
      -h|--help) print -r -- "Usage: ai-assist-<harness> [--triage] [--stream] --request <file> [-- guidance...]"; return 0 ;;
      --) shift; ASSIST_GUIDANCE="$*"; break ;;
      *) ASSIST_GUIDANCE="$*"; break ;;
    esac
  done
  [[ -n "$request_file" ]] || die "missing --request <file>"

  assist::request_read "$request_file"

  # ── Triage path ─────────────────────────────────────────────────────────
  if (( triage_mode )); then
    local kb; kb="$(assist::kb_ensure "${REQ_PROJECT_ROOT:-$PWD}")"
    ASSIST_TRIAGE_PROMPT="$(assist::triage_prompt "$kb")"
    # If the worker defines no cheap pass, exit 3 (graceful escalate).
    if ! typeset -f assist_build_triage_cmd >/dev/null 2>&1; then
      exit 3
    fi
    ASSIST_TRIAGE_CMD=()
    assist_build_triage_cmd
    [[ ${#ASSIST_TRIAGE_CMD[@]} -gt 0 ]] || exit 3
    (
      cd "${REQ_PROJECT_ROOT:-$PWD}" 2>/dev/null || true
      "${ASSIST_TRIAGE_CMD[@]}"
    )
    exit $?
  fi
  # Snapshot the origin environment for the agent's own shell (Phase C1). The
  # worker is exec-chained from the origin shell, so its env IS the origin env.
  # export -p is re-sourceable; readonly specials are tolerated on re-source.
  # Create the file 0600 before writing any secrets (umask 077 ensures the
  # empty file is created with no group/other bits even if the user's umask
  # is more permissive), then append the dump so we never widen the mode.
  local req_env="${request_file:h}/request.env"
  ( umask 077; : > "$req_env" ) 2>/dev/null || : > "$req_env"
  export -p >> "$req_env" 2>/dev/null || true
  # Shell-init artifact (Stage 3, additive): the ZLE trigger captured the user's
  # LIVE interactive aliases/functions (a child can't see them) into a temp file
  # and threaded its path via AI_ASSIST_SHELL_INIT. Persist it as
  # request.shell-init so the agent shell can source it as a --shell-init dump.
  # Reuse semantics keep the ORIGINAL dump across re-invocations:
  #   - fresh trigger (AI_ASSIST_SHELL_INIT set + readable) → copy the full dump.
  #   - re-invocation (regenerate/followup/wrapup) → leave the existing artifact.
  #   - neither → skip; the agent shell falls back to `zsh -il`'s base env.
  # Created 0600 first (umask 077) like req_env so we never widen the mode.
  local req_shell_init="${request_file:h}/request.shell-init"
  if [[ -n "${AI_ASSIST_SHELL_INIT:-}" && -r "$AI_ASSIST_SHELL_INIT" ]]; then
    ( umask 077; : > "$req_shell_init" ) 2>/dev/null || : > "$req_shell_init"
    cat -- "$AI_ASSIST_SHELL_INIT" >> "$req_shell_init" 2>/dev/null || true
  fi
  local kb; kb="$(assist::kb_ensure "${REQ_PROJECT_ROOT:-$PWD}")"
  # --prompt-file lets a caller inject a custom system prompt (used by ai-assist-wrapup
  # for the wrap-up pass). Falls back to the standard system prompt when unset/absent.
  if [[ -n "$prompt_file" && -f "$prompt_file" ]]; then
    ASSIST_PROMPT="$(cat -- "$prompt_file")"
  else
    ASSIST_PROMPT="$(assist::system_prompt "$kb")"
  fi
  [[ -n "$ASSIST_GUIDANCE" ]] && ASSIST_PROMPT+=$'\n\nAdditional guidance from the caller:\n'"$ASSIST_GUIDANCE"

  assist::triage || true   # Phase A: always escalates

  ASSIST_PANE_CMD=()
  "$build_fn"
  [[ ${#ASSIST_PANE_CMD[@]} -gt 0 ]] || die "worker '$label' produced no command"

  # ── Stream mode (--stream) ───────────────────────────────────────────────
  # Run the capable agent command directly to stdout without render/pane.
  # Used by ai-assist-regenerate to pipe the fresh output into the existing
  # docked pane's input FIFO.
  if (( stream_mode )); then
    ( cd "${REQ_PROJECT_ROOT:-$PWD}" 2>/dev/null || true; "${ASSIST_PANE_CMD[@]}" )
    exit $?
  fi

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
    render_flags+=(--shell-env "$req_env" --shell-cwd "${REQ_CWD:-$PWD}")
    # Forward the captured live aliases/functions dump (Stage 3) when present.
    # Additive: carried alongside --shell-env (env for the eval-loop); consolidated
    # at cutover. Both fresh-copy and reused-original artifacts land here.
    [[ -f "$req_shell_init" ]] && render_flags+=(--shell-init "$req_shell_init")
    [[ -n "${REQ_PROJECT_ROOT:-}" ]] && render_flags+=(--project-root "$REQ_PROJECT_ROOT")
    # Forward the cache keys as render ARGS, not env: render runs in a fresh
    # zellij pane that does NOT inherit this process's env, so the playbook
    # persist (render tee → ai-assist-cache store) only fires when these are args.
    [[ -n "${AI_ASSIST_CACHE_CTX:-}" ]]  && render_flags+=(--cache-ctx "$AI_ASSIST_CACHE_CTX")
    [[ -n "${AI_ASSIST_CACHE_REQ:-}" ]]  && render_flags+=(--cache-req "$AI_ASSIST_CACHE_REQ")
    [[ -n "${AI_ASSIST_CACHE_META:-}" ]] && render_flags+=(--cache-meta "$AI_ASSIST_CACHE_META")
    # Forward request.json (same reason: ARG not env) so render saves the regenerate
    # sidecar alongside the persisted playbook. Forwarded unconditionally when the
    # file exists so follow-up/wrap-up can resolve the request even when the cache
    # is disabled (no AI_ASSIST_CACHE_CTX) — render/broker pass it through as
    # --regen-request, and the helpers use it as priority-1 request resolution.
    [[ -n "$request_file" ]] && render_flags+=(--cache-request "$request_file")
    # Forward the debug log path (ARG, not env: new-pane drops env) so the pane's
    # broker/pager/helpers all log to it.
    [[ -n "${AI_ASSIST_DEBUG_LOG:-}" ]] && render_flags+=(--debug-log "$AI_ASSIST_DEBUG_LOG")
    assist::spawn_pane "$render" --harness "$label" "${render_flags[@]}" -- "${ASSIST_PANE_CMD[@]}"
  else
    assist::spawn_pane "${ASSIST_PANE_CMD[@]}"
  fi
  log_ok "ai-assist (${label}) working in a docked pane"
}

# ── Triage classifier (Phase D) ────────────────────────────────────────────
# assist::triage_extract_command <raw> — pull a bare, runnable command out of the
# model's __COMMAND__ body. Models often ignore "no markdown" and wrap the command
# in a ```fence``` and/or trail an explanation; typing that verbatim at the prompt
# is wrong. If a fenced block is present, take ONLY its contents; otherwise keep
# the body as-is. Then strip surrounding whitespace/newlines (no stray newline is
# typed, and no trailing prose rides along).
assist::triage_extract_command() {
  local raw="$1" body
  if [[ "$raw" == *'```'* ]]; then
    body="$(print -r -- "$raw" | awk '/^[[:space:]]*```/{f=!f; next} f{print}')"
  else
    body="$raw"
  fi
  # The command is the FIRST non-empty line — drop any trailing prose the model
  # appended (a single command is what gets typed at the prompt). Models that try
  # to explain after the command no longer leak that explanation onto the prompt.
  body="$(print -r -- "$body" | awk 'NF{print; exit}')"
  body="${body#"${body%%[![:space:]]*}"}"   # ltrim
  body="${body%"${body##*[![:space:]]}"}"   # rtrim
  print -rn -- "$body"
}

# assist::triage_classify <raw> — map the cheap pass's first line to KIND␟PAYLOAD.
assist::triage_classify() {
  local raw="$1" first rest US=$'\x1f'
  # Skip leading blank lines / whitespace so a stray newline before the sentinel
  # does not misclassify the response.
  raw="${raw#"${raw%%[![:space:]]*}"}"
  first="${raw%%$'\n'*}"
  rest="${raw#*$'\n'}"; [[ "$rest" == "$raw" ]] && rest=""
  case "$first" in
    __COMMAND__)
      local cmd; cmd="$(assist::triage_extract_command "$rest")"
      # A well-formed command is non-empty and contains no other sentinel. If the
      # model emitted ambiguous output (e.g. __COMMAND__ then __ANSWER__), DON'T
      # type it at the prompt — escalate to the capable harness instead.
      if [[ -z "$cmd" || "$cmd" == *__ANSWER__* || "$cmd" == *__ESCALATE__* || "$cmd" == *__COMMAND__* ]]; then
        print -rn -- "escalate${US}ambiguous triage output"
      else
        print -rn -- "command${US}${cmd}"
      fi
      ;;
    __ANSWER__)       print -rn -- "answer${US}${rest}" ;;
    __ESCALATE__:*)   local r="${first#__ESCALATE__:}"; print -rn -- "escalate${US}${r# }" ;;
    __ESCALATE__)     print -rn -- "escalate${US}" ;;
    *)                print -rn -- "escalate${US}unrecognized" ;;
  esac
}

# assist::triage_prompt <kb_path> — the cheap, read-only first-pass prompt.
assist::triage_prompt() {
  local kb_path="$1" kb_block=""
  [[ -s "$kb_path" ]] && kb_block=$'\n\n## What we already know\n\n'"$(cat "$kb_path")"
  cat <<EOF
You are a fast terminal triage assistant. Resolve this in ONE quick pass.

Project: ${REQ_PROJECT_NAME:-${REQ_PROJECT_ROOT:-unknown}}
Request: ${REQ_USER_REQUEST:-(none)}
Failed command: ${REQ_COMMAND_TEXT:-(none)}
Recent output:
${REQ_SCROLLBACK:-(none)}${kb_block}

If a "Failed command" is shown above and the request is to explain why it failed
or how to fix it, that is a DIAGNOSIS — return __ESCALATE__ so the full assistant
can investigate the error. Never return a command for failure diagnosis, and
NEVER propose re-running the failed command itself.

For command usage and current flags, look it up with \`ai-assist-docs <cmd>\`
(offline tldr + --help) rather than relying on memory. You MAY run read-only
doc/inspection commands (tldr, --help, man, ls, cat). NEVER run stateful or
destructive commands — propose them instead, or escalate.

Before proposing a command, verify every program it uses is available with
\`command -v <prog>\`. If a required program is NOT installed, do NOT return a
command — return __ANSWER__ explaining it is missing and, if known, how to
install it.

Output EXACTLY ONE of the three sentinels below — never more than one, and put it
on its OWN first line with nothing before it. If a single shell command would
accomplish the request (e.g. "list/show/find/how do I X"), ALWAYS choose
__COMMAND__ — do not explain instead; explanations belong in __ANSWER__ only when
there is genuinely no single command to give.

  __COMMAND__
  <ONE ready-to-run shell command on the very next line and NOTHING else — raw
   text, NO markdown code fences, NO backticks, NO __ANSWER__ section, NO prose
   before or after. It is typed directly onto the user's prompt.>

  __ANSWER__
  <a short markdown explanation — only when no single command fits>

  __ESCALATE__: <one-line reason>   (when this needs multi-step investigation,
  iteration, file changes, or asking the user)
EOF
}
