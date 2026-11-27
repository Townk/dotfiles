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

# job::_rex_open_tab_unlocked <id> — open the job's follower tab in the Jobs
# session, creating the session when no session is labelled Jobs, and record
# the session id in $JOB_STATE_ROOT/.rex_session. The caller holds
# $JOB_STATE_ROOT/.rex.lock: the check and the create are one step, or two
# jobs starting together each create a Jobs session. rc 1 when Rex is gone
# or refuses.
job::_rex_open_tab_unlocked() {
  local id="${1:?job::_rex_open_tab_unlocked: id required}"
  local rex title label cli out sid
  rex=$(job::_rex) || return 1
  title=$(jq -r '.title // empty' "$JOB_STATE_ROOT/$id/meta.json" 2>/dev/null) \
    || title=""
  [ -n "$title" ] || title="$id"
  label="${${title//$'\n'/ }[1,128]}"
  cli="${JOB_CLI:-$HOME/.local/libexec/job}"
  # An unreadable listing is not "no Jobs session": creating one then could
  # make a second.
  out=$("$rex" --autostart=false --timeout 5s ls --json 2>/dev/null) || return 1
  sid=$(print -r -- "$out" | jq -r \
    'first(.sessions[]? | select(.label == "Jobs") | .session_id) // empty' \
    2>/dev/null) || sid=""
  if [ -z "$sid" ]; then
    out=$("$rex" --autostart=false --timeout 5s new Jobs --window "$label" \
      --json -- "$cli" follow "$id" 2>/dev/null) || return 1
    sid=$(print -r -- "$out" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
  else
    "$rex" --autostart=false --timeout 5s window new -s Jobs "$label" \
      --focus=false --json -- "$cli" follow "$id" >/dev/null 2>&1 || return 1
  fi
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

# job::_rex_schedule_tab <id> — return at once; in the background, after
# JOB_FOLLOW_DELAY seconds, open the job's tab if the job still has no
# result and a Rex server answers. A job over sooner never gets a tab (a
# clipboard restore starts one on every restore). Nothing for --notify none.
# The background step holds none of the caller's descriptors, so a caller
# reading job::start's output through $(…) does not wait for the delay.
job::_rex_schedule_tab() {
  local id="${1:?job::_rex_schedule_tab: id required}"
  local dir="$JOB_STATE_ROOT/$1" delay="${JOB_FOLLOW_DELAY:-2}" notify
  notify=$(jq -r '.notify // "all"' "$dir/meta.json" 2>/dev/null) || notify="all"
  [ "$notify" = "none" ] && return 0
  (
    sleep "$delay"
    [ -d "$dir" ] && [ ! -s "$dir/result" ] || exit 0
    job::_rex_available || exit 0
    job::_rex_open_tab "$id"
  ) < /dev/null > /dev/null 2>&1 &!
  return 0
}
