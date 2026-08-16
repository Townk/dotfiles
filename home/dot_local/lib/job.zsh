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
  if ((modal)); then
    # Headless (no controlling terminal on stderr — cron, a run-shell
    # binding piped through something, a bare `</dev/null` invocation): the
    # job is already enqueued regardless, and troupe's own no-tty behavior
    # is untrusted (could error, could hang) — never attempt to drive the
    # dashboard here, just say so and let the GUI HUD be the surface.
    if [ -t 2 ]; then
      job::watch
    else
      log_warn "headless: the GUI HUD is the surface"
    fi
  fi
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

# --- troupe dashboard driver (spec §6 revision: persistent dialog) ---------
# `troupe jobs` (troupe-design.md §6) renders the multi-job dashboard — the
# terminal twin of the Hammerspoon capsule stack — and hands back at most ONE
# action line on stdout, always exiting 0: empty (dismissed), "cancel <id>",
# or "logs <id>". The dashboard is persistent — it never auto-closes; a scan
# that finds no live job renders the widget's own "No task running" empty
# state and keeps polling — so there is no more "is this the last live job"
# question for this driver to answer. Everything else — the confirm, the
# actual cancel, the log tab, every relaunch — is this driver's job
# (troupe-design.md §6: "logic stays in the caller"). The rev-2 inline
# log-viewer loop (mirror, pending buffer, follow child, its own header/bar
# composition) retired earlier; `job log <id>` covers direct log access
# instead.

# job::_troupe — resolve the troupe binary. JOB_TROUPE_BIN is the test seam;
# unset falls back to PATH resolution (troupe ships via the Gofile, no fixed
# install prefix to guess, unlike pueue's Homebrew fallback in job::_pueue).
job::_troupe() {
  if [ -n "${JOB_TROUPE_BIN:-}" ]; then
    print -r -- "$JOB_TROUPE_BIN"
    return 0
  fi
  local p
  p=$(command -v troupe 2>/dev/null) && { print -r -- "$p"; return 0 }
  # The tmux server's PATH lacks the interactive profile's go-bin dirs, and
  # both the J binding and mux-modal's popup run from the SERVER env — so a
  # bare `command -v` fails exactly where the dashboard is used (caught live
  # in Mode B). Same known-paths fallback as input-common's _input::bin.
  for p in "$HOME/.local/share/go/bin/troupe" "$HOME/go/bin/troupe"; do
    [ -x "$p" ] && { print -r -- "$p"; return 0 }
  done
  return 1
}

