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
# RIP_BIN_DIR — where the rip-push / rip-pipeline bins live. pueue
# snapshots the ENQUEUING process's environment, not a shell login
# environment; when the enqueue comes from Hammerspoon (hs.task) that
# snapshot's PATH lacks ~/.local/bin, so a bare `rip-push`/`rip-pipeline`
# on the job command line dies Failed(127) before the worker ever runs
# (live-verified). The enqueue functions below always resolve the
# absolute path through this seam instead of trusting PATH at pueue-add
# time.
RIP_BIN_DIR="${RIP_BIN_DIR:-$HOME/.local/bin}"

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
    -- "$RIP_BIN_DIR/rip-push" --worker "$type"
}

# rip::push_worker <type> — the enqueued body: rsync the staging tree to
# cantina with live progress, then (Task 3) verify and clean. Exit code is
# rsync's own; on ANY non-zero, nothing local is touched.
rip::push_worker() {
  # The real rip-push bin sources this under `set -eu -o pipefail`; a bare
  # rsync-into-a-loop pipeline's non-zero status would trigger errexit
  # BEFORE the next line (`local rc=$pipestatus[1]`) ever runs, skipping
  # this function's own rc-capture/cleanup entirely (live-verified:
  # rip::pipeline_worker's twin bug left an orphaned output dir and no
  # error log). localoptions scopes the override to this function only —
  # the job.zsh precedent (job::watch's `setopt localoptions noerrexit`
  # for the same class of problem).
  setopt localoptions noerrexit nopipefail
  local type="$1"
  rip::_check_type "$type" || return 2
  local src dest rsync_bin="${RIP_RSYNC_BIN:-rsync}"
  src="$(rip::staging_root)/$type"
  dest="$(rip::remote_base)/$type/"
  [ -d "$src" ] || { log_error "rip: no staging dir $src"; return 1 }

  # Stamp the moment the transfer begins. The verify pass blesses the tree
  # as the push found it, but the delete runs moments later — a track XLD
  # finishes in that window, or an encode the pipeline publishes while a
  # hand-run `rip-push movies` is in flight (heavy and transfer are separate
  # groups and DO run concurrently), was never pushed and must not be
  # deleted. _verify_and_clean removes only what is no newer than this.
  # The marker lives in .work, a sibling of every pushed tree, so it is
  # itself never shipped and never shows up in the verify diff.
  local marker; marker="$(rip::staging_root)/.work/push-$type.stamp"
  mkdir -p "${marker:h}" && touch -- "$marker" || {
    log_error "rip: cannot stamp the push marker at $marker"; return 1
  }

  rip::_progress 0 "pushing $type"
  local line pct file
  "$rsync_bin" -a --partial --exclude=.DS_Store --info=progress2,name1 "$src/" "$dest" \
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
  rip::_verify_and_clean "$type" "$src" "$dest" "$marker"
}

