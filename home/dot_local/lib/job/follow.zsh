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
# spaces and the text is cut on a character boundary. Done on bytes
# (nomultibyte), so it needs no tool and no UTF-8 locale: C1 is C2 80-9F in
# UTF-8, and a cut that lands on a continuation byte (80-BF) takes back the
# whole character. iconv, where there is one, then drops bytes that were
# never UTF-8.
job::_follow_msg() {
  setopt localoptions nomultibyte
  local s="$1" c1=$'\xc2' next
  s=${s//[$'\x00'-$'\x1f'$'\x7f']/ }
  s=${s//${c1}[$'\x80'-$'\x9f']/ }
  if (( $#s > 2048 )); then
    next=$s[2049]
    s=$s[1,2048]
    if [[ "$next" == [$'\x80'-$'\xbf'] ]]; then
      while [[ "$s[-1]" == [$'\x80'-$'\xbf'] ]]; do s=$s[1,-2]; done
      s=$s[1,-2]
    fi
  fi
  if command -v iconv >/dev/null 2>&1; then
    print -rn -- "$s" | iconv -c -f UTF-8 -t UTF-8
  else
    print -rn -- "$s"
  fi | base64 | tr -d '\n'
}

# job::_follow_report <id> <queued|running> — print the OSC 7501 body for the
# job's current state, or nothing when no report is due. Always exits 0.
job::_follow_report() {
  local id="$1" phase="${2:-running}"
  local dir="$JOB_STATE_ROOT/$id" title notify
  local epoch res code pct msg
  title=$(jq -r '.title // empty' "$dir/meta.json" 2>/dev/null) || title=""
  notify=$(jq -r '.notify // "all"' "$dir/meta.json" 2>/dev/null) || notify="all"
  [ -n "$title" ] || title=job
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
  if [ -s "$dir/progress" ]; then
    read -r epoch pct msg < "$dir/progress" 2>/dev/null || :
  fi
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
  common::sleep "$(( cs / 100.0 ))" 2>/dev/null || :
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
  local id="$1" inline="${2:-0}" epoch res code notify
  local dir="$JOB_STATE_ROOT/$id"
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
# owner one second on a real close. A block reconcile is closing looks
# exactly like the owner closing it, so a block listed in .rex_closing
# (job::_rex_closing) is never asked about. On a confirmed close a job
# still in flight is cancelled and a failed one is marked dismissed.
# Anything else — rc 4 (server unreachable), rc 0 (block still there), an
# empty, unreadable or different instance id, no rex, no REX_BLOCK —
# leaves the job alone: a server restart must never cancel. An inline
# follower never cancels; its terminal going away moves the job to a tab
# of its own. Outside inline mode the decision is logged (job::_rex_log).
# Always returns 0.
job::_follow_on_hup() {
  local id="$1" inline="${2:-0}" instance="${3:-}"
  local dir="$JOB_STATE_ROOT/$id" rex rc=none match=unasked action=nothing epoch res code
  local -F hup_wait="${JOB_FOLLOW_HUP_WAIT:-1}"
  [ -d "$dir" ] || return 0
  if [ "$inline" = 1 ]; then
    [ -s "$dir/result" ] || job::_rex_open_tab "$id" || :
    return 0
  fi
  if [ -n "${REX_BLOCK:-}" ] && job::_rex_closing "$REX_BLOCK"; then
    job::_rex_log "job $id: hangup of $REX_BLOCK: closed by reconcile: nothing"
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

# job::_follow_hup_decide <id> <inline:0|1> <instance id> — the `job
# hup-decide` verb: job::_follow_on_hup, preceded by a log line, so a
# decision that never completes still leaves a trace. Always returns 0.
job::_follow_hup_decide() {
  job::_rex_log "job ${1:-?}: hangup of ${REX_BLOCK:-no block}: deciding"
  job::_follow_on_hup "$@" || :
  return 0
}

# job::_follow_hup_detach <id> <inline:0|1> <instance id> — start the
# SIGHUP decision where the tab's death cannot reach it, and return at
# once. Rex sends a closed tab's processes SIGHUP and kills them about a
# second later — before the decision's wait is over — so it runs as `job
# hup-decide` in a session of its own (setsid), with the follower's
# environment (REX_BLOCK, the test seams). The state root and the wait are
# handed over by name: the follower's shell may hold them unexported. A
# child that is already a group leader (job control on) cannot setsid
# (POSIX::setsid answers -1): it forks first. Without perl or a runnable
# CLI, the decision runs in-process as before.
job::_follow_hup_detach() {
  local cli="${JOB_CLI:-$HOME/.local/libexec/job}"
  if command -v perl >/dev/null 2>&1 && [ -x "$cli" ]; then
    JOB_STATE_ROOT="$JOB_STATE_ROOT" \
      JOB_FOLLOW_HUP_WAIT="${JOB_FOLLOW_HUP_WAIT:-1}" perl -MPOSIX -e '
      if (POSIX::setsid() == -1) { exit if fork; POSIX::setsid() }
      exec @ARGV or exit 1' "$cli" hup-decide "$@" \
      < /dev/null > /dev/null 2>&1 &!
    return 0
  fi
  job::_follow_on_hup "$@"
}

# job::_follow_stop — kill the log child and remove the follower file if it
# is still this follower's (an inline follower hands its job to a new tab,
# whose follower may already have written its own). Runs in job::follow's
# dynamic scope: it reads and clears that function's `child`, `dir`, `me`
# (`<REX_BLOCK or -> <real pid>`).
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

# job::_follow_tick — one poll: send the job's status report if it differs
# from the last one sent. Runs in job::follow's dynamic scope: it reads
# `id`, `dir`, `pueue`, `task_id` and sets `finished`, `phase`, `body`,
# `last`.
job::_follow_tick() {
  finished=0
  [ -s "$dir/result" ] && finished=1
  phase=running
  (( finished )) || phase=$(job::_follow_phase "$pueue" "$task_id")
  body=$(job::_follow_report "$id" "$phase" 2>/dev/null)
  if [ -n "$body" ] && [ "$body" != "$last" ]; then
    job::_follow_emit "$body"
    last="$body"
  fi
  return 0
}

# job::follow [--inline] <id> — follow a job until its tab should close.
# Writes the `follower` file (`<REX_BLOCK> <pid>`, the block `-` when it is
# not in a Rex pane: an empty first field would read as a file with no pid,
# a follower that looks dead), streams the task's log
# through a `pueue follow` child, and every JOB_FOLLOW_POLL seconds sends a
# status report when it differs from the last one sent. It stops polling
# when the job has a result (or its state dir is gone: exit quietly), then
# ends as job::_follow_end says. Every exit path kills the child and removes
# the follower file. SIGHUP goes to job::_follow_on_hup, started detached
# (job::_follow_hup_detach) with the Rex server instance recorded at start;
# in --inline mode, Ctrl+C detaches instead: the job keeps running in a tab
# of its own.
job::follow() {
  setopt localoptions localtraps
  local inline=0
  if [ "${1:-}" = "--inline" ]; then
    inline=1
    shift
  fi
  local id="${1:?job::follow: id required}"
  local self="${sysparams[pid]:-$$}" dir="$JOB_STATE_ROOT/$id" child=""
  local me="${REX_BLOCK:--} $self"
  local poll="${JOB_FOLLOW_POLL:-1}" ttl="${JOB_FOLLOW_DONE_TTL:-3600}"
  local pueue task_id phase body last="" end REPLY instance="" block pid
  local -i finished n
  local -F deadline
  [ -f "$dir/meta.json" ] || { log_error "job::follow: unknown job $id"; return 1; }

  # One follower per job. A tab's follower never replaces a live one: an
  # inline follower handing its job to this tab exits promptly, so wait up
  # to 3 s for it; one still alive after that keeps the job, and this one
  # leaves before it has a follower file or a hangup trap, so it can never
  # cancel the job. Closing a tab cancels its job on the strength of this
  # rule. An inline follower is not held to it (only job::start runs one,
  # at once, before any tab exists) and never cancels.
  if (( ! inline )); then
    common::now -f
    deadline=$(( REPLY + 3 ))
    while { read -r block pid < "$dir/follower" } 2>/dev/null \
      && [[ "$pid" == <-> ]] && [ "$pid" != "$self" ] \
      && kill -0 "$pid" 2>/dev/null; do
      common::now -f
      if (( REPLY >= deadline )); then
        print -r -- "job $id is already being followed"
        return 0
      fi
      job::_follow_nap "$poll"
    done
  fi

  # TRAPxxx functions, not `trap '…' SIG`: an `exit` in a trap string waits
  # for the running builtin (a zselect nap) to finish, while one in a trap
  # function exits at once. localtraps drops them when this function
  # returns.
  # SIGHUP: the local cleanup here, the decision detached (it waits, and
  # the tab is killed about a second after the hangup).
  # Every $(…) below is a subshell that inherits these traps and, being in
  # the follower's process group, its signals: only the follower acts on
  # one, or a hangup would be decided once per subshell in flight.
  TRAPHUP() {
    [ "${sysparams[pid]:-$$}" = "$self" ] || exit 129
    job::_follow_stop
    job::_follow_hup_detach "$id" "$inline" "$instance"
    exit 129
  }
  TRAPTERM() {
    [ "${sysparams[pid]:-$$}" = "$self" ] || exit 143
    job::_follow_stop
    exit 143
  }
  TRAPINT() {
    [ "${sysparams[pid]:-$$}" = "$self" ] || exit 130
    job::_follow_stop
    if (( inline )); then
      [ -s "$dir/result" ] || job::_rex_open_tab "$id" || :
      exit 0
    fi
    exit 130
  }
  pueue=$(job::_pueue) || pueue=""
  task_id=$(jq -r '.pueue_id // empty' "$dir/meta.json" 2>/dev/null) || task_id=""
  # The first report goes out before the server is asked anything: that
  # answer can take its whole 3 s timeout, and the tab's row should not
  # wait for it.
  job::_follow_tick
  # The server this tab lives under, for job::_follow_on_hup. Inline never
  # cancels, so it does not ask. The follower file comes after it: a tab
  # that is listed as following a job is one whose close can cancel it.
  (( inline )) || instance=$(job::_follow_instance)
  print -r -- "$me" > "$dir/.follower.$self" \
    && mv -f -- "$dir/.follower.$self" "$dir/follower" || :

  if [ -n "$pueue" ] && [[ "$task_id" == <-> ]]; then
    "$pueue" follow "$task_id" &
    child=$!
  fi

  while :; do
    [ -d "$dir" ] || { job::_follow_stop; return 0; }
    job::_follow_tick
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
