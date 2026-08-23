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

# LOCALE GUARD (live 2026-08-21 — the real root of the lyrics corruption):
# pueue spawns workers with NO locale, and under C metaflac transliterates
# non-ASCII on BOTH sides — tag reads became "A'i c^e falou" (silent LRCLIB
# misses) and every accented character in every push-embedded lyric shipped
# to the server as "##". Force a UTF-8 LC_CTYPE whenever the environment
# doesn't already provide one. The parse pipes' per-command LC_ALL=C stays
# authoritative where written (LC_ALL outranks LC_CTYPE).
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) ;;
  *) export LC_CTYPE="en_US.UTF-8" ;;
esac

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

# rip::staging_for <type> — the staging dir for a media type. All three
# types are <root>/<type>, no exceptions. audiobooks was briefly believed
# to carry an extra "Books" level under Libation's configured Books
# folder; that was a misreading of one stale tree. Verified live
# 2026-08-22 against a real liberation with Libation's Books location set
# to <root>/audiobooks: the title landed directly at
# <root>/audiobooks/<Author>/<Title>/ — the configured folder IS the
# <Author>/<Title> parent, with no directory inserted in between. The
# server layout is unaffected either way: audiobooks/<Author>/<Title>/,
# per the fleet spec.
rip::staging_for() {
  case "$1" in
    audiobooks) print -r -- "${RIP_AB_STAGING:-$(rip::staging_root)/audiobooks}" ;;
    *) print -r -- "$(rip::staging_root)/$1" ;;
  esac
}

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
    movies | music | audiobooks) return 0 ;;
    *) log_error "rip: unknown type: $1"; return 2 ;;
  esac
}

