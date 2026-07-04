# backup-tm.zsh — tm scrub sessions (spec 2026-07-04): file-based session
# state driving a timeline pane + a lens pane (yazi explore / hunk diff)
# over one session-long restic mount. Sourced by system-backup-tm and the
# browse verb; sources backup.zsh itself.

_bkp_tm_self="${(%):-%x}"
source "$(dirname "$_bkp_tm_self")/backup.zsh"
unset _bkp_tm_self

: ${BKP_TM_SESSIONS:="${BKP_STATE_DIR:-$HOME/.local/state/terminal-backup}/sessions"}

# bkp::tm::session_new <lens> <anchor>
# Create session state; prints the session dir. Ladder rows carry the tier
# label so the timeline renders without re-deriving policy per frame.
bkp::tm::session_new() {
  local lens="$1" anchor="$2"
  local s ladder policy line id epoch REPLY now="$EPOCHSECONDS"
  mkdir -p "$BKP_TM_SESSIONS"
  s=$(mktemp -d "$BKP_TM_SESSIONS/s.XXXXXX") || return 1
  ladder=$(bkp::snap::ladder) || return 2
  [[ -n "$ladder" ]] || { log_error "bkp: no snapshots yet — nothing to scrub"; return 2 }
  policy=$(bkp::manifest::thin_policy "$BKP_MANIFEST") || return 2
  {
    for line in ${(f)ladder}; do
      id="${line%%$'\t'*}" epoch="${line##*$'\t'}"
      bkp::thin::tier_of "$now" "$epoch" "$policy" || :
      print -r -- "$id"$'\t'"$epoch"$'\t'"$REPLY"
    done
  } > "$s/ladder"
  print -r -- "$lens" > "$s/lens"
  print -r -- "$anchor" > "$s/anchor"
  print -r -- 1 > "$s/rung"
  print -r -- "$s"
}

# bkp::tm::rung_line <session> — REPLY = current ladder line (id\tepoch\ttier).
bkp::tm::rung_line() {
  local s="$1" n
  n=$(<"$s/rung")
  local -a lines=("${(@f)$(<"$s/ladder")}")
  (( n >= 1 && n <= ${#lines} )) || return 1
  REPLY="${lines[n]}"
}

# bkp::tm::rung_id <session> — REPLY = full id of the current rung.
bkp::tm::rung_id() {
  bkp::tm::rung_line "$1" || return 1
  REPLY="${REPLY%%$'\t'*}"
}

# bkp::tm::mount_root <session> — the session mountpoint path.
bkp::tm::mount_root() { print -r -- "$1/mnt" }

# bkp::tm::rung_path <session>
# REPLY = mount path of the current rung (restic mount's default ids/
# layout uses SHORT ids).
bkp::tm::rung_path() {
  local s="$1"
  bkp::tm::rung_id "$s" || return 1
  REPLY="$s/mnt/ids/${REPLY[1,8]}"
}

# bkp::tm::refresh <session>
# Point the lens at the current rung: rewrite current.patch (diff lens —
# hunk --watch reloads) or DDS-cd yazi (explore lens; a failed emit flags
# a respawn for the lens loop).
bkp::tm::refresh() {
  local s="$1" lens anchor REPLY
  lens=$(<"$s/lens") anchor=$(<"$s/anchor")
  bkp::tm::rung_path "$s" || return 1
  local rung="$REPLY"
  if [[ "$lens" == diff ]]; then
    bkp::changeset::patch_live "$rung" "$anchor" > "$s/current.patch.new" || return 1
    mv "$s/current.patch.new" "$s/current.patch"
  else
    [[ -f "$s/yazi.id" ]] || return 0   # yazi not up yet
    local yid
    yid=$(<"$s/yazi.id")
    ya emit-to "$yid" cd "$rung$anchor" 2>/dev/null || touch "$s/respawn"
  fi
  return 0
}

# bkp::tm::step <session> older|newer
# Move the rung (Down/J = older, Up/K = newer), clamped; refresh the lens.
bkp::tm::step() {
  local s="$1" dir="$2" n total
  n=$(<"$s/rung")
  total=$(wc -l < "$s/ladder")
  case "$dir" in
    older) (( n < total )) && (( n++ )) ;;
    newer) (( n > 1 )) && (( n-- )) ;;
    *) return 2 ;;
  esac
  print -r -- "$n" > "$s/rung"
  bkp::tm::refresh "$s"
}

# bkp::tm::end <session> — signal every session process to wind down.
bkp::tm::end() { touch "$1/closed" }
