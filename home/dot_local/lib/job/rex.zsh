# job/rex.zsh — the Rex terminal side of jobs. SOURCED by job.zsh. Every rex
# call from job code passes --autostart=false and is best-effort: a missing,
# slow or restarting Rex must never fail or hang a job operation.

# job::_rex — resolve the rex client. JOB_REX_BIN is the test seam; then a rex
# on PATH; then the CLI the Mac app keeps inside its server bundle (it only
# puts rex on PATH in the panes it starts). rc 1 when none exists.
job::_rex() {
  if [ -n "${JOB_REX_BIN:-}" ]; then
    print -r -- "$JOB_REX_BIN"
    return 0
  fi
  if command -v rex >/dev/null 2>&1; then
    print -r -- rex
    return 0
  fi
  local app="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  [ -x "$app" ] || return 1
  print -r -- "$app"
}

# job::_rex_available — rc 0 when a Rex server answers, without starting one.
job::_rex_available() {
  local rex
  rex=$(job::_rex) || return 1
  "$rex" --autostart=false --timeout 2s whoami >/dev/null 2>&1
}

# job::_rex_log <message…> — append `<ISO time> <message>` to
# ${XDG_CACHE_HOME:-~/.cache}/jobs/rex.log, beside the callback's log: the
# trail of every Rex step that failed or changed a tab. Never fails.
job::_rex_log() {
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/jobs" ts
  {
    zmodload zsh/datetime \
      && strftime -s ts '%Y-%m-%dT%H:%M:%S%z' "$EPOCHSECONDS" \
      && mkdir -p -- "$dir" \
      && print -r -- "$ts $*" >> "$dir/rex.log"
  } 2>/dev/null || :
  return 0
}

# job::_rex_jobs_session <rex> <timeout> — print the id of the session
# labelled exactly Jobs, or nothing when there is none. rc 1 when the list
# cannot be had or read: an unreadable listing is not "no Jobs session",
# and creating one then could make a second.
job::_rex_jobs_session() {
  local out
  out=$("$1" --autostart=false --timeout "$2" ls --json 2>/dev/null) || return 1
  print -r -- "$out" | jq -er '.sessions | arrays
    | first(.[] | select(.label == "Jobs") | .session_id) // ""' 2>/dev/null
}

