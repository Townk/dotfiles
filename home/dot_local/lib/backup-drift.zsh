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

zmodload -F zsh/datetime +b:strftime 2>/dev/null
zmodload zsh/datetime 2>/dev/null   # EPOCHSECONDS

# Where the heartbeat lives (mirrors backup.zsh's BKP_STATE_DIR default).
: ${BKP_DRIFT_STATE:=${BKP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/terminal-backup}}
# The scheduled capture cadence in seconds (services.toml backup-capture
# start_interval). The banner warns past 2× this; keep the two in sync.
: ${BKP_CAPTURE_CADENCE:=1800}

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

# bkp::drift::assess <now> <epoch> <rc> <cadence> — PURE drift verdict.
# Prints "<level>\t<message>" (level = warn|crit) when the last capture is
# overdue or failed; prints nothing (rc 0) when healthy. Testable with a
# fake clock.
bkp::drift::assess() {
  local now="$1" epoch="$2" rc="${3:-0}" cadence="${4:-1800}" REPLY
  local age=$(( now - epoch ))
  (( age < 0 )) && age=0
  local level=""
  if   (( rc != 0 ));          then level=crit
  elif (( age >= 86400 ));     then level=crit
  elif (( age >= cadence*2 )); then level=warn
  else return 0
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
# heartbeat) so a fresh/unconfigured host is never nagged.
bkp::drift::banner() {
  local f="$BKP_DRIFT_STATE/heartbeat"
  [[ -r "$f" ]] || return 0
  local ph e r epoch=0 rc=0
  while IFS=' ' read -r ph e r; do
    [[ "$ph" == capture ]] || continue
    epoch="$e"; rc="${r:-0}"; break
  done < "$f"
  [[ "$epoch" == <-> && "$epoch" -gt 0 ]] || return 0
  local out
  out=$(bkp::drift::assess "$EPOCHSECONDS" "$epoch" "$rc" "$BKP_CAPTURE_CADENCE") || return 0
  [[ -n "$out" ]] || return 0
  local level="${out%%$'\t'*}" msg="${out#*$'\t'}"
  # Palette vars (C_HEX_*) are exported into interactive shells; named
  # fallbacks keep the banner readable if the prompt runs before they load.
  local color="${C_HEX_YELLOW:-yellow}"
  [[ "$level" == crit ]] && color="${C_HEX_RED:-red}"
  print -P -- "%F{$color}⚠ ${msg}%f"
}