# job::_live_ids — print the id of every job dir that has meta.json and no
# result file, one per line, newest first. Generalizes the phase-2b
# `--latest` resolver (retired — the dashboard shows every job at once, so
# there is no more "the one newest job" to single out) into "list every live
# id". job::watch no longer calls this (spec §6 rev: the dashboard is
# persistent and owns its own empty state, so there is no more "any jobs at
# all?"/"was that the last live job?" question to answer here) — kept as a
# small, independently testable primitive.
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
# pueue log and BLOCK until that tab process exits — by ANY means (a clean
# `tail -f` end, which never happens on its own; the user closing the tab;
# Ctrl+C; SIGHUP on pane close) — so job::watch knows precisely when to
# relaunch the dashboard (spec §6 rev 3: "when the tail exits ... the
# driver relaunches").
#
# C1 regression: the wrapped command used to be `tail -f "$1"; printf x >
# "$2"` — a signal that kills the whole `sh -c` (Ctrl+C, the pane's SIGHUP
# on close) kills it BEFORE the `printf` ever runs, so no writer ever opens
# the FIFO and the `cat` below deadlocked FOREVER on every realistic tab
# exit, not just the unrealistic "tail -f reaches EOF on its own" one. Fix:
# the wrapped command HOLDS the FIFO's write end open for its whole life
# (`exec 3>"$2"; exec tail -f "$1"`) and relies on fd-close-on-death — the
# kernel closes every fd the INSTANT a process dies, by any means, no
# cleanup code required to run. The reader then genuinely waits for "every
# writer gone", which fd-close-on-death guarantees unconditionally.
#
# JOB_MUX_NEW_TAB_BIN is the test seam for the tab-SPAWN step ONLY (mirrors
# job::_pueue/_troupe's shape) — not for the whole function, so the FIFO
# open/wait/bound machinery below is real code under the spec suite, not a
# bypassed no-op. The real path shells to mux::new_tab (the house tab-open
# primitive, mirroring how mux-open/edit-terminal-config open a tab running
# a command); mux::new_tab is itself fire-and-forget (a tmux window/zellij
# tab's spawn call returns immediately — the window's own command keeps
# running as the mux server's child, independent of this process), so this
# function's OWN blocking read is what turns "tab requested" into "tab
# closed", not the spawn call.
#
# Bounded wait: a wedged/never-spawned tab (mux::new_tab silently failed,
# or the pane never actually opened) must not hang a run-shell binding
# forever. JOB_LOGTAB_TIMEOUT_S (default 10) is the test/tuning seam for
# the bound; the FIFO is removed on every exit path.
job::_open_log_tab() {
  local title="$1" logfile="$2"
  local sentinel
  sentinel=$(mktemp -u "${TMPDIR:-/tmp}/job-logtab.XXXXXX")
  mkfifo -m 600 -- "$sentinel" 2>/dev/null || return 1

  if [ -n "${JOB_MUX_NEW_TAB_BIN:-}" ]; then
    "$JOB_MUX_NEW_TAB_BIN" --name "$title" -- \
      sh -c 'exec 3>"$2"; exec tail -f "$1"' _ "$logfile" "$sentinel" \
      || { rm -f -- "$sentinel"; return 1; }
  else
    local muxlib="${${(%):-%x}:A:h}/mux.zsh"
    # Same subshell probe as job::_watch_confirm_cancel: pick-common
    # (pulled in by mux.zsh) hard-exits at SOURCE time when fzf is missing.
    if ! { [ -r "$muxlib" ] && ( source "$muxlib" ) >/dev/null 2>&1; }; then
      rm -f -- "$sentinel"
      return 1
    fi
    source "$muxlib" 2>/dev/null || { rm -f -- "$sentinel"; return 1; }
    mux::new_tab --name "$title" -- \
      sh -c 'exec 3>"$2"; exec tail -f "$1"' _ "$logfile" "$sentinel" \
      || { rm -f -- "$sentinel"; return 1; }
  fi

  # A blocking read-open on the FIFO runs in a background reader we poll
  # (kill -0) instead of an unconditional `wait`, so a spawn that never
  # actually opens the write end cannot hang forever — the open itself
  # blocks past any `read -t` timeout, so the timeout has to live on the
  # OUTSIDE of the open, not inside it.
  cat "$sentinel" >/dev/null 2>&1 &
  local reader_pid=$!
  local bound=$(( ${JOB_LOGTAB_TIMEOUT_S:-10} * 10 )) waited=0
  while kill -0 "$reader_pid" 2>/dev/null; do
    if ((waited >= bound)); then
      kill "$reader_pid" 2>/dev/null
      wait "$reader_pid" 2>/dev/null
      rm -f -- "$sentinel"
      log_error "job::_open_log_tab: timed out waiting for the log tab to close"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$reader_pid" 2>/dev/null
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
# rc 0 = the job WAS cancelled, rc 1 = declined OR the cancel itself failed
# (caller relaunches either way — the job genuinely still runs on rc 1, so
# treating it as "not cancelled" is the honest read, not an optimistic one).
job::_watch_confirm_cancel() {
  local id="$1" title="$2"
  local muxlib="${${(%):-%x}:A:h}/mux.zsh"
  [ -r "$muxlib" ] || return 1
  # pick-common (pulled in by mux.zsh) hard-exits at SOURCE time when fzf is
  # missing — probe the load in a subshell so a widget-stack that cannot
  # load declines the confirm instead of killing the caller's whole shell.
  ( source "$muxlib" ) >/dev/null 2>&1 || return 1
  source "$muxlib" 2>/dev/null || return 1
  mux::confirm "Cancel ${title}?" --title "Task runner" --danger \
    --affirmative "Cancel job" --negative "Keep running" --inset 1 >/dev/null || return 1
  if ! job::cancel "$id" >/dev/null 2>&1; then
    log_error "job::_watch_confirm_cancel: cancel failed — is pueued running?"
    return 1
  fi
  return 0
}

# job::_theme_args — populate the global AI_THEME_ARGS with the --theme-*
# flags troupe/ask both read (theme-common.zsh's contract). Env cannot carry
# these across a tmux popup — display-popup runs its command from the
# SERVER's environment, not this shell's (the same constraint --state-root
# used to hit before it became an explicit flag) — so on BOTH dashboard
# launch paths the flags ride the command line instead. Best-effort: an
# unreadable/unloadable theme lib just means no theme flags (troupe keeps
# its own built-in defaults), never a hard failure of the dashboard launch.
job::_theme_args() {
  AI_THEME_ARGS=()
  local themelib="${${(%):-%x}:A:h}/theme-common.zsh"
  [ -r "$themelib" ] || return 0
  # Same subshell probe as job::_watch_confirm_cancel/_open_log_tab: a
  # source-time hard-exit anywhere in the chain must not take the caller
  # down with it.
  ( source "$themelib" ) >/dev/null 2>&1 || return 0
  source "$themelib" 2>/dev/null || return 0
  theme::args
}

# job::_dashboard_float <troupe> [<select-id>] [<known-height>] — float `troupe jobs` in a
# mux-modal popup (TMUX-only, per the established float gate: zellij-modal
# is a float CONSUMER, not a SPAWNER — see mux-modal's own header) and print
# the one action line troupe hands back through the popup's --capture
# channel. <select-id>, when given, rides the real launch as `--select` —
# the resize wire's cursor-preservation half: a relaunch after a resize
# hands back the id the widget was showing a cursor on, so the new instance
# starts there instead of resetting to the top.
# JOB_MUX_MODAL_BIN is the test seam (default: the real mux-modal script).
# The FIFO + concurrent-reader shape mirrors mux/tmux.zsh's _mux_tx_float
# exactly (same rendezvous: the reader opens for read BEFORE the popup can
# open the FIFO for write), so this is a proven pattern, not a new one.
#
# Single-chrome float: troupe draws its OWN framed box (▓▓▓ "Task runner" +
# rule — troupe-design.md §6), so this call carries NO --title (mux-modal
# would draw a second frame around the first) and passes --borderless
# --no-chrome instead — the same "the target owns the box" contract the
# ask/dialog floats already use (tmux-modal's --no-chrome branch; see
# _mux_tx_float's --borderless comment). The popup is sized from troupe's
# own --measure (its rendered height for the current job count) with NO
# padding: _mux_tx_float's own "+2" precedent compensates for a BORDER
# (display-popup's default frame, or the widget's own box drawn inside a
# borderless popup) eating cells — here there is no border at all (-B +
# --no-chrome), so interior == outer and padding would just hand troupe a
# pty 2 cols/2 rows larger than its self-drawn box, a visible empty gap
# band around it. Do not blindly re-copy the +2 padding here. The SAME
# --width also rides the real launch below (not just --measure) so the
# measured height and the actual render agree regardless of the pty size
# the popup itself would otherwise hand troupe.
#
# <known-height>, when given, is the resize wire's own height
# (`resize\t<h>[\t<id>]` — job-runner design §6 rev 2026-08-16) forwarded
# straight through by job::watch on the ONE relaunch that immediately
# follows a resize action: it SKIPS the `--measure` round trip entirely
# ("adopt resize\t<h> ... skip the re-measure"). Every other launch — the
# very first one, and any relaunch after cancel/logs — has no wire-supplied
# height to trust and still measures for real.
job::_dashboard_float() {
  local troupe="$1" select_id="${2:-}" known_h="${3:-}"
  local modal="${JOB_MUX_MODAL_BIN:-$HOME/.config/mux/scripts/mux-modal}"
  local fifo out h
  job::_theme_args

  if [[ -n "$known_h" ]]; then
    h="$known_h"
  else
    h=$("$troupe" jobs --measure --state-root "$JOB_STATE_ROOT" --width 57 2>/dev/null)
    [[ "$h" == <-> ]] || h=15
  fi

  fifo=$(mktemp -u "${TMPDIR:-/tmp}/job-dashboard-fifo.XXXXXX")
  mkfifo -m 600 -- "$fifo" 2>/dev/null || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/job-dashboard-out.XXXXXX") || { rm -f -- "$fifo"; return 1; }
  trap 'rm -f -- "$fifo" "$out"' INT TERM

  cat "$fifo" >"$out" 2>/dev/null &
  local reader_pid=$!

  # --launched-height "$h" is what makes the resize wire possible at all
  # (troupe-design.md §6): this is the exact popup height the caller just
  # sized the pane to, so troupe can tell when its own rendered content no
  # longer matches it. --select forwards the cursor a resize relaunch is
  # asked to restore, when the caller has one.
  local -a select_args=()
  [ -n "$select_id" ] && select_args=(--select "$select_id")
  "$modal" --borderless --no-chrome --width 57 --height "$h" \
    --capture "$fifo" -- \
    "$troupe" jobs --state-root "$JOB_STATE_ROOT" --width 57 \
    --launched-height "$h" "${select_args[@]}" "${AI_THEME_ARGS[@]}" >/dev/null 2>&1
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
  job::_theme_args
  "$troupe" jobs --state-root "$JOB_STATE_ROOT" "${AI_THEME_ARGS[@]}"
}

# --- pane host (job-runner design §6 rev 2026-08-16: "the floating-pane
# host") -----------------------------------------------------------------
# Real pane, not a popup: genuinely persistent (survives switching tabs/
# windows and coming back), live-resized in place via TROUPE_RESIZE_CMD (no
# relaunch-to-resnug dance), non-modal. `troupe jobs --follow` never exits
# on its own — cancel/logs stream as line-buffered stdout, ESC/q ends the
# process (and the pane closes with it, close-on-exit). job::watch picks
# this host over the popup loop above whenever job::_use_pane_host says so.

# job::_use_pane_host — true when job::watch should host the dashboard in a
# floating PANE instead of the popup. JOB_FORCE_HOST=pane|popup is the test
# seam (skips the real probe outright, so pane-host examples don't need a
# tmux build that genuinely carries `new-pane`, and popup examples stay
# pinned to the fallback regardless of what this box's tmux supports).
# Real selection needs an active TMUX session AND the capability probe
# (mux::has_float_pane's `list-commands` grep) — sourced via mux-
# bootstrap.zsh, NOT the full mux.zsh: no fzf/pick-common dependency for a
# plain capability question, same rationale as every other lazy-source in
# this file. The same subshell-probe-then-source guard as
# job::_watch_confirm_cancel/_open_log_tab: a load that dies at source time
# degrades to "no pane host" (the popup fallback), never takes the caller
# down.
job::_use_pane_host() {
  case "${JOB_FORCE_HOST:-}" in
    pane) return 0 ;;
    popup) return 1 ;;
  esac
  [ -n "${TMUX:-}" ] || return 1
  local muxlib="${${(%):-%x}:A:h}/mux-bootstrap.zsh"
  [ -r "$muxlib" ] || return 1
  ( source "$muxlib" ) >/dev/null 2>&1 || return 1
  source "$muxlib" 2>/dev/null || return 1
  mux::has_float_pane
}