# rip::_verify_and_clean <type> <src> <dest> <marker> — deleting the only
# digital copy demands more than "rsync exited 0": a checksum dry-run must
# report ZERO differences before anything local is removed. A difference
# (e.g. a rip that landed mid-push) keeps EVERYTHING and fails the job —
# the next run pushes it. Never uses --delete: the server never loses files
# because staging emptied. <marker> is push_worker's start-of-transfer
# stamp; nothing newer than it is ever deleted.
rip::_verify_and_clean() {
  local type="$1" src="$2" dest="$3" marker="$4"
  local rsync_bin="${RIP_RSYNC_BIN:-rsync}"
  local diffs
  # The verify must see exactly the tree the push shipped, so the two rsync
  # calls have to agree on --exclude; otherwise the excluded files show up
  # as differences and the clean never runs.
  if ! diffs="$("$rsync_bin" -rcn --exclude=.DS_Store --out-format='%n' "$src/" "$dest" 2>&1)"; then
    log_error "rip: verify pass failed to run for $type — keeping local files"
    return 1
  fi
  if [ -n "$diffs" ]; then
    log_error "rip: verify found differences for $type — keeping local files"
    return 1
  fi
  print -r -- "rip: $type verified on cantina — cleaning staging"
  rip::_progress 100 "verified — cleaning $type staging"
  # Refuse to delete anything if the stamp is gone (a Hammerspoon reload
  # sweeping .work mid-push would do it): without a reference point we
  # cannot tell pushed files from ones that arrived since, and the
  # doctrine's answer to "not sure" is always "keep it".
  if [[ ! -f "$marker" ]]; then
    log_error "rip: push marker missing for $type — keeping local files"
    return 1
  fi
  # Snapshot the directories the push covered BEFORE removing any file:
  # deleting a file bumps its parent's mtime, so after the delete every
  # emptied directory would look newer than the marker and nothing would
  # ever be pruned. Directories created since the push started (a brand
  # new album dir XLD is still filling) are absent from this list and so
  # survive even while momentarily empty.
  local -a pushed_dirs
  pushed_dirs=(${(f)"$(find "$src" -mindepth 1 -type d ! -newer "$marker" 2>/dev/null)"})
  find "$src" -type f ! -newer "$marker" -delete
  local d
  for d in ${(Oa)pushed_dirs}; do          # deepest first
    [[ -n "$d" ]] && rmdir -- "$d" 2>/dev/null
  done
  return 0
}

# --- pipeline: encode → push → cleanup, one JOB_ID ------------------------

# The whole encode policy in one place (spec rev 4: flags, not a preset
# file — preset JSON can only be exported from the GUI, and hand-authored
# JSON is unverifiable). DVD-era sources: x265 10-bit RF 20 is visually
# transparent; audio is COPIED (never re-encode lossy AC-3/DTS), subs ride
# along as soft subs.
typeset -ga RIP_HB_ARGS=(
  -f av_mkv -e x265_10bit -q 20
  --all-audio -E copy
  --audio-copy-mask aac,ac3,eac3,dts,dtshd,truehd,mp3,flac
  --audio-fallback ca_aac
  --all-subtitles --subtitle-default=none
)

