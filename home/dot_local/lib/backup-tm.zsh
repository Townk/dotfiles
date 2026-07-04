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

# bkp::tm::timeline_render <session> <height>
# One timeline frame (spec §5.1 mock): newest at top, ● rungs joined by ┃,
# relative ages < 48h, absolute two-line stamps beyond, current rung
# highlighted with its tier label, windowed to <height> rows with … rows
# when clipped. Colors come from common.zsh C_* (empty when not a tty).
bkp::tm::timeline_render() {
  local s="$1" height="$2"
  local -a ladder=("${(@f)$(<"$s/ladder")}")
  local cur n=${#ladder}
  cur=$(<"$s/rung")
  local now="$EPOCHSECONDS"

  # Build per-rung row groups first, then window by rows.
  local -a rows=()          # rendered text rows
  local -a row_rung=()      # owning rung index per row (0 = connector)
  local i id epoch tier age label label2 REPLY
  for (( i = 1; i <= n; i++ )); do
    id="${ladder[i]%%$'\t'*}"
    epoch="${${ladder[i]#*$'\t'}%%$'\t'*}"
    tier="${ladder[i]##*$'\t'}"
    if (( now - epoch < 172800 )); then
      bkp::ux::age $(( now - epoch ))
      label="● $REPLY ago"
      label2=""
    else
      strftime -s label '● %a, %b %e %Y' "$epoch"
      strftime -s label2 '%I:%M %p' "$epoch"
      label2="┃ ${(L)label2}"
    fi
    if (( i == cur )); then
      rows+=("${C_BWH}${label}${C_RES} ${C_BBL}${tier}${C_RES}")
    else
      rows+=("${C_DIM}${label}${C_RES}")
    fi
    row_rung+=($i)
    if [[ -n "$label2" ]]; then
      rows+=("${C_DIM}${label2}${C_RES}")
      row_rung+=($i)
    fi
    if (( i < n )); then
      rows+=("${C_DIM}┃${C_RES}")
      row_rung+=(0)
    fi
  done

  # Window: locate the current rung's first row, center it.
  local total=${#rows} first=1
  if (( total > height )); then
    local cur_row=1 r
    for (( r = 1; r <= total; r++ )); do
      (( row_rung[r] == cur )) && { cur_row=$r; break }
    done
    first=$(( cur_row - height / 2 ))
    (( first < 1 )) && first=1
    (( first + height - 1 > total )) && first=$(( total - height + 1 ))
  fi
  local last=$(( first + height - 1 ))
  (( last > total )) && last=$total
  local out_row
  for (( out_row = first; out_row <= last; out_row++ )); do
    if (( total > height )) && { (( out_row == first && first > 1 )) ||
                                 (( out_row == last && last < total )) }; then
      print -r -- "${C_DIM}…${C_RES}"
    else
      print -r -- "${rows[out_row]}"
    fi
  done
}

# bkp::tm::yazi_overlay <session>
# YAZI_CONFIG_HOME for explore sessions: the user's config (symlinked)
# plus generated scrub bindings appended as prepend_keymap (prepend wins
# over the base keymap regardless of position in the file).
#   K / J   timeline newer / older (matches the parent-arrow muscle memory)
#   R       restore selection to the live filesystem (gated apply flow)
bkp::tm::yazi_overlay() {
  local s="$1" src="${YAZI_USER_CONFIG:-$HOME/.config/yazi}" ovl="$1/yazi"
  mkdir -p "$ovl"
  local f
  for f in yazi.toml init.lua package.toml plugins flavors; do
    [[ -e "$src/$f" ]] && ln -sfn "$src/$f" "$ovl/$f"
  done
  {
    [[ -f "$src/keymap.toml" ]] && cat "$src/keymap.toml"
    cat <<EOF

# --- tm scrub session bindings (generated; spec 2026-07-04 §5.2/§6) ---
[[mgr.prepend_keymap]]
on = "K"
run = 'shell --orphan "\$HOME/.local/bin/system-backup-tm ctl $s newer"'
desc = "tm: newer snapshot"

[[mgr.prepend_keymap]]
on = "J"
run = 'shell --orphan "\$HOME/.local/bin/system-backup-tm ctl $s older"'
desc = "tm: older snapshot"

[[mgr.prepend_keymap]]
on = "R"
run = 'shell --orphan "\$HOME/.local/bin/system-backup-tm apply $s \"\$@\""'
desc = "tm: restore selection to live filesystem"

[[mgr.prepend_keymap]]
on = "q"
run = [ 'shell --orphan "\$HOME/.local/bin/system-backup-tm ctl $s end"', "quit" ]
desc = "tm: end scrub session"
EOF
  } > "$ovl/keymap.toml"
  print -r -- "$ovl"
}

# bkp::tm::lens_cmd <session>
# The lens pane argv, one element per line (caller reads into an array).
# Explore: yazi under the bx Seatbelt jail scoped to the mount (read-only
# by construction; bx blocks navigating out). Diff: hunk in watch mode.
bkp::tm::lens_cmd() {
  local s="$1" lens anchor REPLY
  lens=$(<"$s/lens") anchor=$(<"$s/anchor")
  if [[ "$lens" == diff ]]; then
    print -rl -- hunk patch "$s/current.patch" --watch
    return 0
  fi
  bkp::tm::rung_path "$s" || return 1
  local rung="$REPLY" ovl yid
  ovl=$(bkp::tm::yazi_overlay "$s") || return 1
  yid=$(<"$s/yazi.id")
  if command -v bx >/dev/null 2>&1; then
    print -rl -- bx "$s/mnt" --
  else
    log_warn "bkp: bx not installed — explore runs unjailed (mount is still read-only)"
  fi
  print -rl -- env "YAZI_CONFIG_HOME=$ovl" yazi --client-id "$yid" "$rung$anchor"
}
