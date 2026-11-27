# job/follow.zsh — the follower: the process that runs in a job's Rex tab.
# It shows the job's log, reports the job's state to the terminal as OSC 7501
# (the Program Status Protocol), decides when the tab should close, and
# cancels the job when the tab's owner closes it. SOURCED by job.zsh, after
# JOB_STATE_ROOT is defaulted.

zmodload zsh/zselect 2>/dev/null
# $sysparams[pid]: the follower's real pid. An inline follower runs in a
# ( … ) subshell, where $$ is still the calling shell's.
zmodload zsh/system 2>/dev/null

# job::_follow_msg <text> — sanitize and base64 a report message. Rex rejects
# a msg that decodes to control characters (C0, DEL and the C1 range
# U+0080-U+009F) or more than 2,048 bytes, so control characters become
# spaces and the text is cut on a character boundary (iconv -c drops the
# partial character a byte cut can leave).
job::_follow_msg() {
  print -rn -- "$1" | perl -CS -0777 -pe 's/[\x00-\x1f\x7f-\x9f]/ /g' \
    | head -c 2048 | iconv -c -f UTF-8 -t UTF-8 | base64 | tr -d '\n'
}

# job::_follow_report <id> <queued|running> — print the OSC 7501 body for the
# job's current state, or nothing when no report is due. Always exits 0.
job::_follow_report() {
  local id="$1" phase="${2:-running}"
  local dir="$JOB_STATE_ROOT/$id" title notify
  local epoch res code pct msg
  title=$(jq -r '.title // empty' "$dir/meta.json" 2>/dev/null) || title=""
  notify=$(jq -r '.notify // "all"' "$dir/meta.json" 2>/dev/null) || notify="all"
  local head="app=job"

  if [ -s "$dir/result" ]; then
    read -r epoch res code < "$dir/result" 2>/dev/null || :
    case "$res" in
      Success)
        [ "$notify" = "failures" ] && return 0
        print -r -- "state=done:$head:msg=$(job::_follow_msg "$title completed")"
        ;;
      Killed) ;;
      *)
        if [ -n "$code" ]; then
          msg="$title failed (exit $code)"
        else
          msg="$title failed"
        fi
        print -r -- "state=error:$head:msg=$(job::_follow_msg "$msg")"
        ;;
    esac
    return 0
  fi

  if [ "$phase" = "queued" ]; then
    print -r -- "state=working:$head:msg=$(job::_follow_msg queued)"
    return 0
  fi

  pct=""; msg=""
  [ -s "$dir/progress" ] && read -r epoch pct msg < "$dir/progress" 2>/dev/null
  [ -n "$msg" ] || msg="$title"
  if [ "$(cat "$dir/phase" 2>/dev/null)" = "waiting" ]; then
    msg="waiting: $msg"
  elif [[ "$pct" == <-> ]]; then
    print -r -- "state=working:$head:progress=$pct:msg=$(job::_follow_msg "$msg")"
    return 0
  fi
  print -r -- "state=working:$head:msg=$(job::_follow_msg "$msg")"
  return 0
}

# job::_follow_emit <body> — write the report as one OSC 7501 sequence.
job::_follow_emit() {
  print -rn -- $'\e]7501;'"$1"$'\e\\'
}

# job::_follow_nap <seconds> — sleep without a child process, so a trapped
# signal (the tab closing) runs its trap at once instead of after a `sleep`
# finishes. Fractional seconds are fine; an early wake-up is harmless, since
# every caller loops.
job::_follow_nap() {
  local -i cs=$(( ${1:-1} * 100 ))
  (( cs > 0 )) || cs=1
  if zmodload -e zsh/zselect; then
    zselect -t "$cs" 2>/dev/null || :
  else
    sleep "${1:-1}" 2>/dev/null || :
  fi
  return 0
}

# job::_follow_phase <pueue> <task id> — print `queued` while pueue holds the
# task back (Queued or Stashed), else `running`. An unreadable status counts
# as running.
job::_follow_phase() {
  local state=""
  if [ -n "$1" ] && [[ "$2" == <-> ]]; then
    state=$("$1" status --json 2>/dev/null \
      | jq -r --arg t "$2" '.tasks[$t].status // {} | keys[0] // empty' 2>/dev/null) \
      || state=""
  fi
  case "$state" in
    Queued | Stashed) print -r -- queued ;;
    *) print -r -- running ;;
  esac
}