rip::_check_title() {
  case "$1" in
    "" ) log_error "rip: empty title"; return 2 ;;
    */*) log_error "rip: title may not contain a slash: $1"; return 2 ;;
  esac
  return 0
}

# rip::pipeline_worker <input> <title> — the enqueued body. Encode owns
# 0–85% of the capsule, the push stage 85–100 (rescaled via the
# RIP_PROGRESS_BASE/SPAN seam rip::_progress already honors). Cleanup
# rules (spec): encode fail → rm partial output, keep intermediate;
# push/verify fail → keep encode AND intermediate (re-push needs no
# re-encode); full success → rm intermediate (push_worker already
# removed the verified encode); cancelled or killed mid-encode → nothing
# under movies/ at all, intermediate kept (see the .work staging note).
rip::pipeline_worker() {
  # See rip::push_worker's identical comment: the real rip-pipeline bin
  # sources this under `set -eu -o pipefail`, and this function's own
  # HandBrakeCLI pipeline needs to own its error handling (rc capture +
  # cleanup) regardless of the caller's options.
  setopt localoptions noerrexit nopipefail
  local input="$1" title="$2"
  rip::_check_title "$title" || return 2
  [ -f "$input" ] || { log_error "rip: no such input: $input"; return 1 }
  local hb_bin="${RIP_HANDBRAKE_BIN:-HandBrakeCLI}"
  local out_dir out work_dir out_tmp
  out_dir="$(rip::staging_root)/movies/$title"
  out="$out_dir/$title.mkv"
  # Kill-proof by construction. The encoder writes into .work/ and the
  # result is RENAMED into movies/<Title>/ only after it exits 0, so
  # movies/ only ever holds COMPLETE encodes. This is what makes an
  # untrappable death safe: plain `pueue kill` sends SIGKILL on pueue 4.x
  # (live-verified — no TERM trap can run), and a worker killed at any
  # point mid-encode leaves its debris in .work, which nothing ships.
  #
  # INVARIANT this rests on: only intermediate/ and music/ are watched,
  # and rip-push only ever ships movies/ and music/ — so a dotted sibling
  # of those directories is reachable by nothing but this function.
  #
  # One deterministic temp name is safe because the pipeline runs in the
  # `heavy` group at parallelism 1: there is never a second encode to
  # collide with. The rm below clears whatever a killed predecessor left.
  work_dir="$(rip::staging_root)/.work"
  out_tmp="$work_dir/encode.mkv"
  mkdir -p "$work_dir"
  rm -f -- "$out_tmp"

  rip::_progress 0 "encoding — $title"
  # Correctness no longer depends on this trap — .work already guarantees
  # nothing pushable survives a death of any kind. It buys the two things a
  # SIGKILL cannot: the temp goes away immediately rather than waiting for
  # the next run to sweep it, and the job says WHY it stopped and ends 130
  # instead of looking like a crash. It fires on every signal path that is
  # catchable at all — Ctrl-C on a hand-run `rip-pipeline --worker`,
  # `pueue kill --signal sigterm`, logout/shutdown. It cannot rmdir out_dir
  # because out_dir is not created until the encode has succeeded.
  #
  # Scoped to the encode ONLY (`trap -` below, once rc says the encode is
  # good): a cancel during the push is already safe — rsync --partial resumes
  # next run and the verify gate deletes nothing until a checksum pass is
  # clean — and by then the encode is COMPLETE, which the spec's cleanup rules
  # say to keep for re-push rather than throw away.
  trap 'rm -f -- "$out_tmp"
        log_error "rip: cancelled during encode — partial removed, intermediate kept: $input"
        exit 130' TERM INT
  local line pct
  "$hb_bin" "${RIP_HB_ARGS[@]}" -i "$input" -o "$out_tmp" 2>&1 \
    | tr '\r' '\n' \
    | while IFS= read -r line; do
        case "$line" in
          *Encoding:*%*)
            pct="${line%\%*}"; pct="${pct##*, }"; pct="${pct%%.*}"; pct="${pct// /}"
            [[ "$pct" == <-> ]] \
              && RIP_PROGRESS_BASE=0 RIP_PROGRESS_SPAN=85 \
                 rip::_progress "$pct" "encoding — $title"
            ;;
        esac
      done
  local rc=$pipestatus[1]
  if (( rc != 0 )); then
    rm -f -- "$out_tmp"
    log_error "rip: encode failed (rc=$rc) — intermediate kept: $input"
    trap - TERM INT   # $out_tmp goes out of scope with this return
    return $rc
  fi
  # The encode is complete: from here a cancel must LEAVE it alone.
  trap - TERM INT

  # Publish it: same filesystem, so the rename is atomic — movies/<Title>/
  # springs into existence already holding a whole file, never a growing
  # one. This is the moment the encode becomes visible to `rip-push movies`.
  if ! { mkdir -p "$out_dir" && mv -f -- "$out_tmp" "$out" }; then
    rm -f -- "$out_tmp"
    rmdir -- "$out_dir" 2>/dev/null || :
    log_error "rip: could not publish the encode to $out — intermediate kept: $input"
    return 1
  fi

  RIP_PROGRESS_BASE=85 RIP_PROGRESS_SPAN=15 rip::push_worker movies || return $?

  rm -f -- "$input"
  rip::_progress 100 "done — $title"
  return 0
}

# rip::pipeline_enqueue <input> <title> — one heavy-group job per movie
# (parallelism 1: two concurrent x265 encodes would thrash the laptop).
rip::pipeline_enqueue() {
  local input="$1" title="$2"
  rip::_check_title "$title" || return 2
  [ -f "$input" ] || { log_error "rip: no such input: $input"; return 1 }
  rip::_load_jobs || { log_error "rip: job runner unavailable"; return 1 }
  job::start --group heavy --title "rip: $title" --icon "$RIP_JOB_ICON" \
    -- "$RIP_BIN_DIR/rip-pipeline" --worker "$input" "$title"
}
