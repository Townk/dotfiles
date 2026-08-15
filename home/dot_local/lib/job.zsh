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
  local group="default" title="" icon="" progress="expected"
  while [ $# -gt 0 ]; do
    case "$1" in
      --group) group="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --icon) icon="$2"; shift 2 ;;
      --no-progress) progress="none"; shift ;;
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
