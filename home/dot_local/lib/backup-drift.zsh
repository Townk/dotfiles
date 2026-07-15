#!/usr/bin/env zsh
# backup-drift.zsh — the backup freshness heartbeat + the prompt banner that
# reads it. SOURCED, never executed. Deliberately standalone (no backup.zsh):
# the interactive prompt sources ONLY this, so the drift check on every
# command stays a single small-file read — no restic, no locks, no forks.
#
# The workers (via backup.zsh) call bkp::drift::stamp on each successful
# phase; the prompt calls bkp::drift::banner. A capture that FAILS never
# stamps, so its heartbeat ages and the banner fires on staleness — the
# outage surfaces either way.
#
# When a scheduled/wake catch-up starts while capture is already overdue, the
# worker stamps a short-lived `catchup` phase so the banner stays quiet for
# the duration of that run (age nag only — a failed last stamp still warns).

zmodload -F zsh/datetime +b:strftime 2>/dev/null
zmodload zsh/datetime 2>/dev/null   # EPOCHSECONDS

# Where the heartbeat lives (mirrors backup.zsh's BKP_STATE_DIR default).
: ${BKP_DRIFT_STATE:=${BKP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/terminal-backup}}
# The scheduled capture cadence in seconds (services.toml backup-capture
# half-hourly calendar slots). The banner warns past 2× this; keep in sync.
: ${BKP_CAPTURE_CADENCE:=1800}
# How long a `catchup` stamp silences age-based banner nagging. Mirrors the
# capture wall-clock ceiling so a wedged run can't hide forever.
: ${BKP_CATCHUP_GRACE:=${BKP_CAPTURE_TIMEOUT:-300}}

# bkp::drift::_age <seconds> — compact human age in REPLY: 12m / 4h / 3d.
bkp::drift::_age() {
  local s=$1
  (( s < 0 )) && s=0
  if   (( s < 3600 ));  then REPLY="$(( s / 60 ))m"
  elif (( s < 86400 )); then REPLY="$(( s / 3600 ))h"
  else                       REPLY="$(( s / 86400 ))d"
  fi
}

# bkp::drift::stamp <phase> [<rc>] — record that <phase> finished now.
# One space-separated line per phase in $BKP_DRIFT_STATE/heartbeat
# ("capture <epoch> <rc>"), rewritten atomically via tmp+mv. Best-effort:
# a stamp that can't be written must never fail a backup, so it returns 0.
bkp::drift::stamp() {
  local phase="$1" rc="${2:-0}" f="$BKP_DRIFT_STATE/heartbeat" tmp
  [[ -n "$phase" ]] || return 0
  mkdir -p "$BKP_DRIFT_STATE" 2>/dev/null || return 0
  tmp=$(mktemp "$BKP_DRIFT_STATE/.hb.XXXXXX" 2>/dev/null) || return 0
  {
    [[ -f "$f" ]] && grep -v "^$phase " "$f"
    print -r -- "$phase $EPOCHSECONDS $rc"
  } > "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# bkp::drift::clear <phase> — drop <phase> from the heartbeat (best-effort).
bkp::drift::clear() {
  local phase="$1" f="$BKP_DRIFT_STATE/heartbeat" tmp
  [[ -n "$phase" && -f "$f" ]] || return 0
  tmp=$(mktemp "$BKP_DRIFT_STATE/.hb.XXXXXX" 2>/dev/null) || return 0
  grep -v "^$phase " "$f" > "$tmp" 2>/dev/null || :
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# bkp::drift::last <phase> — echo "<epoch> <rc>" for the recorded <phase>
# stamp, or return nonzero if the heartbeat is missing or lacks that phase.
# Cheap single-file read (no restic), so `status` can show freshness without
# touching a repo.
bkp::drift::last() {
  local f="$BKP_DRIFT_STATE/heartbeat" ph e r
  [[ -r "$f" ]] || return 1
  while IFS=' ' read -r ph e r; do
    [[ "$ph" == "$1" ]] || continue
    [[ "$e" == <-> ]] || return 1
    print -r -- "$e ${r:-0}"
    return 0
  done < "$f"
  return 1
}

# bkp::drift::assess <now> <epoch> <rc> <cadence> [<catchup_epoch> [<grace>]]
# PURE drift verdict. Prints "<level>\t<message>" (level = warn|crit) when the
# last capture is overdue or failed; prints nothing (rc 0) when healthy.
# Optional catchup_epoch/grace: age-based nagging is suppressed while a
# catch-up stamp is still inside the grace window (failed rc still warns).
bkp::drift::assess() {
  local now="$1" epoch="$2" rc="${3:-0}" cadence="${4:-1800}"
  local catchup="${5:-0}" grace="${6:-${BKP_CATCHUP_GRACE:-300}}" REPLY
  local age=$(( now - epoch ))
  (( age < 0 )) && age=0
  local level=""
  if   (( rc != 0 ));          then level=crit
  elif (( age >= 86400 ));     then level=crit
  elif (( age >= cadence*2 )); then level=warn
  else return 0
  fi
  # Catch-up in progress: silence age nags only (rc != 0 still surfaces).
  if (( rc == 0 && catchup > 0 )); then
    local cup_age=$(( now - catchup ))
    (( cup_age < 0 )) && cup_age=0
    (( cup_age < grace )) && return 0
  fi
  bkp::drift::_age $age
  local age_h="$REPLY" cad_h
  if   (( cadence < 3600 ));  then cad_h="$(( cadence / 60 ))m"
  elif (( cadence < 86400 )); then cad_h="$(( cadence / 3600 ))h"
  else                            cad_h="$(( cadence / 86400 ))d"
  fi
  local msg
  if (( rc != 0 )); then
    msg="backup: last capture failed ($age_h ago)"
  else
    msg="backup: last capture $age_h ago (expected every $cad_h)"
  fi
  print -r -- "$level"$'\t'"$msg"
}

# bkp::drift::banner — the precmd hook. Reads the capture heartbeat and, only
# when drifting, prints one themed line above the prompt. Silent (and cheap)
# in the healthy case, and silent on a machine that has never captured (no
# heartbeat) so a fresh/unconfigured host is never nagged. Also silent while
# a recent `catchup` stamp says a wake/boot catch-up is already running.
bkp::drift::banner() {
  local f="$BKP_DRIFT_STATE/heartbeat"
  [[ -r "$f" ]] || return 0
  local ph e r epoch=0 rc=0 catchup=0
  while IFS=' ' read -r ph e r; do
    case "$ph" in
      capture) epoch="$e"; rc="${r:-0}" ;;
      catchup) catchup="$e" ;;
    esac
  done < "$f"
  [[ "$epoch" == <-> && "$epoch" -gt 0 ]] || return 0
  local out
  out=$(bkp::drift::assess "$EPOCHSECONDS" "$epoch" "$rc" "$BKP_CAPTURE_CADENCE" \
    "$catchup" "$BKP_CATCHUP_GRACE") || return 0
  [[ -n "$out" ]] || return 0
  local level="${out%%$'\t'*}" msg="${out#*$'\t'}"
  # Palette vars (C_HEX_*) are exported into interactive shells; named
  # fallbacks keep the banner readable if the prompt runs before they load.
  local color="${C_HEX_YELLOW:-yellow}"
  [[ "$level" == crit ]] && color="${C_HEX_RED:-red}"
  print -P -- "%F{$color}⚠ ${msg}%f"
}
