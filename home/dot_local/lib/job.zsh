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
  ((modal)) && job::watch
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

# --- troupe dashboard driver (spec §6 revision 3) ---------------------------
# `troupe jobs` (troupe-design.md §6) renders the multi-job dashboard — the
# terminal twin of the Hammerspoon capsule stack — and hands back at most ONE
# action line on stdout, always exiting 0: empty (dismissed), "empty" (auto-
# closed, last job finished), "cancel <id>", or "logs <id>". Everything else
# — the confirm, the actual cancel, the log tab, every relaunch — is this
# driver's job (troupe-design.md §6: "logic stays in the caller"). The rev-2
# inline log-viewer loop (mirror, pending buffer, follow child, its own
# header/bar composition) retires with this revision; `job log <id>` covers
# direct log access instead.

# job::_troupe — resolve the troupe binary. JOB_TROUPE_BIN is the test seam;
# unset falls back to PATH resolution (troupe ships via the Gofile, no fixed
# install prefix to guess, unlike pueue's Homebrew fallback in job::_pueue).
job::_troupe() {
  if [ -n "${JOB_TROUPE_BIN:-}" ]; then
    print -r -- "$JOB_TROUPE_BIN"
    return 0
  fi
  command -v troupe 2>/dev/null
}

# job::_live_ids — print the id of every job dir that has meta.json and no
# result file, one per line, newest first. Generalizes the phase-2b
# `--latest` resolver (retired — the dashboard shows every job at once, so
# there is no more "the one newest job" to single out) into "list every live
# id", the shape both job::watch's up-front empty scan and its post-cancel
# "was that the last live job" check need.
job::_live_ids() {
  local dir id
  for dir in "$JOB_STATE_ROOT"/*(N/On); do
    id="${dir:t}"
    [ -f "$dir/meta.json" ] || continue
    [ -f "$dir/result" ] && continue
    print -r -- "$id"
  done
}

# job::_task_log <id> — resolve the pueue task's log file path from the
# job's recorded pueue_id. JOB_PUEUE_LOG_DIR is the override/test seam; the
# real default is pueue's macOS log directory (Linux's differs but this repo
# targets macOS first — a Linux default is a follow-up when that box needs
# job::watch).
job::_task_log() {
  local id="${1:?job::_task_log: id required}" task_id
  task_id=$(jq -r '.pueue_id // empty' "$JOB_STATE_ROOT/$id/meta.json" 2>/dev/null) \
    || return 1
  [[ "$task_id" == <-> ]] || return 1
  local logdir="${JOB_PUEUE_LOG_DIR:-$HOME/Library/Application Support/pueue/task_logs}"
  print -r -- "$logdir/$task_id.log"
}

# job::_open_log_tab <title> <logfile> — open a mux tab tailing a job's
# pueue log and BLOCK until that tab's `tail -f` exits, so job::watch knows
# precisely when to relaunch the dashboard (spec §6 rev 3: "when the tail
# exits ... the driver relaunches"). JOB_OPEN_LOG_TAB_BIN is the test seam —
# it stands in for the whole tab-open-and-wait dance; a fake records argv
# and returns at once, simulating the tab having already closed. The real
# path shells to mux::new_tab (the house tab-open primitive, mirroring how
# mux-open/edit-terminal-config open a tab running a command) wrapping
# `tail -f <logfile>` with a FIFO sentinel the wrapped command signals on
# exit — mux::new_tab itself is fire-and-forget (a tmux window/zellij tab
# doesn't report back when its own command finishes), so this function's
# OWN blocking read is what turns "tab requested" into "tab closed".
job::_open_log_tab() {
  local title="$1" logfile="$2"
  if [ -n "${JOB_OPEN_LOG_TAB_BIN:-}" ]; then
    "$JOB_OPEN_LOG_TAB_BIN" "$title" "tail -f $logfile"
    return $?
  fi
  local muxlib="${${(%):-%x}:A:h}/mux.zsh"
  [ -r "$muxlib" ] || return 1
  # Same subshell probe as job::_watch_confirm_cancel: pick-common (pulled
  # in by mux.zsh) hard-exits at SOURCE time when fzf is missing.
  ( source "$muxlib" ) >/dev/null 2>&1 || return 1
  source "$muxlib" 2>/dev/null || return 1
  local sentinel
  sentinel=$(mktemp -u "${TMPDIR:-/tmp}/job-logtab.XXXXXX")
  mkfifo -m 600 -- "$sentinel" 2>/dev/null || return 1
  mux::new_tab --name "$title" -- \
    sh -c 'tail -f "$1"; printf x > "$2" 2>/dev/null' _ "$logfile" "$sentinel" \
    || { rm -f -- "$sentinel"; return 1; }
  cat "$sentinel" >/dev/null 2>&1
  rm -f -- "$sentinel"
  return 0
}

# job::_watch_confirm_cancel <id> <title> — the "cancel <id>" choreography's
# confirm step, routed through the house dialog layer (mux::confirm — a mux
# popup inside a session, inline input::confirm otherwise). It runs BETWEEN
# dashboard popups: troupe has already exited by the time job::watch calls
# this, so there is never a second popup to stack over the dashboard's own
# (the phase-2b --in-float branch that worked around exactly that stacking
# problem no longer applies and is retired). Fail-closed — ANY non-zero rc
# (declined, unrenderable, or the 130 ESC-cancel) means "do not cancel".
# rc 0 = the job WAS cancelled, rc 1 = declined (caller relaunches as-is).
job::_watch_confirm_cancel() {
  local id="$1" title="$2"
  local muxlib="${${(%):-%x}:A:h}/mux.zsh"
  [ -r "$muxlib" ] || return 1
  # pick-common (pulled in by mux.zsh) hard-exits at SOURCE time when fzf is
  # missing — probe the load in a subshell so a widget-stack that cannot
  # load declines the confirm instead of killing the caller's whole shell.
  ( source "$muxlib" ) >/dev/null 2>&1 || return 1
  source "$muxlib" 2>/dev/null || return 1
  mux::confirm "Cancel ${title}?" --title "Job runner" --danger \
    --affirmative "Cancel job" --negative "Keep running" >/dev/null || return 1
  job::cancel "$id" >/dev/null 2>&1
  return 0
}

# job::_dashboard_float <troupe> — float `troupe jobs` in a mux-modal popup
# (TMUX-only, per the established float gate: zellij-modal is a float
# CONSUMER, not a SPAWNER — see mux-modal's own header) and print the one
# action line troupe hands back through the popup's --capture channel.
# JOB_MUX_MODAL_BIN is the test seam (default: the real mux-modal script).
# The FIFO + concurrent-reader shape mirrors mux/tmux.zsh's _mux_tx_float
# exactly (same rendezvous: the reader opens for read BEFORE the popup can
# open the FIFO for write), so this is a proven pattern, not a new one.
job::_dashboard_float() {
  local troupe="$1"
  local modal="${JOB_MUX_MODAL_BIN:-$HOME/.config/mux/scripts/mux-modal}"
  local fifo out
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/job-dashboard-fifo.XXXXXX")
  mkfifo -m 600 -- "$fifo" 2>/dev/null || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/job-dashboard-out.XXXXXX") || { rm -f -- "$fifo"; return 1; }
  trap 'rm -f -- "$fifo" "$out"' INT TERM

  cat "$fifo" >"$out" 2>/dev/null &
  local reader_pid=$!

  "$modal" --title "Job runner" --capture "$fifo" -- \
    "$troupe" jobs --state-root "$JOB_STATE_ROOT" >/dev/null 2>&1
  local rc=$?
  if ((rc != 0)); then
    kill "$reader_pid" 2>/dev/null
    wait "$reader_pid" 2>/dev/null
    rm -f -- "$fifo" "$out"
    return "$rc"
  fi
  wait "$reader_pid"

  local result
  result=$(<"$out")
  rm -f -- "$fifo" "$out"
  print -r -- "$result"
  return 0
}

# job::_dashboard_inline <troupe> — outside a mux session, run `troupe jobs`
# directly; its stdout IS the one action line (troupe-design.md §6).
job::_dashboard_inline() {
  local troupe="$1"
  "$troupe" jobs --state-root "$JOB_STATE_ROOT"
}

# job::watch — the troupe dashboard driver (spec §6 revision 3). Floats
# `troupe jobs` through mux-modal under tmux, or runs it directly outside a
# mux session, and loops on the widget's one-line action protocol until the
# dashboard is genuinely done:
#
#   (blank) / "empty"  dismissed, or auto-closed after the last job
#                       finished — either way, done.
#   "cancel <id>"       show the house confirm; Keep running relaunches
#                       as-is; Cancel job calls job::cancel and relaunches
#                       UNLESS that was the last live job, in which case the
#                       dashboard stays closed.
#   "logs <id>"         open a tab tailing the task's pueue log, wait for it
#                       to close, then relaunch.
#
# An up-front empty scan means the dashboard (and troupe) is never even
# launched when nothing is running — "no running jobs" is a quiet refusal,
# not an empty popup flash.
job::watch() {
  # ALL loop-body variables are declared here, never inside the while loop:
  # zsh's `local NAME` (no assignment) on an already-local NAME PRINTS
  # `NAME=value` to stdout — from the second iteration on it leaked
  # `action=…`/`rc=…` into the driver's stdout (and --modal's captured
  # stdout). Same regression class the rev-2 viewer hit; see its old fix
  # note (git history) for the first occurrence.
  setopt localoptions noerrexit
  local -a live remaining
  local troupe action cid ctitle lid ltitle logfile
  local rc

  live=(${(f)"$(job::_live_ids)"})
  if ((${#live} == 0)); then
    log_error "job::watch: no running jobs"
    return 1
  fi

  troupe=$(job::_troupe) \
    || die "troupe is not installed — go install github.com/Townk/troupe/cmd/troupe@latest"

  while true; do
    if [ -n "${TMUX:-}" ]; then
      action=$(job::_dashboard_float "$troupe")
      rc=$?
    else
      action=$(job::_dashboard_inline "$troupe")
      rc=$?
    fi
    ((rc == 0)) || { log_error "job::watch: dashboard launch failed"; return 1; }

    case "$action" in
      '' | empty)
        return 0
        ;;
      cancel$'\t'*)
        cid="${action#cancel$'\t'}"
        ctitle=$(jq -r '.title // empty' "$JOB_STATE_ROOT/$cid/meta.json" 2>/dev/null)
        if job::_watch_confirm_cancel "$cid" "${ctitle:-$cid}" >/dev/null 2>&1; then
          remaining=(${(f)"$(job::_live_ids)"})
          remaining=(${remaining:#$cid})
          ((${#remaining} == 0)) && return 0
        fi
        # Declined ("Keep running"), or cancelled with other jobs still
        # live: relaunch the dashboard as-is.
        ;;
      logs$'\t'*)
        lid="${action#logs$'\t'}"
        ltitle=$(jq -r '.title // empty' "$JOB_STATE_ROOT/$lid/meta.json" 2>/dev/null)
        logfile=$(job::_task_log "$lid") || logfile=""
        job::_open_log_tab "${ltitle:-$lid}" "$logfile"
        ;;
      *)
        log_error "job::watch: unrecognized dashboard action: $action"
        return 1
        ;;
    esac
  done
}

# job::log <id> — passthrough to `pueue log <pueue_id>`, for direct access
# to a job's full history outside the dashboard's summary view. Unknown id
# (no meta.json, or an unresolvable pueue_id) → rc 1 "unknown job".
job::log() {
  local id="${1:?job::log: id required}" dir task_id pueue
  dir="$JOB_STATE_ROOT/$id"
  [ -f "$dir/meta.json" ] || { log_error "job::log: unknown job $id"; return 1; }
  task_id=$(jq -r '.pueue_id // empty' "$dir/meta.json" 2>/dev/null)
  [[ "$task_id" == <-> ]] || { log_error "job::log: unknown job $id"; return 1; }
  pueue=$(job::_pueue) || return 1
  "$pueue" log "$task_id"
}
