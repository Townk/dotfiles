# backup.zsh — bkp:: module: the system-backup (Terminal Time Machine) silo.
# This file is intended to be sourced; it does not run on its own.
#
# Phase 1 ships the thinning engine (bkp::thin), the pure retention planner
# from the design spec §5. Later phases add manifest resolution, capture,
# and reconcile helpers.

# Logging and the shared stdlib come from the shared base. Source it relative
# to THIS file so it resolves both at ~/.local/lib (production) and at the
# repo path (the ShellSpec suite sources us directly).
_bkp_self="${(%):-%x}"
source "$(dirname "$_bkp_self")/common.zsh"
unset _bkp_self

zmodload zsh/datetime

# Default retention ladder (spec §5). One tier per line:
#   <grid> <min_age_seconds> <max_age_seconds|->
# A snapshot belongs to the first tier whose half-open band [min, max)
# contains its age; `-` means unbounded. The published per-tier counts
# (48/24/4/2/7/8/12) are emergent — band width divided by grid interval —
# not enforced explicitly.
BKP_THIN_DEFAULT_POLICY='
  30m    0         86400
  1h     86400     172800
  6h     172800    259200
  12h    259200    345600
  day    345600    950400
  week   950400    5788800
  month  5788800   37324800
  year   37324800  -
'

# bkp::thin::cell <grid> <epoch>
# The wall-clock grid cell containing <epoch>, in LOCAL time (TZ-sensitive by
# design: "the 06:00 snapshot" means 06:00 on the user's wall clock). Sets
# REPLY to a cell id unique within the grid; ids from different grids may
# collide, so callers must namespace by tier. Weekly cells are ISO weeks
# (%G%V), which anchors them on Monday.
bkp::thin::cell() {
  local grid="$1" epoch="$2" stamp
  strftime -s stamp '%Y %m %d %H %M %G %V' "$epoch"
  local -a f=(${(z)stamp})
  local Y="$f[1]" m="$f[2]" d="$f[3]" H="$f[4]" M="$f[5]" G="$f[6]" V="$f[7]"
  case "$grid" in
    30m)   REPLY="$Y$m$d$H.$(( 10#$M / 30 ))" ;;
    1h)    REPLY="$Y$m$d$H" ;;
    6h)    REPLY="$Y$m$d.$(( 10#$H / 6 ))" ;;
    12h)   REPLY="$Y$m$d.$(( 10#$H / 12 ))" ;;
    day)   REPLY="$Y$m$d" ;;
    week)  REPLY="$G$V" ;;
    month) REPLY="$Y$m" ;;
    year)  REPLY="$Y" ;;
    *)
      log_error "bkp::thin::cell: unknown grid '$grid'"
      return 2
      ;;
  esac
}

# bkp::thin <now_epoch> [<policy>]
# The retention planner (spec §5). Pure: no restic, no clock reads, no
# filesystem — fully driven by its arguments and stdin.
#
#   stdin:  one snapshot per line:  <id><TAB><unix_epoch>
#   stdout: one line per snapshot:  keep<TAB><id>  |  drop<TAB><id>
#           (input order preserved)
#   policy: BKP_THIN_DEFAULT_POLICY format; defaults to the §5 ladder.
#
# Every snapshot is assigned the first tier whose age band contains it, then
# quantized to that tier's wall-clock grid cell; the newest snapshot in each
# (tier, cell) survives, and the newest snapshot overall always survives
# (keep_last=1). Deterministic and idempotent for a fixed <now>: re-running
# on its own keep-set changes nothing.
bkp::thin() {
  local now="${1:-}" policy="${2:-$BKP_THIN_DEFAULT_POLICY}"
  [[ "$now" == <-> ]] || {
    log_error "bkp::thin: <now> must be a unix epoch, got '$now'"
    return 2
  }

  # Parse the policy table. ${(z)} tokenization (not pattern-trimming, which
  # would need extendedglob) handles indentation and blank lines.
  local -a t_grid=() t_min=() t_max=()
  local line
  local -a f
  while IFS= read -r line; do
    f=(${(z)line})
    (( ${#f} )) || continue
    [[ "$f[1]" == '#'* ]] && continue
    if (( ${#f} != 3 )) || [[ "$f[2]" != <-> ]] ||
      [[ "$f[3]" != <-> && "$f[3]" != - ]]; then
      log_error "bkp::thin: bad policy line: '$line'"
      return 2
    fi
    t_grid+=("$f[1]") t_min+=("$f[2]") t_max+=("$f[3]")
  done <<<"$policy"
  (( ${#t_grid} )) || {
    log_error "bkp::thin: empty policy"
    return 2
  }

  # Read the snapshot list.
  local -a s_id=() s_epoch=()
  local id epoch
  while IFS=$'\t' read -r id epoch; do
    [[ -z "$id$epoch" ]] && continue
    if [[ -z "$id" || "$epoch" != <-> ]]; then
      log_error "bkp::thin: bad snapshot line (want <id><TAB><epoch>): '$id'"
      return 2
    fi
    s_id+=("$id") s_epoch+=("$epoch")
  done
  (( ${#s_id} )) || return 0

  # keep_last=1 — the newest snapshot always survives.
  local i newest=1
  for (( i = 2; i <= ${#s_id}; i++ )); do
    (( s_epoch[i] > s_epoch[newest] )) && newest=$i
  done

  # Newest snapshot per (tier, wall-clock cell).
  local -A best=()   # "tier:cell" -> index of the newest snapshot in that cell
  local age t key REPLY
  for (( i = 1; i <= ${#s_id}; i++ )); do
    age=$(( now - s_epoch[i] ))
    (( age < 0 )) && age=0   # clock skew: a future snapshot is "brand new"
    for (( t = 1; t <= ${#t_grid}; t++ )); do
      (( age >= t_min[t] )) || continue
      [[ "$t_max[t]" == - ]] || (( age < t_max[t] )) || continue
      break
    done
    (( t <= ${#t_grid} )) || {
      log_error "bkp::thin: no tier covers age ${age}s — policy must be exhaustive"
      return 2
    }
    bkp::thin::cell "$t_grid[t]" "$s_epoch[i]" || return 2
    key="$t:$REPLY"
    if [[ -z "${best[$key]:-}" ]] || (( s_epoch[i] > s_epoch[best[$key]] )); then
      best[$key]=$i
    fi
  done

  local -A keep=()
  keep[$newest]=1
  for key in ${(k)best}; do
    keep[$best[$key]]=1
  done

  for (( i = 1; i <= ${#s_id}; i++ )); do
    if (( ${keep[$i]:-0} )); then
      print -r -- "keep"$'\t'"$s_id[i]"
    else
      print -r -- "drop"$'\t'"$s_id[i]"
    fi
  done
}
