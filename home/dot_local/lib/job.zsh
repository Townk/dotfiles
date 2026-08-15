#!/usr/bin/env zsh
# job.zsh — long-running observable tasks over the pueue backbone.
# SOURCED, never executed. The ONLY API scripts use to run background jobs;
# nothing else talks to pueue directly.
# Spec: docs/superpowers/specs/2026-08-15-job-runner-design.md
#
# State per job:  $JOB_STATE_ROOT/<id>/meta.json   (identity, pueue task id)
#                 $JOB_STATE_ROOT/<id>/progress    (one line: epoch pct msg)
#                 $JOB_STATE_ROOT/<id>/result      (written by job-callback)
# The progress sidecar is the whole progress wire: writers write at their own
# cadence, the Hammerspoon reader owns display cadence and derives staleness
# from the epoch — so there is no throttle logic on this side at all.

[ -n "${__JOB_ZSH_LOADED:-}" ] && return 0
__JOB_ZSH_LOADED=1

source "${${(%):-%x}:A:h}/common.zsh"
zmodload zsh/datetime 2>/dev/null

: "${JOB_STATE_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/jobs}"

# job::_pueue — resolve the pueue client. JOB_PUEUE_BIN is the test seam.
job::_pueue() {
  if [ -n "${JOB_PUEUE_BIN:-}" ]; then
    print -r -- "$JOB_PUEUE_BIN"
    return 0
  fi
  local p
  p=$(command -v pueue 2>/dev/null) || p=/opt/homebrew/bin/pueue
  [ -x "$p" ] || return 1
  print -r -- "$p"
}

# job::_ensure_group <pueue> <group> — create a non-default group on first
# use. The parallelism pin happens ONLY when the group was just created, so a
# user's later `pueue parallel N -g heavy` tweak is never clobbered.
job::_ensure_group() {
  local pueue="$1" group="$2" par=4
  [ "$group" = "default" ] && return 0
  if "$pueue" group add "$group" >/dev/null 2>&1; then
    [ "$group" = "heavy" ] && par=1
    "$pueue" parallel "$par" --group "$group" >/dev/null 2>&1 || true
  fi
  return 0
}

# job::start [--group G] [--title T] [--icon SPEC] [--no-progress] -- cmd…
# Enqueue a job; print its id on stdout. The command is passed to pueue as
# ONE sh-quoted string with JOB_ID/JOB_STATE_ROOT prepended inline — pueue
# captures the client environment at add time, but those two are per-task.
# meta.json is written BEFORE the add (pueue_id -1) so the HUD's pathwatcher
# and a lightning-fast callback both find the dir, then patched with the
# real task id.
job::start() {
  local group="default" title="" icon="" progress="expected" modal=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --group) group="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --icon) icon="$2"; shift 2 ;;
      --no-progress) progress="none"; shift ;;
      --modal) modal=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  (($# > 0)) || die "job::start: no command given"
  local pueue
  pueue=$(job::_pueue) \
    || die "job::start: pueue is not installed (brew install pueue)"
  [ -n "$title" ] || title="$1"

  # EPOCHREALTIME (µs), not EPOCHSECONDS: one process may start several jobs
  # inside the same second (a loop of job::start calls), and <epoch>-<pid>
  # collided — three jobs shared one state dir. Microseconds keep ids unique
  # per call and still sortable; $$ separates concurrent processes.
  local id="${EPOCHREALTIME/./}-$$"
  local dir="$JOB_STATE_ROOT/$id"
  mkdir -p -- "$dir"
  jq -n --arg title "$title" --arg icon "$icon" --arg group "$group" \
    --arg progress "$progress" --argjson created "$EPOCHSECONDS" \
    '{title:$title, icon:$icon, group:$group, pueue_id:-1,
      progress:$progress, created:$created}' > "$dir/meta.json"

  job::_ensure_group "$pueue" "$group"
  local cmdline="JOB_ID=${(q)id} JOB_STATE_ROOT=${(q)JOB_STATE_ROOT} ${(j: :)${(q)@}}"
  local task_id
  if ! task_id=$("$pueue" add --group "$group" --label "job:$id" \
    --print-task-id -- "$cmdline"); then
    rm -rf -- "$dir"
    die "job::start: pueued unreachable — start it with: system-service start pueued"
  fi

  local tmp="$dir/.meta.tmp"
  jq --argjson tid "$task_id" '.pueue_id = $tid' "$dir/meta.json" > "$tmp" \
    && mv -f -- "$tmp" "$dir/meta.json"
  print -r -- "$id"
  ((modal)) && job::watch "$id"
  return 0
}