# job::_follow_end <id> <inline:0|1> — how the follower ends once the job has
# a result: `key` (success: wait for a key or the TTL), `stay` (failure: keep
# the tab until its owner closes it) or `exit`. An inline follower always
# exits: it runs in the user's own terminal, not in a Jobs tab.
job::_follow_end() {
  local id="$1" inline="${2:-0}" dir="$JOB_STATE_ROOT/$1" epoch res code notify
  if [ "$inline" = 1 ]; then
    print -r -- exit
    return 0
  fi
  { read -r epoch res code < "$dir/result" } 2>/dev/null || :
  case "$res" in
    Killed) print -r -- exit ;;
    Success)
      notify=$(jq -r '.notify // "all"' "$dir/meta.json" 2>/dev/null) || notify="all"
      if [ "$notify" = "failures" ]; then
        print -r -- exit
      else
        print -r -- key
      fi
      ;;
    *) print -r -- stay ;;
  esac
}

# job::_follow_instance — print the running Rex server's instance id (it
# changes on every server start), or nothing when there is no answer.
job::_follow_instance() {
  local rex
  rex=$(job::_rex) || return 0
  "$rex" --autostart=false --timeout 3s whoami --json 2>/dev/null \
    | jq -r '.instance_id // empty' 2>/dev/null || :
  return 0
}

# job::_follow_on_hup <id> <inline:0|1> <instance id> — the SIGHUP decision.
# A Jobs tab's follower gets SIGHUP both when the owner closes the tab and
# when the Rex server stops or restarts, so it asks the server about its own
# block: rc 3 ("block target … not found") means the tab was closed — but
# only if the server answering is the one the follower started under (the
# recorded instance id). A restarted server gives restored blocks new ids,
# so it answers rc 3 for the old one too; the Rex app restarts its server
# on its own, so that answer can come back fast. The instance is asked
# AFTER the block, so a restart between the two questions shows as a
# mismatch. Before asking it waits JOB_FOLLOW_HUP_WAIT seconds (default
# 1): a stopping server can hang up its tabs while it still answers, rc 3
# from the same instance; after the wait it is gone (rc 4). That costs the
# owner one second on a real close. On a confirmed close a job still in flight is cancelled and a
# failed one is marked dismissed. Anything else — rc 4 (server
# unreachable), rc 0 (block still there), an empty, unreadable or different
# instance id, no rex, no REX_BLOCK — leaves the job alone: a server restart
# must never cancel. An inline follower never cancels; its terminal going
# away moves the job to a tab of its own. Outside inline mode the decision
# is logged (job::_rex_log). Always returns 0.
job::_follow_on_hup() {
  local id="$1" inline="${2:-0}" instance="${3:-}" dir="$JOB_STATE_ROOT/$1"
  local rex rc=none match=unasked action=nothing epoch res code
  local -F hup_wait="${JOB_FOLLOW_HUP_WAIT:-1}"
  [ -d "$dir" ] || return 0
  if [ "$inline" = 1 ]; then
    [ -s "$dir/result" ] || job::_rex_open_tab "$id" || :
    return 0
  fi
  if [ -n "${REX_BLOCK:-}" ] && rex=$(job::_rex); then
    (( hup_wait > 0 )) && job::_follow_nap "$hup_wait"
    rc=0
    "$rex" --autostart=false --timeout 3s block inspect "$REX_BLOCK" \
      >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" = 3 ]; then
    if [ -z "$instance" ]; then
      match=unrecorded
    elif [ "$(job::_follow_instance)" = "$instance" ]; then
      match=same
    else
      match=different
    fi
  fi
  if [ "$match" = same ]; then
    if [ ! -s "$dir/result" ]; then
      action=cancelled
      job::cancel "$id" >/dev/null 2>&1 || action="cancel failed"
    else
      { read -r epoch res code < "$dir/result" } 2>/dev/null || :
      case "$res" in
        Success | Killed) ;;
        *)
          action=dismissed
          touch -- "$dir/dismissed" 2>/dev/null || action="dismiss failed"
          ;;
      esac
    fi
  fi
  job::_rex_log "job $id: hangup of ${REX_BLOCK:-no block}:" \
    "inspect rc=$rc, instance $match: $action"
  return 0
}

