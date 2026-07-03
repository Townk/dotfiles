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