# job::progress <pct> [message…] — called INSIDE a running task ($JOB_ID is
# injected by job::start). Atomic single-line rewrite: write-then-rename, so
# the reader can never see a torn line. pct -1 = indeterminate.
job::progress() {
  [ -n "${JOB_ID:-}" ] || return 1
  local dir="$JOB_STATE_ROOT/$JOB_ID"
  [ -d "$dir" ] || return 1
  local pct="${1:--1}"
  (($#)) && shift
  local tmp="$dir/.progress.tmp"
  print -r -- "$EPOCHSECONDS $pct $*" > "$tmp" && mv -f -- "$tmp" "$dir/progress"
}

# job::cancel <id> — signal the task's whole process group via pueue kill.
# Cancel is not a failure: the task's own TERM trap keeps its contract
# (partial markers, exit 130, …) and the callback sees result=Killed.
job::cancel() {
  local id="${1:?job::cancel: id required}" pueue task_id
  pueue=$(job::_pueue) || return 1
  task_id=$(jq -r '.pueue_id' "$JOB_STATE_ROOT/$id/meta.json" 2>/dev/null) \
    || return 1
  [[ "$task_id" == <-> ]] || return 1
  "$pueue" kill "$task_id"
}

# job::list — one JSON document merging our per-job state with pueue's
# authoritative status. For tooling (the HUD reads files directly); humans
# get the HUD and, in phase 2, job::watch.
job::list() {
  local pueue pueue_status='{}'
  if pueue=$(job::_pueue); then
    pueue_status=$("$pueue" status --json 2>/dev/null) || pueue_status='{}'
  fi
  local -a entries=()
  local dir id prog done_flag
  for dir in "$JOB_STATE_ROOT"/*(N/); do
    id="${dir:t}"
    [ -f "$dir/meta.json" ] || continue
    prog=""
    [ -f "$dir/progress" ] && prog="$(<"$dir/progress")"
    done_flag=false
    [ -f "$dir/result" ] && done_flag=true
    entries+=("$(jq -c --arg id "$id" --arg progress_line "$prog" \
      --argjson done "$done_flag" \
      '. + {id:$id, progress_line:$progress_line, done:$done}' \
      "$dir/meta.json")")
  done
  printf '%s\n' "${entries[@]}" \
    | jq -s --argjson pueue "$pueue_status" '{jobs:., pueue:$pueue}'
}

# job::hud [show|hide|toggle] — recall/dismiss the Hammerspoon HUD. Fire and
# forget, same isolation as pick-clipboard's emitter: -q (the hs.ipc console
# mirror bug), stdin from /dev/null (the real hs CLI reads stdin).
job::hud() {
  local verb="${1:-show}" hs
  case "$verb" in show | hide | toggle) ;; *) return 1 ;; esac
  hs=$(notify::available --path) || return 1
  "$hs" -q -c "require(\"jobs\").${verb}()" </dev/null >/dev/null 2>&1 || true
  return 0
}

# --- modal viewer (phase 2, spec §6) ----------------------------------------
# Pure composition first, loop later: the bar and header are plain string
# functions so the spec suite can pin the layout without a tty.

# job::_watch_bar <pct> [width] — a width-char bar, █ filled / · empty.
# Negative pct = indeterminate = all-empty. No trailing newline.
job::_watch_bar() {
  local pct="$1" width="${2:-24}" filled
  if ((pct < 0)); then
    filled=0
  else
    filled=$((pct * width / 100))
    ((filled > width)) && filled=$width
  fi
  local bar=""
  ((filled > 0)) && bar="${(pl:$filled::█:)}"
  ((filled < width)) && bar="$bar${(pl:$((width - filled))::·:)}"
  print -rn -- "$bar"
}

# job::_watch_header <title> <msg> <pct> <elapsed_s> — the pinned status
# row, uncolored (the loop wraps it in the gated palette): the engine-owned
# label (message when the task has spoken, title before that), the bar, the
# percentage (--% while indeterminate), elapsed seconds, and the key hints.
job::_watch_header() {
  local title="$1" msg="$2" pct="$3" elapsed="$4"
  local label="$title" pctText
  [ -n "$msg" ] && label="$msg"
  if ((pct < 0)); then
    pctText="--%"
  else
    pctText="${pct}%"
  fi
  print -rn -- "$label [$(job::_watch_bar "$pct")] $pctText ${elapsed}s — q/ESC detach · ^C cancel"
}

# job::_watch_confirm_cancel <id> <title> — the Ctrl+C flow, routed through
# the house dialog layer: mux::confirm floats the themed danger-palette
# confirm in a mux popup when inside a session, or degrades to the inline
# input::confirm otherwise. Fail-closed — ANY non-zero rc (declined,
# unrenderable, or the 130 ESC-cancel) means "do not cancel". rc 0 = the
# job WAS cancelled, rc 1 = declined/resume (caller keeps watching).
# mux.zsh is pulled in lazily, the way notify pulls its bridge libs; an
# unreadable lib degrades to a safe decline, never a crash.
job::_watch_confirm_cancel() {
  local id="$1" title="$2"
  local muxlib="${${(%):-%x}:A:h}/mux.zsh"
  [ -r "$muxlib" ] || return 1
  source "$muxlib" 2>/dev/null || return 1
  mux::confirm "Cancel ${title}?" --title "Job runner" --danger \
    --affirmative "Cancel job" --negative "Keep running" >/dev/null || return 1
  job::cancel "$id" >/dev/null 2>&1
  return 0
}

# job::watch <id> — the modal viewer (spec §6). Pinned header row + live
# log tail, all on STDERR so stdout stays pipeable. spin::stream's shape:
# a `pueue follow` child mirrors the task log into a scratch file; complete
# new lines push the header off its row (\r\e[K), print, and the header
# repaints beneath them. Keys ride zselect so the loop never blocks:
# q/ESC detach (rc 0, task untouched), Ctrl+C lands as SIGINT and asks.
job::watch() {
  local id="${1:?job::watch: id required}"
  local dir="$JOB_STATE_ROOT/$id"
  if [ ! -f "$dir/meta.json" ]; then
    log_error "job::watch: unknown job $id"
    return 1
  fi
  if [ -z "${JOB_WATCH_FORCE:-}" ] && ! [ -t 2 ]; then
    log_error "job::watch: needs a terminal (the HUD is the headless surface)"
    return 1
  fi
  local pueue task_id title created
  pueue=$(job::_pueue) || return 1
  task_id=$(jq -r '.pueue_id' "$dir/meta.json" 2>/dev/null) || return 1
  title=$(jq -r '.title // empty' "$dir/meta.json" 2>/dev/null)
  created=$(jq -r '.created // 0' "$dir/meta.json" 2>/dev/null)

  local out off=1 size pct msg epoch key cancelled=0 detached=0 pending=""
  out=$(common::tmpfile)

  # Trap and terminal mode go up BEFORE the follow child spawns: a ^C in
  # the gap between spawning and the loop must never orphan the child with
  # no handler on the stack.
  setopt localoptions localtraps
  trap 'if job::_watch_confirm_cancel "$id" "$title"; then cancelled=1; fi' INT

  # cbreak: single keys (q, bare ESC) must reach us without a trailing
  # Enter and without the tty echoing them into the header row. Headless
  # runs (JOB_WATCH_FORCE, the spec suite) have no /dev/tty to touch and
  # keep zsh's own buffered reads — those feed input a line at a time.
  local saved_stty=""
  if have_tty; then
    saved_stty=$(stty -g </dev/tty 2>/dev/null) || saved_stty=""
    stty -icanon -echo min 0 time 0 </dev/tty 2>/dev/null
  fi

  "$pueue" follow "$task_id" >"$out" 2>/dev/null &
  local follow_pid=$!

  {
    while true; do
      if [ -f "$dir/result" ] || ((cancelled)); then break; fi
      kill -0 "$follow_pid" 2>/dev/null || break
      # Mirror new log bytes above the header row — bounded to exactly the
      # size `wc` just sampled (bytes written after that are next tick's
      # business, never this tick's), and only complete lines are painted:
      # a mid-line fragment joins a carried-forward `pending` buffer and
      # waits for its newline rather than being clobbered by the header's
      # \r\e[K and reprinted (duplicated) once it completes.
      size=$(wc -c <"$out" 2>/dev/null) || size=0
      if ((size >= off)); then
        local newbytes=""
        IFS= read -r -d '' newbytes \
          < <(tail -c "+$off" "$out" 2>/dev/null | head -c $((size - off + 1))) \
          2>/dev/null
        pending+="$newbytes"
        off=$((size + 1))
        if [[ "$pending" == *$'\n'* ]]; then
          local tail_frag="${pending##*$'\n'}"
          local to_print="${pending%"$tail_frag"}"
          print -nu2 -- $'\r\e[K'
          print -nru2 -- "$to_print"
          pending="$tail_frag"
        fi
      fi
      # Header: sidecar line, engine-owned label composition, clamped to
      # the terminal width (COLUMNS reads 0 in a non-interactive zsh, same
      # idiom as _spin_say) — a wrapped header defeats the one-row \r\e[K
      # clear and litters stale rows down the screen.
      pct=-1 msg="" epoch=""
      if [ -f "$dir/progress" ]; then
        IFS=' ' read -r epoch pct msg <"$dir/progress" 2>/dev/null || pct=-1
      fi
      local cols header_line
      cols=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}') || true
      [[ -z "$cols" ]] && cols="${COLUMNS:-80}"
      ((cols < 20)) && cols=80
      header_line="$(job::_watch_header "$title" "$msg" "$pct" $((EPOCHSECONDS - created)))"
      print -nru2 -- $'\r\e[K'"${C_DIM}${header_line[1,cols-1]}${C_RES}"
      # One ~0.2s tick of key listening (fork-free; spin::nap's module).
      if (( _common_have_zselect )); then
        if zselect -t 20 -r 0 2>/dev/null; then
          if read -u0 -k1 key 2>/dev/null; then
            case "$key" in
              q | $'\e') detached=1; break ;;
            esac
          else
            # EOF stdin (headless/forced runs): /dev/null reads as
            # perpetually ready — nap instead of busy-spinning the loop.
            spin::nap 20
          fi
        fi
      else
        if read -u0 -t1 -k1 key 2>/dev/null; then
          case "$key" in q | $'\e') detached=1; break ;; esac
        fi
      fi
    done
  } always {
    trap - INT
    [ -n "$saved_stty" ] && stty "$saved_stty" </dev/tty 2>/dev/null
    kill -TERM "$follow_pid" 2>/dev/null
    wait "$follow_pid" 2>/dev/null
    # Final flush: the loop samples the log once per tick and THEN waits
    # (up to 200ms) for a key — bytes the follow child writes during that
    # wait are invisible to the tick that already ran and would otherwise
    # be lost on a fast detach. Now that the child is reaped, read whatever
    # it left, and this time print it even mid-line (nothing more is
    # coming, so a partial final line beats a dropped one).
    size=$(wc -c <"$out" 2>/dev/null) || size=0
    if ((size >= off)); then
      local newbytes=""
      IFS= read -r -d '' newbytes \
        < <(tail -c "+$off" "$out" 2>/dev/null | head -c $((size - off + 1))) \
        2>/dev/null
      pending+="$newbytes"
      off=$((size + 1))
    fi
    if [ -n "$pending" ]; then
      print -nu2 -- $'\r\e[K'
      print -nru2 -- "$pending"
      # A fragment with no trailing newline leaves the cursor mid-row: the
      # unconditional \r\e[K right below would return to column 0 of that
      # SAME row and erase what was just painted. Complete the row first so
      # the fragment survives and the closing line gets a fresh one.
      [[ "$pending" == *$'\n' ]] || print -nu2 -- $'\n'
    fi
    print -nu2 -- $'\r\e[K'
    rm -f "$out"
  }

  # Normal completion usually arrives here via the follow child's own EOF:
  # `pueue follow` returns the instant the task ends, but job-callback
  # writes `result` only after it has notified. Give the callback a bounded
  # grace window before falling back to a plain "detached" line; an actual
  # q/ESC detach or a confirmed cancel skip the wait and report at once.
  if ((!detached)) && ((!cancelled)) && [ ! -f "$dir/result" ]; then
    local grace=0
    while ((grace < 20)) && [ ! -f "$dir/result" ]; do
      spin::nap 10
      grace=$((grace + 1))
    done
  fi

  # Closing line: state the outcome from observed fact (the result file),
  # or say plainly that we detached and the job runs on.
  if [ -f "$dir/result" ]; then
    local r_epoch r_result r_code
    IFS=' ' read -r r_epoch r_result r_code <"$dir/result" 2>/dev/null || r_result="?"
    print -ru2 -- "${title:-$id}: ${r_result}${r_code:+ (exit $r_code)}"
  elif ((cancelled)); then
    print -ru2 -- "${title:-$id}: cancel requested"
  else
    print -ru2 -- "${title:-$id}: detached — still running (job watch $id)"
  fi
  return 0
}
