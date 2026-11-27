# job/follow.zsh — format a job's state as a Rex status report (OSC 7501,
# the Program Status Protocol). SOURCED by job.zsh, after JOB_STATE_ROOT is
# defaulted. Pure formatting: the follower loop that calls these lives
# elsewhere.

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