# job::_float_pane <width> <height> -- <cmd...> — the pane-SPAWN step, one
# level below job::_watch_pane (mirrors job::_open_log_tab's
# JOB_MUX_NEW_TAB_BIN: the test seam stubs the SPAWN only, so the FIFO/
# read-loop machinery in job::_watch_pane runs for real under the spec
# suite). JOB_MUX_FLOAT_PANE_BIN receives the SAME argv and must print the
# new pane's id on stdout; the real path sources mux-bootstrap.zsh (see
# job::_use_pane_host) and calls mux::float_pane.
job::_float_pane() {
  if [ -n "${JOB_MUX_FLOAT_PANE_BIN:-}" ]; then
    "$JOB_MUX_FLOAT_PANE_BIN" "$@"
    return $?
  fi
  local muxlib="${${(%):-%x}:A:h}/mux-bootstrap.zsh"
  [ -r "$muxlib" ] || return 1
  ( source "$muxlib" ) >/dev/null 2>&1 || return 1
  source "$muxlib" 2>/dev/null || return 1
  mux::float_pane "$@"
}

# job::_focus_pane_if_alive <pane_id> — spec §6 rev 4 re-summon: "prefix-J
# finds the pane alive ... focus it ... instead of respawn". rc 0 means the
# pane was still alive AND is now focused; rc 1 means it's gone (the caller
# launches fresh and overwrites the stale state file). Focusing needs BOTH
# select-window and select-pane — a bare pane id switches which pane is
# active INSIDE its window, not which window the client is looking at.
# JOB_MUX_FOCUS_PANE_BIN is the test seam (same one-level-below shape as
# job::_float_pane): given the pane id, decide alive/gone.
job::_focus_pane_if_alive() {
  local pane="${1:?job::_focus_pane_if_alive: pane id required}"
  if [ -n "${JOB_MUX_FOCUS_PANE_BIN:-}" ]; then
    "$JOB_MUX_FOCUS_PANE_BIN" "$pane"
    return $?
  fi
  local muxlib="${${(%):-%x}:A:h}/mux-bootstrap.zsh"
  [ -r "$muxlib" ] || return 1
  ( source "$muxlib" ) >/dev/null 2>&1 || return 1
  source "$muxlib" 2>/dev/null || return 1
  local bin win
  bin=$(mux::bin tmux) || return 1
  "$bin" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qFx -- "$pane" || return 1
  win=$("$bin" display -p -t "$pane" '#{window_id}' 2>/dev/null) || return 1
  "$bin" select-window -t "$win" 2>/dev/null
  "$bin" select-pane -t "$pane" 2>/dev/null
  return 0
}