# job::_rex_open_tab_unlocked <id> — open the job's follower tab in the Jobs
# session, creating the session when no session is labelled Jobs, and record
# the session id in $JOB_STATE_ROOT/.rex_session and `<epoch> <block id>` of
# the new tab in the job's `tab` file (job::_rex_reconcile leaves a tab that
# young alone while its follower starts). The caller holds
# $JOB_STATE_ROOT/.rex.lock: the check and the create are one step, or two
# jobs starting together each create a Jobs session. rc 1, logged, when Rex
# is gone or refuses.
job::_rex_open_tab_unlocked() {
  local id="${1:?job::_rex_open_tab_unlocked: id required}"
  local rex title label cli out sid block
  rex=$(job::_rex) || { job::_rex_log "job $id: open tab: no rex client"; return 1; }
  title=$(jq -r '.title // empty' "$JOB_STATE_ROOT/$id/meta.json" 2>/dev/null) \
    || title=""
  [ -n "$title" ] || title="$id"
  label="${${title//$'\n'/ }[1,128]}"
  cli="${JOB_CLI:-$HOME/.local/libexec/job}"
  sid=$(job::_rex_jobs_session "$rex" 5s) \
    || { job::_rex_log "job $id: open tab: cannot read the session list"; return 1; }
  if [ -z "$sid" ]; then
    # --window=: a title starting with a dash stays the label, not a flag.
    out=$("$rex" --autostart=false --timeout 5s new Jobs --window="$label" \
      --json -- "$cli" follow "$id" 2>/dev/null) \
      || { job::_rex_log "job $id: open tab: new Jobs failed"; return 1; }
    sid=$(print -r -- "$out" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
    block=$(print -r -- "$out" \
      | jq -r '.initial_windows[0].block_ids[0] // empty' 2>/dev/null) || block=""
  else
    # A positional label starting with a dash would be read as a flag.
    [[ "$label" == -* ]] && label=" $label"
    out=$("$rex" --autostart=false --timeout 5s window new -s Jobs "$label" \
      --focus=false --json -- "$cli" follow "$id" 2>/dev/null) \
      || { job::_rex_log "job $id: open tab: window new failed"; return 1; }
    block=$(print -r -- "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null) \
      || block=""
  fi
  zmodload zsh/datetime 2>/dev/null
  {
    print -r -- "$EPOCHSECONDS $block" > "$JOB_STATE_ROOT/$id/.tab.$$" \
      && mv -f -- "$JOB_STATE_ROOT/$id/.tab.$$" "$JOB_STATE_ROOT/$id/tab"
  } 2>/dev/null || :
  [ -n "$sid" ] || return 0
  print -r -- "$sid" > "$JOB_STATE_ROOT/.rex_session.$$" \
    && mv -f -- "$JOB_STATE_ROOT/.rex_session.$$" "$JOB_STATE_ROOT/.rex_session"
}

# job::_rex_open_tab <id> — job::_rex_open_tab_unlocked under the Jobs lock
# (waits up to 5 s for it). The subshell holds the lock and drops it on exit.
job::_rex_open_tab() {
  local id="${1:?job::_rex_open_tab: id required}"
  mkdir -p -- "$JOB_STATE_ROOT" 2>/dev/null || return 1
  (
    lock::hold "$JOB_STATE_ROOT/.rex.lock" 5 || exit 1
    job::_rex_open_tab_unlocked "$id"
  )
}

# job::_rex_reconcile_unlocked [<id>] — repair the Jobs session after a Rex
# server restart, which restores each job tab as a bare shell with the same
# label, a new block id and no follower. A no-op, rc 1, unless a session
# labelled exactly Jobs exists and its blocks can be listed; every call
# names that session and no other. Otherwise rc 0, after:
#   1. closing every block in Jobs that no live follower names;
#   2. opening a tab for every job with no result, and every failed job
#      that had a Jobs tab (its `tab` file exists) and is not dismissed,
#      that has no live follower — never for a success, a cancel or a
#      --notify none job.
# A follower is live when the pid in the job's `follower` file is alive (a
# follower outside Jobs — inline, in the pane that started the job — covers
# its job too). A tab still starting is left alone: one opened (per the
# job's `tab` file) less than JOB_FOLLOW_DELAY + 5 s ago is neither closed
# nor reopened, and the listing is taken before any tab is opened, so a run
# never closes what it opened. A job with no result younger than that is
# left to its own scheduled step, unless it is <id>: the job whose step this
# is. The caller holds $JOB_STATE_ROOT/.rex.lock. Closes and reopens are
# logged.
job::_rex_reconcile_unlocked() {
  local due="${1:-}" rex sid out d id block pid epoch res code notify created
  local -i covered
  local -F grace=$(( ${JOB_FOLLOW_DELAY:-2} + 5 ))
  local -a listed reopen
  local -A keep
  rex=$(job::_rex) || return 1
  sid=$(job::_rex_jobs_session "$rex" 2s) || return 1
  [ -n "$sid" ] || return 1
  out=$("$rex" --autostart=false --timeout 2s block ls -s Jobs --json \
    2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  out=$(print -r -- "$out" | jq -r 'if (.blocks | type) == "array"
    then .blocks[].block_id // empty else error("no blocks") end' 2>/dev/null) \
    || return 1
  listed=(${(f)out})
  zmodload zsh/datetime 2>/dev/null

  for d in "$JOB_STATE_ROOT"/*(N/); do
    [ -f "$d/meta.json" ] || continue
    id="${d:t}" covered=0
    block="" pid=""
    { read -r block pid < "$d/follower" } 2>/dev/null || :
    if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
      covered=1
      [ -n "$block" ] && keep[$block]=1
    fi
    epoch="" block=""
    { read -r epoch block < "$d/tab" } 2>/dev/null || :
    if [[ "$epoch" == <-> ]] && (( EPOCHSECONDS - epoch < grace )); then
      covered=1
      [ -n "$block" ] && keep[$block]=1
    fi
    (( covered )) && continue
    out=$(jq -r '"\(.notify // "all") \(.created // 0)"' "$d/meta.json" \
      2>/dev/null) || continue
    read -r notify created <<< "$out"
    [ "$notify" = "none" ] && continue
    if [ -s "$d/result" ]; then
      res=""
      { read -r epoch res code < "$d/result" } 2>/dev/null || :
      case "$res" in Success | Killed) continue ;; esac
      [ -e "$d/dismissed" ] && continue
      # Only a failure that had a Jobs tab gets one back: one followed
      # inline, or over within the delay, never had one.
      [ -e "$d/tab" ] || continue
    elif [ "$id" != "$due" ]; then
      [[ "$created" == <-> ]] && (( EPOCHSECONDS - created < grace )) && continue
    fi
    reopen+=("$id")
  done

  for block in "${listed[@]}"; do
    (( ${+keep[$block]} )) && continue
    if "$rex" --autostart=false --timeout 2s block close -s Jobs "$block" \
      >/dev/null 2>&1; then
      job::_rex_log "reconcile: closed $block: no live follower"
    else
      job::_rex_log "reconcile: could not close $block"
    fi
  done
  for id in "${reopen[@]}"; do
    job::_rex_open_tab_unlocked "$id" \
      && job::_rex_log "reconcile: reopened the tab of job $id"
  done
  return 0
}

# job::_rex_reconcile — job::_rex_reconcile_unlocked under the Jobs lock.
# Best-effort: always rc 0.
job::_rex_reconcile() {
  mkdir -p -- "$JOB_STATE_ROOT" 2>/dev/null || return 0
  (
    lock::hold "$JOB_STATE_ROOT/.rex.lock" 5 \
      || { job::_rex_log "reconcile: the Jobs lock is busy"; exit 0; }
    job::_rex_reconcile_unlocked
  ) || :
  return 0
}

# job::_rex_schedule_tab <id> — return at once; in the background, after
# JOB_FOLLOW_DELAY seconds, if the job still has no result and a Rex server
# answers, reconcile the Jobs session (which opens this job's tab with the
# rest), or, when there is no Jobs session to reconcile, open the tab and
# the session. One lock covers both, so the job gets one tab. A job over
# sooner never gets a tab (a clipboard restore starts one on every
# restore). Nothing for --notify none. The background step holds none of
# the caller's descriptors, so a caller reading job::start's output through
# $(…) does not wait for the delay.
job::_rex_schedule_tab() {
  local id="${1:?job::_rex_schedule_tab: id required}"
  local dir="$JOB_STATE_ROOT/$1" delay="${JOB_FOLLOW_DELAY:-2}" notify
  notify=$(jq -r '.notify // "all"' "$dir/meta.json" 2>/dev/null) || notify="all"
  [ "$notify" = "none" ] && return 0
  (
    sleep "$delay"
    [ -d "$dir" ] && [ ! -s "$dir/result" ] || exit 0
    job::_rex_available || exit 0
    lock::hold "$JOB_STATE_ROOT/.rex.lock" 5 \
      || { job::_rex_log "job $id: open tab: the Jobs lock is busy"; exit 0; }
    job::_rex_reconcile_unlocked "$id" || job::_rex_open_tab_unlocked "$id"
  ) < /dev/null > /dev/null 2>&1 &!
  return 0
}
