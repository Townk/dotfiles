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

  local id="${EPOCHSECONDS}-$$"
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
