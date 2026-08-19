#!/usr/bin/env zsh
# rip.zsh — the rip pipeline's behavior: push (rsync + verify + delete)
# and pipeline (encode → push → cleanup) workers, and their enqueues over
# the job:: runner. SOURCED by the thin rip-push / rip-pipeline bins.
# Spec: docs/superpowers/specs/2026-08-19-rip-push-design.md (rev 4).
#
# DOCTRINE: the physical discs are the master copy. ~/Depot/Rips is
# transient staging — files are deleted ONLY after a checksum-verified
# push (rsync -rcn reporting zero differences). Never --delete remotely.

[ -n "${__RIP_ZSH_LOADED:-}" ] && return 0
__RIP_ZSH_LOADED=1

RIP_LIB_SELF_DIR="${${(%):-%x}:A:h}"
source "$RIP_LIB_SELF_DIR/common.zsh"

RIP_JOB_ICON="${RIP_JOB_ICON:-glyph:nf-md-disc}"

rip::staging_root() { print -r -- "${RIP_STAGING_ROOT:-$HOME/Depot/Rips}"; }
rip::remote_base()  { print -r -- "${RIP_REMOTE_BASE:-media@cantina:/srv/media}"; }

rip::_load_jobs() {
  [ -n "${__JOB_ZSH_LOADED:-}" ] && return 0
  local lib="$RIP_LIB_SELF_DIR/job.zsh"
  [[ -f "$lib" ]] || return 1
  source "$lib"
}

# rip::_progress <pct> <msg…> — guarded sidecar write (the share.zsh
# wrapper pattern), linearly rescaled so a composed stage can own a slice
# of the capsule: pct' = BASE + pct*SPAN/100.
rip::_progress() {
  local pct="$1"; shift
  if [[ "$pct" == <-> ]]; then
    pct=$(( ${RIP_PROGRESS_BASE:-0} + pct * ${RIP_PROGRESS_SPAN:-100} / 100 ))
  fi
  (( $+functions[job::progress] )) || return 0
  job::progress "$pct" "$@" 2>/dev/null || return 0
}

rip::_check_type() {
  case "$1" in
    movies | music) return 0 ;;
    *) log_error "rip: unknown type: $1"; return 2 ;;
  esac
}

# rip::push_enqueue <type> — enqueue `rip-push --worker <type>` unless the
# staging dir has nothing to push (then say so and exit 0 — an empty rsync
# job is noise, not work).
rip::push_enqueue() {
  local type="$1"
  rip::_check_type "$type" || return 2
  local src; src="$(rip::staging_root)/$type"
  local -a files=("$src"/**/*(N.))
  if (( ${#files} == 0 )); then
    print -r -- "rip: nothing to push for $type"
    return 0
  fi
  rip::_load_jobs || { log_error "rip: job runner unavailable"; return 1 }
  job::start --group transfer --title "rip push: $type" --icon "$RIP_JOB_ICON" \
    -- rip-push --worker "$type"
}

# rip::push_worker <type> — the enqueued body: rsync the staging tree to
# cantina with live progress, then (Task 3) verify and clean. Exit code is
# rsync's own; on ANY non-zero, nothing local is touched.
rip::push_worker() {
  local type="$1"
  rip::_check_type "$type" || return 2
  local src dest rsync_bin="${RIP_RSYNC_BIN:-rsync}"
  src="$(rip::staging_root)/$type"
  dest="$(rip::remote_base)/$type/"
  [ -d "$src" ] || { log_error "rip: no staging dir $src"; return 1 }

  rip::_progress 0 "pushing $type"
  local line pct file
  "$rsync_bin" -a --partial --info=progress2,name1 "$src/" "$dest" \
    | tr '\r' '\n' \
    | while IFS= read -r line; do
        case "$line" in
          *%*)
            pct="${line%\%*}"; pct="${pct##* }"
            [[ "$pct" == <-> ]] && rip::_progress "$pct" "${file:-$type}"
            ;;
          ?*) file="$line" ;;
        esac
      done
  local rc=$pipestatus[1]
  if (( rc != 0 )); then
    log_error "rip: rsync failed (rc=$rc) for $type — keeping local files"
    return $rc
  fi
  rip::_verify_and_clean "$type" "$src" "$dest"
}

# Placeholder until Task 3: verified-clean is a no-op success.
rip::_verify_and_clean() { return 0; }