# job::_watch_pane <troupe> — the pane-host driver body. Re-summon check
# first (a live pane on record wins, focused instead of a second dashboard);
# otherwise mkfifo, launch `troupe jobs --follow` inside a fresh float with
# TROUPE_RESIZE_CMD wired to re-snug ITS OWN pane live (the `$TMUX_PANE`
# read from inside the float resolves to that pane's own id — see the
# verification note on _mux_tx_float_pane), then read the streamed action
# lines off the FIFO until EOF (troupe exits on ESC/q, closing its stdout —
# fd-close-on-death, the same rendezvous job::_open_log_tab already relies
# on): "cancel\t<id>" routes through the house confirm and job::cancel
# exactly like the popup path (troupe keeps running regardless — cancel
# never closes the dashboard here); "logs\t<id>" opens the log tab and
# waits for it, same as the popup path; anything else is logged and
# ignored (never kills the reader — a skewed action must not orphan the
# pane). EOF ends the loop: the pane is already gone (it closed itself),
# so cleanup is just the fifo and the state file.
#
# The initial float IS measured (troupe --measure, same call the popup path
# makes) even though later drift self-corrects via the live hook: Follow's
# resize-hook debounce baseline is the model's OWN first-render height, not
# the pane's actual launched size, so an unmeasured guess would never be
# corrected by the hook — only a wrong SUBSEQUENT size would.
#
# --no-frame (troupe-design.md §6 rev, geometry fix 2026-08-16): unlike the
# popup path (job::_dashboard_float, mux-modal's own -B/--no-chrome IS the
# frame there), a pane host's chrome is tmux's OWN pane border — troupe's
# self-drawn ▓▓▓ box would double up with it. --width stays 57 TOTAL (the
# pane's own on-screen width, unchanged from the popup path): --no-frame
# widens troupe's CONTENT to fill that same 57 instead of shrinking the pane
# — troupe's own width semantics, not this driver's. --measure must pass
# the identical --no-frame + --width so the height it reports is the height
# the follow launch below will actually render (measure-parity) — a framed
# measurement here would size the pane 2 rows short (the border rows
# --no-frame drops), leaving %h from TROUPE_RESIZE_CMD's later live re-snug
# to correct only on the FIRST resize hook firing, not the initial spawn.
job::_watch_pane() {
  local troupe="$1"
  local statefile="$JOB_STATE_ROOT/.dashboard-pane"

  if [ -s "$statefile" ]; then
    local existing
    existing=$(<"$statefile")
    if job::_focus_pane_if_alive "$existing"; then
      return 0
    fi
    rm -f -- "$statefile"
  fi

  job::_theme_args
  local h
  h=$("$troupe" jobs --measure --no-frame --state-root "$JOB_STATE_ROOT" --width 57 2>/dev/null)
  [[ "$h" == <-> ]] || h=15

  local fifo
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/job-pane-fifo.XXXXXX")
  mkfifo -m 600 -- "$fifo" 2>/dev/null || return 1

  # TROUPE_RESIZE_CMD is exported INSIDE the pane's own command, not on this
  # process's env: display-popup/new-pane both run from the SERVER's
  # environment (job::_theme_args' comment covers the same constraint), so
  # setting it here would never reach troupe at all. The double-quote-
  # inside-double-quote (`\"\$TMUX_PANE\"`) is deliberate: this whole
  # string must survive intact as troupe's OWN opaque template — %h is
  # substituted by troupe itself (already the FRAMELESS height, since
  # --no-frame is threaded through to this same --follow launch, so the
  # model's own height()/Render agree end to end — troupe/jobs' model.go
  # height() calls Render with opts.Frameless, and Measure above used the
  # same flag), and $TMUX_PANE must stay UNexpanded until troupe's hook runs
  # it via its own `sh -c`, reading the FLOAT pane's environment (not this
  # driver's) at that later moment.
  local -a pane_cmd=(sh -c '
export TROUPE_RESIZE_CMD="tmux resize-pane -t \"\$TMUX_PANE\" -y %h"
exec "$1" jobs --follow --no-frame --state-root "$2" --width 57 "${@:4}" > "$3"
' _ "$troupe" "$JOB_STATE_ROOT" "$fifo" "${AI_THEME_ARGS[@]}")

  local pane_id
  pane_id=$(job::_float_pane 57 "$h" -- "${pane_cmd[@]}")
  if [[ -z "$pane_id" ]]; then
    rm -f -- "$fifo"
    log_error "job::_watch_pane: failed to open the floating pane"
    return 1
  fi
  print -r -- "$pane_id" > "$statefile"

  local verb id ctitle lid ltitle logfile
  while IFS=$'\t' read -r verb id; do
    case "$verb" in
      cancel)
        ctitle=$(jq -r '.title // empty' "$JOB_STATE_ROOT/$id/meta.json" 2>/dev/null)
        job::_watch_confirm_cancel "$id" "${ctitle:-$id}" >/dev/null 2>&1
        ;;
      logs)
        ltitle=$(jq -r '.title // empty' "$JOB_STATE_ROOT/$id/meta.json" 2>/dev/null)
        logfile=$(job::_task_log "$id") || logfile=""
        job::_open_log_tab "${ltitle:-$id}" "$logfile"
        ;;
      *)
        [ -n "$verb" ] && log_error "job::_watch_pane: unrecognized dashboard action: $verb"
        ;;
    esac
  done < "$fifo"

  rm -f -- "$fifo" "$statefile"
  return 0
}