# rip::push_enqueue <type> — enqueue `rip-push --worker <type>` unless the
# staging dir has nothing to push (then say so and exit 0 — an empty rsync
# job is noise, not work).
rip::push_enqueue() {
  local type="$1"
  rip::_check_type "$type" || return 2
  local src; src="$(rip::staging_for "$type")"
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
  # Workers must load the job lib THEMSELVES: the thin bins source only
  # rip.zsh, and rip::_progress silently no-ops when job::progress is
  # undefined — which left every live run's capsule with no sidecar and no
  # progress at all (live 2026-08-20; the suites masked it by pre-sourcing
  # job.zsh in worker examples). Best-effort on purpose: progress is
  # cosmetic, the rip itself must not care.
  rip::_load_jobs || true
  local type="$1"
  rip::_check_type "$type" || return 2
  local src dest rsync_bin="${RIP_RSYNC_BIN:-rsync}"
  src="$(rip::staging_for "$type")"
  dest="$(rip::remote_base)/$type/"
  [ -d "$src" ] || { log_error "rip: no staging dir $src"; return 1 }

  # SERIALIZE same-type pushes (live 2026-08-21, Spirit of Africa): the
  # transfer group runs 4 wide, and a second music push enqueued while the
  # first was mid-transfer listed the same staged files — then had them
  # verify-DELETED out from under its rsync (rc 24 "file has vanished").
  # Nothing was lost (the first push had verified every byte before
  # deleting) but the loser failed a job over files that were already
  # safe. A BLOCKING flock taken BEFORE the list is built makes the
  # second push wait and then glob the post-clean staging, shipping only
  # what is genuinely new. The fd releases the lock at process exit on
  # every path, kills included. Touched on acquire so sweepWork's age
  # gate never reaps a lock file that sees regular use.
  zmodload zsh/system 2>/dev/null
  local push_lock_fd push_lock
  push_lock="$(rip::staging_root)/.work/push-$type.lock"
  mkdir -p "${push_lock:h}"
  # touch BEFORE flock: zsystem flock does not create the file (verified
  # live — ENOENT on first use), and the fresh mtime doubles as the
  # sweepWork age-gate protection.
  touch "$push_lock" 2>/dev/null
  if zmodload -e zsh/system; then
    zsystem flock -f push_lock_fd "$push_lock" 2>/dev/null
  fi

  # AGE GATE (spec UX-v2, live-bitten 2026-08-19): a half-written track that
  # holds still for the ~2s push+verify window can ship truncated and be
  # verify-deleted from under its writer. Only files that have been quiet
  # for RIP_PUSH_MIN_AGE_S are visible to this run — pushed, verified, and
  # deleted as one fixed set. 0 disables the gate: the pipeline's inner
  # push runs on a file that is complete by construction (atomic rename).
  local age="${RIP_PUSH_MIN_AGE_S:-90}"
  # Private to THIS invocation ($$ in the name): the heavy group's inner
  # push (from rip::pipeline_worker) and a transfer-group/hand-run
  # `rip-push <type>` DO run concurrently on the same type, and a fixed
  # path here let one invocation's list-rebuild land mid-flight of
  # another's verify/delete — belt+braces even so, verify and delete are
  # driven off one in-memory snapshot rather than a second read of this
  # file (see rip::_verify_and_clean). Removed on every exit path below;
  # a killed process's leftover is swept at Hammerspoon startup along with
  # the rest of .work/.
  local listfile; listfile="$(rip::staging_root)/.work/push-$type.$$.list"
  mkdir -p "${listfile:h}"
  if (( age > 0 )); then
    find "$src" -type f ! -name .DS_Store -mtime +"${age}s" 2>/dev/null
  else
    find "$src" -type f ! -name .DS_Store 2>/dev/null
  fi | sed "s|^$src/||" > "$listfile"
  if [[ ! -s "$listfile" ]]; then
    print -r -- "rip: nothing settled to push for $type (age gate ${age}s)"
    rm -f -- "$listfile"
    return 0
  fi

  if [[ "$type" == music ]]; then
    rip::_enrich_music "$src" "$listfile" || log_warn "rip: enrich pass had failures — pushing anyway"
  elif [[ "$type" == audiobooks ]]; then
    rip::_enrich_audiobooks "$src" "$listfile" || log_warn "rip: enrich pass had failures — pushing anyway"
  fi

  local marker; marker="$(rip::staging_root)/.work/push-$type.stamp"
  touch -- "$marker" || {
    log_error "rip: cannot stamp the push marker at $marker"
    rm -f -- "$listfile"
    return 1
  }

  rip::_progress 0 "pushing $type"
  local line pct file
  # --iconv=utf-8-mac,utf-8 on BOTH rsync invocations (here and the
  # verify): the library is NFC-canonical. A macOS-decomposed (NFD) staged
  # name shipped byte-identically leaves the server holding a file the
  # macOS SMB client cannot OPEN — it lists NFD but opens NFC, so Samba
  # byte-compares and 404s (live 2026-08-21: Picard ENOENT on "05 Há
  # quanto tempo.flac" through the metadata-fix share).
  "$rsync_bin" -a --iconv=utf-8-mac,utf-8 --partial --exclude=.DS_Store --files-from="$listfile" \
      --info=progress2,name1 "$src/" "$dest" \
    | LC_ALL=C tr '\r' '\n' \
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
    rm -f -- "$listfile"
    return $rc
  fi
  # Snapshot the pushed set before the verify: _verify_and_clean removes
  # the listfile on EVERY exit path, and the remote hops need to know what
  # landed. Copied to a sibling name so the two never share a path.
  local hooklist=""
  if [[ "$type" == audiobooks ]] && (( ${#RIP_AB_REMOTE_HOPS} )); then
    hooklist="$listfile.hooks"
    cp -- "$listfile" "$hooklist" 2>/dev/null || hooklist=""
  fi
  rip::_verify_and_clean "$type" "$src" "$dest" "$marker" "$listfile"
  local vrc=$?
  if (( vrc == 0 )) && [[ -n "$hooklist" ]]; then
    rip::_enrich_audiobooks_remote "$hooklist"
  fi
  [[ -n "$hooklist" ]] && rm -f -- "$hooklist"
  return $vrc
}

# rip::_verify_and_clean <type> <src> <dest> <marker> <listfile> — deleting
# the only digital copy demands more than "rsync exited 0": a checksum
# dry-run must report ZERO differences before anything local is removed. A
# difference (e.g. a rip that landed mid-push) keeps EVERYTHING and fails
# the job — the next run pushes it. Never uses --delete: the server never
# loses files because staging emptied. <marker> is push_worker's
# start-of-transfer stamp; <listfile> is the exact set of relative paths
# the age gate admitted — only those are verified and deleted, belt+braces
# with the not-newer-than-marker check below.
#
# <listfile> is snapshotted into an in-memory array ONCE, right here, before
# anything else runs. The verify's --files-from and the delete loop both
# drive off that one snapshot rather than each doing its own read of
# <listfile> — the file is already private to this invocation ($$ in its
# name, see push_worker), but pinning the verify's rsync to read back
# exactly the snapshot (never whatever might be on disk by the time the
# delete loop gets there) costs nothing and removes any dependency on
# <listfile> staying byte-identical across the whole function. <listfile>
# itself is removed on every exit path below — it is pure scratch once
# snapshotted, and a leftover from a killed process is swept at Hammerspoon
# startup along with the rest of .work/.
rip::_verify_and_clean() {
  local type="$1" src="$2" dest="$3" marker="$4" listfile="$5"
  local rsync_bin="${RIP_RSYNC_BIN:-rsync}"
  local -a listed=()
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && listed+=("$rel")
  done < "$listfile"
  # Re-pin the private file to EXACTLY the snapshot before rsync reads it.
  printf '%s\n' "${listed[@]}" > "$listfile"

  local diffs
  # The verify must see exactly the tree the push shipped, so the two rsync
  # calls have to agree on --exclude and the file list; otherwise excluded
  # or unlisted files show up as differences and the clean never runs.
  # --iconv matches the push: the verify must compare against the
  # NFC names the push created, or every accented file reads "missing".
  if ! diffs="$("$rsync_bin" -rcn --iconv=utf-8-mac,utf-8 --exclude=.DS_Store --files-from="$listfile" \
      --out-format='%n' "$src/" "$dest" 2>&1)"; then
    log_error "rip: verify pass failed to run for $type — keeping local files"
    rm -f -- "$listfile"
    return 1
  fi
  if [ -n "$diffs" ]; then
    log_error "rip: verify found differences for $type — files still settling or changed; keeping local, will retry"
    rm -f -- "$listfile"
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
    rm -f -- "$listfile"
    return 1
  fi
  # Delete EXACTLY the snapshotted list (∩ not-newer-than-marker,
  # belt+braces), then prune only directories that held listed files and
  # are now empty.
  local f
  local -a touched_dirs=()
  for rel in "${listed[@]}"; do
    f="$src/$rel"
    [[ -f "$f" && ! "$f" -nt "$marker" ]] || continue
    rm -f -- "$f"
    touched_dirs+=("${f:h}")
  done
  local d
  for d in ${(Oau)touched_dirs}; do
    while [[ "$d" != "$src" && -d "$d" ]]; do
      rmdir -- "$d" 2>/dev/null || break
      d="${d:h}"
    done
  done
  rm -f -- "$listfile"
  return 0
}

# --- enrichment: embedded cover art + lyrics, pre-push -----------------------
# Best-effort by doctrine: any failure logs and continues — a lyrics outage
# must never strand an album locally. Idempotent: tracks already carrying a
# PICTURE block / LYRICS tag are skipped. Runs BEFORE the push marker is
# stamped, so enriched mtimes are older than the marker and the clean pass
# still removes them.

# rip::_track_meta <flac> — prints
# "artist<TAB>album<TAB>title<TAB>duration_s<TAB>year". year is the DATE
# tag's first 4 characters, kept ONLY when that's exactly 4 characters —
# empty otherwise (DATE absent, or too short to be a year at all: a bare
# "04" must not leak through as a junk `date:04` MB query) — the cover
# search's disambiguator for an ambiguous title (see rip::_fetch_cover).
# Built with printf (not `print -r`): print -r takes its arguments RAW, so a
# literal \t embedded in a double-quoted string would ride through as the two
# characters backslash-t instead of becoming a real tab, breaking every
# consumer below that splits on $'\t' / cut. printf's format string is where
# \t is interpreted, and — unlike `print` without -r — it never reprocesses
# escape-like content inside the %s argument values themselves, so an artist
# or album tag that happens to contain a literal backslash sequence rides
# through unmolested.
# rip::_nfc <text> — normalize to composed Unicode (NFC). macOS/XLD write
# accented tag text DECOMPOSED (NFD: "í" = i + combining acute); external
# lookups match bytes, and LRCLIB missed lyrics for NFD queries that NFC
# finds (live 2026-08-21, XLD-converted Jota Quest album). iconv's
# utf-8-mac codec is exactly the NFD→NFC leg; already-composed text passes
# through unchanged. Best-effort: on any iconv failure the original text
# stands. Contract (revised 2026-08-21, NFC-canonical server): normalize
# QUERY/DISPLAY text and REMOTE/server paths (the push ships NFC via
# rsync --iconv, so server names ARE composed); never normalize LOCAL
# staging paths — those must keep matching the on-disk bytes.
rip::_nfc() {
  local out
  if out="$(print -rn -- "$1" | iconv -f utf-8-mac -t utf-8 2>/dev/null)" \
     && { [[ -n "$out" ]] || [[ -z "$1" ]] }; then
    print -rn -- "$out"
  else
    print -rn -- "$1"
  fi
}

# --- audiobook identity ----------------------------------------------------
#
# Every book folder carries .fleet-book.json: WHO this book is, independent
# of where it was bought. Two levels on purpose (spec):
#   ids  — EDITION identity, namespaced per source (audible.asin, isbn13, …),
#          so the same book from two stores gains a key, not a second folder.
#   work — WORK identity (openlibrary / wikidata), null at ingest. An
#          audiobook's ASIN and its ebook's ISBN are different editions of
#          one work and never match each other, so this is the key the
#          future whispersync and X-ray services join on. A later resolver
#          hop fills it; NOTHING here may ever overwrite a resolved one.
# NOT metadata.json — Audiobookshelf reserves that name for its own import
# format and would read ours as instructions.

# rip::_ab_meta_index_default — the STABLE, session-independent path the
# meta index lives at when the caller does not set RIP_AB_META_INDEX
# explicitly. rip::ab_worker writes every session's rows here now (review
# finding, 2026-08-22: it used to write a $$-suffixed path and remove it
# mid-session, so a watcher-triggered push — which never sets the var at
# all — could never see a session's rich rows). ANY audiobooks push,
# session-triggered or watcher-triggered, reads from here by default.
rip::_ab_meta_index_default() { print -r -- "$(rip::staging_root)/.work/ab-meta.jsonl"; }

# Provider-fallback cache (fix 3b, review finding 2026-08-22): a push with
# NO usable index row (the watcher path, or an import provider with none)
# tries the provider's own `list` ONCE per push run and matches by `.path`,
# rather than falling straight to the path-derived minimal identity. GLOBAL
# and process-scoped on purpose — every real invocation (rip-push
# --worker, rip-audiobook --session-worker) is its own fresh zsh process
# (see executable_rip-push: --worker handles exactly one type per
# process), so "reset once per push run" falls out of normal process
# lifetime with no explicit reset needed; guarded like RIP_AB_ENRICH_HOPS
# above so re-sourcing this file mid-process never clobbers a run already
# under way. _RIP_AB_PROVIDER_FETCHED flips exactly once — success or
# failure — so a 20-book push makes at most ONE provider call, never one
# per book, and a missing/failing provider is never retried within the run.
typeset -g _RIP_AB_PROVIDER_ROWS
typeset -g _RIP_AB_PROVIDER_FETCHED
(( ${+_RIP_AB_PROVIDER_FETCHED} )) || { _RIP_AB_PROVIDER_ROWS=""; _RIP_AB_PROVIDER_FETCHED=0 }

# rip::_book_meta_for <relpath> — one JSON object for the book at
# <Author>/<Title>. The provider's rows, when a session wrote them, live in
# the JSON-lines index at $RIP_AB_META_INDEX (default: the stable path
# above) keyed by `path`. Below that: a best-effort, at-most-once provider
# `list` fallback for a push with no matching index row at all — the
# watcher path (a title liberated through Libation's own GUI enqueues a
# plain `rip-push audiobooks` with no index) and an import provider that
# keeps none either. Only once BOTH give up is a MINIMAL identity derived
# from the path a first-class outcome, not an error: the folder names are
# the only truth available and they are still worth recording.
rip::_book_meta_for() {
  setopt localoptions noerrexit nopipefail
  local rel; rel="$(rip::_nfc "$1")"
  local idx="${RIP_AB_META_INDEX:-$(rip::_ab_meta_index_default)}"
  local row=""
  if [[ -n "$idx" && -f "$idx" ]]; then
    row="$(jq -c --arg p "$rel" 'select((.path // "") == $p)' "$idx" 2>/dev/null | head -1)"
  fi
  if [[ -z "$row" ]]; then
    # Best-effort, best-once: never let a missing/failing provider slow
    # down or fail the push — every step here is guarded so the worst case
    # is exactly today's path-derived minimal identity.
    if (( ! _RIP_AB_PROVIDER_FETCHED )); then
      _RIP_AB_PROVIDER_FETCHED=1
      local pbin=""
      pbin="$(rip::ab_provider_bin 2>/dev/null)"
      [[ -n "$pbin" ]] && _RIP_AB_PROVIDER_ROWS="$(zsh "$pbin" list 2>/dev/null)"
    fi
    [[ -n "$_RIP_AB_PROVIDER_ROWS" ]] && row="$(print -r -- "$_RIP_AB_PROVIDER_ROWS" \
      | jq -c --arg p "$rel" 'select((.path // "") == $p)' 2>/dev/null | head -1)"
  fi
  if [[ -n "$row" ]]; then
    print -r -- "$row"
    return 0
  fi
  jq -nc --arg author "${rel%%/*}" --arg title "${rel##*/}" \
    '{path: ($author + "/" + $title), title: $title, authors: [$author],
      ids: {}, provider: "unknown", format: "m4b"}'
}

# rip::_book_sidecar <book_dir> <meta_json_file> — write or MERGE the
# sidecar. Merge rule: the existing file wins at every depth (jq's `*` with
# the old object on the right), which is what protects a resolved `work` and
# any ids a different source contributed. New keys from the provider row
# fill gaps; nothing already recorded is rewritten.
#
# Byte-stability matters beyond tidiness: this runs on EVERY push of a book
# folder, and a sidecar that churned would re-enter the push set forever and
# make "the enrichment stage is a no-op" untestable. Unchanged content is
# left completely alone — same bytes, same mtime.
rip::_book_sidecar() {
  setopt localoptions noerrexit nopipefail
  local dir="$1" meta="$2"
  local sidecar="$dir/.fleet-book.json"
  [[ -d "$dir" ]] || { log_error "rip: no such book dir: $dir"; return 1 }
  [[ -f "$meta" ]] || { log_error "rip: no such book meta: $meta"; return 1 }

  local built
  built="$(jq -n --slurpfile m "$meta" '
    ($m[0] // {}) as $r
    | {schema: 1, kind: "audiobook",
       title: ($r.title // ""),
       subtitle: ($r.subtitle // null),
       authors: ($r.authors // []),
       narrators: ($r.narrators // []),
       series: (if ($r.series // "") == "" then null
                else {name: $r.series, position: ($r.series_position // null)} end),
       duration_s: ($r.duration_s // null),
       language: ($r.language // null),
       abridged: (if ($r|has("abridged")) then $r.abridged else null end),
       ids: ($r.ids // {}),
       work: null,
       source: {provider: ($r.provider // "unknown"),
                provider_version: ($r.provider_version // null),
                acquired_utc: ($r.acquired_utc // null),
                format: ($r.format // "m4b")}}' 2>/dev/null)" \
    || { log_error "rip: could not build a sidecar for $dir"; return 1 }

  local merged="$built"
  if [[ -f "$sidecar" ]] && jq -e . "$sidecar" >/dev/null 2>&1; then
    # jq's `*` gives the RIGHT operand (the old file) priority at every
    # depth, even when its value is null — a sidecar that recorded
    # `subtitle: null` (the minimal-identity shape a verify-failure retry
    # writes first) would then permanently shadow a later pass's real
    # subtitle: `jq -n --argjson new '{"subtitle":"S"}' --argjson old
    # '{"subtitle":null}' '$new * $old'` → `{"subtitle":null}` (review
    # finding, 2026-08-22). A null in the OLD object is not something
    # "already recorded" (see the merge-rule note above), so strip
    # null-valued keys from it before merging — a resolved `work` and a
    # foreign `ids` entry are non-null and still win untouched.
    merged="$(jq -n --argjson new "$built" --slurpfile old "$sidecar" \
      '$new * (($old[0] // {}) | with_entries(select(.value != null)))' 2>/dev/null)" \
      || { log_error "rip: could not merge the sidecar at $sidecar"; return 1 }
  fi

  # Unchanged → touch nothing at all.
  if [[ -f "$sidecar" ]] && [[ "$merged" == "$(cat "$sidecar")" ]]; then
    return 0
  fi
  # The scratch write lives under .work/, never inside the book dir itself
  # (review finding, 2026-08-22): a process killed mid-write used to leave
  # ".fleet-book.json.tmp.$$" sitting IN the book dir, where it is just
  # another file — a LATER push's age-gated find would pick it up and ship
  # it to the server. .work/ is this file's own established idiom for
  # exactly this kind of scratch (book-meta.$$.json, the ab-meta index,
  # push listfiles/locks/markers all live there), and it can never be
  # listed by a push regardless of book dir or push type.
  local work_dir; work_dir="$(rip::staging_root)/.work"
  mkdir -p "$work_dir" || { log_error "rip: cannot create $work_dir"; return 1 }
  local tmp="$work_dir/fleet-book.$$.json.tmp"
  print -r -- "$merged" > "$tmp" || { rm -f -- "$tmp"; return 1 }
  mv -f -- "$tmp" "$sidecar" || { rm -f -- "$tmp"; return 1 }
  return 0
}

# --- audiobook enrichment --------------------------------------------------
#
# TWO registries, both EMPTY today, because the deletion doctrine forces the
# distinction (spec):
#   RIP_AB_ENRICH_HOPS  local, pre-push: runs while the files are still here.
#   RIP_AB_REMOTE_HOPS  post-verify: runs against cantina, for anything too
#                       heavy for the laptop (force-alignment, X-ray index).
# After a verified push the local copy is GONE, so a future stage that needs
# the audio must live in one of these two slots. Naming both now is what
# stops someone later discovering there is nowhere to put it.
#
# Hop contract (inherited verbatim from the music enrichment's hard-won
# rules): idempotent, best-effort — a failure logs and continues and NEVER
# fails the push — bounded, and ADDITIVE: a hop may modify files in place or
# add files inside the book dir, and every file it adds must be registered
# with rip::_enrich_add or it will be neither pushed nor cleaned.
typeset -ga RIP_AB_ENRICH_HOPS
typeset -ga RIP_AB_REMOTE_HOPS
(( ${+RIP_AB_ENRICH_HOPS} )) || RIP_AB_ENRICH_HOPS=()
(( ${+RIP_AB_REMOTE_HOPS} )) || RIP_AB_REMOTE_HOPS=()

# First real remote hop (the registry stops being deliberately empty here):
# after a verified push, ask Audiobookshelf to backfill image + bio for
# the pushed books' authors it has never populated — see
# rip::_abs_match_authors below for the full rationale. PREPENDED, not
# appended: "first entry" per spec, so any later remote hop that wants ABS
# to already know about this push's authors can rely on it.
RIP_AB_REMOTE_HOPS=(rip::_abs_match_authors "${RIP_AB_REMOTE_HOPS[@]}")

# rip::_enrich_add <relpath> — register a file (relative to the type's
# staging dir) into the running push's list, so it is pushed, verified and
# cleaned as part of the same fixed set. The music enrichment's cover.jpg /
# artist.jpg idiom, made a function now that third-party hops need it.
rip::_enrich_add() {
  local rel="$1"
  [[ -n "${RIP_ENRICH_LISTFILE:-}" ]] || return 0
  grep -qxF -- "$rel" "$RIP_ENRICH_LISTFILE" 2>/dev/null \
    || print -r -- "$rel" >> "$RIP_ENRICH_LISTFILE"
}

# rip::_enrich_audiobooks <src> <listfile> — per book dir holding listed
# files: write the identity sidecar, then run each local hop. The book dir
# set is derived from the LISTFILE (the age gate's admitted set), never a
# directory glob — the same rule the music stage follows, so a book still
# being written is invisible to this pass.
rip::_enrich_audiobooks() {
  setopt localoptions noerrexit nopipefail
  local src="$1" listfile="$2"
  local -a rels=()
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && rels+=("${rel:h}")
  done < "$listfile"
  local -a dirs=(${(u)rels})
  (( ${#dirs} )) || return 0

  local RIP_ENRICH_LISTFILE="$listfile"
  local d meta hop failed=0
  for d in "${dirs[@]}"; do
    [[ -d "$src/$d" ]] || continue
    meta="$(rip::staging_root)/.work/book-meta.$$.json"
    mkdir -p "${meta:h}"
    if rip::_book_meta_for "$d" > "$meta" 2>/dev/null \
       && rip::_book_sidecar "$src/$d" "$meta"; then
      rip::_enrich_add "$d/.fleet-book.json"
    else
      log_warn "rip: could not write the identity sidecar for $d"
      failed=1
    fi
    rm -f -- "$meta"
    for hop in "${RIP_AB_ENRICH_HOPS[@]}"; do
      (( $+functions[$hop] )) || { log_warn "rip: no such enrichment hop: $hop"; failed=1; continue }
      "$hop" "$src/$d" "$src/$d/.fleet-book.json" "$d" \
        || { log_warn "rip: enrichment hop failed: $hop ($d)"; failed=1 }
    done
  done
  return $failed
}

# rip::_enrich_audiobooks_remote <listfile> — the post-verify slot. The
# files are on cantina and the local copies are gone, so a hop here works
# against REMOTE paths: it is handed the remote base and every relpath the
# push landed. Failure is logged and swallowed by contract — the push
# already delivered everything it promised, and a stalled aligner must not
# turn a successful transfer into a failed job.
rip::_enrich_audiobooks_remote() {
  setopt localoptions noerrexit nopipefail
  local listfile="$1"
  (( ${#RIP_AB_REMOTE_HOPS} )) || return 0
  [[ -f "$listfile" ]] || return 0
  local -a rels=()
  local rel hop
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && rels+=("$rel")
  done < "$listfile"
  (( ${#rels} )) || return 0
  for hop in "${RIP_AB_REMOTE_HOPS[@]}"; do
    (( $+functions[$hop] )) || { log_warn "rip: no such remote hop: $hop"; continue }
    "$hop" "$(rip::remote_base)" "${rels[@]}" \
      || log_warn "rip: remote enrichment hop failed: $hop (files are on the server regardless)"
  done
  return 0
}

# rip::_abs_match_authors <remote_base> <relpath…> — the first
# RIP_AB_REMOTE_HOPS entry. Audiobookshelf keeps an author's image and bio
# in its OWN database (the `authors` table), never in the media tree, so
# nothing a push writes into /srv/media can ever populate it. ABS already
# knows how to fill it in itself — POST /api/authors/{id}/match makes ABS
# query Audnexus (keyless) and write image+bio+ASIN — so this hop just
# asks it to, for the authors THIS push landed.
#
# <remote_base> is unused: ABS is reached over its own HTTP API
# (rip-abs-authors, RIP_ABS_URL/RIP_CURL_BIN), never over the rsync
# target — the parameter is kept only for signature parity with every
# other RIP_AB_REMOTE_HOPS entry. Author names are the FIRST path segment
# of each <Author>/<Title>/<file> relpath, deduped with the same ${(u)…}
# idiom rip::_enrich_audiobooks uses for book dirs: two books by one
# author in a single push make exactly ONE call into rip-abs-authors,
# which itself makes at most one ABS match call per never-before-seen
# author (the "first sighting" rule lives in the bin, not here).
#
# Best-effort by construction, not just by the caller's `|| log_warn`: the
# bin itself never fails a lookup outward (a missing/unreachable ABS, or
# an author ABS hasn't scanned yet, is a logged skip, never a hard exit),
# and every HTTP call it makes carries a timeout — a hung ABS cannot wedge
# this hop, and a failing one cannot fail the push that already landed on
# cantina.
rip::_abs_match_authors() {
  setopt localoptions noerrexit nopipefail
  shift  # remote_base — unused, see above
  (( $# )) || return 0
  local -a authors=()
  local rel author
  for rel in "$@"; do
    author="${rel%%/*}"
    [[ -n "$author" ]] && authors+=("$author")
  done
  authors=(${(u)authors})
  (( ${#authors} )) || return 0
  "$RIP_BIN_DIR/rip-abs-authors" "${authors[@]}"
}

rip::_track_meta() {
  local mf="${RIP_METAFLAC_BIN:-metaflac}" f="$1"
  local artist album title date year samples rate dur=0
  artist="$("$mf" --show-tag=ARTIST "$f" 2>/dev/null | head -1)"; artist="$(rip::_nfc "${artist#*=}")"
  album="$("$mf" --show-tag=ALBUM "$f" 2>/dev/null | head -1)";  album="$(rip::_nfc "${album#*=}")"
  title="$("$mf" --show-tag=TITLE "$f" 2>/dev/null | head -1)";  title="$(rip::_nfc "${title#*=}")"
  date="$("$mf" --show-tag=DATE "$f" 2>/dev/null | head -1)";   date="${date#*=}"
  year="${date[1,4]}"
  [[ ${#year} == 4 ]] || year=""
  samples="$("$mf" --show-total-samples "$f" 2>/dev/null)"
  rate="$("$mf" --show-sample-rate "$f" 2>/dev/null)"
  [[ "$samples" == <-> && "$rate" == <1-> ]] && dur=$(( samples / rate ))
  printf '%s\t%s\t%s\t%s\t%s\n' "$artist" "$album" "$title" "$dur" "$year"
}

# rip::_mb_call <curl_bin> <jq_filter> <curl args…> — MusicBrainz rate-
# limits to ~1 req/s; a request arriving right behind another of OUR OWN
# calls (e.g. the artist-image step's MB lookup right after the cover
# step's own MB lookup for the same run) gets 503'd, and `curl -sf` fails
# silently — the caller would otherwise honestly report a miss on data
# that's really there (live-caught 2026-08-20: the chain missed on a real
# push while succeeding standalone). Sleeps RIP_MB_PAUSE_S before the
# request to space it from whatever MB call came before, then retries
# ONCE after RIP_MB_RETRY_PAUSE_S — but ONLY on a curl TRANSPORT failure
# (curl's own exit code, captured separately from jq's — with -f a 503
# is rc 22). An empty-but-successful parse (curl rc 0, body legitimately
# has no match) is a real miss, not a rate-limit symptom, and must be
# accepted as-is: retrying it would double MB traffic and add up to 8s of
# sleep on every ordinary miss, including the by-design date-filtered miss
# in rip::_fetch_cover (round 3, live-caught 2026-08-20 in review — the
# first version of this wrapper retried on ANY empty parse). Deezer/
# Wikidata/Commons don't rate-limit at our volumes, so this wrapper is
# MB-only. Both pauses are seams (defaults 1s / 3s) so the test suite can
# zero them out and stay fast.
rip::_mb_call() {
  local curl_bin="$1" jq_filter="$2"; shift 2
  local pause="${RIP_MB_PAUSE_S:-1}" retry_pause="${RIP_MB_RETRY_PAUSE_S:-3}"
  local raw rc result
  (( pause > 0 )) && sleep "$pause"
  raw="$("$curl_bin" "$@" 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then
    (( retry_pause > 0 )) && sleep "$retry_pause"
    raw="$("$curl_bin" "$@" 2>/dev/null)"; rc=$?
  fi
  result="$(jq -r "$jq_filter" <<<"$raw")"
  print -r -- "$result"
}

# rip::_fetch_cover <artist> <album> <out> [year] — MB release search by
# title+artist alone can match the wrong edition on an ambiguous title
# (live-bitten 2026-08-20: an art-less rip of "MTV ao Vivo" matched the
# wrong release — embedded-first, the round-2 fix, can't help when
# nothing is embedded to begin with). <year> — the rip's own DATE tag,
# already in hand via rip::_track_meta — disambiguates: when given, the MB
# query adds `AND date:<year>` first; only if THAT yields nothing does it
# retry once with the plain title+artist query (a right-titled
# wrong-edition cover beats none). Same idea for the iTunes fallback: with
# a year in hand, prefer the result whose releaseDate year matches,
# falling back to the first result otherwise.
rip::_fetch_cover() {
  local artist="$1" album="$2" out="$3" year="${4:-}"
  local curl_bin="${RIP_CURL_BIN:-curl}"
  local mb="${RIP_MB_URL:-https://musicbrainz.org/ws/2}"
  local caa="${RIP_CAA_URL:-https://coverartarchive.org}"
  local itunes="${RIP_ITUNES_URL:-https://itunes.apple.com}"
  local mbid=""
  if [[ -n "$year" ]]; then
    mbid="$(rip::_mb_call "$curl_bin" '(.releases // [])[0].id // empty' \
        -sf -A 'fleet-rip/2.0' -G "$mb/release/" \
        --data-urlencode "query=release:\"$album\" AND artist:\"$artist\" AND date:$year" \
        --data-urlencode fmt=json --data-urlencode limit=1)"
  fi
  if [[ -z "$mbid" ]]; then
    [[ -n "$year" ]] && print -r -- "rip: cover — date:$year yielded nothing, retrying without it — $artist / $album"
    mbid="$(rip::_mb_call "$curl_bin" '(.releases // [])[0].id // empty' \
        -sf -A 'fleet-rip/2.0' -G "$mb/release/" \
        --data-urlencode "query=release:\"$album\" AND artist:\"$artist\"" \
        --data-urlencode fmt=json --data-urlencode limit=1)"
  fi
  if [[ -n "$mbid" ]]; then
    "$curl_bin" -sfL -o "$out" "$caa/release/$mbid/front-500" 2>/dev/null \
      && [[ -s "$out" ]] && return 0
  fi
  local art_url
  if [[ -n "$year" ]]; then
    art_url="$("$curl_bin" -sf -G "$itunes/search" \
        --data-urlencode "term=$artist $album" --data-urlencode entity=album \
        --data-urlencode limit=5 2>/dev/null \
      | jq -r --arg y "$year" \
          '(.results // []) as $r
           | (first($r[] | select((.releaseDate // "")[0:4] == $y)) // $r[0])
           | .artworkUrl100 // empty' \
      | sed 's/100x100bb/600x600bb/')"
  else
    art_url="$("$curl_bin" -sf -G "$itunes/search" \
        --data-urlencode "term=$artist $album" --data-urlencode entity=album \
        --data-urlencode limit=1 2>/dev/null \
      | jq -r '(.results // [])[0].artworkUrl100 // empty' \
      | sed 's/100x100bb/600x600bb/')"
  fi
  [[ -n "$art_url" ]] || { rm -f -- "$out"; return 1 }
  "$curl_bin" -sfL -o "$out" "$art_url" 2>/dev/null && [[ -s "$out" ]] && return 0
  rm -f -- "$out"; return 1
}

# Deezer's empty-image placeholder cover, keyed by MD5 (live-discovered
# 2026-08-20): any picture_xl containing this must be rejected outright.
RIP_ARTIST_IMAGE_PLACEHOLDER_MD5='d41d8cd98f00b204e9800998ecf8427e'

# rip::_remote_has_file <media_relpath> — existence check on the server for
# <media_relpath>, relative to the remote base itself (e.g.
# "music/<Artist>/artist.jpg", "music/<Artist>/<Album>/cover.jpg", or
# "movies/<Movie>/extras/<Name>.mkv") — ahead of any fetch/encode
# (idempotency, per operator requirement). Shared by the music
# enrichment's artist.jpg and cover.jpg pre-fetch checks (round 4:
# cover.jpg used to lack this entirely — a future re-rip of an art-less
# album would refetch and rsync-overwrite a curated server cover, live
# case: the hand-corrected "MTV ao Vivo") and by rip-extra's server
# idempotency check. GENERALIZED from a music-only helper (it used to
# hardcode a "music/" prefix internally, taking only the path under it) —
# every caller now supplies its own full type-prefixed path; no caller's
# observable behavior changed, only the string each one passes in. If
# rip::remote_base contains a ':' it's `user@host:path`: shell out to `ssh
# <host> test -f …`. No ':' (the hermetic tests use a plain local dir): a
# direct filesystem test. Returns 0 exists / 1 confirmed absent / 2 unknown
# (the ssh call itself failed to run — e.g. the host is unreachable — rc
# 255 on a real ssh; distinct from the remote `test -f` legitimately
# reporting rc 1). Every caller treats 2 exactly like "unknown": never
# block, never refetch/reprocess blindly, just skip this run and log one
# line.
rip::_remote_has_file() {
  # The tri-state IS this function's contract, so it has to own its own
  # error handling: under the `set -e` the real bins source this file with,
  # an ssh that exits 255 (unreachable host) would kill the whole process
  # before the `local rc=$?` below ever runs, and "unknown" could never be
  # reported at all. Every worker already sets this for its own reasons;
  # rip::session_have (the `rip-disc --have` body) is a bare helper call
  # straight from the bin, which is where the gap showed up.
  setopt localoptions noerrexit nopipefail
  # The server is NFC-canonical (the push's --iconv guarantees it), but
  # this relpath is composed from LOCAL folder names, which macOS keeps in
  # whatever form they were created (often NFD). Normalize before asking,
  # or a present NFC file reads "confirmed absent" — and for the cover
  # check that verdict green-lights a refetch over curated art.
  local relpath; relpath="$(rip::_nfc "$1")"
  local base; base="$(rip::remote_base)"
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    # Artist/album names (and, for rip-extra, movie/extra names) are
    # untrusted CDDB/MusicBrainz tag data or hand-typed titles — an
    # apostrophe ("Guns N' Roses") breaks hand-rolled single-quoting, and
    # a crafted name can break OUT of it entirely and execute arbitrary
    # commands on cantina over the media@ ssh credentials. ${(q)...} is
    # zsh's own quoter: it safely shell-quotes the remote-file path for
    # ANY content, never hand-interpolated into a quoted string ourselves.
    # BatchMode+ConnectTimeout: a network black-hole or host-key prompt
    # must never hang the push worker — "never block" applies to the
    # check itself, not just its result.
    local rfile="$rpath/$relpath"
    "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 \
      "$host" "test -f ${(q)rfile}" 2>/dev/null
    local rc=$?
    (( rc == 0 )) && return 0
    (( rc == 1 )) && return 1
    return 2
  fi
  [[ -f "$base/$relpath" ]] && return 0
  return 1
}

# rip::_remote_has_artist_image <artist_reldir> — thin rip::_remote_has_file
# wrapper for the artist.jpg path shape.
rip::_remote_has_artist_image() {
  rip::_remote_has_file "music/$1/artist.jpg"
}

# rip::_fetch_artist_image <artist> <out> — keyless fetch chain: Deezer
# first (REJECT any picture_xl containing Deezer's empty-image placeholder
# MD5, live-discovered 2026-08-20), then Wikimedia via MusicBrainz→Wikidata
# as fallback. rc 1 on a total miss (best-effort; caller never fails the
# push over this).
rip::_fetch_artist_image() {
  local artist="$1" out="$2"
  local curl_bin="${RIP_CURL_BIN:-curl}"
  local deezer="${RIP_DEEZER_URL:-https://api.deezer.com}"
  local mb="${RIP_MB_URL:-https://musicbrainz.org/ws/2}"
  local wikidata="${RIP_WIKIDATA_URL:-https://www.wikidata.org}"
  local commons="${RIP_COMMONS_URL:-https://commons.wikimedia.org}"
  local pic_url
  pic_url="$("$curl_bin" -sf -A 'fleet-rip/2.0' -G "$deezer/search/artist" \
      --data-urlencode "q=$artist" 2>/dev/null \
    | jq -r '(.data // [])[0].picture_xl // empty')"
  if [[ -n "$pic_url" && "$pic_url" != *"$RIP_ARTIST_IMAGE_PLACEHOLDER_MD5"* ]]; then
    if "$curl_bin" -sfL -o "$out" "$pic_url" 2>/dev/null && [[ -s "$out" ]]; then
      # The URL check is NOT enough: Deezer also serves placeholder ART
      # (grey silhouette) under normal per-artist URL hashes — one shipped
      # as a real artist.jpg live 2026-08-21 (The Black Piper). Digest the
      # downloaded BYTES against the known-placeholder denylist; a match
      # falls through to the Wikidata chain like the URL reject does.
      # Denylist entries collected live; extend when a new variant ships:
      #   3a0adf20… grey silhouette (1000x1000)   cf0b6a52… empty-MD5 URL's bytes
      local got_md5
      got_md5="$(md5 -q "$out" 2>/dev/null)"
      if [[ -z "$got_md5" || " ${RIP_DEEZER_PLACEHOLDER_FILE_MD5S:-3a0adf20e5abdafa2c1f954ca4537f36 cf0b6a5247e606f67470140451774cb5} " != *" $got_md5 "* ]]; then
        return 0
      fi
      print -r -- "rip: Deezer served placeholder art for $artist — trying the fallback chain"
    fi
    rm -f -- "$out"
  fi
  # Fallback: MusicBrainz artist search → url-rels → Wikidata P18 → Commons.
  local mbid
  mbid="$(rip::_mb_call "$curl_bin" '(.artists // [])[0].id // empty' \
      -sf -A 'fleet-rip/2.0' -G "$mb/artist/" \
      --data-urlencode "query=artist:\"$artist\"" \
      --data-urlencode fmt=json --data-urlencode limit=1)"
  [[ -n "$mbid" ]] || return 1
  local resource wikidata_id
  resource="$(rip::_mb_call "$curl_bin" \
      '[(.relations // [])[] | select((.url.resource // "") | test("wikidata\\.org"))][0].url.resource // empty' \
      -sf -A 'fleet-rip/2.0' "$mb/artist/$mbid?inc=url-rels&fmt=json")"
  wikidata_id="${resource##*/}"
  [[ -n "$wikidata_id" ]] || return 1
  local filename
  filename="$("$curl_bin" -sf -G "$wikidata/w/api.php" \
      --data-urlencode action=wbgetclaims \
      --data-urlencode "entity=$wikidata_id" \
      --data-urlencode property=P18 \
      --data-urlencode format=json 2>/dev/null \
    | jq -r '(.claims.P18 // [])[0].mainsnak.datavalue.value // empty')"
  [[ -n "$filename" ]] || return 1
  local encoded; encoded="$(jq -rn --arg s "$filename" '$s|@uri')"
  "$curl_bin" -sfL -o "$out" "$commons/wiki/Special:FilePath/$encoded?width=1000" 2>/dev/null \
    && [[ -s "$out" ]] && return 0
  rm -f -- "$out"
  return 1
}

# rip::_ensure_artist_image <src> <artist_reldir> <artist> <listfile> —
# idempotent per-artist image: skip the fetch if the image already exists
# locally OR on the server; a failed/unknown remote check also skips the
# fetch (never block, never refetch blindly). On any local file (freshly
# fetched, or already sitting there — the "local but not remote" edge),
# ensure it's on the push list so it ships and is cleaned this run.
# Best-effort: a total miss just logs and returns — never fails the push.
rip::_ensure_artist_image() {
  local src="$1" artist_rel="$2" artist="$3" listfile="$4"
  local out="$src/$artist_rel/artist.jpg"
  if [[ ! -s "$out" ]]; then
    local remote_rc
    rip::_remote_has_artist_image "$artist_rel"
    remote_rc=$?
    case $remote_rc in
      0) return 0 ;;   # server already has it
      1) ;;             # confirmed absent — proceed to fetch
      *)
        print -r -- "rip: artist image remote check unreachable — skipping fetch this run: $artist"
        return 0 ;;
    esac
    if ! rip::_fetch_artist_image "$artist" "$out"; then
      print -r -- "rip: no artist image found — $artist"
      return 0
    fi
  fi
  grep -qxF -- "$artist_rel/artist.jpg" "$listfile" || print -r -- "$artist_rel/artist.jpg" >> "$listfile"
  return 0
}

rip::_fetch_lyrics() {
  local artist="$1" album="$2" title="$3" dur="$4"
  local curl_bin="${RIP_CURL_BIN:-curl}"
  local lrclib="${RIP_LRCLIB_URL:-https://lrclib.net}"
  local json
  json="$("$curl_bin" -sf -A 'fleet-rip/2.0' -G "$lrclib/api/get" \
      --data-urlencode "artist_name=$artist" \
      --data-urlencode "track_name=$title" \
      --data-urlencode "album_name=$album" \
      --data-urlencode "duration=$dur" 2>/dev/null)" || return 1
  local lyr
  lyr="$(jq -r '.syncedLyrics // .plainLyrics // empty' <<<"$json")"
  [[ -n "$lyr" && "$lyr" != null ]] || return 1
  print -r -- "$lyr"
}

# rip::_enrich_music <src> <listfile> — per album dir holding listed .flac
# files: embed cover art into each track (+ cover.jpg beside them, appended
# to the list so it ships THIS run), embed LYRICS per track, and (once per
# unique artist touched this run) fetch a per-artist artist.jpg into the
# artist's staging dir, appended to the list the same way. rc 1 if any
# sub-step failed (caller logs and pushes anyway) — the artist-image step
# itself is pure best-effort and never contributes to that rc (a fetch miss
# just logs and moves on; see rip::_ensure_artist_image).
rip::_enrich_music() {
  setopt localoptions noerrexit nopipefail
  local src="$1" listfile="$2"
  local mf="${RIP_METAFLAC_BIN:-metaflac}"
  local rel adir failed=0
  # Every bare (no `=value`) `local name` below is declared EXACTLY ONCE
  # here, outside the per-album loop — never re-declared bare inside it.
  # zsh prints "name=value" to STDOUT when `local name` (no assignment)
  # re-declares a variable that's ALREADY local in this scope with a value
  # set — confirmed across stock zsh 5.9 and this fleet's zsh build alike,
  # live-caught 2026-08-20 in review. A bare `local` INSIDE a loop that
  # runs more than once (any multi-album push) re-declares on every
  # iteration after the first, leaking every one of these variables'
  # previous-album leftover values as bare "name=value" stdout lines (the
  # pre-existing `rel2` had this latent bug too, dormant only because no
  # multi-album test happened to run without a faked metaflac). `local
  # name=value` (WITH an assignment, e.g. `abs`/`flacs`/`cover` below,
  # still declared per-iteration) is unaffected — the print only fires for
  # a bare re-declaration.
  local rel2 meta artist album year cover_remote_rc artist_rel f tmeta title dur lyr
  # Group the LISTED flac relpaths by album dir — deliberately NOT a glob of
  # the album directory. A sibling flac can be mid-write (XLD writing a
  # neighboring track while this one already settled): metaflac's
  # rewrite-and-rename on that sibling would still be live, and probing or
  # embedding into it here could send its remaining writes into an unlinked
  # inode — the truncated file then settles, ships, self-verifies clean, and
  # is deleted locally, destroying the only digital copy. Only files the age
  # gate already admitted into <listfile> may be touched. Values are
  # newline-joined relpaths (not space-joined: filenames carry spaces).
  local -A album_files=()
  # Artists whose per-artist image step has already run THIS invocation —
  # dedup across every album touched this run (a multi-album session for
  # the same artist must only fetch once). Keyed by the artist's staging
  # dir relative to $src (the album dir's parent), derived from the SAME
  # listfile-based album map above — never a directory glob, same
  # discipline as album_files itself.
  local -A artist_seen=()
  while IFS= read -r rel; do
    [[ "$rel" == *.flac ]] || continue
    adir="${rel:h}"
    # ${...:-} guards the unset-key read: the real bins source this under
    # `set -u`, and a plain ${album_files[$adir]} on a key not yet seen is
    # a hard "parameter not set" error there (not merely empty).
    album_files[$adir]="${album_files[$adir]:-}$rel"$'\n'
  done < "$listfile"
  for adir in ${(k)album_files}; do
    local abs="$src/$adir"
    local -a flacs=()
    while IFS= read -r rel2; do
      [[ -n "$rel2" ]] && flacs+=("$src/$rel2")
    done <<< "${album_files[$adir]}"
    (( ${#flacs} )) || continue
    meta="$(rip::_track_meta "${flacs[1]}")"
    artist="${meta%%$'\t'*}"
    album="$(print -r -- "$meta" | cut -f2)"
    year="$(print -r -- "$meta" | cut -f5)"
    # cover: fetch once per album, embed where absent, ship cover.jpg.
    #
    # Server check FIRST (round 4, live case: the hand-corrected "MTV ao
    # Vivo"): without it, a future re-rip of an art-less album would
    # refetch and rsync-overwrite a curated server cover. Mirrors the
    # artist.jpg tri-state check exactly (rip::_remote_has_file): 0 server
    # already has one → skip the ENTIRE cover step this run, INCLUDING the
    # per-track embed loop below (simplest consistent rule — no export, no
    # fetch, no embeds; whatever's on the server stands; logged once).
    # 2/unreachable → same fail-safe: skip entirely rather than guess. Only
    # rc 1 (confirmed absent) proceeds to the embedded-first / external
    # chain below. Skipped outright when cover.jpg is already sitting here
    # locally (multi-run leftover) — no need to ask the server at all.
    #
    # Source priority once we DO proceed: an embedded PICTURE block wins
    # over any external fetch — XLD matched it against the actual disc, so
    # it's the most trustworthy source there is — checked across EVERY
    # listed track in the album (not just the first: find/listfile order
    # is arbitrary, and a partially-embedded or partially-settled album
    # whose first-enumerated track happens to be art-less must not bury a
    # later track's correct embedded art under a wrong external fetch;
    # live-caught 2026-08-20 in review). The first listed track (in
    # enumeration order) that carries a PICTURE block wins; only when NONE
    # of them do does the external MB/CAA→iTunes chain run (which can
    # itself be fooled by an ambiguous title — live-bitten 2026-08-20:
    # "MTV ao Vivo" matched the wrong release — and Navidrome's default
    # CoverArtPriority puts cover.* ABOVE embedded art, so a wrong external
    # fetch would win the display even though per-track idempotency
    # correctly left any good embedded art alone).
    local cover="$abs/cover.jpg" have_cover=0
    [[ -s "$cover" ]] && have_cover=1
    if (( ! have_cover )); then
      rip::_remote_has_file "music/$adir/cover.jpg"
      cover_remote_rc=$?
      case $cover_remote_rc in
        0) print -r -- "rip: cover — server already has $adir/cover.jpg, skipping this run: $artist / $album" ;;
        1) ;;   # confirmed absent — proceed below
        *) print -r -- "rip: cover remote check unreachable — skipping this run: $artist / $album" ;;
      esac
      if (( cover_remote_rc == 1 )); then
        for f in "${flacs[@]}"; do
          [[ -n "$("$mf" --list --block-type=PICTURE "$f" 2>/dev/null)" ]] || continue
          "$mf" --export-picture-to="$cover" "$f" 2>/dev/null \
            && [[ -s "$cover" ]] && have_cover=1
          (( have_cover )) && break
        done
        if (( ! have_cover )) && [[ -n "$artist" && -n "$album" ]]; then
          rip::_fetch_cover "$artist" "$album" "$cover" "$year" && have_cover=1 || failed=1
        fi
      fi
    fi
    if (( have_cover )); then
      grep -qxF -- "$adir/cover.jpg" "$listfile" || print -r -- "$adir/cover.jpg" >> "$listfile"
      for f in "${flacs[@]}"; do
        [[ -n "$("$mf" --list --block-type=PICTURE "$f" 2>/dev/null)" ]] && continue
        "$mf" --import-picture-from="$cover" "$f" 2>/dev/null || failed=1
      done
    fi
    # lyrics: per track
    for f in "${flacs[@]}"; do
      [[ -n "$("$mf" --show-tag=LYRICS "$f" 2>/dev/null)" ]] && continue
      tmeta="$(rip::_track_meta "$f")"
      title="$(print -r -- "$tmeta" | cut -f3)"
      dur="$(print -r -- "$tmeta" | cut -f4)"
      [[ -n "$title" ]] || continue
      if lyr="$(rip::_fetch_lyrics "$artist" "$album" "$title" "$dur")"; then
        print -r -- "$lyr" | "$mf" --set-tag-from-file=LYRICS=/dev/stdin "$f" 2>/dev/null || failed=1
      else
        print -r -- "rip: no lyrics found — $artist / $title"
      fi
    done
    # artist image: once per unique artist dir touched this run — the
    # artist staging dir is the album dir's PARENT ($src/<Artist>).
    artist_rel="${adir:h}"
    if [[ -n "$artist" && -z "${artist_seen[$artist_rel]:-}" ]]; then
      artist_seen[$artist_rel]=1
      rip::_ensure_artist_image "$src" "$artist_rel" "$artist" "$listfile"
    fi
  done
  (( failed )) && { log_error "rip: enrich pass had failures (see above)"; return 1 }
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
  # DVDs are routinely interlaced (480i); without this, combing bakes into
  # the encode (seen live 2026-08-19 on a concert disc). comb-detect makes
  # decomb a no-op on progressive content, so this is safe everywhere.
  --comb-detect --decomb
  --all-audio -E copy
  --audio-copy-mask aac,ac3,eac3,dts,dtshd,truehd,mp3,flac
  --audio-fallback ca_aac
  --all-subtitles --subtitle-default=none
)

rip::_check_title() {
  case "$1" in
    "" ) log_error "rip: empty title"; return 2 ;;
    */*) log_error "rip: title may not contain a slash: $1"; return 2 ;;
    # A bare "." or ".." composes as a path segment ($staging/movies/<title>
    # or …/movies/<title>/extras): "." is a no-op segment (harmless but
    # meaningless as a title) and ".." walks back up a level — a title of
    # ".." makes $staging/movies/../extras, escaping the movies/ subtree
    # entirely. Reject both outright rather than let either compose.
    . | ..) log_error "rip: title may not be . or ..: $1"; return 2 ;;
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
  rip::_load_jobs || true # see rip::push_worker: sidecar writes need job.zsh in-process
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

  # Progress composition: this worker may itself run inside an outer band
  # (rip-disc gives it 40–100). Encode takes the first 85% OF THE BAND,
  # push the rest — identical to the old hardcoded 0–85/85–100 when no
  # outer band is set.
  local band_base="${RIP_PROGRESS_BASE:-0}" band_span="${RIP_PROGRESS_SPAN:-100}"
  local enc_span=$(( band_span * 85 / 100 ))

  RIP_PROGRESS_BASE=$band_base RIP_PROGRESS_SPAN=$band_span \
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
  # pty wrap: see rip::_hb_dvd — piped HandBrake block-buffers progress
  # into minute-apart bursts; a pty keeps the sidecar ticking steadily.
  # -F is load-bearing: without it macOS script(1) batches its own
  # passthrough (observed live 2026-08-21: sidecar epochs 30-45s apart
  # mid-encode, capsule stall-flickering — the pty fixed HandBrake's
  # buffering only for script to reintroduce its own).
  local -a pty_wrap=(${=RIP_PTY_WRAP-script -q -F /dev/null})
  "${pty_wrap[@]}" "$hb_bin" "${RIP_HB_ARGS[@]}" -i "$input" -o "$out_tmp" 2>&1 \
    | LC_ALL=C tr '\r' '\n' \
    | while IFS= read -r line; do
        case "$line" in
          *Encoding:*%*)
            pct="${line%\%*}"; pct="${pct##*, }"; pct="${pct%%.*}"; pct="${pct// /}"
            [[ "$pct" == <-> ]] \
              && RIP_PROGRESS_BASE=$band_base RIP_PROGRESS_SPAN=$enc_span \
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

  RIP_PUSH_MIN_AGE_S=0 \
  RIP_PROGRESS_BASE=$(( band_base + enc_span )) \
  RIP_PROGRESS_SPAN=$(( band_span - enc_span )) \
  rip::push_worker movies || return $?

  rm -f -- "$input"
  RIP_PROGRESS_BASE=$band_base RIP_PROGRESS_SPAN=$band_span \
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

# --- disc: makemkvcon rip → pipeline, one capsule ---------------------------

# rip::disc_worker <title> — the auto-rip body (UX v2). Scans disc:0,
# picks the LONGEST title (the movie heuristic; MakeMKV GUI → intermediate/
# is the fallback for discs where that guess is wrong), rips it losslessly
# into .work/autorip/ (unwatched, unpushed — same invariant as the encode
# temp), then chains the pipeline stages under the 40–100 band. The drive
# is free the moment the rip stage ends.
rip::disc_worker() {
  setopt localoptions noerrexit nopipefail
  rip::_load_jobs || true # see rip::push_worker: sidecar writes need job.zsh in-process
  local title="$1"
  rip::_check_title "$title" || return 2
  local mkc="${RIP_MAKEMKVCON_BIN:-/Applications/MakeMKV.app/Contents/MacOS/makemkvcon}"
  local rip_dir; rip_dir="$(rip::staging_root)/.work/autorip"
  rm -rf -- "$rip_dir" && mkdir -p "$rip_dir"

  # Longest title: TINFO:<idx>,9,0,"H:MM:SS" is the duration attribute.
  # Single-pass awk (not a pipe-into-`read` chain — that shape runs each
  # stage in its own subshell in zsh, which is a known footgun for getting
  # a scalar back out): split on `:`, `,`, `"` so the quoted "H:MM:SS"
  # duration and the leading TINFO:<idx>,9,0, header share one delimiter
  # set, then track the max in END and print just the winning index.
  local best_idx
  best_idx="$("$mkc" -r info disc:0 2>/dev/null | awk -F'[:,"]' '
    /^TINFO:[0-9]+,9,0,/ {
      idx = $2
      secs = ($6 + 0) * 3600 + ($7 + 0) * 60 + ($8 + 0)
      if (best_idx == "" || secs > best_secs) { best_secs = secs; best_idx = idx }
    }
    END { print best_idx }
  ')"
  [[ -n "$best_idx" ]] || { log_error "rip: disc scan found no titles"; rm -rf -- "$rip_dir"; return 1 }

  rip::_progress 0 "ripping disc — $title"
  local cur total rest
  # PTY WRAP (live-bitten 2026-08-20): real makemkvcon block-buffers stdout
  # once it's piped instead of writing to a terminal, so the loop below saw
  # ZERO PRGV lines for the whole rip on a real DVD (the test fake is
  # line-buffered by default and never caught this). `script -q /dev/null`
  # gives it a pty, which forces line buffering back on — verified on this
  # box that `script -q /dev/null` both allocates its own pty even fully
  # detached from any controlling terminal (setsid-equivalent) AND
  # propagates the wrapped command's exit status unchanged (`script -q
  # /dev/null sh -c 'exit 7'` → rc 7). RIP_PTY_WRAP is the seam: default
  # the real wrapper, empty in tests — the fake harness doesn't need a pty
  # (it isn't buffered), and shellspec's own sandboxing has no reason to
  # fight a real `script` invocation on every run.
  #
  # A pty round-trip has two side effects the parse below has to tolerate:
  # ONLCR turns every line's trailing \n into \r\n (stripped wholesale with
  # `tr -d '\r'` rather than trimmed per-line, since a source line could in
  # principle carry an embedded \r of its own), and the pty's own line
  # discipline prepends a few literal echo/erase bytes (observed: literal
  # "^D" + two backspaces) to the very first line of output — matched with
  # `*PRGV:*` instead of an anchored `PRGV:*` so that garbage prefix can
  # never suppress the first real progress update.
  local -a pty_wrap=(${=RIP_PTY_WRAP-script -q -F /dev/null})
  "${pty_wrap[@]}" "$mkc" -r --progress=-same mkv disc:0 "$best_idx" "$rip_dir" 2>&1 \
    | LC_ALL=C tr -d '\r' \
    | while IFS= read -r line; do
        case "$line" in
          *PRGV:*)
            rest="${line#*PRGV:}"; total="${rest##*,}"; cur="${rest%%,*}"
            [[ "$cur" == <-> && "$total" == <1-> ]] \
              && RIP_PROGRESS_BASE=0 RIP_PROGRESS_SPAN=40 \
                 rip::_progress $(( cur * 100 / total )) "ripping disc — $title"
            ;;
        esac
      done
  local rc=$pipestatus[1]
  local -a ripped=("$rip_dir"/*.mkv(N))
  if (( rc != 0 )) || (( ${#ripped} == 0 )); then
    rm -rf -- "$rip_dir"
    log_error "rip: disc rip failed (rc=$rc, files=${#ripped}) — nothing kept"
    return $(( rc ? rc : 1 ))
  fi

  RIP_PROGRESS_BASE=40 RIP_PROGRESS_SPAN=60 rip::pipeline_worker "${ripped[1]}" "$title"
  rc=$?
  # pipeline success already rm'd the input; sweep the dir either way
  # (failure keeps the encode-stage rules; the RIP itself is cheap to redo
  # from the disc, so autorip debris never outlives the job)
  rm -rf -- "$rip_dir"
  return $rc
}

# rip::disc_enqueue <title> — one heavy job per disc (parallelism 1 also
# serializes drive access, which is physical anyway).
rip::disc_enqueue() {
  local title="$1"
  rip::_check_title "$title" || return 2
  rip::_load_jobs || { log_error "rip: job runner unavailable"; return 1 }
  job::start --group heavy --title "rip: $title" --icon "$RIP_JOB_ICON" \
    -- "$RIP_BIN_DIR/rip-disc" --worker "$title"
}

# --- extra: one DVD extra, encoded DIRECT from the disc ---------------------

# rip::_dvd_volume — the mounted DVD's mount point: the first /Volumes/*
# entry holding a VIDEO_TS dir (the ripper module's own disc-detection
# test, mirrored here so rip-extra recognizes the same discs it does).
# RIP_DVD_VOLUME is the seam: set, it's used directly (still required to
# hold a VIDEO_TS dir — the hermetic tests build a real one under a sandbox
# dir, so this stays a faithful stand-in rather than a rubber stamp),
# bypassing the /Volumes scan entirely. Prints the volume path; empty + rc
# 1 when nothing matches.
rip::_dvd_volume() {
  if [[ -n "${RIP_DVD_VOLUME:-}" ]]; then
    [[ -d "$RIP_DVD_VOLUME/VIDEO_TS" ]] || return 1
    print -r -- "$RIP_DVD_VOLUME"
    return 0
  fi
  local vol
  for vol in /Volumes/*(N); do
    [[ -d "$vol/VIDEO_TS" ]] && { print -r -- "$vol"; return 0 }
  done
  return 1
}

# rip::_hb_dvd <hb_bin> <args…> — run HandBrakeCLI directly against the
# optical drive (a --scan, or a -t <n> encode) with
# DYLD_FALLBACK_LIBRARY_PATH exported ahead of exec, inside a bare `sh -c`.
# The export has to happen INSIDE the child `sh -c` — not in this
# function's own environment before exec'ing HandBrakeCLI directly —
# because SIP strips DYLD_* from the environment of protected parent
# processes; only a freshly-spawned, unprotected `sh -c` can carry it
# through to HandBrakeCLI. libdvdcss itself lives at /opt/homebrew/lib
# (brew). This is the FIRST use of this technique anywhere in this repo —
# no disc worker or any other code here does this, despite what an earlier
# version of this comment claimed — and it has NOT yet been exercised
# against a real disc; manual live-disc verification is an outstanding
# follow-up. The actual precedent is the runbook (fleet repo,
# runbooks/rip-media.md), which documents this same CLI+DYLD fact for
# manual/watcher-down use. Separately: pueue snapshots the ENQUEUING
# process's environment (not a login shell's), and a hand-run `rip-extra
# --list` straight from Hammerspoon has the same gap, so HandBrakeCLI's own
# dylibs go unfound on the default search path without this either way.
# RIP_DYLD_FALLBACK_PATH is the seam (defaults to Homebrew's own lib dir);
# the fake HandBrakeCLI in tests ignores the environment entirely, so no
# test needs to touch it. Args ride through sh -c's own positional "$@"
# mechanism rather than being string-interpolated into the script text, so
# a volume path or extra name containing spaces or shell metacharacters is
# safe.
rip::_hb_dvd() {
  local hb_bin="$1"; shift
  local dyld="${RIP_DYLD_FALLBACK_PATH:-/opt/homebrew/lib}"
  # pty wrap (same seam and reason as the disc worker's makemkvcon):
  # HandBrakeCLI block-buffers progress into a pipe — updates arrived in
  # ~4KB bursts a minute apart, tripping the HUD's stall rendering between
  # them (live 2026-08-20: capsule grey at 10% with a 46s-stale sidecar).
  # Under a pty HB line-buffers and the sidecar ticks steadily. The scan
  # path rides through harmlessly (its output is parsed after exit).
  local -a pty_wrap=(${=RIP_PTY_WRAP-script -q -F /dev/null})
  "${pty_wrap[@]}" \
    sh -c 'export DYLD_FALLBACK_LIBRARY_PATH="$1"; shift; exec "$@"' \
    _ "$dyld" "$hb_bin" "$@"
}

# rip::_dvd_scan <volume> — HandBrakeCLI's own title scan (`-t 0` scans
# every title without encoding anything), reduced to one `title N:
# duration` line per title. Real scan output nests each title's attributes
# under a "+ title N:" header, one of which is "+ duration: H:MM:SS"; the
# awk below pairs each duration with the title header most recently seen
# (single-pass, no intermediate array — same discipline as the disc
# worker's TINFO parse).
rip::_dvd_scan() {
  local vol="$1"
  local hb_bin="${RIP_HANDBRAKE_BIN:-HandBrakeCLI}"
  rip::_hb_dvd "$hb_bin" -i "$vol" --scan -t 0 2>&1 | awk '
    /\+ title [0-9]+:/ {
      match($0, /[0-9]+/); n = substr($0, RSTART, RLENGTH); next
    }
    /\+ duration:/ {
      if (n != "") {
        d = $0
        sub(/^.*duration: */, "", d)
        print "title " n ": " d
        n = ""
      }
    }
  '
}

# rip::extra_list — the `rip-extra --list` body: locate the mounted DVD and
# print its scan. No volume mounted is an error (rc 1), not a silent
# no-op — there is nothing useful to list.
rip::extra_list() {
  local vol
  vol="$(rip::_dvd_volume)" || { log_error "rip: no DVD volume mounted"; return 1 }
  rip::_dvd_scan "$vol"
}

# rip::_check_title_no <n> — title numbers come straight off `rip-extra
# --list`'s own output, but are still hand-typed by the operator afterward;
# reject anything that isn't a plain non-negative integer.
rip::_check_title_no() {
  [[ "$1" == <-> ]] && return 0
  log_error "rip: title number must be numeric: $1"
  return 2
}

# rip::_check_extra_name <name> — same shape of rule as rip::_check_title
# (non-empty, no slash — it becomes a filename component), kept as its own
# function since the error message names "extra name" rather than "title".
rip::_check_extra_name() {
  case "$1" in
    "") log_error "rip: empty extra name"; return 2 ;;
    */*) log_error "rip: extra name may not contain a slash: $1"; return 2 ;;
    # Same defense-in-depth as rip::_check_title, for consistency: a name
    # of "." or ".." isn't actually a traversal here (the ".mkv" suffix
    # composes it into "..mkv" or "...mkv" respectively — harmless garbage,
    # not a path escape), but rejecting it outright is simpler than
    # explaining why it's fine, and it matches the title rule's shape
    # exactly.
    . | ..) log_error "rip: extra name may not be . or ..: $1"; return 2 ;;
  esac
  return 0
}

# rip::extra_worker <title-no> <movie> <name> — the enqueued body: encode
# title <title-no> DIRECT from the mounted disc (no MakeMKV intermediate —
# an extra is short enough that a lossless rip-then-encode round trip buys
# nothing), publish it into Jellyfin's extras/ convention
# (movies/<movie>/extras/<name>.mkv), and push it. Progress composition
# mirrors rip::pipeline_worker: encode owns 0-85 of the capsule, push owns
# 85-100 (both bands are fixed here, unlike the pipeline's outer-band
# rescale — rip-extra is never itself composed inside another worker's
# band). Cleanup rules mirror the pipeline's: encode failure removes the
# temp and keeps nothing; a push/verify failure leaves the ALREADY-
# PUBLISHED extra on disk for a plain `rip-push movies` retry.
rip::extra_worker() {
  # See rip::pipeline_worker's identical comment: the real rip-extra bin
  # sources this under `set -eu -o pipefail`, and this function's own
  # HandBrakeCLI pipeline needs to own its error handling (rc capture +
  # cleanup) regardless of the caller's options.
  setopt localoptions noerrexit nopipefail
  rip::_load_jobs || true # see rip::push_worker: sidecar writes need job.zsh in-process
  local title_no="$1" movie="$2" name="$3"
  rip::_check_title_no "$title_no" || return 2
  rip::_check_title "$movie" || return 2
  rip::_check_extra_name "$name" || return 2

  local vol
  vol="$(rip::_dvd_volume)" || { log_error "rip: no DVD volume mounted"; return 1 }

  # SERVER IDEMPOTENCY FIRST (operator's rule): a re-run against an extra
  # the server already has must touch nothing — no disc access, no encode.
  local relpath="movies/$movie/extras/$name.mkv"
  local remote_rc
  rip::_remote_has_file "$relpath"
  remote_rc=$?
  if (( remote_rc == 0 )); then
    print -r -- "rip: server already has $relpath — nothing to do"
    return 0
  fi

  local hb_bin="${RIP_HANDBRAKE_BIN:-HandBrakeCLI}"
  # Same kill-proof-by-construction shape as rip::pipeline_worker: the
  # encoder writes into .work/ and is only renamed into movies/ once it has
  # exited 0, so a killed worker (plain `pueue kill` sends SIGKILL on pueue
  # 4.x — untrappable) leaves debris only where nothing ships from.
  local work_dir out_tmp
  work_dir="$(rip::staging_root)/.work"
  out_tmp="$work_dir/.extra-encode.mkv"
  mkdir -p "$work_dir"
  rm -f -- "$out_tmp"

  rip::_progress 0 "encoding extra — $name"
  trap 'rm -f -- "$out_tmp"
        log_error "rip: cancelled during extra encode — partial removed: $movie — $name"
        exit 130' TERM INT
  local line pct
  # LC_ALL=C on every tr in these parse pipes (this file, all sites): the
  # streams are raw bytes, and under a UTF-8 locale macOS tr ABORTS on an
  # invalid sequence — the collapsing pipe then SIGPIPEs the still-writing
  # encoder, killing a good encode at rc=141 (live: Elvis TTWII title 5,
  # 2026-08-20; regression-pinned in tests/rip-extra_spec.sh).
  rip::_hb_dvd "$hb_bin" -t "$title_no" -i "$vol" "${RIP_HB_ARGS[@]}" -o "$out_tmp" 2>&1 \
    | LC_ALL=C tr '\r' '\n' \
    | while IFS= read -r line; do
        case "$line" in
          *Encoding:*%*)
            pct="${line%\%*}"; pct="${pct##*, }"; pct="${pct%%.*}"; pct="${pct// /}"
            [[ "$pct" == <-> ]] \
              && RIP_PROGRESS_BASE=0 RIP_PROGRESS_SPAN=85 \
                 rip::_progress "$pct" "encoding extra — $name"
            ;;
        esac
      done
  local rc=$pipestatus[1]
  if (( rc != 0 )); then
    rm -f -- "$out_tmp"
    log_error "rip: extra encode failed (rc=$rc) — nothing kept: $movie — $name"
    trap - TERM INT   # $out_tmp goes out of scope with this return
    return $rc
  fi
  # The encode is complete: from here a cancel must LEAVE it alone.
  trap - TERM INT

  local out_dir out
  out_dir="$(rip::staging_root)/movies/$movie/extras"
  out="$out_dir/$name.mkv"
  if ! { mkdir -p "$out_dir" && mv -f -- "$out_tmp" "$out" }; then
    rm -f -- "$out_tmp"
    rmdir -- "$out_dir" 2>/dev/null || :
    log_error "rip: could not publish the extra to $out"
    return 1
  fi

  RIP_PUSH_MIN_AGE_S=0 RIP_PROGRESS_BASE=85 RIP_PROGRESS_SPAN=15 \
    rip::push_worker movies
  # Push/verify failure: the published extra stays exactly where it is —
  # the standard cleanup rule (see the pipeline's identical contract) — for
  # a plain `rip-push movies` retry with no re-encode.
}

# rip::extra_enqueue <title-no> <movie> <name> — one heavy-group job (same
# group as the pipeline/disc jobs: two concurrent x265 encodes would thrash
# the laptop, and only one disc can be in the drive at a time regardless).
rip::extra_enqueue() {
  local title_no="$1" movie="$2" name="$3"
  rip::_check_title_no "$title_no" || return 2
  rip::_check_title "$movie" || return 2
  rip::_check_extra_name "$name" || return 2
  rip::_load_jobs || { log_error "rip: job runner unavailable"; return 1 }
  job::start --group heavy --title "extra: $movie — $name" --icon "$RIP_JOB_ICON" \
    -- "$RIP_BIN_DIR/rip-extra" --worker "$title_no" "$movie" "$name"
}

# --- session: one disc, one operator-authored plan, one job -----------------
#
# The Rip Session Review panel (hammerspoon modules/ripper/session-dialog.lua)
# is the consent + naming surface for a DVD insert: every title on the disc is
# a row the operator marks Feature / Extra / Skip, the feature carries a TMDB
# pick, each extra a name and an attach target. What comes back is a PLAN, and
# these four functions are its whole server side:
#
#   rip::session_scan            rip-disc --scan            → the panel's rows
#   rip::session_have <movie>    rip-disc --have <movie>    → auto-extras flip
#   rip::session_enqueue <plan>  rip-disc --session <plan>  → one heavy job
#   rip::session_worker <plan>   rip-disc --session-worker  → the job body
#
# ONE SCANNER, ONE NUMBERING (spec, and a standing reviewer warning):
# HandBrake and makemkvcon number a disc's titles DIFFERENTLY, and no mapping
# between them may ever be assumed. The session flow is makemkvcon end to end —
# the scan that fills the panel and the rip that follows read the same
# numbering. `rip-extra` (HandBrake direct-from-disc, HB numbering) stays the
# standalone manual tool and is never mixed into this flow.

# rip::session_scan — `makemkvcon -r info disc:0`, reduced to one JSON line
# per title for the panel:
#   {"no":1,"duration":"2:08:59","seconds":7739,"size":"6.9 GB","bytes":7408345088}
#
# TINFO attributes (MakeMKV's ap_ItemAttributeId enum, the same table the disc
# worker's own `attr 9 = duration` parse rests on): 9 = duration "H:MM:SS",
# 10 = human size string ("6.9 GB"), 11 = size in bytes. Only those three are
# read; every other attribute on the line (2 = name, 27 = source filename, …)
# is ignored, and a title with no duration at all is not a row the panel can
# show, so it is dropped.
#
# The parse is a single-pass awk over `TINFO:<idx>,<attr>,<code>,"<value>"`,
# splitting on POSITION (three commas, then the quoted tail) rather than on a
# comma delimiter — attribute VALUES routinely contain commas ("Trailer,
# Theatrical") and a field-split parse silently mangles them. Same discipline
# as the disc worker's own TINFO awk.
#
# Everything that reaches the JSON is numeric or structural AND is scrubbed to
# a safe character class right here in awk (duration → digits and colons, size
# → alphanumerics, dot and space, bytes → digits or 0), so the printf below
# cannot be handed a quote or a backslash to escape. That is the whole reason
# this emits JSON with printf instead of shelling out to jq.
#
# Runs under the same RIP_PTY_WRAP seam as every other makemkvcon/HandBrake
# invocation here, and pipes through `LC_ALL=C tr -d '\r'` for the pty's own
# ONLCR translation (see the disc worker's long note on both).
#
# rc 1 when nothing parsed — no disc, an unreadable disc, or a drive that
# answered with no titles are all the same thing to the panel: "could not read
# the disc".
rip::session_scan() {
  setopt localoptions noerrexit nopipefail
  local mkc="${RIP_MAKEMKVCON_BIN:-/Applications/MakeMKV.app/Contents/MacOS/makemkvcon}"
  local -a pty_wrap=(${=RIP_PTY_WRAP-script -q -F /dev/null})
  local rows
  rows="$("${pty_wrap[@]}" "$mkc" -r info disc:0 2>/dev/null \
    | LC_ALL=C tr -d '\r' \
    | awk '
      {
        p = index($0, "TINFO:")
        if (p == 0) next
        rest = substr($0, p + 6)
        c = index(rest, ","); if (c == 0) next
        idx = substr(rest, 1, c - 1); rest = substr(rest, c + 1)
        c = index(rest, ","); if (c == 0) next
        attr = substr(rest, 1, c - 1); rest = substr(rest, c + 1)
        c = index(rest, ","); if (c == 0) next
        val = substr(rest, c + 1)
        if (substr(val, 1, 1) == "\"") {
          val = substr(val, 2)
          q = index(val, "\"")
          if (q > 0) val = substr(val, 1, q - 1)
        }
        if (idx !~ /^[0-9]+$/) next
        if (attr == "9") {
          dur[idx] = val
          if (!(idx in seen)) { order[n++] = idx; seen[idx] = 1 }
        } else if (attr == "10") size[idx] = val
        else if (attr == "11") bytes[idx] = val
      }
      END {
        for (i = 0; i < n; i++) {
          k = order[i]
          d = dur[k]; gsub(/[^0-9:]/, "", d)
          if (d == "") continue
          s = (k in size) ? size[k] : ""; gsub(/[^0-9A-Za-z. ]/, "", s)
          b = (k in bytes) ? bytes[k] : ""
          if (b !~ /^[0-9]+$/) b = 0
          m = split(d, t, ":")
          secs = 0
          if (m == 3) secs = t[1] * 3600 + t[2] * 60 + t[3]
          else if (m == 2) secs = t[1] * 60 + t[2]
          else secs = t[1] + 0
          printf "%s\t%s\t%s\t%s\t%s\n", k, d, secs, s, b
        }
      }
    ')"
  local idx dur secs size bytes n=0
  while IFS=$'\t' read -r idx dur secs size bytes; do
    [[ "$idx" == <-> ]] || continue
    printf '{"no":%d,"duration":"%s","seconds":%d,"size":"%s","bytes":%d}\n' \
      "$idx" "$dur" "$secs" "$size" "$bytes"
    n=$(( n + 1 ))
  done <<< "$rows"
  (( n > 0 )) || { log_error "rip: disc scan found no titles"; return 1 }
  return 0
}

# rip::session_have <movie> — does the server already hold this movie? The
# disc cannot say which film it is, but the operator's TMDB pick can, so the
# panel asks the moment a movie is picked and flips the feature row to Skip
# when the answer is yes (the extras then ride along to a movie the server
# already has — the auto-extras path).
#
# Prints nothing; the ANSWER is the exit code, straight through from
# rip::_remote_has_file: 0 have, 1 confirmed absent, 2 unknown (the check
# itself could not run). The panel treats 1 and 2 identically — silence — so
# an unreachable cantina can never mark a disc as already-owned.
rip::session_have() {
  local movie="$1"
  rip::_check_title "$movie" || return 2
  rip::_remote_has_file "movies/$movie/$movie.mkv"
}

# rip::session_library — the movies the server already holds, one directory
# name per line ("Elvis TTWII (1970)"), in `ls` order.
#
# The panel's attach chip is what points an EXTRA at a movie, and on an
# extras-only disc (the feature is already in the library, so there is no
# Feature row and no TMDB pick to inherit) that chip is the ONLY way to name
# an attach target — with no list to open, the session cannot be started at
# all. So the list has to come from the one place that knows it: the server's
# own movies/ directory. Jellyfin's layout is one directory per movie and
# nothing else there, so `ls -1` IS the library.
#
# Same host/path split, ${(q)} quoting and BatchMode/ConnectTimeout as
# rip::_remote_has_file (see its long note: an apostrophe in a movie title
# and a network black hole are both routine here), and the same tri-state
# honesty:
#   rc 0  the listing ran — the lines printed are the library, and NO lines
#         is a real answer ("the server has no movies yet")
#   rc 2  the listing could not run at all (host unreachable, no movies/
#         directory) — prints nothing, and the panel says so rather than
#         showing an empty picker that looks like an empty library.
rip::session_library() {
  setopt localoptions noerrexit nopipefail
  local base; base="$(rip::remote_base)"
  local out rc line
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    local rdir="$rpath/movies"
    out="$("$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 \
      "$host" "ls -1 -- ${(q)rdir}" 2>/dev/null)"
    rc=$?
  else
    # No ':' — the hermetic tests' plain local dir.
    out="$(ls -1 -- "$base/movies" 2>/dev/null)"
    rc=$?
  fi
  (( rc == 0 )) || { log_error "rip: could not list the movie library on the server"; return 2 }
  # A here-string over an empty capture still feeds one empty line; drop it,
  # so "reachable but empty" prints nothing at all.
  while IFS= read -r line; do
    [[ -n "$line" ]] && print -r -- "$line"
  done <<< "$out"
  return 0
}

# rip::_plan_extras <plan.json> — the plan's extras as
# "<no>\t<name>\t<attachTo>" lines. `.extras` is defended twice: absent, null
# and (the real hazard) an EMPTY LIST are all the same thing here, because
# hs.json.encode cannot tell an empty Lua list from an empty Lua map and emits
# "{}" for both — jq would abort trying to iterate that object.
rip::_plan_extras() {
  jq -r '(if (.extras | type) == "array" then .extras else [] end)[]
         | [((.no // "") | tostring), (.name // ""), (.attachTo // "")]
         | @tsv' "$1" 2>/dev/null
}

# rip::_validate_plan <plan.json> — defense in depth. The panel already gates
# every one of these (its nameValid() is a deliberate mirror of
# rip::_check_extra_name, and Start stays disabled until the plan is clean),
# but a plan is a FILE on disk naming path components under the staging root,
# and it arrives here through a queue that outlives the panel. Re-run every
# check, and refuse the whole plan on the first failure — rc 2, exactly like
# the single-title enqueues.
rip::_validate_plan() {
  # The real rip-disc bin sources this under `set -eu -o pipefail`, and the
  # jq calls below legitimately exit non-zero on a malformed plan — this
  # function owns that, the caller must not die of it (same rule the workers
  # state at length).
  setopt localoptions noerrexit nopipefail
  local plan="$1"
  jq -e . "$plan" >/dev/null 2>&1 || { log_error "rip: session plan is not valid JSON: $plan"; return 2 }
  local feat_movie feat_no no name attach rel n=0
  # Every relpath this plan would compose, so a COLLISION can be caught here
  # rather than discovered as a missing rip. Two extras sharing a name and an
  # attach target compose the same movies/<attachTo>/extras/<Name>.mkv; the
  # publish is an `mv -f`, so the second one would quietly overwrite the
  # first and the worker would still exit 0 with a full capsule — an entire
  # rip lost with nothing anywhere saying so (review finding, 2026-08-20).
  # The feature's own path joins the set for completeness; it cannot collide
  # with an extra's by construction, but the rule belongs to the SET of
  # published paths, not to extras specifically.
  local -A composed=()
  feat_movie="$(jq -r '.feature.movie // empty' "$plan")"
  feat_no="$(jq -r '(.feature.no // empty) | tostring' "$plan")"
  if [[ -n "$feat_movie" ]]; then
    rip::_check_title "$feat_movie" || return 2
    rip::_check_title_no "$feat_no" || return 2
    composed["movies/$feat_movie/$feat_movie.mkv"]=1
  fi
  while IFS=$'\t' read -r no name attach; do
    [[ -n "$no$name$attach" ]] || continue
    rip::_check_title_no "$no" || return 2
    rip::_check_extra_name "$name" || return 2
    # The attach target composes into movies/<attachTo>/extras/… exactly like
    # a feature title does, so it gets the title rule, not the name rule.
    rip::_check_title "$attach" || return 2
    rel="movies/$attach/extras/$name.mkv"
    if [[ -n "${composed["$rel"]-}" ]]; then
      log_error "rip: session plan composes the same file twice: $rel"
      return 2
    fi
    composed["$rel"]=1
    n=$(( n + 1 ))
  done < <(rip::_plan_extras "$plan")
  if [[ -z "$feat_movie" ]] && (( n == 0 )); then
    log_error "rip: session plan selects nothing — no feature and no extras"
    return 2
  fi
  return 0
}

# rip::session_enqueue <plan.json> — validate, then ONE heavy-group job for
# the whole session (parallelism 1 also serializes drive access, which is
# physical anyway). Titled after the feature, falling back to the disc's
# volume label for an extras-only session.
rip::session_enqueue() {
  setopt localoptions noerrexit nopipefail
  local plan="$1"
  [[ -f "$plan" ]] || { log_error "rip: no such session plan: $plan"; return 2 }
  rip::_validate_plan "$plan" || return 2

  # The plan the panel hands us is a TEMP file written by Hammerspoon; the
  # job it launches may not run for minutes (the heavy group is serialized)
  # and pueue stores the command LINE, not the file. Copy the plan into a
  # name of this enqueue's own before the path goes on a queue — .work is
  # rip.zsh's scratch area, unwatched and never pushed.
  #
  # The SUBDIRECTORY is load-bearing, not tidiness: ripper/init.lua's
  # sweepWork() unlinks every plain FILE sitting directly in .work at each
  # Hammerspoon start (and reload), which is exactly right for the
  # deterministic encode temps and push stamps — and exactly wrong for a
  # queued plan, whose whole job is to outlive the panel and wait behind a
  # two-hour heavy job. sweepWork skips directories, so a plan under
  # .work/session-plans/ survives a reload; the worker removes its own copy
  # when it has read it (rip::session_worker), which is the only thing that
  # ever reclaims one.
  local work_dir; work_dir="$(rip::staging_root)/.work/session-plans"
  mkdir -p "$work_dir" || { log_error "rip: cannot create $work_dir"; return 1 }
  local queued="$work_dir/session-$$-$RANDOM.json"
  cp -- "$plan" "$queued" || { log_error "rip: cannot stage the session plan at $queued"; return 1 }

  local title
  title="$(jq -r '.feature.movie // .volume // empty' "$plan")"
  [[ -n "$title" ]] || title="disc"

  rip::_load_jobs || { log_error "rip: job runner unavailable"; rm -f -- "$queued"; return 1 }
  job::start --group heavy --title "rip session: $title" --icon "$RIP_JOB_ICON" \
    -- "$RIP_BIN_DIR/rip-disc" --session-worker "$queued"
}

# rip::session_worker <plan.json> — the enqueued body, three phases in one
# capsule:
#
#   0–50   RIP     makemkvcon rips each selected title into .work/session/.
#                  The drive is free the moment this phase ends.
#   50–85  ENCODE  HandBrake encodes each ripped file (RIP_HB_ARGS, from FILE
#                  — the pipeline worker's path) and publishes it by atomic
#                  rename: feature → movies/<Movie>/<Movie>.mkv, extra →
#                  movies/<attachTo>/extras/<Name>.mkv.
#   85–100 PUSH    one rip::push_worker movies for the whole session.
#
# Each band is split evenly across the session's items, so a four-title
# session's capsule advances four times per phase rather than jumping.
#
# FAILURE HONESTY (spec, and the same rules the sibling workers already
# state):
#   * A rip failure is a DISC failure — the drive could not read a title, and
#     the rest of the session is built on the same disc. Abort the whole
#     thing, remove .work/session, propagate the rc. Nothing was published
#     yet, so nothing is stranded.
#   * ONE item's encode failure is that ITEM's failure. Remove its temp, log
#     it, keep going with the rest, and remember the rc — a bad extra must
#     never cost the operator the feature they already waited for.
#   * A publish or push failure keeps the PUBLISHED file exactly where it is,
#     for a plain `rip-push movies` retry with no re-encode.
#   * .work/session is removed on EVERY exit path. The published items are
#     what a retry needs, and they are already keep-for-retry above; the raw
#     rips under .work/session are 8–12 GB that nothing re-reads (a re-push
#     never re-encodes) and that nothing else reclaims — ripper's sweepWork
#     only unlinks plain files in .work and skips directories entirely, so
#     "the next Hammerspoon start will clear it" was never true of this
#     directory (review finding, 2026-08-20).
rip::session_worker() {
  setopt localoptions noerrexit nopipefail
  rip::_load_jobs || true # see rip::push_worker: sidecar writes need job.zsh in-process
  local plan="$1"
  [[ -f "$plan" ]] || { log_error "rip: no such session plan: $plan"; return 2 }
  # This file is the job's OWN copy, staged by rip::session_enqueue under
  # .work/session-plans/ — deliberately out of the startup sweep's reach, so
  # this worker is the only thing that can ever reclaim it. It goes away as
  # soon as it has been read, on every path: a rejected plan leaves its
  # reason in the log (that is the artifact worth keeping), and a plan that
  # parsed has nothing left to say once the arrays below exist.
  if ! rip::_validate_plan "$plan"; then
    rm -f -- "$plan"
    return 2
  fi

  # Items in rip order: the feature first, then the extras as the panel
  # ordered them. Three parallel arrays rather than one array of records —
  # zsh has no struct, and the three are only ever indexed together.
  local -a item_no=() item_rel=() item_label=()
  local feat_movie feat_no no name attach
  feat_movie="$(jq -r '.feature.movie // empty' "$plan")"
  feat_no="$(jq -r '(.feature.no // empty) | tostring' "$plan")"
  if [[ -n "$feat_movie" ]]; then
    item_no+=("$feat_no")
    item_rel+=("movies/$feat_movie/$feat_movie.mkv")
    item_label+=("$feat_movie")
  fi
  while IFS=$'\t' read -r no name attach; do
    [[ "$no" == <-> ]] || continue
    item_no+=("$no")
    item_rel+=("movies/$attach/extras/$name.mkv")
    item_label+=("$attach — $name")
  done < <(rip::_plan_extras "$plan")
  rm -f -- "$plan" # read in full: see the note above rip::_validate_plan's call
  local n=${#item_no}
  (( n > 0 )) || { log_error "rip: session plan selects nothing"; return 2 }

  local mkc="${RIP_MAKEMKVCON_BIN:-/Applications/MakeMKV.app/Contents/MacOS/makemkvcon}"
  local hb_bin="${RIP_HANDBRAKE_BIN:-HandBrakeCLI}"
  local work_dir sess_dir out_tmp
  work_dir="$(rip::staging_root)/.work"
  sess_dir="$work_dir/session"
  # Same kill-proof-by-construction shape as every other encode here: both
  # the ripped titles and the in-flight encode live under .work, which
  # nothing watches and rip-push never ships, so a SIGKILLed worker (plain
  # `pueue kill` on pueue 4.x) can only ever leave debris where debris is
  # harmless. movies/ receives whole files by rename or nothing at all.
  out_tmp="$work_dir/session-encode.mkv"
  mkdir -p "$work_dir" || { log_error "rip: cannot create $work_dir"; return 1 }
  rm -rf -- "$sess_dir"
  mkdir -p "$sess_dir" || { log_error "rip: cannot create $sess_dir"; return 1 }

  local -a pty_wrap=(${=RIP_PTY_WRAP-script -q -F /dev/null})
  # Every bare `local` below is declared ONCE, here, outside the loops: zsh
  # PRINTS "name=value" to stdout when a bare `local name` re-declares a
  # variable that already holds a value in the same scope, so a bare local
  # inside a loop leaks the previous iteration's values as stdout garbage
  # (live-caught in rip::_enrich_music, 2026-08-20 — same rule, same file).
  local i rc base span line rest cur total produced f
  local src rel out out_dir remote_rc pct failed=0 published=0 push_rc=0
  local -a fresh=()

  #--- RIP phase (0–50) ------------------------------------------------------
  # Nothing is published yet, so a cancel here throws the scratch away whole.
  trap 'rm -rf -- "$sess_dir"
        log_error "rip: cancelled during the disc rip — session scratch removed"
        exit 130' TERM INT
  for (( i = 1; i <= n; i++ )); do
    base=$(( 50 * (i - 1) / n ))
    span=$(( 50 * i / n - base ))
    RIP_PROGRESS_BASE=$base RIP_PROGRESS_SPAN=$span \
      rip::_progress 0 "ripping title ${item_no[i]} — ${item_label[i]}"
    # The disc worker's exact makemkvcon idiom: pty wrap (real makemkvcon
    # block-buffers into a pipe and emits NO progress at all otherwise),
    # `LC_ALL=C tr -d '\r'` for the pty's ONLCR translation and for byte
    # safety, and an unanchored *PRGV:* match so the pty's own echo/erase
    # bytes on the first line cannot suppress the first update.
    "${pty_wrap[@]}" "$mkc" -r --progress=-same mkv disc:0 "${item_no[i]}" "$sess_dir" 2>&1 \
      | LC_ALL=C tr -d '\r' \
      | while IFS= read -r line; do
          case "$line" in
            *PRGV:*)
              rest="${line#*PRGV:}"; total="${rest##*,}"; cur="${rest%%,*}"
              [[ "$cur" == <-> && "$total" == <1-> ]] \
                && RIP_PROGRESS_BASE=$base RIP_PROGRESS_SPAN=$span \
                   rip::_progress $(( cur * 100 / total )) "ripping title ${item_no[i]} — ${item_label[i]}"
              ;;
          esac
        done
    rc=$pipestatus[1]
    # MakeMKV names its own output ("title_t01.mkv", or whatever it decides
    # from the disc's metadata) and gives no way to ask what it wrote, so the
    # file is identified positionally — newest first (glob qualifier `om`),
    # skipping anything this loop has already claimed. Because each title is
    # renamed IMMEDIATELY below, there is normally exactly one unclaimed file
    # here and the mtime ordering is belt-and-braces rather than load-bearing.
    fresh=("$sess_dir"/*.mkv(N.om))
    produced=""
    for f in "${fresh[@]}"; do
      [[ "${f:t}" == title-*.mkv ]] && continue
      produced="$f"; break
    done
    if (( rc != 0 )) || [[ -z "$produced" ]]; then
      trap - TERM INT
      rm -rf -- "$sess_dir"
      log_error "rip: session rip failed on title ${item_no[i]} (rc=$rc) — disc unreadable, nothing kept"
      return $(( rc ? rc : 1 ))
    fi
    if ! mv -f -- "$produced" "$sess_dir/title-${item_no[i]}.mkv"; then
      trap - TERM INT
      rm -rf -- "$sess_dir"
      log_error "rip: could not stage the ripped title ${item_no[i]}"
      return 1
    fi
  done
  trap - TERM INT

  #--- ENCODE phase (50–85) --------------------------------------------------
  for (( i = 1; i <= n; i++ )); do
    src="$sess_dir/title-${item_no[i]}.mkv"
    rel="${item_rel[i]}"
    base=$(( 50 + 35 * (i - 1) / n ))
    span=$(( 50 + 35 * i / n - base ))
    # SERVER IDEMPOTENCY PER ITEM, before any encode (the operator's rule,
    # already honored by rip::extra_worker): only a confirmed HAVE (rc 0)
    # skips. rc 2 is "unknown" and must never block work.
    rip::_remote_has_file "$rel"
    remote_rc=$?
    if (( remote_rc == 0 )); then
      print -r -- "rip: server already has $rel — skipping this item"
      continue
    fi
    rm -f -- "$out_tmp"
    RIP_PROGRESS_BASE=$base RIP_PROGRESS_SPAN=$span \
      rip::_progress 0 "encoding — ${item_label[i]}"
    # Scoped to THIS item's encode: items already published are complete and
    # keep-for-retry (the standard rule), so a cancel may only take the temp.
    trap 'rm -f -- "$out_tmp"
          log_error "rip: cancelled during a session encode — partial removed, published items kept"
          exit 130' TERM INT
    "${pty_wrap[@]}" "$hb_bin" "${RIP_HB_ARGS[@]}" -i "$src" -o "$out_tmp" 2>&1 \
      | LC_ALL=C tr '\r' '\n' \
      | while IFS= read -r line; do
          case "$line" in
            *Encoding:*%*)
              pct="${line%\%*}"; pct="${pct##*, }"; pct="${pct%%.*}"; pct="${pct// /}"
              [[ "$pct" == <-> ]] \
                && RIP_PROGRESS_BASE=$base RIP_PROGRESS_SPAN=$span \
                   rip::_progress "$pct" "encoding — ${item_label[i]}"
              ;;
          esac
        done
    rc=$pipestatus[1]
    trap - TERM INT
    if (( rc != 0 )); then
      rm -f -- "$out_tmp"
      log_error "rip: session encode failed (rc=$rc) — item dropped, session continues: ${item_label[i]}"
      failed=1
      continue
    fi
    out="$(rip::staging_root)/$rel"
    out_dir="${out:h}"
    if ! { mkdir -p "$out_dir" && mv -f -- "$out_tmp" "$out" }; then
      rm -f -- "$out_tmp"
      log_error "rip: could not publish $rel — item dropped, session continues"
      failed=1
      continue
    fi
    published=$(( published + 1 ))
  done

  #--- PUSH phase (85–100) ---------------------------------------------------
  if (( published > 0 )); then
    RIP_PUSH_MIN_AGE_S=0 RIP_PROGRESS_BASE=85 RIP_PROGRESS_SPAN=15 \
      rip::push_worker movies
    push_rc=$?
  else
    # Every item was already on the server (or every one failed): an empty
    # rsync job is noise, not work — the same judgement rip::push_enqueue makes.
    print -r -- "rip: session published nothing new — nothing to push"
  fi

  # The scratch goes either way. On success it is spent; on failure it is
  # STILL spent — the retry path is `rip-push movies` over the published
  # files, which never looks at .work/session, and keeping 8–12 GB of raw
  # rips that no code path reads (and that no sweep removes: sweepWork skips
  # directories) is not caution, it is a slow leak of the staging disk.
  rm -rf -- "$sess_dir"
  if (( failed == 0 && push_rc == 0 )); then
    rip::_progress 100 "session done"
    return 0
  fi
  log_error "rip: session finished with failures (items=$failed push=$push_rc) — published files kept for a plain \`rip-push movies\` retry"
  (( push_rc != 0 )) && return $push_rc
  return 1
}

# --- audiobook provider seam -----------------------------------------------
#
# A provider is ONE executable, ~/.local/libexec/rip-provider-<name>,
# implementing capabilities / list / acquire (spec). Everything downstream
# of acquire is provider-blind, which is what lets a second store (a
# DRM-free seller, or the `manual` importer) arrive as a new file rather
# than a rewrite of this one.
RIP_LIBEXEC_DIR="${RIP_LIBEXEC_DIR:-$HOME/.local/libexec}"

# rip::ab_provider_bin [name] — absolute path to the named provider's
# executable (default: $RIP_AB_PROVIDER, else "libation"). Chezmoi's source
# names carry the executable_ prefix; the deployed name does not. Accept
# either so the suite can run against the source tree without a chezmoi
# apply.
rip::ab_provider_bin() {
  local name="${1:-${RIP_AB_PROVIDER:-libation}}"
  case "$name" in
    */* | "" | . | ..) log_error "rip: bad provider name: $name"; return 2 ;;
  esac
  local p
  for p in "$RIP_LIBEXEC_DIR/rip-provider-$name" "$RIP_LIBEXEC_DIR/executable_rip-provider-$name"; do
    [[ -f "$p" ]] && { print -r -- "$p"; return 0 }
  done
  log_error "rip: no such provider: $name"
  return 2
}

# rip::ab_library [name] — the provider's JSON lines, passed through
# unmodified (the panel's own jq does the shaping).
rip::ab_library() {
  setopt localoptions noerrexit nopipefail
  local bin; bin="$(rip::ab_provider_bin "${1:-}")" || return 2
  zsh "$bin" list
}

# rip::ab_server_library — every <Author>/<Title> cantina holds, from ONE
# ssh. The panel's hide filter is a set-membership test against this, never
# a --have per row: 460 rows would be 460 round-trips and a panel that
# takes a minute to open. The audiobook library is two levels deep
# (<Author>/<Title>) where movies are one — that is why this needs its own
# function rather than reusing rip::session_library. Same host/path split,
# ${(q)} quoting and BatchMode/ConnectTimeout as rip::_remote_has_file /
# rip::session_library, and the plain-local-dir fallback the hermetic tests
# rely on.
rip::ab_server_library() {
  setopt localoptions noerrexit nopipefail
  local base; base="$(rip::remote_base)"
  local out rc line
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    local rdir="$rpath/audiobooks"
    out="$("$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 \
      "$host" "cd ${(q)rdir} && find . -mindepth 2 -maxdepth 2 -type d | sed 's|^\./||'" 2>/dev/null)"
    rc=$?
  else
    # No ':' — the hermetic tests' plain local dir.
    out="$(cd "$base/audiobooks" 2>/dev/null && find . -mindepth 2 -maxdepth 2 -type d | sed 's|^\./||')"
    rc=$?
  fi
  (( rc == 0 )) || { log_error "rip: could not list the audiobook library on the server"; return 2 }
  # A here-string over an empty capture still feeds one empty line; drop it,
  # so "reachable but empty" prints nothing at all.
  while IFS= read -r line; do
    [[ -n "$line" ]] && print -r -- "$line"
  done <<< "$out"
  return 0
}

# rip::ab_have <Author/Title> — tri-state, the rip-disc --have shape: 0
# have / 1 confirmed absent / 2 unknown, straight through from
# rip::_remote_has_file. The .m4b is named after the title, which is the
# relpath's last segment.
rip::ab_have() {
  local rel="$1"
  [[ -n "$rel" ]] || { log_error "rip: empty book path"; return 2 }
  rip::_remote_has_file "audiobooks/$rel/${rel:t}.m4b"
}

# rip::ab_import <src> <author> <title> — take a DRM-free file or folder the
# operator already has and stage it exactly as an acquired book would land,
# so it rides the same enrich → push → verify → clean path as everything else.
# The provider seam's `manual` entry reports can_acquire:false precisely
# because this is the import door: nothing is downloaded, we only place bytes.
#
# The identity row is written to the shared meta index (the same file
# rip::_book_meta_for defaults to), so the sidecar carries provider "manual"
# rather than the path-derived fallback.
rip::ab_import() {
  setopt localoptions noerrexit nopipefail
  local src="$1" author="$2" title="$3"
  [[ -n "$src" ]] || { log_error "rip: import needs a source path"; return 2 }
  [[ -e "$src" ]] || { log_error "rip: no such source: $src"; return 2 }
  rip::_check_title "$author" || return 2
  rip::_check_title "$title" || return 2

  local root; root="$(rip::staging_for audiobooks)"
  local rel; rel="$(rip::_nfc "$author/$title")"
  local dest="$root/$rel"
  # Refuse only when the destination actually holds real files. The glob
  # ("$dest"/*(N)) is deliberately dot-blind — zsh's bare `*` never matches
  # dotfiles or dot-directories, so a destination holding only Finder debris
  # (.DS_Store, etc.) reads as "empty" here and is let through rather than
  # refused as "already staged". The (N) qualifier just expands an empty
  # match to nothing instead of erroring. Count the array, never test a
  # captured string: a `$(print …)` capture with any literal whitespace
  # inside the quotes is non-empty even on zero matches, which would refuse
  # every import. Dotfiles are dealt with separately, in the cleanup block
  # right before the rename below: this guard only decides whether to
  # REFUSE (real content present); the invariant check right before mv
  # catches anything that cleanup couldn't remove (e.g. a dot-directory)
  # rather than let mv silently nest the temp inside a survivor.
  local -a existing=("$dest"/*(N))
  if (( ${#existing} )); then
    log_error "rip: already staged, refusing to clobber: $rel"
    return 2
  fi

  # Build in a temp location and publish atomically to avoid leaving
  # half-copied books in the watched staging tree. Use ${root:h}/.rip-import.*
  # to ensure: (1) same filesystem as $dest so mv is atomic, and (2) outside
  # the watched tree (watcher watches ROOT/{intermediate,music,audiobooks},
  # not ROOT; push enumerates only ROOT/audiobooks). Do NOT anchor to
  # ROOT/audiobooks — temp files there would be enumerated and shipped.
  local temp
  temp="$(mktemp -d "${root:h}/.rip-import.XXXXXX")" || {
    log_error "rip: cannot create an import staging dir"
    return 1
  }

  local detected_fmt=""
  if [[ -d "$src" ]]; then
    # Copy directory; detect format from first audio file
    cp -R -- "$src"/. "$temp"/ || {
      rm -rf "$temp"
      log_error "rip: could not copy $src"
      return 1
    }
    # Scan for first audio file to determine format
    local -a audio=("$temp"/*.(m4b|mp3|m4a)(N))
    if (( ${#audio} )); then
      detected_fmt="${audio[1]:e}"
    fi
  else
    # Single file: reject if extension-less. Lowercased ("${(L)...}"): taken
    # verbatim, an uppercase source extension (Book.M4B) would stage
    # <Title>.M4B and record format:"M4B", which rip::ab_have's hardcoded
    # "${rel:t}.m4b" can never match — the book would look permanently
    # absent from the server (2026-08-23 review finding).
    local ext="${(L)${src:e}}"
    [[ -n "$ext" ]] || {
      rm -rf "$temp"
      log_error "rip: imported file has no extension; cannot determine format"
      return 2
    }
    # Use NFC-normalized tail from rel path for the filename
    cp -- "$src" "$temp/${rel:t}.$ext" || {
      rm -rf "$temp"
      log_error "rip: could not copy $src"
      return 1
    }
    detected_fmt="$ext"
  fi

  # Publish atomically: create parent, then rename temp into place (same
  # filesystem ensures atomic mv). The clobber guard above is dot-blind, so
  # a directory holding only Finder debris (.DS_Store) reads as empty for
  # refusal, but plain files aren't something mv can rename over — remove
  # them first, then rmdir the now-empty (we hope) destination. This only
  # ever deletes plain files we can positively identify as debris; it never
  # recurses into subdirectories, so a dot-DIRECTORY (or anything else
  # `find -type f -delete` + `rmdir` can't clear) survives on purpose here.
  if [[ -d "$dest" ]]; then
    find "$dest" -maxdepth 1 -type f -delete 2>/dev/null || true
    rmdir "$dest" 2>/dev/null || true
  fi

  # Assert the invariant directly rather than trust the cleanup above: if
  # $dest still exists — a dot-directory the cleanup above can't rmdir, a
  # permissions failure, anything else `rm -rf` isn't authorized to force
  # away on the operator's real staging tree — mv would nest the temp
  # inside it and ship a mis-shaped book instead of publishing. Refuse
  # loudly and recoverably instead.
  if [[ -e "$dest" ]]; then
    rm -rf "$temp"
    log_error "rip: refusing to publish — destination still exists after cleanup (contains something other than plain files, e.g. a dot-directory): $dest"
    return 2
  fi

  mkdir -p "$dest:h" 2>/dev/null || true
  mv -- "$temp" "$dest" || {
    rm -rf "$temp"
    log_error "rip: could not publish to $dest"
    return 1
  }

  # Record identity in the meta index
  local index; index="$(rip::_ab_meta_index_default)"
  mkdir -p "${index:h}"
  # Format is operator-supplied and goes through --arg to prevent injection.
  # Omit the key if no format was detected (sidecar writer's default applies).
  if [[ -n "$detected_fmt" ]]; then
    jq -nc --arg p "$rel" --arg t "$title" --arg a "$author" --arg f "$detected_fmt" \
      '{path:$p, title:$t, authors:[$a], ids:{}, provider:"manual", format:$f}' \
      >> "$index" || log_warn "rip: staged $rel but could not record its identity"
  else
    jq -nc --arg p "$rel" --arg t "$title" --arg a "$author" \
      '{path:$p, title:$t, authors:[$a], ids:{}, provider:"manual"}' \
      >> "$index" || log_warn "rip: staged $rel but could not record its identity"
  fi
  print -ru2 -- "rip: imported $rel — the watcher will push it"
  return 0
}

# rip::_validate_ab_plan <plan.json> — defense in depth. The panel gates all
# of this, but a plan is a FILE naming path components under the staging
# root and it arrives through a queue that outlives the panel. Re-check
# everything and refuse the whole plan on the first failure (rc 2), exactly
# like rip::_validate_plan does for a disc session.
rip::_validate_ab_plan() {
  setopt localoptions noerrexit nopipefail
  local plan="$1"
  jq -e . "$plan" >/dev/null 2>&1 || { log_error "rip: session plan is not valid JSON: $plan"; return 2 }
  local -A composed=()
  # NOTE: the local var is named "bpath", not "path" — zsh's lowercase
  # "path" is a special parameter perpetually tied to $PATH (array-valued),
  # and `local path` does not detach that tie. `read -r id path` into it
  # silently fails to assign (read's array-tied-scalar case), so the loop
  # body never runs and every plan looks empty. Verified live against this
  # repo's zsh (5.9.999.3-test) before landing.
  local id bpath author title n=0
  while IFS=$'\t' read -r id bpath; do
    # No blanket "both empty, skip" here: well-formed jq @tsv output over
    # an array never emits a genuinely blank line, so a blank id here
    # means a malformed item (e.g. "{}") that must be REJECTED, not
    # silently dropped from validation — a batch of one good item plus
    # one "{}" would otherwise enqueue one book short with no error at
    # all (review finding, 2026-08-22).
    [[ -n "$id" ]] || { log_error "rip: plan item has no id"; return 2 }
    author="${bpath%%/*}"; title="${bpath##*/}"
    # A book path is exactly two segments, each of which becomes a
    # directory name: <Author>/<Title>. Validate BOTH with the title rule
    # (no slash, never . or ..) — "../etc/x" splits to author ".." and
    # would compose staging/audiobooks/../etc, escaping the tree.
    [[ "$bpath" == */* ]] || { log_error "rip: book path must be <Author>/<Title>: $bpath"; return 2 }
    rip::_check_title "$author" || return 2
    rip::_check_title "$title" || return 2
    # author/title above are derived from the FIRST and LAST slash only
    # (${bpath%%/*} / ${bpath##*/}), so a MIDDLE segment is silently
    # dropped by the split and never reaches rip::_check_title at all:
    # "A/../../etc/passwd" splits to author "A" title "passwd", both
    # individually clean, and would compose straight through to the
    # staging tree — a traversal hole (review finding, 2026-08-22). The
    # roundtrip below is what actually enforces "exactly two segments":
    # reassembling author/title must reproduce bpath byte-for-byte, or
    # something in the middle was lost. Ordered AFTER rip::_check_title
    # so a bad first/last segment (e.g. "..") still reports its own
    # specific reason rather than the generic segment-count one.
    [[ "$author/$title" == "$bpath" ]] || { log_error "rip: book path must be exactly <Author>/<Title>: $bpath"; return 2 }
    if [[ -n "${composed["$bpath"]-}" ]]; then
      log_error "rip: session plan composes the same book twice: $bpath"
      return 2
    fi
    composed["$bpath"]=1
    n=$(( n + 1 ))
  done < <(jq -r '(if (.items | type) == "array" then .items else [] end)[]
                  | [(.id // ""), (.path // "")] | @tsv' "$plan" 2>/dev/null)
  (( n > 0 )) || { log_error "rip: session plan selects nothing"; return 2 }
  return 0
}

# rip::ab_enqueue <plan.json> — validate, copy the plan somewhere it can
# outlive the panel, then ONE heavy job for the whole batch. The .work
# SUBDIRECTORY is load-bearing: ripper's sweepWork() unlinks plain files
# sitting directly in .work at every Hammerspoon start and skips
# directories, so a queued plan waiting behind a long job survives only
# under a subdir (the disc session's own hard-won rule).
rip::ab_enqueue() {
  setopt localoptions noerrexit nopipefail
  local plan="$1"
  [[ -f "$plan" ]] || { log_error "rip: no such session plan: $plan"; return 2 }
  rip::_validate_ab_plan "$plan" || return 2

  local work_dir; work_dir="$(rip::staging_root)/.work/ab-plans"
  mkdir -p "$work_dir" || { log_error "rip: cannot create $work_dir"; return 1 }
  local queued="$work_dir/ab-$$-$RANDOM.json"
  cp -- "$plan" "$queued" || { log_error "rip: cannot stage the session plan at $queued"; return 1 }

  local n; n="$(jq -r '(.items // []) | length' "$plan")"
  local title="$n books"
  (( n == 1 )) && title="$(jq -r '.items[0].title // .items[0].path' "$plan")"

  rip::_load_jobs || { log_error "rip: job runner unavailable"; rm -f -- "$queued"; return 1 }
  job::start --group heavy --title "rip audiobooks: $title" --icon "$RIP_JOB_ICON" \
    -- "$RIP_BIN_DIR/rip-audiobook" --session-worker "$queued"
}

# rip::ab_worker <plan.json> — the enqueued body, two phases in one capsule:
#
#   0–70   ACQUIRE  the provider fetches each item the server lacks into
#                   staging. The band is split evenly across items, so a
#                   four-book session advances four times rather than
#                   jumping.
#   70–100 PUSH     one rip::push_worker audiobooks for the whole batch —
#                   enrichment (sidecars, hops), rsync, verify, clean.
#
# FAILURE HONESTY (the sibling workers' rules, applied to a batch):
#   * ONE item's acquire failure is that ITEM's failure. Log it, keep going,
#     remember the rc — a store hiccup on book four must not cost the three
#     already downloaded.
#   * A push or verify failure keeps everything staged for a plain
#     `rip-push audiobooks` retry with no re-download.
#   * The plan copy is removed once read: it is this run's only reader, and
#     nothing else ever reclaims it.
rip::ab_worker() {
  setopt localoptions noerrexit nopipefail
  rip::_load_jobs || true # see rip::push_worker: sidecar writes need job.zsh in-process
  local plan="$1"
  [[ -f "$plan" ]] || { log_error "rip: no such session plan: $plan"; return 2 }
  rip::_validate_ab_plan "$plan" || return 2

  local provider; provider="$(jq -r '.provider // "libation"' "$plan")"
  local bin; bin="$(rip::ab_provider_bin "$provider")" || return 2
  # ONE source of truth for both the acquire destination and the push
  # source: rip::staging_for audiobooks (the RIP_AB_STAGING seam) IS the
  # dir rip::push_worker reads from AND the dir the provider is told to
  # write into — there is no separate parent/child pair here (verified
  # live 2026-08-22: Libation's configured Books folder IS the
  # <Author>/<Title> parent, no extra level inserted). An earlier version
  # derived the acquire destination as its OWN literal
  # "$(rip::staging_root)/audiobooks", which ignored the RIP_AB_STAGING
  # override — the session would acquire into one tree and push from
  # another, silently losing the session to an empty push (review finding,
  # 2026-08-22). Both roles now share this one variable so that bug class
  # cannot recur.
  local ab_root; ab_root="$(rip::staging_for audiobooks)"
  mkdir -p "$ab_root" || { log_error "rip: cannot create $ab_root"; return 1 }

  # The meta index the enrichment stage reads: every item's row, keyed by
  # path. STABLE path now (review finding, 2026-08-22), not a $$-suffixed
  # one: rip::_book_meta_for defaults RIP_AB_META_INDEX to this exact path,
  # which is what lets a watcher-triggered `rip-push audiobooks` — no
  # session, no index var set at all — pick up a session's rich rows too,
  # not just a session-triggered push. Merged by `path`, never truncated:
  # a stable shared path must not erase another session's still-unpushed
  # rows (heavy-group parallelism is 1, but a prior session's push can
  # still be sitting there having failed verify, kept staged for a manual
  # `rip-push audiobooks` retry per the failure-honesty rule below).
  local index; index="$(rip::_ab_meta_index_default)"
  mkdir -p "${index:h}"
  [[ -f "$index" ]] || : > "$index"
  local idx_tmp="$index.tmp.$$"
  jq -c -s '
    [.[] | select((.path // "") != "")]
    | reduce .[] as $r ({}; .[$r.path] = $r)
    | .[]
  ' "$index" <(jq -c '(.items // [])[]' "$plan" 2>/dev/null) > "$idx_tmp" 2>/dev/null \
    && mv -f -- "$idx_tmp" "$index" \
    || { log_warn "rip: could not update the meta index at $index — enrichment for this batch may fall back to minimal identity"; rm -f -- "$idx_tmp" }

  local -a items=()
  # NOTE: every local var below is declared HERE, once, including the loop
  # variable "entry" — a bare `for entry in …` would leak entry as a global.
  # And the book-path variable is named "bpath", not "path": zsh's lowercase
  # "path" is a special parameter perpetually tied to $PATH (array-valued),
  # and even a `local path` does not detach that tie — assigning to it
  # rewrites the shell's command search path for the rest of this scope, so
  # every command run afterwards (jq, find, the provider bin, rsync) can
  # fail to resolve. Same bug, same fix as rip::_validate_ab_plan (Task 11).
  local id bpath entry
  while IFS=$'\t' read -r id bpath; do
    [[ -n "$id$bpath" ]] && items+=("$id"$'\t'"$bpath")
  done < <(jq -r '(.items // [])[] | [(.id // ""), (.path // "")] | @tsv' "$plan" 2>/dev/null)

  local total=${#items} n=0 rc=0 line pct
  local base span; span=$(( 70 / (total > 0 ? total : 1) ))
  for entry in "${items[@]}"; do
    id="${entry%%$'\t'*}"; bpath="${entry#*$'\t'}"
    base=$(( n * span )); n=$(( n + 1 ))
    rip::ab_have "$bpath"
    case $? in
      0) print -r -- "rip: cantina already has $bpath — skipping"; continue ;;
      2) log_warn "rip: could not ask cantina about $bpath — acquiring anyway" ;;
    esac
    rip::_progress "$base" "downloading — ${bpath:t}"
    zsh "$bin" acquire "$id" "$ab_root" 2>&1 \
      | while IFS= read -r line; do
          case "$line" in
            progress\ *)
              pct="${${line#progress }%% *}"
              if [[ "$pct" == <-> ]]; then
                rip::_progress $(( base + pct * span / 100 )) "downloading — ${bpath:t}"
              elif [[ "$pct" == "-1" ]]; then
                # Indeterminate, passed straight through UNSCALED — rescaling
                # a sentinel would turn -1 into a real percentage and the HUD
                # would draw a definite bar for something we cannot measure.
                # rip::_progress only rescales values matching <-> (which is
                # non-negative), so -1 already survives it untouched; this
                # branch exists because the <-> test above would otherwise
                # drop the line on the floor, leaving the capsule frozen at
                # its band start for the whole download and greyed out as
                # stalled (live 2026-08-23). The per-item band still advances
                # at each item boundary below.
                rip::_progress -1 "${${line#progress }#* } — ${bpath:t}"
              fi
              ;;
            *) print -r -- "$line" ;;
          esac
        done
    local arc=$pipestatus[1]
    if (( arc != 0 )); then
      log_error "rip: acquire failed for $bpath (rc=$arc) — continuing with the rest"
      rc=$arc
      continue
    fi
    # RECONCILE what actually landed. The plan's path is COMPOSED from store
    # metadata ("<Author>/<Title>: <Subtitle>", per Global Constraints), and
    # a provider may still sanitize a character or truncate a very long name
    # on its way to the filesystem. If the composed dir is not there, the
    # newest book dir under the author dir (glob qualifier (N/om): dirs
    # only, most-recently-modified first) is taken to BE this acquisition —
    # robust even when a pre-existing sibling book dir is already there —
    # and the meta index must be re-keyed to the real path or the sidecar it
    # feeds would never match the folder it belongs to.
    if [[ ! -d "$ab_root/$bpath" ]]; then
      local -a landed=("$ab_root/${bpath%%/*}"/*(N/om))
      if (( ${#landed} )); then
        # NFC-normalize the landed folder name before writing it as the new
        # key: rip::_book_meta_for (this index's only reader) NFC-normalizes
        # its lookup via rip::_nfc before matching .path, so a provider that
        # lands an NFD-decomposed name — the exact case this reconcile step
        # exists for — would otherwise re-key to bytes the lookup can never
        # match, silently falling back to the path-derived minimal identity.
        # Same bug class as 21322287 (NFC-canonical server names) in this
        # same file.
        local actual="${bpath%%/*}/$(rip::_nfc "${landed[1]:t}")"
        log_warn "rip: $bpath landed as $actual — re-keying the plan identity"
        jq -c --arg old "$bpath" --arg new "$actual" \
          'if .path == $old then .path = $new else . end' "$index" > "$index.tmp" \
          && mv -f -- "$index.tmp" "$index"
      else
        log_warn "rip: acquire reported success but nothing landed for $bpath"
      fi
    fi
  done
  rm -f -- "$plan"

  # The push owns 70–100. The age gate is disabled for this inner push the
  # same way the disc pipeline disables it: these files are complete by
  # construction (the provider returned) rather than by having held still.
  local RIP_PROGRESS_BASE=70 RIP_PROGRESS_SPAN=30
  local RIP_PUSH_MIN_AGE_S=0
  local RIP_AB_META_INDEX="$index"
  rip::push_worker audiobooks
  local prc=$?
  # Removed at the END, after the push (not "once read" mid-session as
  # before, review finding 2026-08-22): the index is stable now, so a
  # watcher-triggered push racing this session mid-acquire — the
  # AUDIOBOOK_QUIET_SECS timer fires well inside a multi-book session's
  # total download time — still finds it. heavy-group parallelism is
  # pinned to 1 (job::_ensure_group), so no second ab_worker can be
  # mid-write to this same path concurrently.
  rm -f -- "$index"
  (( prc != 0 )) && return $prc
  return $rc
}