# job::_follow_stop — kill the log child and remove the follower file if it
# is still this follower's (an inline follower hands its job to a new tab,
# whose follower may already have written its own). Runs in job::follow's
# dynamic scope: it reads and clears that function's `child`, `dir`, `me`
# (`<REX_BLOCK> <real pid>`).
job::_follow_stop() {
  if [ -n "${child:-}" ]; then
    kill "$child" 2>/dev/null || :
    wait "$child" 2>/dev/null || :
    child=""
  fi
  if [ "$(cat "$dir/follower" 2>/dev/null)" = "$me" ]; then
    rm -f -- "$dir/follower" 2>/dev/null || :
  fi
  return 0
}

# job::follow [--inline] <id> — follow a job until its tab should close.
# Writes the `follower` file (`<REX_BLOCK> <pid>`), streams the task's log
# through a `pueue follow` child, and every JOB_FOLLOW_POLL seconds sends a
# status report when it differs from the last one sent. It stops polling
# when the job has a result (or its state dir is gone: exit quietly), then
# ends as job::_follow_end says. Every exit path kills the child and removes
# the follower file. SIGHUP goes to job::_follow_on_hup, with the Rex server
# instance recorded at start; in --inline mode, Ctrl+C detaches instead: the
# job keeps running in a tab of its own.
job::follow() {
  setopt localoptions localtraps
  local inline=0
  if [ "${1:-}" = "--inline" ]; then
    inline=1
    shift
  fi
  local id="${1:?job::follow: id required}"
  local self="${sysparams[pid]:-$$}" dir="$JOB_STATE_ROOT/$id" child=""
  local me="${REX_BLOCK:-} $self"
  local poll="${JOB_FOLLOW_POLL:-1}" ttl="${JOB_FOLLOW_DONE_TTL:-3600}"
  local pueue task_id phase body last="" end REPLY instance=""
  local -i finished n
  [ -f "$dir/meta.json" ] || { log_error "job::follow: unknown job $id"; return 1; }

  # TRAPxxx functions, not `trap '…' SIG`: an `exit` in a trap string waits
  # for the running builtin (a zselect nap) to finish, while one in a trap
  # function exits at once. localtraps drops them when this function
  # returns.
  TRAPHUP() {
    job::_follow_stop
    job::_follow_on_hup "$id" "$inline" "$instance"
    exit 129
  }
  TRAPTERM() {
    job::_follow_stop
    exit 143
  }
  TRAPINT() {
    job::_follow_stop
    if (( inline )); then
      [ -s "$dir/result" ] || job::_rex_open_tab "$id" || :
      exit 0
    fi
    exit 130
  }
  print -r -- "$me" > "$dir/.follower.$self" \
    && mv -f -- "$dir/.follower.$self" "$dir/follower" || :
  # The server this tab lives under, for job::_follow_on_hup. Inline never
  # cancels, so it does not ask.
  (( inline )) || instance=$(job::_follow_instance)

  pueue=$(job::_pueue) || pueue=""
  task_id=$(jq -r '.pueue_id // empty' "$dir/meta.json" 2>/dev/null) || task_id=""
  if [ -n "$pueue" ] && [[ "$task_id" == <-> ]]; then
    "$pueue" follow "$task_id" &
    child=$!
  fi

  while :; do
    [ -d "$dir" ] || { job::_follow_stop; return 0; }
    finished=0
    [ -s "$dir/result" ] && finished=1
    phase=running
    (( finished )) || phase=$(job::_follow_phase "$pueue" "$task_id")
    body=$(job::_follow_report "$id" "$phase" 2>/dev/null)
    if [ -n "$body" ] && [ "$body" != "$last" ]; then
      job::_follow_emit "$body"
      last="$body"
    fi
    (( finished )) && break
    job::_follow_nap "$poll"
  done

  end=$(job::_follow_end "$id" "$inline")
  case "$end" in
    key)
      print -r -- "done — press any key to close"
      # A closed or non-tty stdin (EOF) returns at once instead of spinning.
      if [[ -t 0 ]]; then
        read -sk1 -t "$ttl" 2>/dev/null || :
      else
        read -k1 -u0 -t "$ttl" 2>/dev/null || :
      fi
      ;;
    stay)
      # Until signalled — or until the job's state dir is pruned.
      while [ -d "$dir" ]; do job::_follow_nap "$poll"; done
      ;;
    *)
      # Let the child print the task's last lines: `pueue follow` ends on
      # its own once the task is done. Bounded at one second.
      n=0
      while [ -n "$child" ] && kill -0 "$child" 2>/dev/null && (( n++ < 10 )); do
        job::_follow_nap 0.1
      done
      ;;
  esac
  job::_follow_stop
  return 0
}