# job::watch — the troupe dashboard driver (spec §6 revision: persistent
# dialog). Floats `troupe jobs` through mux-modal under tmux, or runs it
# directly outside a mux session, and loops on the widget's one-line action
# protocol until the dashboard is genuinely dismissed:
#
#   (blank)             dismissed (ESC/q) — done.
#   "cancel <id>"       show the house confirm, then relaunch either way —
#                       Keep running, or a confirmed cancel, even of the
#                       last live job: the dashboard now renders its own
#                       persistent "No task running" empty state instead of
#                       auto-closing, so there is nothing left to track here.
#   "logs <id>"         open a tab tailing the task's pueue log, wait for it
#                       to close, then relaunch.
#   "resize[\t<id>]"    the popup's content height drifted from the height
#                       it was launched at (tmux popups can't resize
#                       themselves) — relaunch IMMEDIATELY, no confirm, no
#                       delay, forwarding <id> (if any) as --select so the
#                       new instance's cursor lands back where it was.
#
# The dashboard owns the empty state now (troupe-design.md §6 rev): there is
# no up-front "any live jobs?" scan — job::watch always floats/runs it, and
# a truly empty state just means the widget renders "No task running" and
# keeps polling until the user dismisses it.
#
# Loop-termination note: every OTHER action either returns (dismiss/empty)
# or is bounded by a real, user-driven event (a confirm decision, a log tab
# closing) before the next relaunch — resize is the one action the widget
# can emit entirely on its own, poll after poll, with nothing in between.
# In practice that's bounded too (relaunches are driven by genuine content
# changes, and troupe's own debounce settles once the height stops
# drifting), but a pathological back-and-forth (e.g. a --launched-height/
# --measure mismatch that never converges) must not spin this loop forever
# — resize_streak counts CONSECUTIVE resize actions with no other action in
# between and bails out past 5.
job::watch() {
  # ALL loop-body variables are declared here, never inside the while loop:
  # zsh's `local NAME` (no assignment) on an already-local NAME PRINTS
  # `NAME=value` to stdout — from the second iteration on it leaked
  # `action=…`/`rc=…` into the driver's stdout (and --modal's captured
  # stdout). Same regression class the rev-2 viewer hit; see its old fix
  # note (git history) for the first occurrence.
  setopt localoptions noerrexit
  local troupe action cid ctitle lid ltitle logfile select_id="" resize_h="" rest
  local rc resize_streak=0

  troupe=$(job::_troupe) \
    || die "troupe is not installed — go install github.com/Townk/troupe/cmd/troupe@latest"

  # Host selection (job-runner design §6 rev 4): a floating PANE — real,
  # live-resizable, genuinely persistent — when the probe (or the
  # JOB_FORCE_HOST test seam) says so; the popup loop below stays the
  # fallback on stock tmux/outside tmux, unchanged.
  if job::_use_pane_host; then
    job::_watch_pane "$troupe"
    return $?
  fi

  while true; do
    if [ -n "${TMUX:-}" ]; then
      action=$(job::_dashboard_float "$troupe" "$select_id" "$resize_h")
      rc=$?
    else
      action=$(job::_dashboard_inline "$troupe")
      rc=$?
    fi
    ((rc == 0)) || { log_error "job::watch: dashboard launch failed"; return 1; }

    case "$action" in
      '')
        return 0
        ;;
      empty)
        # Binary-skew compat: an older troupe binary may still emit the
        # retired ~1s completed-beat's "empty" action (spec §6 rev — the
        # dashboard is persistent now and owns its own empty state).
        # Treat it exactly like dismiss rather than falling into the
        # unrecognized-action branch below.
        return 0
        ;;
      resize | resize$'\t'*)
        # No confirm, no delay — the driver relaunches immediately, and (as
        # of the height-on-the-wire amendment) WITHOUT re-measuring: the
        # wire is now `resize\t<h>[\t<id>]` — height first, so the height
        # travels with the very action that just proved it, and the
        # selected id (if any) is the resize wire's cursor-preservation
        # half, unchanged. A bare "resize" (no height, an older/skewed
        # binary) strips to "" and falls back to a real re-measure on the
        # next launch — never crashes on the unexpected shape.
        rest="${action#resize}"
        rest="${rest#$'\t'}"
        resize_h="${rest%%$'\t'*}"
        if [[ "$rest" == *$'\t'* ]]; then
          select_id="${rest#*$'\t'}"
        else
          select_id=""
        fi
        ((resize_streak++))
        if ((resize_streak > 5)); then
          log_error "job::watch: resize loop bailout — more than 5 consecutive resizes with no other action"
          return 1
        fi
        continue
        ;;
      cancel$'\t'*)
        resize_streak=0
        select_id=""
        resize_h=""
        cid="${action#cancel$'\t'}"
        ctitle=$(jq -r '.title // empty' "$JOB_STATE_ROOT/$cid/meta.json" 2>/dev/null)
        job::_watch_confirm_cancel "$cid" "${ctitle:-$cid}" >/dev/null 2>&1
        # Declined ("Keep running"), or a confirmed cancel — relaunch
        # either way; even the last live job's cancel just means the
        # dashboard's next render is the empty state.
        ;;
      logs$'\t'*)
        resize_streak=0
        select_id=""
        resize_h=""
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
