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

  # INSIDE the lock, and still BEFORE the listfile is built — both halves of
  # that sentence are load-bearing.
  #
  # Before the listfile: renaming a staged author after `find` has already
  # named its books leaves every entry in the list pointing at a directory
  # that no longer exists, and rsync --files-from silently skips them (see
  # rip::_canonicalize_staged_authors). Pinned by the ordering examples in
  # tests/rip-push_spec.sh.
  #
  # Inside the lock: it used to run BEFORE the flock, where it could rename
  # a staged author directory out from under a concurrent push that was
  # already mid-rsync on it — push A holding the lock transferring
  # "J.R.R. Tolkien/The Hobbit/…", push B (the heavy group's inner push and
  # a hand-run `rip-push <type>` DO run concurrently on the same type)
  # starting up and canonicalizing that very directory, A's rsync exiting
  # 23/24 and failing the job below. No data is lost, but that is exactly
  # the spurious same-type-race job failure the flock was added to
  # eliminate — so the rename now waits for the lock like everything else
  # (review finding 5, 2026-08-24).
  [[ "$type" == audiobooks ]] && rip::_canonicalize_staged_authors "$src"

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
  # NAME-ANCHORED, not a blanket dot-directory exclusion (review finding
  # 2026-08-25, reverting an earlier `-not -path '*/.*/*'` on this same
  # line): a bare "any dot-prefixed path component" pattern also matches a
  # real, dot-prefixed TITLE — "...And Justice for All" is a real Metallica
  # album, ".45" is a real 2006 film and rip::_check_title accepts it — and
  # silently drops the whole album/movie from the listfile with rc 0 and no
  # warning naming what was skipped. For rip::pipeline_worker specifically
  # that is worse than the bug being guarded against: push_worker returns
  # 0, the capsule reports done, and the caller then rm -f's the lossless
  # MakeMKV intermediate — the file never reaches the server and the only
  # local copy is gone. Excluding by NAME instead only ever matches this
  # tool's own scratch temps (.rip-folder.*, .rip-import.*), never
  # anything an operator could plausibly be storing.
  if (( age > 0 )); then
    find "$src" -type f ! -name .DS_Store \
      ! -path '*/.rip-folder.*/*' ! -path '*/.rip-import.*/*' -mtime +"${age}s" 2>/dev/null
  else
    find "$src" -type f ! -name .DS_Store \
      ! -path '*/.rip-folder.*/*' ! -path '*/.rip-import.*/*' 2>/dev/null
  fi | sed "s|^$src/||" > "$listfile"
  if [[ ! -s "$listfile" ]]; then
    print -r -- "rip: nothing settled to push for $type (age gate ${age}s)"
    rm -f -- "$listfile"
    return 0
  fi

  # A book REFUSED by the enrichment (its authoritative tags could not be
  # written and verified) has already been dropped from $listfile, so the
  # rsync below never sees it. What is left is to make sure the push does
  # not report success over it: `refused` survives a clean transfer of every
  # OTHER book and turns the worker's rc non-zero at the end.
  local refused=0
  if [[ "$type" == music ]]; then
    rip::_enrich_music "$src" "$listfile" || log_warn "rip: enrich pass had failures — pushing anyway"
  elif [[ "$type" == audiobooks ]]; then
    rip::_enrich_audiobooks "$src" "$listfile"
    local erc=$?
    if (( erc == 3 )); then
      refused=1
      if [[ ! -s "$listfile" ]]; then
        log_error "rip: every book in this push was refused — nothing left to push, keeping local files"
        rm -f -- "$listfile"
        return 1
      fi
    elif (( erc != 0 )); then
      log_warn "rip: enrich pass had failures — pushing anyway"
    fi
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
  # --chmod=Dg+rx,Fg+r because -a replays the LOCAL mode and would otherwise
  # override the server's setgid inheritance: a staged directory that happens
  # to be 0700 lands 0700 under /srv/media, where every media service reaches
  # the tree through the `media` GROUP (Audiobookshelf runs as its own uid
  # with groups=media). A group-less directory is then unenterable, so the
  # scanner never sees the book, the item never enters the library, and the
  # only symptom is one EACCES watcher line in the server's journal — which
  # is how "Ready Player One" stayed invisible for five days (2026-08-28).
  # Additive on purpose: this only ever ADDS the two bits the services need,
  # so it cannot widen anything else or churn modes on already-pushed files.
  # The -rcn verify below carries no -p, so it never compares modes and is
  # unaffected by this.
  "$rsync_bin" -a --chmod=Dg+rx,Fg+r --iconv=utf-8-mac,utf-8 --partial --exclude=.DS_Store --files-from="$listfile" \
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
  if (( vrc == 0 && refused )); then
    log_error "rip: at least one book was refused and stays staged — retry $type once its tags can be written"
    return 1
  fi
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

# rip::_dir_has_audio <dir> — 0 when <dir> holds at least one audio file at
# any depth, 1 otherwise (including "no such directory").
#
# This is the CAPTURED OUTCOME an acquire is judged by. LibationCli exits 0
# for a title whose licence has lapsed, having written nothing at all
# (reproduced live 2026-08-24 with Pierce Brown/Red Rising), so the provider's
# rc alone reports a successful rip for a book that never arrived. Same
# extension set as rip::_sidecars_hash_primary's server-side scan, so "what
# counts as audio" has one answer on both sides of the push.
rip::_dir_has_audio() {
  setopt localoptions noerrexit nopipefail
  local d="${1:-}"
  [[ -n "$d" && -d "$d" ]] || return 1
  local -a found=("$d"/**/*.(m4b|m4a|mp3|mp4|aac|flac|ogg|opus|wav|aax|aaxc)(N.))
  (( ${#found} > 0 ))
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

# Canonicalized-book rename map: NEW relpath -> the relpath the identity was
# recorded under BEFORE rip::_canonicalize_staged_authors renamed the staged
# author directory (review finding 1, 2026-08-24 — the merge blocker).
#
# The meta index is re-keyed on disk too (rip::_rekey_book_meta), which
# covers every reader; this in-memory map covers the ONE reader that has no
# index at all — the provider-`list` fallback below, whose rows are keyed on
# the PROVIDER's author spelling and can never match a canonicalized path.
# Without it a watcher-triggered push (no index, no session) that happens to
# canonicalize an author writes the path-derived MINIMAL identity over a
# perfectly good provider row: `ids: {}`, `published: null`, provider
# "unknown". That is permanent — staging is emptied after the verified push,
# and --backfill-published cannot repair a sidecar with no ASIN in it.
#
# Process-scoped and guarded exactly like the cache above: every real push is
# its own fresh zsh process, and re-sourcing this file mid-run must not
# clobber a map the run already built.
# (`typeset -gA` on an already-existing associative array keeps its
# contents, so this is idempotent on re-source with no explicit guard.)
typeset -gA _RIP_AB_RENAMED_BOOKS

# rip::_rekey_book_meta <old-author> <new-author> <title>... — follow a
# canonicalizing rename through the identity plumbing.
#
# Called by rip::_canonicalize_staged_authors for each book that ACTUALLY
# moved. Two effects, both required:
#   * the on-disk meta index has its `path` rewritten from
#     "<old-author>/<title>" to "<new-author>/<title>", so the very next
#     rip::_book_meta_for lookup (which searches by the post-rename relpath)
#     finds the rich row instead of missing and falling back;
#   * the in-memory map above records new -> old for the provider fallback.
#
# Written to a temp file and moved into place: a truncated index would lose
# every OTHER book's identity too, including a prior session's rows still
# waiting on a failed-verify retry. Keys are NFC-normalized because
# rip::_book_meta_for NFC-normalizes its lookup before matching `.path`
# (same reasoning as rip::ab_worker's "landed as" re-key).
rip::_rekey_book_meta() {
  setopt localoptions noerrexit nopipefail
  local old_author="$1" new_author="$2"
  shift 2
  local idx="${RIP_AB_META_INDEX:-$(rip::_ab_meta_index_default)}"
  local title old_rel new_rel tmp
  for title in "$@"; do
    old_rel="$(rip::_nfc "$old_author/$title")"
    new_rel="$(rip::_nfc "$new_author/$title")"
    [[ "$old_rel" == "$new_rel" ]] && continue
    _RIP_AB_RENAMED_BOOKS[$new_rel]="$old_rel"
    [[ -n "$idx" && -f "$idx" ]] || continue
    tmp="$idx.rekey.$$"
    if jq -c --arg old "$old_rel" --arg new "$new_rel" \
         'if .path == $old then .path = $new else . end' "$idx" > "$tmp" 2>/dev/null \
       && mv -f -- "$tmp" "$idx"; then
      :
    else
      rm -f -- "$tmp"
      log_warn "rip: could not re-key the meta index for $old_rel — its sidecar may fall back to minimal identity"
    fi
  done
  return 0
}

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
  # A book whose staged author was canonicalized on the way in (see
  # rip::_canonicalize_staged_authors) is looked up under its NEW relpath,
  # while the identity was recorded under the provider's spelling. The index
  # is re-keyed on disk at rename time, so $rel alone finds it there; the
  # provider-`list` fallback below has no such rewrite, so the pre-rename
  # relpath is kept as a second key to try. Empty for every ordinary book.
  local prev="${_RIP_AB_RENAMED_BOOKS[$rel]:-}"
  local row=""
  if [[ -n "$idx" && -f "$idx" ]]; then
    row="$(jq -c --arg p "$rel" 'select((.path // "") == $p)' "$idx" 2>/dev/null | head -1)"
    [[ -z "$row" && -n "$prev" ]] \
      && row="$(jq -c --arg p "$prev" 'select((.path // "") == $p)' "$idx" 2>/dev/null | head -1)"
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
    [[ -z "$row" && -n "$prev" && -n "$_RIP_AB_PROVIDER_ROWS" ]] \
      && row="$(print -r -- "$_RIP_AB_PROVIDER_ROWS" \
        | jq -c --arg p "$prev" 'select((.path // "") == $p)' 2>/dev/null | head -1)"
  fi
  if [[ -n "$row" ]]; then
    # "Identity at import, not repaired later" (spec). ids["local.sha256"]
    # used to be written ONLY by --repair-sidecars Case C, gated to provider
    # "manual" — so a folder-acquired book never got identity of its own,
    # and the byte-level duplicate refusal in rip::ab_worker could never
    # recognize a re-import of a book THIS feature itself imported. This is
    # the one place every row (index, provider-list fallback) converges
    # before becoming a sidecar, so it is where that gap closes: a
    # provider-"folder" row is stamped with a locally minted fleet.uid, the
    # same durable join key Case C mints, PAIRED with local.sha256 — and the
    # pairing is what makes THIS the site that can write that key at all:
    # here the SOURCE file was hashed moments ago, so `local.sha256` means
    # what it says. Case C, repairing a book already on the server, has no
    # source to hash and records `local.stored.sha256` instead (review
    # finding F3, 2026-08-26).
    #
    # local.sha256 is never (re)hashed here — rip::ab_worker already hashes
    # the primary m4b once, for its own duplicate-bytes check, and threads
    # that exact value into this row's ids["local.sha256"] (see the targeted
    # index patch in rip::ab_worker's acquire loop) before this function
    # ever runs. A row with nothing threaded gets nothing minted — the same
    # refusal Case C makes for a book it cannot hash: half an identity pair
    # is the very exposure this feature exists to close.
    #
    # A failed mint is a hard failure of THIS call, not a silent half-write
    # (review finding 3, 2026-08-25): the production caller
    # (rip::_enrich_audiobooks) redirects this function's own stderr to
    # /dev/null, so a log_warn here alone never reaches the operator, and a
    # push would report success while shipping a book with local.sha256 but
    # no fleet.uid — half an identity pair, silently. Returning non-zero
    # lets that caller's OWN unsuppressed "could not write the identity
    # sidecar" warning fire instead, the same path the sibling uuidgen
    # failure in --repair-sidecars Case C already uses to reach the
    # operator.
    if [[ "$(print -r -- "$row" | jq -r '.provider // ""' 2>/dev/null)" == "folder" ]]; then
      local sha256; sha256="$(print -r -- "$row" | jq -r '.ids["local.sha256"] // ""' 2>/dev/null)"
      if [[ -n "$sha256" ]]; then
        local uid; uid="$(uuidgen 2>/dev/null)"; uid="${(L)uid}"
        if [[ -n "$uid" ]]; then
          row="$(print -r -- "$row" | jq -c --arg u "$uid" --arg s "$sha256" \
            "$_RIP_JQ_IDS_DEF"'.ids = ((.ids | _ids_obj) + {"fleet.uid": $u, "local.sha256": $s})' 2>/dev/null)"
        else
          log_warn "rip: uuidgen produced nothing — cannot assign a local identity to $rel"
          return 1
        fi
      fi
    fi
    print -r -- "$row"
    return 0
  fi
  jq -nc --arg author "${rel%%/*}" --arg title "${rel##*/}" \
    '{path: ($author + "/" + $title), title: $title, authors: [$author],
      ids: {}, provider: "unknown", format: "m4b"}'
}

# rip::_file_bytes <file> — size in bytes. macOS stat and GNU stat disagree on
# flags, so try GNU first and fall back; print 0 rather than an empty string,
# because the caller feeds this to jq --argjson.
rip::_file_bytes() {
  setopt localoptions noerrexit nopipefail
  local n
  n="$(stat -c %s -- "$1" 2>/dev/null)" || n="$(stat -f %z -- "$1" 2>/dev/null)"
  [[ "$n" == <-> ]] && print -r -- "$n" || print -r -- 0
}

# _RIP_COMPANION_KIND_JQ — the companion `kind` mapping, as one jq expression,
# in ONE place. Input `.` is the file basename; output is the kind string.
#
# Shared rather than copied because TWO scanners now classify a companion: the
# push (rip::_companions_json, reading a staged directory) and the retroactive
# sweep (rip::ab_repair_companions, reading a POSIX listing off the server,
# where the classification cannot be done at all — cantina has no jq). A book
# swept into the library and a book pushed into it must not end up with
# different `kind` values for the same file.
#
# Case-insensitive, like the zsh `${(L)}` match it replaced: covers arrive from
# Libation as `.jpg` and from a folder import as `.JPG` just as often.
#
# A plain constant, not a cache: re-sourcing this file mid-run reassigns the
# same text, exactly as _RIP_SIDECAR_JQ does.
typeset -g _RIP_COMPANION_KIND_JQ
_RIP_COMPANION_KIND_JQ='(ascii_downcase) as $l
   | if   ($l|endswith(".jpg")) or ($l|endswith(".jpeg")) or ($l|endswith(".png")) then "cover"
     elif ($l|endswith(".pdf"))  then "pdf"
     elif ($l|endswith(".epub")) then "epub"
     elif ($l|endswith(".txt"))  then "txt"
     else "other" end'

# rip::_companions_json <bookdir> — the book's non-audio files as a JSON array
# of {file, kind, bytes, sha256}. Always an array; `[]` when there are none.
#
# The audio and the sidecar itself are excluded: the audio IS the book, and a
# sidecar listing itself is a fixpoint nobody needs. Everything else that
# shipped with the book is recorded, cover included — one uniform notion of
# "the files belonging to this book" beats two, and consumers filter by kind.
#
# The audio exclusion uses the SAME extension set as rip::_dir_has_audio and
# rip::_sidecars_hash_primary's server-side scan (review finding, 2026-08-25),
# not just `*.m4b`: a book that still carries its Libation-decrypted `.aax`
# alongside the `.m4b` (or any other audio format) would otherwise have that
# audio file recorded as a companion — the exact thing this function exists
# to exclude — AND fully read end to end by rip::_sha256_of below, which for
# a retained multi-gigabyte `.aax` is precisely the "hash a large file twice"
# cost Step 3b exists to avoid.
rip::_companions_json() {
  setopt localoptions noerrexit nopipefail
  local d="$1" f base
  # The kind comes from the SHARED mapping, not a second copy of it — see
  # _RIP_COMPANION_KIND_JQ above.
  local prog='{file:$file, kind:($file|'"$_RIP_COMPANION_KIND_JQ"'), bytes:$bytes, sha256:(if $sha=="" then null else $sha end)}'
  local -a rows=()
  for f in "$d"/*(N.); do
    base="${f:t}"
    [[ "$base" == .fleet-book.json ]] && continue
    case "${(L)base}" in
      *.m4b|*.m4a|*.mp3|*.mp4|*.aac|*.flac|*.ogg|*.opus|*.wav|*.aax|*.aaxc) continue ;;
    esac
    rows+=("$(jq -nc --arg file "$base" \
      --argjson bytes "$(rip::_file_bytes "$f")" \
      --arg sha "$(rip::_sha256_of "$f")" "$prog")")
  done
  if (( ${#rows} )); then
    print -rl -- "${rows[@]}" | jq -sc .
  else
    print -r -- "[]"
  fi
}

# _RIP_JQ_IDS_DEF — the ids COERCION, as jq definitions in ONE place. Prefix
# it to any program that reads an `ids` map: `(.ids | _ids_obj)` /
# `($r.ids | _ids_obj)` for a value, `_ids_fix` for a whole row.
#
# WHY THIS EXISTS (review finding, 2026-08-25). `ids` is an OBJECT by schema,
# but an empty one does not survive a Lua round trip: Hammerspoon 1.1.1
# encodes an empty Lua table as `[]`, not `{}` (LuaSkin's Skin.m at tag
# 1.1.1 — with maxNatIndex == countNatIndex == 0 it picks NSMutableArray),
# and the panel re-encodes the plan on its way to the queue. The folder
# provider is the only producer of an EMPTY ids object, so `"ids": []` is
# what actually reaches jq for a locally-imported book.
#
# `.ids // {}` does NOT rescue that: `[]` is neither null nor false, so it
# flows straight through and then `[] + {…}` raises "array and object cannot
# be added" and `.ids["audible.asin"]` raises "Cannot index array with
# string". Every one of those raises is swallowed by a `2>/dev/null`, and the
# row it happened on is DROPPED from the stream — measured against jq 1.7.1
# (Apple) and 1.8.2: a poisoned sidecar disappears from rip::_sidecar_index
# entirely, which is exactly the book the repair sweep exists to fix.
#
# The coercion is deliberately total rather than a `select`: anything that is
# not an object (an array, a string, a number, null) becomes {}, which is what
# "no identity recorded" means. Normalizing at every boundary that READS ids
# also repairs a sidecar already poisoned on the server the next time it is
# rewritten, instead of only stopping new ones.
#
# Two definitions, because the two needs differ. `_ids_obj` maps a VALUE to a
# usable object (used where an object is about to be indexed or added to).
# `_ids_fix` repairs an OBJECT IN PLACE and is absence-preserving: a sidecar
# that never had an `ids` key keeps not having one, so normalizing a row on
# its way through a reader cannot make an unchanged sidecar churn.
typeset -g _RIP_JQ_IDS_DEF
_RIP_JQ_IDS_DEF='def _ids_obj: if type == "object" then . else {} end;
  def _ids_fix: if (.ids != null) and ((.ids | type) != "object")
                then .ids = {} else . end;'

# _RIP_JQ_WORK_DEF — the `work` COERCION, the exact sibling of _ids_obj above
# and there for the same reason. `work` is an OBJECT by schema now
# ({uid, edition}, design doc 2026-08-25 S1), and an empty one does not
# survive a Lua round trip either: Hammerspoon encodes an empty Lua table as
# `[]` (see _RIP_JQ_IDS_DEF for the measurement), and every reader of this
# field subscripts it — `.work.uid` — which RAISES on an array. The raise is
# swallowed by the `2>/dev/null` at the call site and the book it happened on
# is dropped from whatever is asking, so an edition would silently resolve to
# a fresh uid against a book that already anchors a work.
#
# Kept as its own constant rather than folded into _RIP_JQ_IDS_DEF: the two
# are prefixed independently, and a program that reads only one should not
# have to carry the other's definitions.
typeset -g _RIP_JQ_WORK_DEF
_RIP_JQ_WORK_DEF='def _work_obj: if type == "object" then . else {} end;'

# _RIP_SIDECAR_JQ — the sidecar SCHEMA, as one jq program, in ONE place.
#
# Reads the provider row from `$r` and emits the whole `.fleet-book.json`
# object. Three call sites now compose a sidecar — the push
# (rip::_book_sidecar), the repair sweep (rip::ab_repair_sidecars) and the
# confirmation verb (rip::ab_adopt_asin) — and a repaired sidecar that did
# not come out shaped like a freshly-pushed one would be a second, silently
# diverging schema on the only copy of every book's identity. So the program
# is shared rather than copied.
#
# A plain constant, not a cache: re-sourcing this file mid-run reassigns the
# same text, so it needs none of the guards _RIP_AB_PROVIDER_ROWS carries.
#
# ids["local.sha256"] MEANS THE HASH OF THE SOURCE THAT WAS IMPORTED, NOT OF
# THE FILE SITTING BESIDE THIS SIDECAR. Say it plainly because it stopped
# being obvious on 2026-08-26: the enrichment now rewrites every staged
# book's authoritative tags (rip::_retag_book), which is a remux, which
# changes the stored file's bytes — so sha256-ing the `.m4b` next to a
# sidecar will NOT reproduce the value recorded here. That is not drift. The
# field exists for the byte-level duplicate refusal in rip::ab_worker, which
# hashes the operator's SOURCE file before acquiring it and compares against
# exactly this recorded source hash — so dedupe keeps working for every book
# whose source was actually hashed, which is every book acquired through the
# worker.
#
# The books it does NOT cover are the ones nobody ever hashed a source for:
# --repair-sidecars Case C repairs a book that was already on the server and
# can only hash the STORED bytes. Those are recorded under their own key,
# `local.stored.sha256`, precisely BECAUSE of the sentence above (review
# finding F3, 2026-08-26): filed as `local.sha256` they would offer the
# dedupe a value no source file can ever match, and it would silently stop
# firing for every repaired book. A book whose source hash nobody knows is
# absent from the dedupe index, which is the honest answer rather than a
# wrong one.
#
# `local.stored.sha256` is NOT the `stored.sha256` the design doc refused to
# add. That refusal was about the PUSH composer minting a second hash of a
# file it had already hashed, for no reader. This one is the only hash Case C
# can compute, it names what it actually is, and it is the recovery anchor
# rip::_sidecars_hash_primary exists for.
typeset -g _RIP_SIDECAR_JQ
_RIP_SIDECAR_JQ="$_RIP_JQ_IDS_DEF$_RIP_JQ_WORK_DEF"'
  {schema: 1, kind: "audiobook",
   title: ($r.title // ""),
   subtitle: ($r.subtitle // null),
   authors: ($r.authors // []),
   narrators: ($r.narrators // []),
   series: (if ($r.series // "") == "" then null
            else {name: $r.series, position: ($r.series_position // null)} end),
   duration_s: ($r.duration_s // null),
   language: ($r.language // null),
   abridged: (if ($r|has("abridged")) then $r.abridged else null end),
   published: ($r.published // null),
   ids: ($r.ids | _ids_obj),
   work: (($r.work | _work_obj) | if . == {} then null else . end),
   companions: $companions,
   source: {provider: ($r.provider // "unknown"),
            provider_version: ($r.provider_version // null),
            acquired_utc: ($r.acquired_utc // null),
            format: ($r.format // "m4b")}}'

# rip::_sidecar_compose <provider-row-json> — the composed sidecar for one
# provider row, on stdout. The pretty (non-compact) shape is deliberate: it
# is what rip::_book_sidecar writes at every push, and a repaired sidecar
# must not be distinguishable from one.
#
# companions is always [] here: this composer builds a sidecar from a
# provider ROW alone, with no local directory to scan (--repair-sidecars
# Case A composes for a book that exists only on the server). There is
# nothing to merge against either — Case A only ever fires when no sidecar
# exists yet — so [] is not a loss, just the honest "not scanned" answer.
rip::_sidecar_compose() {
  setopt localoptions noerrexit nopipefail
  local row="${1:-}"
  [[ -n "$row" ]] || row='{}'
  jq -n --argjson r "$row" --argjson companions '[]' "$_RIP_SIDECAR_JQ" 2>/dev/null
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

  local built companions
  # The book dir's current companion files, scanned FRESH on every call —
  # unlike ids/work below, this is a live reflection of what's on disk right
  # now, not operator-resolved metadata to protect across pushes, so it must
  # never be frozen at whatever the first push happened to see.
  companions="$(rip::_companions_json "$dir")"
  [[ -n "$companions" ]] || companions='[]'
  # ONE composer for the whole module (see _RIP_SIDECAR_JQ above): a sidecar
  # repaired by rip::ab_repair_sidecars or adopted by rip::ab_adopt_asin must
  # come out byte-shaped like this freshly-pushed one, which a second copy of
  # the program would guarantee only until someone edited one of them.
  built="$(jq -n --slurpfile m "$meta" --argjson companions "$companions" \
    '($m[0] // {}) as $r | '"$_RIP_SIDECAR_JQ" 2>/dev/null)" \
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
    #
    # `.companions` is ALSO stripped from the old side, deliberately unlike
    # ids/work: those are protected across pushes on purpose, but companions
    # is a fresh scan every time (see above) — jq's `*` does not merge two
    # array values element-wise, it just lets one win outright, so leaving
    # the old array in would freeze companions at whatever the FIRST push
    # saw and a PDF added later would never appear.
    #
    # `.source.provider` IS STRIPPED TOO (review finding F1, 2026-08-26), and
    # for a sharper reason than either: it is the field that must NAME THE ROW
    # THAT ACQUIRED THE BYTES, and old-wins let it outlive that row.
    #
    # The interleaving is entirely supported, no misuse required:
    # `--import` stages "<Author>/<Title>" and records a provider "manual"
    # row; the push writes a manual sidecar and then FAILS ITS VERIFY, which
    # by documented design leaves everything staged for a retry; the operator
    # then rips the same book through the folder panel (rip::ab_have says
    # absent, so it is offered), the folder provider's "already staged,
    # nothing to copy" branch leaves the OLD sidecar in place, and
    # rip::ab_worker threads the SOURCE hash of the file it just handled into
    # `ids["local.sha256"]`. Merge old-wins, and the sidecar ends up saying
    # `provider: "manual"` about a `local.sha256` that is a SOURCE hash.
    #
    # That combination is exactly what rip::ab_retag's re-key reads as "a
    # --repair-sidecars Case C stored-bytes hash" — so the sweep would move a
    # genuine source hash to `local.stored.sha256`, rip::_stored_sha_index
    # would stop seeing it, and the byte-dedupe would silently die for that
    # book with nothing able to detect it afterwards. The gate's premise is
    # that provider names the writer of the ids; this is what makes that TRUE
    # rather than merely usual.
    #
    # Guarded on `.source` actually being an object: a hand-corrupted
    # `"source": []` (the shape `_RIP_JQ_IDS_DEF` and `_RIP_JQ_WORK_DEF` exist
    # for) makes `del(.source.provider)` RAISE, and a raise here fails the
    # whole sidecar write. Left alone it merges exactly as it did before —
    # already wrong, but not newly fatal.
    merged="$(jq -n --argjson new "$built" --slurpfile old "$sidecar" \
      '$new * (($old[0] // {})
               | del(.companions)
               | (if (.source | type) == "object" then del(.source.provider) else . end)
               | with_entries(select(.value != null)))' 2>/dev/null)" \
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

# --- authoritative tags ------------------------------------------------------
#
# THE INVARIANT: a book's tags say exactly what its path says.
#
# What went wrong without it (2026-08-26): the operator ripped seven Harry
# Potter books, correcting each title in the panel. The directories, the
# filenames and all seven sidecars recorded the correction — and
# Audiobookshelf showed something else, because ABS reads the file's EMBEDDED
# metadata and nothing here had ever written one. The seven source files
# disagreed with each other; the two carrying `artist=Jim Dale` displayed the
# NARRATOR as the author. The operator's statement of the requirement: "this
# book title is XXXXX and its author is YYYY and it belongs to the edition
# WWWW. If the rip lands in the library with anything that is not that, it is
# just wrong."
#
# Written on the STAGED COPY, after the acquire and before the push. The
# operator's original file is never touched — that guarantee is load-bearing
# for the folder provider (its acquire COPIES, deliberately, because the
# local copy IS the original) and does not change here.

# rip::_tags_match <file> <album_artist> <bookname> — rc 0 when <file>'s three
# authoritative tags already read back EXACTLY as given. Prints nothing; any
# unreadable file, missing tag or difference is a plain non-zero.
#
# ONE comparison, two callers, on purpose: rip::_retag_book asks it before the
# remux ("is there anything to do?") and again afterwards ("did it take?"),
# and those two questions must never be able to answer differently for the
# same file — a skip rule that was even slightly looser than the verification
# would skip a book the verification would have refused.
#
# BOTH METADATA LEVELS ARE READ, and that is a bug fix, not thoroughness
# (review finding F1, 2026-08-26). `-show_entries format_tags` is not "the
# file's tags", it is ONE of the two places a tag can live: mp4/mp3/flac keep
# these at the FORMAT level, while ogg and opus keep VorbisComment on the
# audio STREAM. A format-only read of an opus book returns `{}`, so the
# comparison could never match, the retag could never be verified, and the
# book was REFUSED on every retry — forever, deterministically, with retry as
# the only remedy the design offers. Merged with the stream on the right so
# the stream wins where a container keeps both, which is the container that
# treats the stream as authoritative.
#
# `-select_streams a:0`: the audio stream, not "stream 0" — a file whose
# attached cover sorts first must not have the picture's own tags read as the
# book's.
#
# jq does the whole comparison rather than shell string-splitting ffprobe's
# output: a tag value containing a tab, an equals sign or a newline can then
# never be split wrong on the way to being compared.
# _RIP_JQ_TAGS_OK — THE comparison, as one jq definition, in ONE place.
#
# `_tags_ok($p; $aa; $bn)` is true when the ffprobe JSON `$p` already carries
# exactly these three authoritative tags. FOUR call sites now ask that
# question and none of them may ever be able to answer differently about the
# same bytes: rip::_retag_book asks it before a remux ("is there anything to
# do?") and after ("did it take?"), and rip::ab_retag asks it twice more over
# JSON a SERVER produced — "does this stored book disagree with its path?"
# and "did the remote rewrite take?". A skip rule even slightly looser than
# the verification would skip a book the verification would have refused, and
# a sweep whose comparison differed from the writer's would never reach a
# fixed point. Sharing the TEXT, not the intent, is what makes that
# impossible rather than merely unlikely.
#
# `.format.tags` merged with the a:0 stream's tags, STREAM ON THE RIGHT:
# mp4/mp3/flac keep these at the FORMAT level while ogg and opus keep
# VorbisComment on the audio STREAM (review finding F1, 2026-08-26), and a
# container that keeps both treats the stream as authoritative.
#
# Written defensively against a MISSING `streams` array as well as an empty
# one: the sweep feeds this JSON that came off another machine, where a probe
# of an unreadable file yields `{}` rather than the shape ffprobe promises.
#
# `artist` AND `composer` ARE ASKED ABOUT TOO, and that is the clause the
# library-wide sweep converges or diverges on (2026-08-26, second amendment).
# They are never REPLACED — see rip::_retag_book's header — but their SPELLING
# is normalised in place, so this predicate has to ask whether each already
# equals its own canonical form. Without it, `--retag` SKIPS a book whose only
# fault is an un-spaced `artist`, and the 258 books already on the server are
# never repaired, which is the entire point of the change. The rule is
# idempotent, so one pass canonicalises and the next finds nothing.
#
# ABSENT IS SATISFIED, not violated: `// ""` folds a missing tag to the empty
# string, whose canonical form is itself. A book with no `artist` must not
# acquire one — the only value this pipeline could invent is the author, which
# is exactly the guess that produced the original defect.
#
# `_canon` IS A SECOND IMPLEMENTATION of rip::_author_display, in jq, and it
# is deliberate: jq cannot call a zsh function and the sweep cannot fork one
# per book. It sits on the opposite side of a write from the zsh one — that
# one PRODUCES the value, this one DECIDES whether what came back is
# canonical — so a divergence would refuse a book the writer had just
# repaired, on every retry, forever. tests/rip-audiobook_spec.sh compares the
# two row for row, over rip::_author_display's whole table plus the accented
# names where a zsh `[A-Za-z]` range and Oniguruma's could part ways.
#
# The lookbehind and lookahead are what make a RUN of initials work in a
# single gsub: "J.R.R." needs its middle R read both as the letter after one
# period and as the lone letter before the next, and a regex that CONSUMED
# those letters could not reuse them. Only the period is consumed.
typeset -g _RIP_JQ_TAGS_OK
_RIP_JQ_TAGS_OK='def _canon: gsub("(?<![A-Za-z])(?<c>[A-Za-z])\\.(?=[A-Za-z])"; .c + ". ");
def _tags_ok($p; $aa; $bn):
  ((($p.format.tags) // {}) + (((($p.streams // [])[0]).tags) // {})) as $t
  | (($t.album_artist // "") == $aa)
    and (($t.album // "") == $bn)
    and (($t.title // "") == $bn)
    and ((($t.artist // "") | _canon) == ($t.artist // ""))
    and ((($t.composer // "") | _canon) == ($t.composer // ""));
'

# rip::_tags_match_json <ffprobe-json> <album_artist> <bookname> — the
# predicate above, over JSON that is already in hand. Empty, truncated or
# unparseable input is a plain non-zero, never a match: this is the half of
# the pair that runs against a probe performed on cantina, and "we could not
# read it" must never read as "it is already correct".
rip::_tags_match_json() {
  setopt localoptions noerrexit nopipefail
  print -r -- "${1:-}" \
    | jq -e --arg aa "${2:-}" --arg bn "${3:-}" \
        "$_RIP_JQ_TAGS_OK"'_tags_ok(.; $aa; $bn)' >/dev/null 2>&1
}

rip::_tags_match() {
  setopt localoptions noerrexit nopipefail
  local ffprobe_bin="${RIP_FFPROBE_BIN:-ffprobe}"
  local js
  js="$("$ffprobe_bin" -v error -select_streams a:0 -show_entries format_tags:stream_tags \
      -of json -- "$1" 2>/dev/null)"
  rip::_tags_match_json "$js" "$2" "$3"
}

# rip::_retag_book <file> <author> <bookname> — rewrite this audio file's
# authoritative tags. rc 0 ONLY when the tags were written AND read back
# correctly.
#
#   album_artist  the author, VERBATIM
#   album         the book name
#   title         the book name
#   artist        NORMALISED IN PLACE — spelling only, never replaced
#   composer      NORMALISED IN PLACE — spelling only, never replaced
#
# VERBATIM IS A CONVERGENCE REQUIREMENT, not laziness (coordinator ruling,
# 2026-08-26). The invariant is checkable in BOTH directions, and the
# library-wide `--retag` sweep is the direction that checks it: it compares a
# stored book's tags AGAINST its path. A retag that wrote a TRANSFORMED
# author — the canonical initials form, say — while the path kept the raw one
# would make that comparison report a mismatch on every single run and
# rewrite the file every time: a sweep with no fixed point, rewriting every
# book on the server forever. So the canonical form enters through the PATH
# and never through the tag: the panel normalises the author on blur, so new
# rips get canonical paths and the tags follow for free, and
# --canonicalize-authors repairs stored paths, after which a retag brings
# those books' tags into line ONCE and then goes quiet.
#
# `artist` and `composer` ARE NEVER REPLACED, and that is unchanged: they
# hold the narrator in some of these files and the author in others, there is
# no reliable narrator to write, and guessing is what produced the defect.
#
# But their SPELLING IS NORMALISED IN PLACE, through the same
# rip::_author_display the path goes through (2026-08-26, second amendment).
# Measured on the live library, on a book pushed twenty minutes after the
# first version of this function landed: album_artist="J. K. Rowling" (ours,
# canonical) beside artist="J.K. Rowling" (the source file's, untouched), and
# Audiobookshelf displayed the UNNORMALISED one. Writing `album_artist` alone
# is NOT sufficient — ABS reads `artist` in preference in some configurations.
#
# Normalising in place is safe exactly where replacement was not: it cannot
# introduce a name that was not already in the file. "J.K. Rowling" becomes
# "J. K. Rowling"; "Jim Dale" has no initials and is untouched; a narrator
# genuinely called "J.D. Jackson" becomes "J. D. Jackson", which is a
# correction rather than a guess.
#
# AND IT DOES NOT BREAK THE CONVERGENCE ARGUMENT ABOVE, because it is not a
# transformation of something the PATH also spells: the rule is idempotent, so
# a canonicalised `artist` reads back already canonical and rip::_tags_match —
# which now asks that question too — finds nothing to do on the next pass.
#
# AN ABSENT TAG IS NOT CREATED. The -metadata flag is added only when the file
# already carries a non-empty value, because the only `artist` this pipeline
# could invent is the author, which is the guess this whole design exists to
# stop making.
#
# A REMUX, not a re-encode (-c copy): no quality loss, and cover art rides
# along as an attached picture stream.
#
# TWO ffmpeg traps are pinned in the invocation below, both measured:
#
#   * `-map 0` ALONE DOES NOT WORK ON AN M4B. An m4b's chapters live in a
#     text track that ffmpeg's mov demuxer exposes as a `bin_data` stream,
#     and the ipod muxer refuses to copy it: "Tag text incompatible with
#     output codec id '98314'", header not written, whole remux failed. The
#     input's data streams are therefore excluded (`-map -0:d?`) and the
#     chapters are re-generated by `-map_chapters 0` — verified to produce
#     an output with the same stream set and the same chapter titles.
#   * THE TEMP MUST KEEP THE REAL EXTENSION. ffmpeg picks its muxer from the
#     OUTPUT FILENAME, so a ".part" suffix makes every invocation fail to
#     find an output format at all (rip-provider-folder's _embedded_cover was
#     bitten by exactly this).
#
# THE VERIFICATION IS THE POINT. ffmpeg's exit code is not evidence: this
# subsystem's signature defect is success reported because control flow
# reached a line rather than because an outcome was established (the cover
# extraction that returned 0 for seven books it never wrote). So the three
# tags are read BACK out of the written file with ffprobe and compared to
# what was intended, and only a file that reads back correctly is renamed
# into place. Verifying the TEMP, before the rename, also means a failure
# leaves the staged book exactly as it arrived rather than half-written.
#
# RIP_FFMPEG_BIN / RIP_FFPROBE_BIN are the usual test seams (the
# RIP_RSYNC_BIN / RIP_SSH_BIN idiom), defaulting to the real tools.
# _RIP_RETAG_FF_MAP — the stream-selection half of the retag remux, in ONE
# place, because the remux is now written TWICE: here, in zsh, against a
# STAGED file, and inside rip::_retag_write's POSIX sh script, against a
# STORED file on cantina. Both encode the same two measured facts (the
# `bin_data` chapter track the ipod muxer refuses, and the chapters that must
# therefore be regenerated), and a change made to one and not the other would
# leave the library-wide sweep remuxing differently from the push that wrote
# the book in the first place — a divergence nothing would report.
#
# Split at whitespace by BOTH readers: `${=_RIP_RETAG_FF_MAP}` here, `set -f`
# plus an unquoted expansion there. The `?` in `-0:d?` is why the remote half
# needs `set -f` — a POSIX sh would otherwise offer it to pathname expansion.
typeset -g _RIP_RETAG_FF_MAP='-map 0 -map -0:d? -c copy -map_chapters 0'

rip::_retag_book() {
  setopt localoptions noerrexit nopipefail
  local f="$1" author="$2" bookname="$3"
  local ffmpeg_bin="${RIP_FFMPEG_BIN:-ffmpeg}" ffprobe_bin="${RIP_FFPROBE_BIN:-ffprobe}"
  [[ -f "$f" ]] || { log_error "rip: no such audio file to retag: $f"; return 1 }
  # An empty author or book name is a REFUSAL, not a partial write: a book
  # this pipeline cannot name authoritatively is exactly the book that must
  # not land in the library carrying whatever the seller happened to embed.
  [[ -n "$bookname" ]] || { log_error "rip: refusing to retag ${f:t} — no book name to write"; return 1 }
  [[ -n "$author" ]] || { log_error "rip: refusing to retag ${f:t} — no author to write"; return 1 }

  # ALREADY CORRECT → do nothing at all. Idempotence is what makes the
  # documented keep-staged retry path (a book re-enriched after a failed
  # verify) cheap instead of a second full remux of a multi-gigabyte file,
  # and it is the half of the convergence property that the sweep in the
  # header comment depends on: a pass that finds nothing to change must
  # leave the bytes, and the mtime, exactly where they were.
  #
  # ONE PROBE, TWO USES. The skip question is asked of JSON that is then kept,
  # because the never-replaced tags have to be read out of the SAME read: a
  # second probe would be a second chance for the file to be answering about a
  # different state, and rip::_tags_match's whole reason for existing is that
  # the skip and the verify cannot be allowed to disagree.
  local js
  js="$("$ffprobe_bin" -v error -select_streams a:0 -show_entries format_tags:stream_tags \
      -of json -- "$f" 2>/dev/null)"
  if rip::_tags_match_json "$js" "$author" "$bookname"; then
    return 0
  fi

  # The scratch write lives under .work/, never inside the book dir itself —
  # the same rule (and the same reasoning) as rip::_book_sidecar's temp: a
  # process killed mid-retag would otherwise leave a second, differently
  # named .m4b sitting IN the book dir, where a LATER push's age-gated find
  # would pick it up and ship it as part of the book. .work/ is a sibling of
  # the type's staging dir and is never enumerated by a push.
  local work_dir; work_dir="$(rip::staging_root)/.work"
  mkdir -p "$work_dir" || { log_error "rip: cannot create $work_dir"; return 1 }
  local tmp="$work_dir/retag.$$.${f:t}"
  rm -f -- "$tmp"

  # WRITTEN AT BOTH LEVELS, for the same reason rip::_tags_match reads both.
  # `-metadata` alone reaches only the FORMAT level, and the ogg/opus muxers
  # write the stream's VorbisComment — measured: an opus remux carrying
  # `-metadata album_artist=<new>` came back still holding the OLD value,
  # copied off the input stream. `-metadata:s:a:0` is inert for mp4 (its
  # stream tags carry only language/handler_name, and the format tags land
  # correctly), so one invocation serves every container this retags.
  local -a mdargs=(
    -metadata album_artist="$author" -metadata album="$bookname" -metadata title="$bookname"
    -metadata:s:a:0 album_artist="$author" -metadata:s:a:0 album="$bookname"
    -metadata:s:a:0 title="$bookname"
  )

  # THE NEVER-REPLACED PAIR, normalised in place. Read out of the probe above
  # and written back through rip::_author_display — the flag is added ONLY for
  # a tag the file already carries a non-empty value for, so an absent one is
  # never created and an empty one is left exactly as empty as it was.
  #
  # An array, not a string: every value here is a person's name and contains
  # spaces, and a command line assembled by concatenation would split them.
  local tag cur
  for tag in artist composer; do
    cur="$(print -r -- "$js" | jq -r --arg k "$tag" \
      '((.format.tags // {}) + ((.streams[0].tags) // {})) | .[$k] // ""' 2>/dev/null)"
    [[ -n "$cur" ]] || continue
    cur="$(rip::_author_display "$cur")"
    mdargs+=(-metadata "$tag=$cur" -metadata:s:a:0 "$tag=$cur")
  done

  "$ffmpeg_bin" -v error -y -i "$f" ${=_RIP_RETAG_FF_MAP} "${mdargs[@]}" \
    -- "$tmp" </dev/null >/dev/null 2>&1
  local wrc=$?

  # Read the tags back out of what was ACTUALLY written, and judge on that.
  if ! rip::_tags_match "$tmp" "$author" "$bookname"; then
    # Only now (a failure is rare, and this is the message's only reader) pay
    # a second probe, so the operator is told what the file actually says
    # rather than just that something went wrong.
    local got
    got="$("$ffprobe_bin" -v error -select_streams a:0 -show_entries format_tags:stream_tags \
        -of json -- "$tmp" 2>/dev/null \
      | jq -c '((.format.tags // {}) + (.streams[0].tags // {})) | {album_artist, album, title, artist, composer}' 2>/dev/null)"
    [[ -n "$got" ]] || got='(nothing readable was written)'
    # artist/composer are in the read-back because they can now BE the reason
    # it failed: they are never replaced, but their spelling must come back
    # canonical, and an operator shown three correct-looking tags and no
    # fourth would have nothing to act on.
    if (( wrc == 0 )); then
      log_error "rip: ffmpeg reported success but the tags did not take on ${f:t} — wanted album_artist=\"$author\" album=\"$bookname\" title=\"$bookname\" (and artist/composer in canonical spelling), read back $got"
    else
      log_error "rip: could not write tags to ${f:t} (ffmpeg rc=$wrc) — read back $got"
    fi
    rm -f -- "$tmp"
    return 1
  fi

  mv -f -- "$tmp" "$f" || {
    log_error "rip: could not move the retagged ${f:t} into place"
    rm -f -- "$tmp"
    return 1
  }
  return 0
}

# rip::_retag_staged_book <bookdir> <author> <bookname> — retag every audio
# file the book dir holds. rc non-zero when ANY of them could not be written
# and verified.
#
# EVERY audio file, not just the primary: a multi-part book whose part 2 kept
# the seller's metadata is the same defect, one file down.
#
# TWO DELIBERATE EXCLUSIONS, and both are WARNED rather than silently skipped:
#
#   * `.aax`/`.aaxc` — a retained Audible original is still DRM encrypted and
#     ffmpeg cannot remux it without the account's activation bytes. It is not
#     the copy the library reads (the `.m4b` beside it is), and the module's
#     own "the audio IS the book" rule already treats it as an also-ran.
#   * `.wav`/`.aac` — the container CANNOT CARRY the tag (review finding F1,
#     2026-08-26). WAV's RIFF INFO has no album-artist chunk at all (measured:
#     `album` and `title` take, `album_artist` reads back null), and raw ADTS
#     `.aac` has no metadata container whatsoever. Without this arm they were
#     not merely untagged, they were UNPUSHABLE: the verification can never
#     pass, so the book is refused, and the retry that is this design's whole
#     remedy can never clear a deterministic failure. A book that cannot be
#     tagged authoritatively must not become a push that can never succeed —
#     so it ships, and the operator is told why, in a message they can act on
#     (re-encode to m4b) rather than a refusal they can only re-run.
#
# Both are first-class inputs: rip::ab_import accepts any extension for a
# single file, and `.opus`/`.wav` are what DRM-free downloads carry.
rip::_retag_staged_book() {
  setopt localoptions noerrexit nopipefail
  local dir="$1" author="$2" bookname="$3"
  local f base rc=0 n=0
  for f in "$dir"/*(N.); do
    base="${f:t}"
    case "${(L)base}" in
      *.aax|*.aaxc)
        log_warn "rip: not retagging ${f:t} — a DRM-encrypted Audible original cannot be remuxed; the library reads the .m4b beside it"
        continue ;;
      *.wav|*.aac)
        log_warn "rip: not retagging ${f:t} — this container cannot carry album_artist, so its tags cannot be made authoritative; re-encode to .m4b if the library must show them"
        continue ;;
      *.m4b|*.m4a|*.mp3|*.mp4|*.flac|*.ogg|*.opus) ;;
      *) continue ;;
    esac
    n=$(( n + 1 ))
    rip::_retag_book "$f" "$author" "$bookname" || rc=1
  done
  # No audio here at all: nothing to tag, and nothing this function can
  # conclude about a directory that is not a book. Whether an acquire
  # produced audio is rip::_dir_has_audio's job, and it is already asked.
  (( n > 0 )) || return 0
  return $rc
}

# rip::_book_rel_of <staged relpath> — the "<Author>/<Title>" a staged path
# belongs to: its first two components, or the whole thing when it has fewer.
#
# ONE answer to "which book is this?", because two callers now need it to
# agree exactly: the pre-scan that decides whether a book is refused, and the
# per-directory loop that has to skip every member of a refused book. A path
# that is already exactly <Author>/<Title> comes back unchanged, which is how
# both callers tell a valid book from a too-deep or too-shallow one — `$d`
# equals its own book rel if and only if it IS the book.
rip::_book_rel_of() {
  local d="${1:-}"
  if [[ "$d" == */* ]]; then
    print -r -- "${d%%/*}/${${d#*/}%%/*}"
  else
    print -r -- "$d"
  fi
}

# rip::_listfile_drop <listfile> <reldir> — remove every entry under <reldir>
# from the push list, so a refused book cannot reach the rsync.
#
# The list is the ONE fixed set the push, the verify and the clean all drive
# off (see rip::push_worker), so dropping a book here is what makes "not
# pushed" true of all three at once — it is never transferred, never
# verified, and never deleted from staging, which is exactly what the
# operator's retry needs to find.
#
# The prefix test is `"$d"/*`, and BOTH halves of that are load-bearing. $d
# is QUOTED so its own characters stay literal — a book title is free to
# contain `[`, `?` or `*`, and unquoted they would be read as pattern syntax
# and match the wrong lines (or none). And the `/` before the `*` is what
# stops a refused book taking its similarly named neighbour down with it:
# "A/B" must not match "A/B (Full Cast)/x", which a bare prefix test would.
rip::_listfile_drop() {
  setopt localoptions noerrexit nopipefail
  local lf="$1" d="$2" line
  [[ -f "$lf" && -n "$d" ]] || return 1
  local tmp="$lf.drop.$$"
  : > "$tmp" || return 1
  while IFS= read -r line; do
    # "." is what ${rel:h} yields for a file staged at the TOP of the type's
    # dir rather than under <Author>/<Title> — not a shape this pipeline
    # produces, but a shape a push can be handed, and it must not be the one
    # case where a refusal silently ships the book anyway.
    if [[ "$d" == "." ]]; then
      [[ "$line" != */* || "$line" == ./* ]] && continue
    else
      [[ "$line" == "$d"/* ]] && continue
    fi
    print -r -- "$line" >> "$tmp"
  done < "$lf"
  mv -f -- "$tmp" "$lf" || { rm -f -- "$tmp"; return 1 }
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
  # Declared ONCE, out here, loop variables included: a bare `local` re-run
  # in a loop body prints "name=value" onto the stream this runs on, and
  # this file has been bitten by that before.
  local d meta hop failed=0 refused=0 b_author b_book b_rel
  local -A refused_book=()

  # THE PRE-SCAN, AND IT HAS TO BE A PRE-SCAN (review finding, 2026-08-26).
  #
  # `dirs` is one entry per distinct ${rel:h}, with no notion of nesting, so
  # ONE book laid out the way rip::ab_import's `cp -R` produces it —
  # "<Author>/<Title>/zz-notes.pdf" beside "<Author>/<Title>/Disc 1/book.m4b"
  # — arrives here as TWO entries: the valid "<Author>/<Title>" and the
  # invalid "<Author>/<Title>/Disc 1". Refusing them one at a time inside the
  # loop below is not enough, because the shallow entry is a perfectly valid
  # book path in its own right: it wrote a `.fleet-book.json` for a book whose
  # audio had just been refused, and rip::_enrich_add PUT THAT SIDECAR BACK on
  # the push list after the refusal had dropped it. An orphan identity then
  # shipped to cantina for a book that never arrived, with the push reporting
  # rc 1 and "verified on cantina" in the same breath.
  #
  # Which symptom you got depended on which sibling `find` returned first
  # (rip::push_worker's find is unsorted), so it was intermittent rather than
  # absent — the worst shape a bug can have.
  #
  # Deciding the whole book's fate BEFORE any member is touched is what makes
  # iteration order irrelevant: nothing under a refused book is meta-read,
  # sidecar-written, tagged, re-added or hopped, in any order.
  for d in "${dirs[@]}"; do
    b_rel="$(rip::_book_rel_of "$d")"
    # Refused when the entry is not exactly its own <Author>/<Title>: too
    # deep ("A/B/Disc 1"), or too shallow ("A", or "." for a file staged at
    # the top of the type's tree). No slicing can recover which segment is
    # the author from a path that does not say, so refuse and name it.
    [[ "$d" == "$b_rel" && "$b_rel" == */* && "$b_rel" != */*/* ]] && continue
    refused_book[$b_rel]=1
  done
  for b_rel in "${(@k)refused_book}"; do
    log_error "rip: refusing to push \"$b_rel\" — a staged book is <Author>/<Title>, and tags cannot be written from a path that does not say which is which"
    # The whole BOOK is dropped, companions and sidecar included, not just
    # the sub-directory the audio happened to sit in.
    rip::_listfile_drop "$listfile" "$b_rel" \
      || log_error "rip: could not drop \"$b_rel\" from the push list"
    refused=1
  done

  for d in "${dirs[@]}"; do
    [[ -d "$src/$d" ]] || continue
    # Every member of a refused book, skipped before anything is written.
    (( ${+refused_book[$(rip::_book_rel_of "$d")]} )) && continue
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
    # THE AUTHORITATIVE TAGS (design doc S2). The author and the book name
    # come from the STAGED PATH, not from the provider row, and they are
    # written VERBATIM, because the path is what the library shows and the
    # invariant is that the tags say what the path says. The two are NOT the
    # same string: the libation provider emits title "Steelheart" for a
    # directory it names "Steelheart: The Reckoners, Book 1", and
    # rip::_canonicalize_staged_authors may have already renamed the author
    # directory to the spelling the server uses while the row still carries
    # the provider's. The edition needs no special handling here for the same
    # reason — the panel composed the path as "<Author>/<Title> (<Edition>)",
    # so the directory name already IS "<Title> (<Edition>)".
    #
    # EXACTLY TWO COMPONENTS, guaranteed by the pre-scan above (review
    # finding F2, 2026-08-26). $d is ${rel:h}, so a book whose audio sits one
    # level deeper — "<Author>/<Title>/Disc 1/…", which rip::ab_import's
    # directory copy will happily produce — used to reach this with the WRONG
    # TWO SEGMENTS in hand and stamp album_artist="<Title>", album="Disc 1"
    # into the audio. Audiobookshelf would then show a book called "Disc 1"
    # by an author called "Deathly Hallows": the exact wrong this phase
    # exists to fix, no longer merely READ out of the file but written
    # authoritatively into it.
    #
    # NFC, because the tag is REMOTE text (review finding F4, 2026-08-26).
    # macOS stages accented names DECOMPOSED and this module deliberately
    # leaves local staging paths that way (see rip::_nfc's contract), while
    # the push --iconv's to NFC on the wire — so the server path, and every
    # comparison spec S4's `--retag` sweep makes against it, is composed. A
    # tag written from the raw staged bytes would differ from the server path
    # on every accented author and be rewritten on every sweep: the same
    # non-convergence the verbatim-author rule removes, through another door.
    # Exactly two components by construction now — the pre-scan above refused
    # and skipped anything else, so this is a plain split, not a check.
    b_author="$(rip::_nfc "${d%%/*}")"
    b_book="$(rip::_nfc "${d#*/}")"
    if ! rip::_retag_staged_book "$src/$d" "$b_author" "$b_book"; then
      # REFUSED, not warned (design doc S3, the operator's rule verbatim:
      # "not failing on error is a recipe for drift in the long run"). The
      # book is dropped from the push list, so it is never transferred,
      # never verified and never deleted from staging — the retry finds it
      # exactly where it was.
      log_error "rip: refusing to push \"$d\" — its tags could not be written and verified"
      rip::_listfile_drop "$listfile" "$d" \
        || log_error "rip: could not drop \"$d\" from the push list"
      refused=1
      continue
    fi
    for hop in "${RIP_AB_ENRICH_HOPS[@]}"; do
      (( $+functions[$hop] )) || { log_warn "rip: no such enrichment hop: $hop"; failed=1; continue }
      "$hop" "$src/$d" "$src/$d/.fleet-book.json" "$d" \
        || { log_warn "rip: enrichment hop failed: $hop ($d)"; failed=1 }
    done
  done
  # rc 3 is DISTINCT from rc 1 on purpose: 1 is this pass's ordinary
  # best-effort failure ("log and push anyway", the hop contract), while 3
  # says a book was REFUSED and the push must report a failure even if every
  # other book lands. See rip::push_worker, which is the only caller.
  (( refused )) && return 3
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

# rip::_remote_has_file / rip::_remote_has_dir <media_relpath> — existence
# check on the server for
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
#
# rip::_remote_has_file and rip::_remote_has_dir are the two entry points;
# both are one-line wrappers over rip::_remote_test, which takes the `test`
# flag as its first argument. ONE body, so the -n guard, the NFC
# normalization and the ${(q)} quoting below can never drift apart between a
# file probe and a directory probe.
rip::_remote_test() {
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
  local flag="$1"
  local relpath; relpath="$(rip::_nfc "$2")"
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
    # -n IS LOAD-BEARING, NEVER REMOVE IT (review finding, 2026-08-24).
    # Without -n, ssh(1) reads THIS SHELL's stdin eagerly and forwards it to
    # the remote, whether or not the remote command consumes it — and `test
    # -f` never does. Callers run this helper inside `while read` loops fed by
    # a here-string or a pipe (the --repair-sidecars sweep is one: `done <<<
    # "$lib"`), so a single probe swallowed the entire remaining library and
    # the loop ended after ONE book — silently, with rc 0 and a report that
    # looked complete. Third appearance of this fd-0 family in this subsystem
    # (the author sweep's variants list, LibationCli under pueue), so the
    # guard lives HERE, at the source, where it protects every present and
    # future caller instead of one call site.
    "$ssh_bin" -n -o BatchMode=yes -o ConnectTimeout=5 \
      "$host" "test $flag ${(q)rfile}" 2>/dev/null
    local rc=$?
    (( rc == 0 )) && return 0
    (( rc == 1 )) && return 1
    return 2
  fi
  test "$flag" "$base/$relpath" && return 0
  return 1
}

rip::_remote_has_file() { rip::_remote_test -f "$1" }

# rip::_remote_has_dir <media_relpath> — the same tri-state for a DIRECTORY.
# Used where the question is "does the server hold this book/album at all",
# which must not be answered by guessing at a filename inside it.
rip::_remote_has_dir() { rip::_remote_test -d "$1" }

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

# rip::ab_library [name] [root] — the provider's JSON lines, passed through
# unmodified (the panel's own jq does the shaping). `root` is forwarded to
# the provider's `list` verb ONLY when non-empty: passing "" as $2 would
# make a scanning provider (rip-provider-folder) walk the empty string, and
# argv length is part of the contract.
rip::ab_library() {
  setopt localoptions noerrexit nopipefail
  local bin; bin="$(rip::ab_provider_bin "${1:-}")" || return 2
  local root="${2:-}"
  if [[ -n "$root" ]]; then
    zsh "$bin" list "$root"
  else
    zsh "$bin" list
  fi
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
# rip::_remote_has_dir.
#
# THE BOOK DIRECTORY, NOT A GUESSED FILENAME (review finding, 2026-08-25).
# This used to probe "<Title>/<Title>.m4b" — an invariant only rip::ab_import
# upholds and only Libation happens to satisfy. The folder provider copies
# source basenames verbatim, so for a locally imported book the probe asked
# about a file that never exists and the "already on cantina" refusal could
# NEVER fire: re-tag a source file, re-rip, and the book directory ends up
# holding two differently-named .m4b (rsync carries no --delete by doctrine),
# after which rip::_sidecars_hash_primary picks whichever sorts first.
#
# The directory is the provider-blind question, and it is deliberately the
# LENIENT one. This check is also on the Libation path, against a library of
# ~248 books, many of them predating sidecars entirely — so anything stricter
# than "is the book there" (a sidecar probe, an *.m4b probe) would report a
# legacy shape as ABSENT and re-push the whole library. Every stored shape —
# Libation's <Title>/<Title>.m4b, a manual import under any filename, a book
# stored as .mp3 or .m4a, a book with no .fleet-book.json — answers "present"
# on the directory alone. rip::ab_retire already reasons this way for the
# same reason ("a manual import carries whatever filename it was given, and
# would read as not stored"), only via the whole-library listing; here one
# targeted probe is enough, and keeps the per-item cost at exactly what it
# was before.
rip::ab_have() {
  local rel="$1"
  [[ -n "$rel" ]] || { log_error "rip: empty book path"; return 2 }
  rip::_remote_has_dir "audiobooks/$rel"
}

# rip::ab_at_risk — the irreplaceable set: books cantina holds that are
# Audible Plus AND absent from Audible's last scan.
#
# WHY THIS VERB EXISTS. The runbook's backup doctrine used to be "audiobooks
# are not backed up; if the volume is lost, re-export from Libation — Audible
# is the permanent copy". That is true for a title you BOUGHT and false for a
# title you BORROWED: an Audible Plus book is licensed only while it sits in
# the catalog, and when it leaves, Libation can never liberate it again. Four
# Talon Saga books were lost that way with no warning. For a Plus title
# already ripped, the server copy is then the ONLY copy in existence — this
# verb is how the operator learns which those are.
#
# READ-ONLY by construction: no --apply, no writes, no ssh beyond the ONE
# listing rip::_server_sidecars already makes.
rip::ab_at_risk() {
  setopt localoptions noerrexit nopipefail

  # Captured as VALUES so their failure PROPAGATES. Read through `< <(...)`
  # an unreachable server is byte-identical to an empty library, and this
  # verb printing "nothing at risk" for a server it never reached is the
  # exact false reassurance it exists to prevent.
  #
  # rip::_server_sidecars, not rip::ab_server_library: the ASIN tier below
  # needs each stored book's ids["audible.asin"], which only the sidecar
  # carries, and _server_sidecars already emits every sidecar with its
  # "<Author>/<Title>" attached as `_path`. Reusing it here — the same
  # enumeration rip::ab_editions and rip::ab_backfill_published already pull
  # from — is what keeps this verb at ONE remote round trip instead of two.
  local rows; rows="$(rip::_server_sidecars)" || return 2

  local pname="${RIP_AB_PROVIDER:-libation}"
  local pbin; pbin="$(rip::ab_provider_bin "$pname")" || return 2
  local prows; prows="$(zsh "$pbin" list 2>/dev/null)"
  if [[ -z "$prows" ]]; then
    log_error "rip: the $pname library returned no rows — refusing to report an at-risk set derived from an empty library"
    return 2
  fi

  # THE JOIN IS THREE-TIER, ASIN first. 246 of 247 stored sidecars carry
  # ids["audible.asin"] (backfilled 2026-08-24), and the matching provider
  # row carries the same value as `.id` — an exact key, immune to the
  # author/title spelling divergence that motivated the other two tiers:
  # Libation files a book under "Shawn Speakman - editor" where the server
  # holds "Shawn Speakman", and rip::_canonical_author measured one such
  # author collision across 116 distinct first-authors on 2026-08-23.
  #
  # The exact-composed-path and title tiers remain, unchanged, as FALLBACKS
  # for the rare stored book whose sidecar carries no ASIN at all — under a
  # path-only join those stored books matched no row and were silently
  # folded into "not at risk"; what still matches when the author spelling
  # diverges is the composed TITLE component.
  #
  # Every row is indexed, not just the at-risk ones, because this verb has
  # to tell four states apart: at risk, established-safe, an ASIN the
  # provider no longer lists, and no ASIN to try in the first place. The
  # flag is "1" (plus AND absent) or "0"; the ASIN and path maps take the
  # FIRST row for a given key (an exact identifier is not expected to
  # collide), but the title key accumulates one character per candidate
  # row, so "1"/"0" is an unambiguous answer and "10" is candidates that
  # disagree — which establishes nothing.
  #
  # Path/title matching goes through rip::_nfc: the server is NFC and macOS
  # composes NFD, so an accented author would otherwise read as "no match".
  # The ASIN is an opaque identifier and needs no such normalization.
  local -A prisk=() ptitle_risk=() pasin_risk=()
  local ppath pflag pasin ptitle
  while IFS=$'\t' read -r ppath pflag pasin; do
    [[ -n "$ppath" ]] || continue
    ppath="$(rip::_nfc "$ppath")"
    [[ -n "${prisk[$ppath]:-}" ]] || prisk[$ppath]="$pflag"
    ptitle="${ppath##*/}"
    ptitle_risk[$ptitle]+="$pflag"
    if [[ -n "$pasin" ]]; then
      [[ -n "${pasin_risk[$pasin]:-}" ]] || pasin_risk[$pasin]="$pflag"
    fi
  done < <(print -r -- "$prows" \
    | jq -r 'select((.path // "") != "")
             | (.path) + "\t"
               + (if (((.plus // false) == true) and ((.absent // false) == true))
                  then "1" else "0" end)
               + "\t" + (.id // "")' 2>/dev/null)

  # found: genuinely at risk. not_established: HAS an Audible ASIN, but no
  # provider row carries it any more — the real anomaly (spec 2026-08-24:
  # report the SHAPE, not a diagnosis — a lapsed Plus licence, a returned
  # purchase and an account change all produce this same evidence, and
  # nothing here can tell them apart). not_audible: no ASIN in the sidecar
  # at all, so this isn't an Audible-provider book to begin with (a manual
  # import) — out of this check's scope, not a gap in it.
  local -a found=() not_established=() not_audible=()
  local rel asin nrel flags
  while IFS=$'\t' read -r rel asin; do
    [[ -n "$rel" ]] || continue
    if [[ -n "$asin" ]]; then
      flags="${pasin_risk[$asin]:-}"
      if [[ -z "$flags" ]]; then
        not_established+=("$rel")
        continue
      fi
    else
      nrel="$(rip::_nfc "$rel")"
      flags="${prisk[$nrel]:-}"
      [[ -n "$flags" ]] || flags="${ptitle_risk[${nrel##*/}]:-}"
      if [[ -z "$flags" ]]; then
        # NO ROW AT ALL, NO ASIN TO TRY. Not an Audible-provider book.
        not_audible+=("$rel")
        continue
      fi
    fi
    if [[ "$flags" != *0* ]]; then
      found+=("$rel")
    elif [[ "$flags" == *1* ]]; then
      # Title-tier candidates that disagree: one says lapsed, another says
      # owned, and nothing here says which one this folder is. Only the
      # title tier ever accumulates more than one flag, and it is only ever
      # consulted for a book with no ASIN — so this is the no-ASIN "could
      # not establish" case, not the real ASIN anomaly above. Never at-risk
      # either way — do not weaken that.
      not_audible+=("$rel")
    fi
  done < <(print -r -- "$rows" \
    | jq -r '(._path // "") + "\t" + (.ids["audible.asin"] // "")' 2>/dev/null)

  local f
  if (( ${#found} )); then
    print -r -- "rip: ${#found} stored book(s) can NEVER be re-acquired."
    print -r -- "rip: each is an Audible Plus title — licensed while it sits in the catalog, not owned — and Audible's last scan no longer returns it, so its licence has lapsed and Libation cannot liberate it again. The copy on cantina is the only copy that exists."
    for f in "${(@o)found}"; do
      print -r -- "    $f"
    done
  elif (( ${#not_established} == 0 && ${#not_audible} == 0 )); then
    print -r -- "rip: nothing at risk — every book on cantina is either owned outright or still in the Audible Plus catalog."
  elif (( ${#not_established} == 0 )); then
    # ONLY manual imports are left unaccounted for. That is not a gap in the
    # Audible check — those books are simply out of its scope — so this
    # still cannot say "every book on cantina", but for a different reason
    # than the hedge below: every Audible-provider title WAS resolved.
    print -r -- "rip: nothing at risk among cantina's Audible titles — each of those is either owned outright or still in the Audible Plus catalog."
  else
    # CLAIM ONLY WHAT THE JOIN ESTABLISHED. With a book carrying an Audible
    # ASIN the provider no longer lists, this line must not say "every book
    # on cantina": that book is exactly the one it could not speak for.
    print -r -- "rip: nothing at risk among the books that matched a $pname row — each of those is either owned outright or still in the Audible Plus catalog."
  fi

  if (( ${#not_established} )); then
    if (( ${#not_established} == 1 )); then
      print -r -- "rip: 1 stored book(s) carries an Audible ASIN that $pname no longer lists — its Plus status could not be established:"
    else
      print -r -- "rip: ${#not_established} stored book(s) carry an Audible ASIN that $pname no longer lists — their Plus status could not be established:"
    fi
    for f in "${(@o)not_established}"; do
      print -r -- "    $f"
    done
  fi

  if (( ${#not_audible} )); then
    if (( ${#not_audible} == 1 )); then
      print -r -- "rip: 1 stored book(s) does not seem to be an Audible book:"
    else
      print -r -- "rip: ${#not_audible} stored book(s) do not seem to be Audible books:"
    fi
    for f in "${(@o)not_audible}"; do
      print -r -- "    $f"
    done
  fi
  return 0
}

# rip::_server_sidecars — every stored sidecar as JSON lines, each carrying
# the "<Author>/<Title>" it came from as `_path`. ONE ssh: 248 books is ~124 KB
# of JSON, and a call per book would be 248 round-trips.
rip::_server_sidecars() {
  setopt localoptions noerrexit nopipefail
  local base; base="$(rip::remote_base)"
  # NO `find -printf` here: it is a GNU extension that stock BSD/macOS find
  # rejects outright, and this same script runs BOTH remotely (Linux) and
  # locally (the hermetic tests' plain-directory remote base, on macOS).
  # Verified 2026-08-24: it appears to work interactively on the dev machine
  # only because `find` there resolves to brew's bfs; /usr/bin/find fails with
  # "-printf: unknown primary or operator". Strip the leading "./" instead.
  local script='find . -mindepth 3 -maxdepth 3 -name .fleet-book.json 2>/dev/null | while read -r f; do d=${f#./}; d=${d%/.fleet-book.json}; printf "%s\t" "$d"; tr -d "\n" < "$f"; printf "\n"; done'
  # PROPAGATE THE FAILURE (review finding 4, 2026-08-24). Both branches used
  # to discard their status, so an ssh that exited 255 produced an empty
  # enumeration and rc 0 — byte-identical, to every caller, to a library
  # with nothing in it. Measured with a stub ssh exiting 255: `--editions`
  # returned rc 0 with no output, which reads as "your library has no
  # duplicate editions" and is the report the operator consults before
  # deciding what to DELETE. rip::ab_canonicalize_authors already refuses
  # this way (rc 2 on an unreachable server); so does rip::ab_retire.
  local raw rc=0
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    raw="$("$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "cd ${(q)rpath}/audiobooks 2>/dev/null && $script" 2>/dev/null)" || rc=$?
  else
    raw="$(cd "$base/audiobooks" 2>/dev/null && eval "$script")" || rc=$?
  fi
  if (( rc != 0 )); then
    log_error "rip: could not read the stored sidecars from cantina (rc=$rc) — refusing to report on a library we could not reach"
    return 2
  fi
  # A line that fails to parse (a truncated/corrupt sidecar) must not just
  # vanish: this enumerator also feeds rip::ab_editions, so a silently
  # dropped book would disappear from every report an operator uses to
  # reason about the library, with no sign anything was skipped (review
  # finding 2026-08-24). The output CONTRACT is unchanged — still one JSON
  # object per readable sidecar, `_path` attached — only a new stderr
  # warning is added for the ones that don't parse.
  local line rel json out
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rel="${line%%$'\t'*}"; json="${line#*$'\t'}"
    # NORMALIZE `ids` HERE, at the boundary (review finding, 2026-08-25). A
    # sidecar written from a Lua-encoded plan can carry `"ids": []` instead of
    # `{}` (see _RIP_JQ_IDS_DEF), and every downstream reader of these rows
    # indexes ids by string — `.ids["audible.asin"]`, `.ids["local.sha256"]`,
    # `.ids + {…}` — each of which RAISES on an array, silently dropping that
    # book from whichever report is asking. This is the one funnel all of them
    # pass through, so coercing once here protects rip::ab_at_risk,
    # rip::ab_editions, rip::_stored_sha_index and rip::_sidecar_index alike.
    # The two indexes coerce again on their own: they carry their own stdin
    # contracts and must not depend on who fed them.
    out="$(print -r -- "$json" | jq -c --arg p "$rel" "$_RIP_JQ_IDS_DEF"'_ids_fix | . + {_path:$p}' 2>/dev/null)"
    if [[ -n "$out" ]]; then
      print -r -- "$out"
    else
      log_warn "rip: malformed sidecar for $rel — skipped"
    fi
  done <<< "$raw"
}

# rip::_stored_sha_index — "<sha256>\t<Author>/<Title>" for every stored book
# whose sidecar carries ids["local.sha256"].
#
# This is the dedupe key for locally-imported books. It is EXACT: it
# identifies the same bytes regardless of how anyone spelled the author,
# which path and title matching cannot do (Libation files a book under
# "Shawn Speakman - editor" where the server has "Shawn Speakman", and
# normalized author matching fails on that too).
#
# Derived from the ONE ssh rip::_server_sidecars already makes, and cached
# for the life of the process: an acquire batch consults it per book and
# must not open a connection per book.
#
# CALL AS A PLAIN COMMAND ONCE, BEFORE ANY FORK, then read $_RIP_STORED_SHA
# directly — the identical contract rip::_server_authors carries (below,
# and at both its callers), for the identical reason: the cache lives in
# these globals, and stdout is only a courtesy copy. `$(...)` and `< <(...)`
# both fork a subshell, and a fork's copy of the cache dies with it.
# Measured with a counting fake ssh over three books: direct in-shell calls
# made ONE ssh; `$( )`, `< <( )`, and a plain pipe each made THREE. A
# consumer that reads the printed copy from inside a per-item loop must
# prime this once, in the loop's own shell, before the loop starts —
# exactly as rip::_canonicalize_staged_authors primes rip::_server_authors.
typeset -g _RIP_STORED_SHA_FETCHED
typeset -g _RIP_STORED_SHA
rip::_stored_sha_index() {
  setopt localoptions noerrexit nopipefail
  if [[ -z "${_RIP_STORED_SHA_FETCHED:-}" ]]; then
    local rows rc=0
    rows="$(rip::_server_sidecars)" || rc=$?
    if (( rc != 0 )); then
      # Do NOT set _FETCHED on failure. rip::_server_sidecars was
      # deliberately given failure propagation (review finding 4,
      # 2026-08-24) precisely so an unreachable server cannot be
      # mistaken for "asked, and it has nothing" — the same distinction
      # the editions report already protects, and _server_sidecars'
      # own log_error already told the operator why. This function is a
      # DEDUPE check: an empty index reads as "not a duplicate", so
      # swallowing the failure here would silently DISABLE dedupe on an
      # ssh outage instead of refusing it — and caching _FETCHED=1
      # anyway would make that outage permanent for the rest of the
      # process. Leaving it unset lets the next call retry.
      return $rc
    fi
    _RIP_STORED_SHA_FETCHED=1
    # `_ids_obj` before any string subscript: a sidecar carrying `"ids": []`
    # (see _RIP_JQ_IDS_DEF) makes `.ids["local.sha256"]` raise, and the raise
    # is swallowed by the `2>/dev/null` right there — the book vanishes from
    # the dedupe index with rc 0, which reads as "not a duplicate".
    _RIP_STORED_SHA="$(print -r -- "$rows" \
      | jq -r "$_RIP_JQ_IDS_DEF"'(.ids | _ids_obj) as $ids
          | select(($ids["local.sha256"] // "") != "")
          | "\($ids["local.sha256"])\t\(._path)"' 2>/dev/null)"
  fi
  print -r -- "$_RIP_STORED_SHA"
}

# rip::ab_editions — works stored in more than one edition.
#
# The rule (spec 2026-08-24): same normalized first author, same normalized
# bare title, and BOTH published dates present and DIFFERENT. Measured against
# the real library that is 2 true positives and 0 false positives. The
# different-date requirement is what keeps two PARTS of one issue — which
# share a publication date — from being read as a stale edition of each other,
# a mistake whose remedy would be a deletion.
#
# The all-distinct check below is PER CLUSTER, not "does at least one pair
# differ": a cluster is reported only when EVERY member's `published` is
# distinct from every other member's (unique count == row count). A mixed
# cluster — say two rows sharing a date plus a third with a different one —
# cannot be safely presented as an edition list, because some of its rows
# are parts of one issue rather than alternative editions, and the report's
# only downstream action is deleting a "stale" copy. Reporting nothing costs
# a manual look; reporting a misleading pair costs a deleted book that the
# server holds the only copy of. So ANY repeated date anywhere in the
# cluster suppresses the whole cluster, not just the tied rows (review
# finding 2026-08-24, reproduced against the shipped jq with a 3-member
# cluster: two rows dated 2001-01-01 plus one dated 2005-06-01 were all
# printed side by side under the old "any pair differs" filter).
#
# COMPARED ON THE DATE, NOT THE RAW FIELD (review finding 2, 2026-08-24).
# `published` is Libation's DatePublished — a full timestamp
# ("2013-09-24T07:00:00") — but the line this function PRINTS is
# \(.published[0:10]) and the panel's own edition mark slices the same ten
# characters (rip-library.html, otherEditionHtml). Filtering on the raw
# field let two parts of one issue that share a calendar date but differ in
# the time component through as an "edition set": two identical printed
# dates, one of them marked `<- newest`, with a deletion as the only
# downstream action — and the panel showing NO mark for the same pair, so
# the two operator surfaces disagreed. Not hypothetical in form: T07:00:00
# and T08:00:00 are midnight-Pacific renderings, so a plain-date record
# (T00:00:00) mixed with a converted one on the same calendar day is the
# natural way this arrives.
#
# A non-empty first author is required for the same reason the date must be
# present: the group key is (first author, bare title), so two authorless
# books sharing a bare title would otherwise cluster on ("", "sometitle")
# and be offered up as editions of each other.
#
# An unreachable server RETURNS 2 and prints nothing rather than the empty
# output that reads as "your library has no duplicate editions" — this is
# the one report an operator consults before deciding what to delete
# (review finding 4, 2026-08-24). rip::_server_sidecars is captured as a
# VALUE, not piped: through a pipe its status is invisible here.
#
# GROUPS BY `work.uid` FIRST (design doc 2026-08-25-audiobook-editions, S6).
# The heuristic above catches ACCIDENTAL same-title duplicates; it cannot see
# a DELIBERATE edition, because a deliberate edition (design S3, the panel's
# Edition field) composes a DIFFERENT title on purpose — that is what clears
# the path collision. Two rows sharing a non-null `work.uid` are two editions
# of one work regardless of what their titles say, so they are grouped on
# that FIRST, and every row NOT in a reported uid group falls through to the
# author+title+date pipeline, unchanged. A uid group of size one — a book
# that anchors a work but has no sibling edition yet — is not a finding as a
# uid group and is dropped from that section, exactly like a same-title
# cluster of one.
#
# BUT IT FALLS THROUGH TO THE DATE PIPELINE, and that is the whole reason
# the partition below splits on GROUP MEMBERSHIP rather than on the mere
# PRESENCE of a uid (review finding, 2026-08-26). --backfill-work-uid is
# REQUIRED (design S5) and mints a uid for EVERY stored book, so after the
# one sweep the operator is told to run, "books without a uid" is the empty
# set: a `$rest` defined as `uid_of == ""` made the date section stop
# printing forever, while each of those books was also a singleton uid group
# and therefore dropped from the uid section too. The date-derived pair
# vanished from BOTH sections — rc 0, no output, on the one report an
# operator consults before deciding what to delete. An anchored book with no
# sibling edition is exactly as unexamined as it was before it was anchored,
# so it must reach the heuristic exactly as it did then.
#
# The two kinds are printed under separate headings: a confirmed edition set
# and a suspected accidental duplicate are different findings, and merging
# them would bury the accidental ones (design S6). Recency has no meaning
# inside a uid group — editions are not "newer" or "older" than each other —
# so the "<- newest" marker stays exactly where it was, inside the
# date-derived section only.
#
# THE TRAP (carried forward from `.ids`, review finding 2026-08-25, see
# _RIP_JQ_WORK_DEF): `.work` can be `[]` rather than `{}` — a Lua-encoded
# empty table round-trips that way — and `.work.uid` RAISES on an array. The
# raise would abort the whole `-s` (slurp) program under the `2>/dev/null`
# below, so ONE poisoned sidecar would silently drop every other book from
# BOTH sections of this report while `--editions` still exited 0. Every read
# of `.work` here goes through `_work_obj` first (from $_RIP_JQ_WORK_DEF,
# prefixed below), never a bare `.work.uid` — a poisoned row simply reads as
# "no uid" and falls through to the date pipeline like any other unanchored
# book, instead of taking the rest of the library down with it.
rip::ab_editions() {
  setopt localoptions noerrexit nopipefail
  local rows
  rows="$(rip::_server_sidecars)" || return 2
  print -r -- "$rows" | jq -s -r "$_RIP_JQ_WORK_DEF"'
    def uid_of: (.work | _work_obj | (.uid // ""));
    def edition_of: (.work | _work_obj | (.edition // ""));
    . as $all
    | ($all | map(select(uid_of != "")) | group_by(uid_of)) as $ubuckets
    | ($ubuckets | map(select(length > 1)))                 as $ugroups
    | (($all | map(select(uid_of == "")))
       + ($ubuckets | map(select(length == 1)) | add // [])) as $rest
    | ($rest
        | map(select((.published // "") != "" and ((.authors[0] // "") != "")))
        | group_by([ (.authors[0] // "" | ascii_downcase | gsub("[^a-z0-9]";"")),
                     (.title // "" | ascii_downcase | gsub("[^a-z0-9]";"")) ])
        | map(select(length > 1))
        | map(select(([.[].published | .[0:10]] | unique | length) == length))
      ) as $dgroups
    | (if ($ugroups | length) > 0 then
         "== confirmed editions (shared work uid) ==",
         ($ugroups[]
           | "work \(.[0] | uid_of)",
             (sort_by(edition_of)[]
               | "    \(if edition_of == "" then "(none)" else edition_of end)  \(._path)")
         )
       else empty end),
      (if ($dgroups | length) > 0 then
         "== possible duplicate editions (title/date match) ==",
         ($dgroups[]
           | (max_by(.published)._path) as $newest
           | "\(.[0].title)",
             (sort_by(.published)[]
               | "    \(.published[0:10])  \(.ids["audible.asin"] // "?")  \(._path)\(if ._path == $newest then "   <- newest" else "" end)")
         )
       else empty end)
  ' 2>/dev/null
}

# rip::ab_backfill_published [--apply] — fill `published` into sidecars that
# predate it.
#
# Task 1 records the date on every sidecar written from now on. The 248 books
# already on the server were pushed before that field existed (measured
# 2026-08-24: 248 sidecars, 0 with `published`), and edition detection groups
# on exactly that field — so without this sweep `--editions` reports nothing
# about the library the operator actually has.
#
# The date comes from the provider's own rows, matched by ASIN: that is the
# same value a fresh push would have recorded, so a backfilled sidecar and a
# re-pushed one agree.
#
# ADDITIVE ONLY. A sidecar that already carries a non-null `published` is left
# exactly as it is, no other field is touched, and the replacement is written
# to a temp file in the same directory and moved into place — a half-written
# sidecar would destroy identity metadata that cannot be recovered from the
# audio, and staging is emptied after every verified push.
rip::ab_backfill_published() {
  setopt localoptions noerrexit nopipefail
  local apply=0
  [[ "${1:-}" == "--apply" ]] && apply=1

  # asin -> published, from the provider's library rows.
  local provider_bin; provider_bin="$(rip::ab_provider_bin libation)"
  local map
  map="$("$provider_bin" list 2>/dev/null \
    | jq -s -c 'map(select((.published // "") != "" and (.id // "") != ""))
                | map({key: .id, value: .published}) | from_entries' 2>/dev/null)"
  [[ -n "$map" ]] || map='{}'

  local base; base="$(rip::remote_base)"
  # $to_fill holds "<rel>\t<date>" for the dry-run report and the tallies;
  # $to_fill_json holds the SAME books' stored JSON, index for index, because
  # the replacement sidecar is composed HERE (see rip::_sidecars_write
  # — the server has no jq) and composing it needs the original object, not
  # just the path.
  local -a to_fill=() to_fill_json=()
  local -i seen=0
  # Candidates that were LOOKED AT, needed a date, and could not be given
  # one — the "no ASIN in the sidecar" and "no provider row" continues
  # below, split by cause so the summary can name which one actually
  # happened instead of always blaming the provider (review finding
  # 2026-08-24, R2: a missing ASIN is the fingerprint of an
  # orphaned-identity book, not a LibationCli problem). Distinct from
  # $seen, which counts every line the enumerator produced (dated ones
  # included). Consulted below AND after the apply/dry-run tallies (review
  # finding 2026-08-24, R1) — a partial sweep must not read as complete.
  local -i no_asin=0 no_row=0
  local line rel asin have want
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    (( seen++ ))
    rel="$(print -r -- "$line" | jq -r '._path // ""' 2>/dev/null)"
    [[ -n "$rel" ]] || continue
    have="$(print -r -- "$line" | jq -r '.published // ""' 2>/dev/null)"
    [[ -z "$have" ]] || continue          # already dated — never rewritten
    asin="$(print -r -- "$line" | jq -r '.ids["audible.asin"] // ""' 2>/dev/null)"
    if [[ -z "$asin" ]]; then
      log_warn "rip: no ASIN in the sidecar for $rel — cannot backfill"
      (( no_asin++ ))
      continue
    fi
    want="$(print -r -- "$map" | jq -r --arg a "$asin" '.[$a] // ""' 2>/dev/null)"
    if [[ -z "$want" ]]; then
      log_warn "rip: no provider row for $rel ($asin) — leaving it undated"
      (( no_row++ ))
      continue
    fi
    to_fill+=("$rel"$'\t'"$want")
    to_fill_json+=("$line")
  done < <(rip::_server_sidecars)

  local -i undated=$(( no_asin + no_row ))
  # Worded from whichever cause(s) actually fired, not a blanket blame on
  # LibationCli — a no-ASIN sidecar and a provider that lacks the row are
  # different conditions with different remedies.
  local undated_detail=""
  if (( no_row > 0 && no_asin > 0 )); then
    undated_detail="$no_row with no provider row, $no_asin with no ASIN"
  elif (( no_row > 0 )); then
    undated_detail="$no_row with no provider row (is LibationCli available?)"
  elif (( no_asin > 0 )); then
    undated_detail="$no_asin with no ASIN"
  fi

  if (( ${#to_fill[@]} == 0 )); then
    # Reported in BOTH modes. A silent `--apply` with nothing to fill is
    # byte-identical on stdout/stderr/exit-code to `rip::_server_sidecars`'s
    # ssh call failing (that call is wrapped in 2>/dev/null, so an
    # unreachable server also yields an empty work list and rc 0) — the
    # operator could not tell "ran fine, nothing needed" from "never reached
    # the server" (review finding 2026-08-24). Always narrating the no-op
    # closes that ambiguity and costs nothing: the caller already expects
    # this function to print progress.
    #
    # BUT that alone still conflates two different situations that both
    # yield an empty $to_fill: a genuinely satisfied library (every stored
    # sidecar already dated) and an enumerator that produced ZERO lines
    # because the ssh to the server failed. This is a one-shot sweep over
    # the whole library — a false "nothing to backfill" here would read as
    # "the sweep is done" and let a real gap stand undetected, then
    # propagate silently into `--editions` finding no duplicates either
    # (review finding 2026-08-24, round 2). $seen (incremented for every
    # non-empty line rip::_server_sidecars actually produced, before any
    # filtering) tells them apart without changing `_server_sidecars`'s
    # output contract or asserting a reachability check we cannot make: an
    # empty library legitimately produces zero lines too, so the wording
    # below only names the possibility, it does not claim failure.
    #
    # THIRD case (review finding 3B, 2026-08-24): every candidate was seen
    # and every one FAILED to match — a provider whose export died (exit 3:
    # LibationCli missing, unauthorized, or mid-update) yields an empty
    # asin->published map, so all 248 books take a `continue` above. That
    # scrolled 248 stderr warnings past and then printed "rip: nothing to
    # backfill" on stdout with rc 0 — the operator reads the LAST line,
    # concludes the sweep is done, sees --editions report nothing, and
    # concludes the library has no duplicates. $undated counts exactly those
    # skipped candidates, so the summary line can say what actually
    # happened, and the rc says it to a wrapper too.
    if (( seen == 0 )); then
      print -r -- "rip: no sidecars found on the server — nothing to backfill (is cantina reachable?)"
    elif (( undated > 0 )); then
      print -r -- "rip: nothing filled — $undated book(s) still undated ($undated_detail)"
      return 1
    else
      print -r -- "rip: nothing to backfill"
    fi
    return 0
  fi

  local entry
  if (( ! apply )); then
    for entry in "${to_fill[@]}"; do
      print -r -- "would fill: ${entry%%$'\t'*}  ->  ${entry#*$'\t'}"
    done
    print -r -- "(${#to_fill[@]} book(s); re-run with --apply)"
    # R1: a PARTIAL sweep — some candidates matched, others didn't — must
    # not read as a complete one. Reported even in dry-run mode: the
    # operator deciding whether to --apply needs to know the run won't
    # finish the job either way.
    if (( undated > 0 )); then
      print -r -- "rip: $undated book(s) still undated ($undated_detail)"
      return 1
    fi
    return 0
  fi

  # COMPOSE LOCALLY, WRITE REMOTELY (live finding, 2026-08-24). The whole new
  # sidecar is built here, where jq exists, and shipped as opaque base64 —
  # see rip::_sidecars_write for why the server cannot be asked to
  # do it. `del(._path)`: rip::_server_sidecars ANNOTATES every row it emits
  # with the "<Author>/<Title>" it came from, and that key is NOT in the
  # stored file — writing the annotated object back would permanently add a
  # bogus `_path` field to every sidecar it touched.
  local -a payloads=() sent_rels=() ok_flags=()
  local -A idx_of=()
  local -i i
  local payload b64rel
  for (( i = 1; i <= ${#to_fill[@]}; i++ )); do
    rel="${to_fill[i]%%$'\t'*}"; want="${to_fill[i]#*$'\t'}"
    payload="$(print -r -- "${to_fill_json[i]}" | jq -r --arg d "$want" \
      '(._path|@base64) + "\t" + ((del(._path) | .published = $d) | tojson | @base64)' 2>/dev/null)"
    if [[ -z "$payload" || "$payload" != *$'\t'* ]]; then
      # Never ship a half-composed payload: the remote would write it.
      log_warn "rip: could not backfill $rel"
      continue
    fi
    payloads+=("$payload")
    sent_rels+=("$rel")
    ok_flags+=(0)
    b64rel="${payload%%$'\t'*}"
    idx_of[$b64rel]=${#payloads}
  done

  # ONE ssh for the whole sweep: 245 books is 245 round-trips otherwise.
  local out=""
  (( ${#payloads[@]} > 0 )) && out="$(rip::_sidecars_write "$base" "${payloads[@]}")"

  # GATED ON THE REPORTED OUTCOME, never on the write having been attempted:
  # a book counts as filled only when the remote loop said "ok" for it, so an
  # ssh that dies halfway leaves the rest counted as failures and named.
  local -i filled=0
  local rline st key
  while IFS= read -r rline; do
    [[ -n "$rline" ]] || continue
    st="${rline%%$'\t'*}"; key="${rline#*$'\t'}"
    [[ "$st" == "ok" ]] || continue
    i=${idx_of[$key]:-0}
    (( i > 0 )) && ok_flags[i]=1
  done <<< "$out"
  for (( i = 1; i <= ${#sent_rels[@]}; i++ )); do
    if (( ok_flags[i] )); then
      (( filled++ ))
    else
      log_warn "rip: could not backfill ${sent_rels[i]}"
    fi
  done
  print -r -- "rip: backfilled $filled of ${#to_fill[@]} sidecar(s)"
  # THE EXIT CODE FOLLOWS WHAT LANDED, not whether the sweep ran. A run that
  # wrote nothing at all used to print "backfilled 0 of 245" and exit 0 —
  # exactly what the live jq-less failure looked like (2026-08-24) — so a
  # wrapper or a `&&` chain read a total failure as success.
  local -i unwritten=$(( ${#to_fill[@]} - filled ))
  (( unwritten > 0 )) && print -r -- "rip: $unwritten sidecar(s) could not be written"
  # Same partial-sweep guard as the dry-run path above: "backfilled N of N"
  # only counts $to_fill, which already excluded every no-ASIN/no-row
  # candidate — without this, a run that filled everything IT COULD reads
  # as a complete sweep even when other books were left untouched.
  (( undated > 0 )) && print -r -- "rip: $undated book(s) still undated ($undated_detail)"
  (( unwritten > 0 || undated > 0 )) && return 1
  return 0
}

# rip::ab_backfill_work_uid [--apply] — mint `work.uid` for every stored book
# whose `work` is null, leaving `edition: null` behind — recording that the
# book anchors a work, not that it is a named edition of one (design doc
# docs/superpowers/specs/2026-08-25-audiobook-editions-design.md, S5).
#
# This is what makes the common edition-rip path READ-ONLY afterward:
# rip::ab_worker's own uid-resolution step (reuse an existing work.uid; mint
# and write back only when the book it finds has none) would otherwise turn
# a read of the anchor book's sidecar into a write on the only copy of its
# identity, once per work, the first time anyone ever rips a second edition
# of it. That write path is retained regardless — a book can still arrive on
# cantina by paths this subsystem does not own — but after this sweep runs
# it should never fire.
#
# Same discipline as rip::ab_backfill_published, mirrored closely: dry run
# by default, --apply required, one enumerating ssh + one writing ssh for
# the whole sweep (cantina has no jq — compose the replacement sidecar
# LOCALLY and ship it as an opaque base64 payload; see rip::_sidecars_write).
#
# ADDITIVE AND EXCLUSIVE: a sidecar whose `work` is already non-null is never
# even considered a candidate — not read into $to_fill, not touched, not
# re-serialized — so it comes back from a run of this sweep byte-for-byte
# identical to what it was. Any candidate that IS filled mints its OWN
# uuidgen call: sharing one value across the loop would silently merge every
# anchored book in the sweep into a single "work", which is the one mistake
# this verb must never make on the operator's real library.
rip::ab_backfill_work_uid() {
  setopt localoptions noerrexit nopipefail
  local apply=0
  [[ "${1:-}" == "--apply" ]] && apply=1

  local base; base="$(rip::remote_base)"
  # $to_fill holds the "<rel>" of every null-`work` candidate, for the
  # dry-run report and the tallies; $to_fill_json holds the SAME books'
  # stored JSON, index for index — composing the replacement sidecar needs
  # the original object (the server has no jq to do it for us).
  # CAPTURE the enumerator's status (review finding, 2026-08-26). This used
  # to read `done < <(rip::_server_sidecars)`, and a process substitution
  # throws the rc away: an unreachable cantina then produced zero lines,
  # printed "nothing to backfill", and exited 0 — so
  # `--backfill-work-uid --apply && echo done` said "done" on a dropped VPN.
  # That matters more for this sweep than for any other, because running it
  # is precisely what makes the rip path read-only (design §5): a falsely
  # complete run leaves rip::ab_worker's write-back-into-another-book's-
  # sidecar path live with nobody aware it is still armed.
  #
  # The comment that justified the old form claimed rip::_server_sidecars
  # yields rc 0 on failure. That was true once and is not any more — it was
  # given failure propagation on 2026-08-24 and now returns 2 with a
  # log_error. Capturing it is this module's own convention:
  # rip::ab_repair_companions, rip::ab_editions, rip::ab_canonicalize_authors
  # and rip::ab_retire all refuse the same way.
  local rows sidecars_rc=0
  rows="$(rip::_server_sidecars)" || sidecars_rc=$?
  (( sidecars_rc == 0 )) || return 2

  local -a to_fill=() to_fill_json=()
  local -i seen=0
  local line rel has_work
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    (( seen++ ))
    rel="$(print -r -- "$line" | jq -r '._path // ""' 2>/dev/null)"
    [[ -n "$rel" ]] || continue
    # `.work` present and non-null — an object with `edition: null` (a bare
    # anchor) is STILL non-null and must be left alone; only genuine absence
    # (missing key or a literal `null`) is a candidate.
    has_work="$(print -r -- "$line" | jq -r 'if (.work // null) == null then "" else "x" end' 2>/dev/null)"
    [[ -z "$has_work" ]] || continue      # already anchors a work — never rewritten
    to_fill+=("$rel")
    to_fill_json+=("$line")
  done <<< "$rows"

  if (( ${#to_fill[@]} == 0 )); then
    # Same seen==0 vs "genuinely satisfied" distinction as
    # rip::ab_backfill_published, and for the same reason: this is a
    # one-shot sweep over the whole library, and a false "nothing to
    # backfill" reads as "the sweep is done" when it could instead mean the
    # ssh to cantina never landed (rip::_server_sidecars's own ssh runs
    # under 2>/dev/null, so an unreachable server and a satisfied library
    # both yield zero lines and rc 0 here).
    if (( seen == 0 )); then
      print -r -- "rip: no sidecars found on the server — nothing to backfill (is cantina reachable?)"
    else
      print -r -- "rip: nothing to backfill"
    fi
    return 0
  fi

  local rel2
  if (( ! apply )); then
    for rel2 in "${to_fill[@]}"; do
      print -r -- "would assign a work uid: $rel2"
    done
    print -r -- "(${#to_fill[@]} book(s); re-run with --apply)"
    return 0
  fi

  # COMPOSE LOCALLY, WRITE REMOTELY (see rip::ab_backfill_published for why:
  # cantina has no jq). `del(._path)`: rip::_server_sidecars ANNOTATES every
  # row it emits with the "<Author>/<Title>" it came from, and that key is
  # NOT in the stored file — writing the annotated object back would
  # permanently add a bogus `_path` field to every sidecar it touches.
  local -a payloads=() sent_rels=() ok_flags=()
  local -A idx_of=()
  local -i i
  local payload b64rel uid
  for (( i = 1; i <= ${#to_fill[@]}; i++ )); do
    rel="${to_fill[i]}"
    # uuidgen LOCALLY, ONE PER CANDIDATE — see rip::ab_repair_sidecars Case C
    # and rip::_book_meta_for's folder-provider mint for the same pattern.
    # Lowercased so two runs (or a hand-typed uid elsewhere) compare equal
    # byte for byte.
    uid="$(uuidgen 2>/dev/null)"; uid="${(L)uid}"
    if [[ -z "$uid" ]]; then
      log_warn "rip: uuidgen produced nothing — cannot assign a work uid to $rel"
      continue
    fi
    payload="$(print -r -- "${to_fill_json[i]}" | jq -r --arg u "$uid" \
      '(._path|@base64) + "\t" + ((del(._path) | .work = {uid: $u, edition: null}) | tojson | @base64)' 2>/dev/null)"
    if [[ -z "$payload" || "$payload" != *$'\t'* ]]; then
      # Never ship a half-composed payload: the remote would write it.
      log_warn "rip: could not backfill $rel"
      continue
    fi
    payloads+=("$payload")
    sent_rels+=("$rel")
    ok_flags+=(0)
    b64rel="${payload%%$'\t'*}"
    idx_of[$b64rel]=${#payloads}
  done

  # ONE ssh for the whole sweep, on top of the ONE that enumerated it.
  local out=""
  (( ${#payloads[@]} > 0 )) && out="$(rip::_sidecars_write "$base" "${payloads[@]}")"

  # GATED ON THE REPORTED OUTCOME, never on the write having been attempted —
  # the recurring defect class in this module (rip::ab_backfill_published's
  # "backfilled 0 of 245" among 11+ instances): a book counts as filled only
  # when the remote loop said "ok" for it.
  local -i filled=0
  local rline st key
  while IFS= read -r rline; do
    [[ -n "$rline" ]] || continue
    st="${rline%%$'\t'*}"; key="${rline#*$'\t'}"
    [[ "$st" == "ok" ]] || continue
    i=${idx_of[$key]:-0}
    (( i > 0 )) && ok_flags[i]=1
  done <<< "$out"
  for (( i = 1; i <= ${#sent_rels[@]}; i++ )); do
    if (( ok_flags[i] )); then
      (( filled++ ))
    else
      log_warn "rip: could not backfill ${sent_rels[i]}"
    fi
  done
  print -r -- "rip: backfilled $filled of ${#to_fill[@]} sidecar(s)"
  local -i unwritten=$(( ${#to_fill[@]} - filled ))
  (( unwritten > 0 )) && print -r -- "rip: $unwritten sidecar(s) could not be written"
  (( unwritten > 0 )) && return 1
  return 0
}

# --- --retag: the library that already exists (design doc S4) ---------------
#
# The enrichment writes authoritative tags into a STAGED copy on the way in.
# This is the same invariant read from the other end, for the ~248 books that
# were already on cantina before the feature existed and were never tagged at
# all: report every stored book whose album_artist/album/title disagree with
# its PATH, and under --apply rewrite them.
#
# THE PATH IS THE AUTHORITY, VERBATIM — not the sidecar's `title`, and not a
# canonicalized spelling of the author. Three consequences, all deliberate:
#
#   * the sidecar's `title` is the PROVIDER's title ("Steelheart") while the
#     directory is what the operator asked for and what the library shows
#     ("Steelheart: The Reckoners, Book 1"). Comparing against the sidecar
#     would rewrite every Libation book to a name the library does not use;
#   * the EDITION needs no special handling: the panel composed the directory
#     as "<Title> (<Edition>)", so the directory name already IS the book name
#     the design says to write;
#   * NO CANONICALIZATION OF album_artist here. That form enters through the
#     PATH (the panel normalises on blur, --canonicalize-authors repairs
#     stored paths) and never through the tag. A sweep that wrote a
#     TRANSFORMED author while the path kept the raw one would report a
#     mismatch on every run and rewrite every book on the server forever — a
#     sweep with no fixed point. Same ruling, same reason, as
#     rip::_retag_book's header.
#
#     `artist`/`composer` ARE canonicalised, and that is not the same thing:
#     no path spells them, so there is nothing for the result to disagree
#     with, and the rule is idempotent, so the second pass finds nothing. The
#     values are computed HERE (cantina has no jq and no zsh) by the same
#     `_canon` the shared predicate judges with, and shipped base64-framed —
#     see rip::_retag_write's header.
#
# The server's own spelling is used byte-for-byte, with no rip::_nfc pass. On
# the staging side _nfc is REQUIRED (the tag must match what rsync --iconv
# will land), but here both sides of the comparison are already the server's,
# and normalizing only one of them is how a decomposed legacy path would be
# rewritten on every single sweep.
#
# WHERE THE WORK HAPPENS: on cantina. It has ffmpeg and ffprobe (verified
# 2026-08-26), so a stored book is remuxed IN PLACE — nothing is fetched,
# rewritten and pushed back. It has no jq, so every judgement is made HERE,
# from probe JSON the server base64-frames back, through the one shared
# predicate (_RIP_JQ_TAGS_OK) that rip::_retag_book verifies with.
#
# FOUR CONNECTIONS FOR THE WHOLE LIBRARY, one per stage: enumerate the
# sidecars, list the book directories (to name the ones holding no sidecar,
# which the enumerator cannot see), probe every book's audio, rewrite the
# mismatched. Plus a fifth only when there is a sidecar to re-key (below).
# Never one per book.

# rip::_retag_probe <base> <base64 relpath…> — the tags every stored book's
# audio actually carries, in ONE ssh.
#
# Prints one line per file:
#
#   probe   <b64 rel> <b64 filename> <b64 ffprobe-json>
#   skip    <b64 rel> <b64 filename> drm|notags
#   noaudio <b64 rel>
#   nodir   <b64 rel>
#
# The skip set is rip::_retag_staged_book's, for the same measured reasons:
# `.aax`/`.aaxc` are DRM-encrypted originals ffmpeg cannot remux, and
# `.wav`/`.aac` cannot carry `album_artist` at ALL (RIFF INFO has no such
# chunk; raw ADTS has no metadata container). Both are reported so the
# operator hears about them, and neither is a failure — a deterministic
# failure cannot be cleared by a retry, and a sweep that returned non-zero for
# one would report the library as permanently broken on every run.
#
# THE STATUS PROPAGATES, unlike rip::_sidecars_hash_primary's (whose caller
# judges per line). An empty probe here is indistinguishable from a library
# whose tags are all already correct, which is the "nothing to backfill on a
# dropped VPN" defect wearing a different hat — and this is the sweep that
# REWRITES AUDIO, so it is the one that must refuse loudest.
#
# `</dev/null` on the ffprobe (and on rip::_retag_write's ffmpeg): the payload
# arrives on this script's stdin and a child that inherits fd 0 can eat the
# rest of the batch — exactly the bug rip::_remote_test's `ssh -n` exists for,
# one layer in. UNPROVABLE HERE, and kept anyway: ffmpeg 9.0.1 leaves a
# non-tty stdin untouched, so no fixture on this machine can reproduce the
# hazard at any size, but cantina runs Debian's ffmpeg and `-nostdin` exists
# precisely because older builds do drain it. A guard whose absence cannot be
# demonstrated locally is not a guard that is unnecessary remotely.
#
# POSIX sh + coreutils only, and no single quote anywhere in the script, so
# ${(qq)} — which is what a real POSIX /bin/sh needs, unlike ${(q)}'s $'\n' —
# wraps it exactly.
rip::_retag_probe() {
  setopt localoptions noerrexit nopipefail
  local base="$1"; shift
  (( $# > 0 )) || return 0
  local script='while read -r br; do
  [ -n "$br" ] || continue
  d=$(printf %s "$br" | base64 -d 2>/dev/null)
  if [ -z "$d" ] || [ ! -d "$d" ]; then printf "nodir\t%s\n" "$br"; continue; fi
  n=0
  for c in "$d"/*; do
    [ -f "$c" ] || continue
    b=${c##*/}
    lb=$(printf %s "$b" | tr "[:upper:]" "[:lower:]")
    case "$lb" in
      *.aax|*.aaxc) k=drm ;;
      *.wav|*.aac) k=notags ;;
      *.m4b|*.m4a|*.mp3|*.mp4|*.flac|*.ogg|*.opus) k=audio ;;
      *) continue ;;
    esac
    n=$((n+1))
    bn=$(printf %s "$b" | base64 | tr -d "\n")
    if [ "$k" = audio ]; then
      j=$(ffprobe -v error -select_streams a:0 -show_entries format_tags:stream_tags -of json -- "$c" </dev/null 2>/dev/null | base64 | tr -d "\n")
      printf "probe\t%s\t%s\t%s\n" "$br" "$bn" "$j"
    else
      printf "skip\t%s\t%s\t%s\n" "$br" "$bn" "$k"
    fi
  done
  [ "$n" -gt 0 ] || printf "noaudio\t%s\n" "$br"
done'
  local out="" rc=0
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    out="$(print -rl -- "$@" | "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "cd ${(q)rpath}/audiobooks && sh -c ${(qq)script} sh" 2>/dev/null)" || rc=$?
  else
    # No ':' — the hermetic tests' plain local dir.
    out="$(print -rl -- "$@" | ( cd "$base/audiobooks" 2>/dev/null && sh -c "$script" sh ) 2>/dev/null)" || rc=$?
  fi
  [[ -n "$out" ]] && print -r -- "$out"
  return $rc
}

# rip::_retag_write <base> <framed line…> — remux the named files in place on
# the server, in ONE ssh. Each input line is
# "<b64 rel>\t<b64 filename>\t<b64 album_artist>\t<b64 bookname>\t<b64 artist|->\t<b64 composer|->".
#
# THE LAST TWO FIELDS ARE THE NEVER-REPLACED PAIR, already canonicalised
# (2026-08-26, second amendment). cantina has no jq and no zsh, so the
# canonical spelling is computed HERE — by the same `_canon` the shared
# predicate checks with — and shipped, exactly as the album_artist beside it
# is. `-` means "this file has no such tag": the remote must not CREATE one,
# and the sentinel is a character base64 never emits, so it can never be
# mistaken for a value. It is also why absence is spelled `-` rather than left
# empty — `read` collapses runs of IFS whitespace, and two adjacent tabs would
# slide the composer into the artist's field.
#
# BOTH WRITE SITES DO THE SAME THING, and they have to: rip::_retag_book
# writes a STAGED copy on the way in and this writes a STORED one, and a book
# excluded by one and rewritten by the other would never settle.
#
# Prints "ok<TAB><b64 rel><TAB><b64 filename><TAB><b64 ffprobe-json>" for a
# file it wrote and moved into place, "fail<TAB><b64 rel><TAB><b64 filename>"
# otherwise — so the caller counts what it actually got rather than inferring
# it from an exit status, the rule this module keeps relearning.
#
# THE VERIFICATION IS SPLIT ACROSS THE TWO MACHINES, and that is forced, not
# preferred. rip::_retag_book verifies the TEMP and only then renames, so a
# failure leaves the original exactly as it was; doing that from here would
# mean shipping every temp's probe back and opening a THIRD connection to
# rename the good ones — with the whole library's temps alive at once, which
# for 248 multi-gigabyte books is hundreds of gigabytes of server disk. So the
# remote makes the rename decision from an EXACT comparison of the three
# values it reads back out of the temp (stream level first, format level as
# the fallback — the same precedence _RIP_JQ_TAGS_OK encodes), and the
# authoritative count is still made HERE, by that shared predicate, over the
# probe of the file as it finally sits. The remote may only ever be
# optimistic: a file it renamed but this side cannot verify is reported as a
# failure and retried, and it is still a valid `-c copy` remux of the
# original, never a truncated one.
#
# The scratch write lives in `<audiobooks>/.work/`, never in the book
# directory — the same prohibition rip::_retag_book and rip::_book_sidecar
# document: a process killed mid-remux would otherwise leave a second,
# differently named audio file INSIDE the book, where the next push's
# age-gated find would ship it as part of the book. `.work` sits at depth 1,
# below rip::ab_server_library's `-mindepth 2` and rip::_server_sidecars'
# `-mindepth 3`, so it is invisible to every enumerator; it is rmdir'd when
# the batch empties it.
#
# `set -f` is load-bearing: $_RIP_RETAG_FF_MAP is expanded UNQUOTED so it word
# splits, and it contains `-0:d?`, which a POSIX sh would otherwise offer to
# pathname expansion.
rip::_retag_write() {
  setopt localoptions noerrexit nopipefail
  local base="$1"; shift
  (( $# > 0 )) || return 0
  local script='set -f
mf=$1
mkdir -p .work 2>/dev/null
tv() {
  s=$(ffprobe -v error -select_streams a:0 -show_entries "stream_tags=$2" -of default=noprint_wrappers=1:nokey=1 -- "$1" </dev/null 2>/dev/null)
  if [ -n "$s" ]; then printf %s "$s"; return 0; fi
  ffprobe -v error -show_entries "format_tags=$2" -of default=noprint_wrappers=1:nokey=1 -- "$1" </dev/null 2>/dev/null
}
while read -r br bn ba bk bx bc; do
  [ -n "$br" ] || continue
  d=$(printf %s "$br" | base64 -d 2>/dev/null)
  n=$(printf %s "$bn" | base64 -d 2>/dev/null)
  a=$(printf %s "$ba" | base64 -d 2>/dev/null)
  k=$(printf %s "$bk" | base64 -d 2>/dev/null)
  if [ -z "$d" ] || [ -z "$n" ] || [ -z "$a" ] || [ -z "$k" ]; then printf "fail\t%s\t%s\n" "$br" "$bn"; continue; fi
  f="$d/$n"
  if [ ! -f "$f" ]; then printf "fail\t%s\t%s\n" "$br" "$bn"; continue; fi
  t=".work/retag.$$.$n"
  rm -f -- "$t"
  set -- -v error -y -i "$f" $mf -metadata album_artist="$a" -metadata album="$k" -metadata title="$k" -metadata:s:a:0 album_artist="$a" -metadata:s:a:0 album="$k" -metadata:s:a:0 title="$k"
  x=""
  c=""
  if [ -n "$bx" ] && [ "$bx" != "-" ]; then
    x=$(printf %s "$bx" | base64 -d 2>/dev/null)
    set -- "$@" -metadata artist="$x" -metadata:s:a:0 artist="$x"
  fi
  if [ -n "$bc" ] && [ "$bc" != "-" ]; then
    c=$(printf %s "$bc" | base64 -d 2>/dev/null)
    set -- "$@" -metadata composer="$c" -metadata:s:a:0 composer="$c"
  fi
  ffmpeg "$@" -- "$t" </dev/null >/dev/null 2>&1
  if [ ! -s "$t" ]; then rm -f -- "$t"; printf "fail\t%s\t%s\n" "$br" "$bn"; continue; fi
  ok=1
  [ "$(tv "$t" album_artist)" = "$a" ] || ok=0
  [ "$(tv "$t" album)" = "$k" ] || ok=0
  [ "$(tv "$t" title)" = "$k" ] || ok=0
  [ -z "$x" ] || [ "$(tv "$t" artist)" = "$x" ] || ok=0
  [ -z "$c" ] || [ "$(tv "$t" composer)" = "$c" ] || ok=0
  if [ "$ok" = 1 ] && mv -- "$t" "$f"; then
    j=$(ffprobe -v error -select_streams a:0 -show_entries format_tags:stream_tags -of json -- "$f" </dev/null 2>/dev/null | base64 | tr -d "\n")
    printf "ok\t%s\t%s\t%s\n" "$br" "$bn" "$j"
  else
    rm -f -- "$t"
    printf "fail\t%s\t%s\n" "$br" "$bn"
  fi
done
rmdir .work 2>/dev/null
exit 0'
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    print -rl -- "$@" | "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "cd ${(q)rpath}/audiobooks && sh -c ${(qq)script} sh ${(qq)_RIP_RETAG_FF_MAP}" 2>/dev/null
  else
    # No ':' — the hermetic tests' plain local dir.
    print -rl -- "$@" \
      | ( cd "$base/audiobooks" 2>/dev/null && sh -c "$script" sh "$_RIP_RETAG_FF_MAP" ) 2>/dev/null
  fi
  return 0
}

# rip::ab_retag [--apply] — the sweep.
#
# Dry run by default, the same discipline as --backfill-published,
# --backfill-work-uid and --repair-sidecars: report by default, write only
# under --apply, and NEVER report a count that exceeds what actually changed.
#
# rip::_server_sidecars is captured as a VALUE and its status checked. Read
# through `< <(...)` a process substitution throws the rc away, and an
# unreachable cantina then yields zero rows, prints "nothing to retag" and
# exits 0 — the live defect --backfill-work-uid was fixed for, and worse here,
# because this sweep is the one that rewrites the audio in the operator's only
# copy of their library.
#
# THE RE-KEY, and why it lives inside this pass (design doc S5, carried into
# S4). --repair-sidecars' Case C used to record its hash under
# `local.sha256`. That value is a hash of the STORED BYTES — the only bytes
# that repair can reach — and it was correct when it was written. It is stale
# the instant this sweep rewrites those bytes, and it is stale under the exact
# key rip::_stored_sha_index reads, so the byte-dedupe would go on consulting
# a value no source file can ever match. Case C now writes
# `local.stored.sha256`; the books an EARLIER Case C run repaired still hold
# the old key, and NOTHING on a sidecar records when it was written relative
# to a feature landing, so nothing can find them afterwards. They are re-keyed
# here, in the pass that invalidates them.
#
# HOW THE TWO KINDS ARE TOLD APART — this is the load-bearing judgement of
# this function, so it is written out in full:
#
#   `local.sha256` has exactly two writers in this module, and they are
#   disjoint on `source.provider`.
#
#     * THE ACQUIRE (rip::ab_worker threads the hash it took of the operator's
#       SOURCE file; rip::_book_meta_for mints the pair from it) fires ONLY
#       when the provider row says "folder" — `if [[ "$provider" == folder ]]`
#       in the worker, `.provider == "folder"` in the mint. That value is a
#       SOURCE hash. It must be preserved: moving it would silently disable
#       the byte-dedupe for every folder-imported book, which is the very
#       failure this re-key exists to prevent, pointed the other way.
#     * CASE C fires ONLY when the stored sidecar records provider "manual"
#       AND its ids were EMPTY (`sc_prov[$nrel] == "manual"`, reached only
#       under `sc_state == "empty"`). A book that reaches Case C therefore had
#       no `local.sha256` at all beforehand, and the one it carries afterwards
#       came from rip::_sidecars_hash_primary — the STORED bytes.
#
#   So: provider "manual" + a `local.sha256` present == a Case C value, with
#   no residual ambiguity to guess at. The acquire cannot have put it there,
#   because rip::ab_import records provider "manual" with `ids: {}` and the
#   worker's hash-threading is gated on "folder".
#
# THE TEMPTING TEST IS THE WRONG ONE, and it is worth naming so nobody
# "improves" this later: comparing the recorded hash against a fresh hash of
# the stored bytes does NOT discriminate. Until the enrichment retag landed
# (2026-08-26) a folder-acquired book's stored bytes WERE its source bytes, so
# the hashes are equal for both populations, and every legacy folder book
# would be re-keyed — destroying exactly the dedupe entries this is meant to
# protect.
#
# SCOPED TO WHAT THIS RUN ACTUALLY REWROTE, gated on the server having
# reported the rename ("ok"), not on the write having been attempted. A Case C
# hash on a book nobody touched is still a live, working dedupe entry: the
# stored bytes are the bytes a re-import would hash. It becomes wrong exactly
# when the bytes change, so that is when it moves — and any later sweep that
# rewrites that book will re-key it then.
rip::ab_retag() {
  setopt localoptions noerrexit nopipefail
  local apply=0
  [[ "${1:-}" == "--apply" ]] && apply=1

  local base; base="$(rip::remote_base)"

  local rows sidecars_rc=0
  rows="$(rip::_server_sidecars)" || sidecars_rc=$?
  (( sidecars_rc == 0 )) || return 2

  local -i seen=0
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && (( seen++ ))
  done <<< "$rows"
  if (( seen == 0 )); then
    # The same seen==0 vs "genuinely satisfied" distinction the other sweeps
    # draw: rip::_server_sidecars' own ssh runs under 2>/dev/null, so a
    # server that answered with nothing and a library with nothing in it
    # arrive here identical.
    print -r -- "rip: no sidecars found on the server — nothing to retag (is cantina reachable?)"
    return 0
  fi

  # TWO jq passes over the enumeration, not two per book: the shared
  # rip::_sidecar_index for provider + stored object, and one more for the
  # base64 relpath the remote scripts are framed with and the `local.sha256`
  # the re-key needs. rip::_sidecar_index deliberately does not carry that
  # key — six positional columns are read by three other callers and a
  # seventh would silently land inside their JSON column.
  local idx_rows sha_rows
  idx_rows="$(print -r -- "$rows" | rip::_sidecar_index)"
  sha_rows="$(print -r -- "$rows" | jq -r "$_RIP_JQ_IDS_DEF"'select((._path // "") != "")
      | (._path) + "\t" + (._path|@base64)
        + "\t" + (((.ids | _ids_obj)["local.sha256"] // "") | if . == "" then "-" else . end)' 2>/dev/null)"

  local -a b64rels=()
  local -A rel_of_b64=() prov_of=() json_of=() sha_of=() known=()
  local irel istate iprov iasin iuid ijson xrel xb64 xsha
  while IFS=$'\t' read -r irel istate iprov iasin iuid ijson; do
    [[ -n "$irel" ]] || continue
    prov_of[$irel]="$iprov"
    json_of[$irel]="$ijson"
  done <<< "$idx_rows"
  while IFS=$'\t' read -r xrel xb64 xsha; do
    [[ -n "$xrel" && -n "$xb64" ]] || continue
    rel_of_b64[$xb64]="$xrel"
    known[$xrel]=1
    b64rels+=("$xb64")
    [[ "$xsha" != "-" ]] && sha_of[$xrel]="$xsha"
  done <<< "$sha_rows"
  if (( ${#b64rels[@]} == 0 )); then
    # Sidecars were enumerated but none survived indexing — a jq that is not
    # there, or output nothing can parse. Refusing is the only honest answer:
    # an empty plan here would print "nothing to retag" about a library this
    # function never managed to look at.
    log_error "rip: could not index the stored sidecars — refusing to report on a library we could not read"
    return 2
  fi

  # THE BOOKS WITH NO SIDECAR AT ALL (review finding F3, 2026-08-26). The only
  # enumerator this sweep has is rip::_server_sidecars, whose remote `find`
  # matches `.fleet-book.json` — so a stored book directory carrying audio and
  # no sidecar is never probed, never warned about, and never counted in
  # "retagged N of M". That population is real and already known: it is
  # rip::ab_repair_sidecars' `norow` bucket, which that verb reports by name
  # and deliberately never repairs. This function's promise is EVERY stored
  # book whose tags disagree with its path, so the gap is NAMED rather than
  # quietly counted as done — the same class of silence the seen==0 guard
  # above exists to prevent, one level in.
  #
  # Both sides come from the server's own `find`, so they are compared
  # BYTE-FOR-BYTE with no rip::_nfc pass: normalizing one side of a comparison
  # whose other side is already the server's spelling is how a decomposed
  # legacy path would be reported missing on every single run.
  #
  # A listing that fails is WARNED about, not fatal. The sidecar enumeration
  # already landed, so the sweep itself is sound and refusing here would turn
  # a working retag into a failure; what must never happen is a silent gap, and
  # "I could not check" is not silence.
  local lib="" lib_rc=0 librel
  lib="$(rip::ab_server_library)" || lib_rc=$?
  if (( lib_rc != 0 )); then
    log_warn "rip: could not list the stored book directories — cannot say whether a book is missing its sidecar and was skipped for that reason"
  else
    while IFS= read -r librel; do
      [[ -n "$librel" ]] || continue
      (( ${+known[$librel]} )) \
        || log_warn "rip: no sidecar for $librel — not retagged; run --repair-sidecars"
    done <<< "$lib"
  fi

  local probe_out="" probe_rc=0
  probe_out="$(rip::_retag_probe "$base" "${b64rels[@]}")" || probe_rc=$?
  if (( probe_rc != 0 )) || [[ -z "$probe_out" ]]; then
    log_error "rip: could not read the stored tags from cantina (rc=$probe_rc) — refusing to report on a library we could not probe"
    return 2
  fi

  # Reported, never fatal (design doc, "Containers that cannot carry these
  # tags"): a book that cannot be tagged authoritatively must not become a
  # sweep that can never succeed.
  local ptype pb64rel pb64name pinfo prel pname
  while IFS=$'\t' read -r ptype pb64rel pb64name pinfo; do
    [[ -n "$ptype" ]] || continue
    prel="${rel_of_b64[$pb64rel]:-$pb64rel}"
    case "$ptype" in
      skip)
        pname="$(jq -rn --arg b "$pb64name" '$b|@base64d' 2>/dev/null)"
        if [[ "$pinfo" == drm ]]; then
          log_warn "rip: not retagging $prel/$pname — a DRM-encrypted Audible original cannot be remuxed; the library reads the .m4b beside it"
        else
          log_warn "rip: not retagging $prel/$pname — this container cannot carry album_artist, so its tags cannot be made authoritative; re-encode to .m4b if the library must show them"
        fi ;;
      noaudio) log_warn "rip: no taggable audio in $prel — nothing to retag there" ;;
      nodir)   log_warn "rip: $prel is not a directory on the server — skipped" ;;
    esac
  done <<< "$probe_out"

  # THE COMPARISON, in ONE jq for the whole library, through the SAME
  # predicate rip::_retag_book verifies with (_RIP_JQ_TAGS_OK). The expected
  # values are derived inside jq from the relpath the server itself printed,
  # so the string the tag is compared against and the string the book is
  # stored under cannot drift apart on the way.
  local plan
  plan="$(print -r -- "$probe_out" | jq -Rr "$_RIP_JQ_TAGS_OK"'
      split("\t") as $c
      | select(($c[0] // "") == "probe")
      | ($c[1] | @base64d) as $rel
      | ($rel | split("/")) as $seg
      | ($seg[0]) as $aa
      | ($seg[1:] | join("/")) as $bn
      | (try ($c[3] | @base64d | fromjson) catch null) as $j
      | if $j == null then "unreadable\t" + $c[1] + "\t" + $c[2]
        elif _tags_ok($j; $aa; $bn) then empty
        else ((($j.format.tags) // {}) + (((($j.streams // [])[0]).tags) // {})) as $t
          | "retag\t" + $c[1] + "\t" + $c[2] + "\t" + ($aa|@base64) + "\t" + ($bn|@base64)
            + "\t" + ((($t.artist // "") | _canon) | if . == "" then "-" else @base64 end)
            + "\t" + ((($t.composer // "") | _canon) | if . == "" then "-" else @base64 end)
        end' 2>/dev/null)"

  # THE PAYLOAD CARRIES SIX FIELDS, the last two being the never-replaced
  # pair already canonicalised by the same `_canon` the predicate above judged
  # with, or `-` where the file has no such tag (see rip::_retag_write's
  # header for why absence is a sentinel and not an empty field).
  local -a payloads=()
  local -A need_of=()
  local rtype rb64rel rb64name rb64aa rb64bn rb64ar rb64co
  while IFS=$'\t' read -r rtype rb64rel rb64name rb64aa rb64bn rb64ar rb64co; do
    prel="${rel_of_b64[$rb64rel]:-$rb64rel}"
    case "$rtype" in
      retag)
        payloads+=("$rb64rel"$'\t'"$rb64name"$'\t'"$rb64aa"$'\t'"$rb64bn"$'\t'"${rb64ar:--}"$'\t'"${rb64co:--}")
        need_of[$prel]=$(( ${need_of[$prel]:-0} + 1 )) ;;
      unreadable)
        pname="$(jq -rn --arg b "$rb64name" '$b|@base64d' 2>/dev/null)"
        log_warn "rip: could not read the tags of $prel/$pname — skipped, never assumed correct" ;;
    esac
  done <<< "$plan"

  if (( ${#need_of} == 0 )); then
    print -r -- "rip: nothing to retag"
    return 0
  fi

  # Sorted, so two runs over the same library print the same report.
  local -a books=("${(@ko)need_of}")
  local -a rekeys=()
  local rel2
  for rel2 in "${books[@]}"; do
    [[ "${prov_of[$rel2]:-}" == "manual" && -n "${sha_of[$rel2]:-}" ]] && rekeys+=("$rel2")
  done

  if (( ! apply )); then
    for rel2 in "${books[@]}"; do
      print -r -- "would retag: $rel2  (${need_of[$rel2]} file(s))  ->  album_artist=\"${rel2%%/*}\" album=\"${rel2#*/}\" title=\"${rel2#*/}\""
    done
    for rel2 in "${rekeys[@]}"; do
      print -r -- "would re-key: $rel2  (local.sha256 -> local.stored.sha256)"
    done
    print -r -- "(${#books[@]} book(s); re-run with --apply)"
    return 0
  fi

  # --- apply ---------------------------------------------------------------
  local write_out=""
  write_out="$(rip::_retag_write "$base" "${payloads[@]}")"

  # ok_of counts the files the SERVER renamed — the bytes that changed, which
  # is what the re-key is gated on. verified_of counts the files THIS side
  # confirmed with the shared predicate — what may be counted as retagged.
  # They are different questions and are deliberately not merged.
  local -A ok_of=() verified_of=()
  local wtype wb64rel wb64name wb64json
  while IFS=$'\t' read -r wtype wb64rel wb64name wb64json; do
    [[ "$wtype" == "ok" ]] || continue
    prel="${rel_of_b64[$wb64rel]:-$wb64rel}"
    ok_of[$prel]=$(( ${ok_of[$prel]:-0} + 1 ))
  done <<< "$write_out"

  local checked
  checked="$(print -r -- "$write_out" | jq -Rr "$_RIP_JQ_TAGS_OK"'
      split("\t") as $c
      | select(($c[0] // "") == "ok")
      | ($c[1] | @base64d) as $rel
      | ($rel | split("/")) as $seg
      | (try ($c[3] | @base64d | fromjson) catch null) as $j
      | (if $j != null and _tags_ok($j; $seg[0]; ($seg[1:] | join("/")))
         then "verified" else "unverified" end) + "\t" + $c[1] + "\t" + $c[2]' 2>/dev/null)"
  local vtype vb64rel vb64name
  while IFS=$'\t' read -r vtype vb64rel vb64name; do
    [[ "$vtype" == "verified" ]] || continue
    prel="${rel_of_b64[$vb64rel]:-$vb64rel}"
    verified_of[$prel]=$(( ${verified_of[$prel]:-0} + 1 ))
  done <<< "$checked"

  # GATED ON THE REPORTED OUTCOME, per book and per FILE: a multi-part book
  # counts as retagged only when every file that needed one reads back
  # correctly. The recurring defect class here ("backfilled 0 of 245") is a
  # total taken from what was attempted.
  local -i retagged=0
  for rel2 in "${books[@]}"; do
    if (( ${verified_of[$rel2]:-0} == ${need_of[$rel2]} )); then
      (( retagged++ ))
      print -r -- "retagged: $rel2"
    else
      log_warn "rip: could not retag $rel2 — ${verified_of[$rel2]:-0} of ${need_of[$rel2]} file(s) verified"
    fi
  done

  # COMPOSE LOCALLY, WRITE REMOTELY (cantina has no jq — the live "backfilled
  # 0 of 245" failure). The stored object is AMENDED, never re-composed from a
  # provider row it does not have. An already-present local.stored.sha256 wins
  # over the stale key rather than being overwritten by it.
  local -a rk_payloads=() rk_rels=() rk_ok=()
  local -A rk_idx=()
  local composed payload
  for rel2 in "${rekeys[@]}"; do
    (( ${ok_of[$rel2]:-0} > 0 )) || continue
    composed="$(print -r -- "${json_of[$rel2]:-}" | jq -c "$_RIP_JQ_IDS_DEF"'
        (.ids | _ids_obj) as $i
        | .ids = (($i + {"local.stored.sha256": ($i["local.stored.sha256"] // $i["local.sha256"])})
                  | del(.["local.sha256"]))' 2>/dev/null)"
    payload=""
    [[ -n "$composed" ]] && payload="$(rip::_sidecar_payload "$rel2" "$composed")"
    if [[ -z "$payload" || "$payload" != *$'\t'* ]]; then
      # Never ship a half-composed payload: the remote would write it.
      log_warn "rip: could not compose the re-keyed sidecar for $rel2"
      continue
    fi
    rk_payloads+=("$payload"); rk_rels+=("$rel2"); rk_ok+=(0)
    rk_idx[${payload%%$'\t'*}]=${#rk_payloads}
  done

  local rkout=""
  (( ${#rk_payloads[@]} > 0 )) && rkout="$(rip::_sidecars_write "$base" "${rk_payloads[@]}")"
  local -i rekeyed=0 i=0
  local rline st key
  while IFS= read -r rline; do
    [[ -n "$rline" ]] || continue
    st="${rline%%$'\t'*}"; key="${rline#*$'\t'}"
    [[ "$st" == "ok" ]] || continue
    i=${rk_idx[$key]:-0}
    (( i > 0 )) && rk_ok[i]=1
  done <<< "$rkout"
  for (( i = 1; i <= ${#rk_rels[@]}; i++ )); do
    if (( rk_ok[i] )); then
      (( rekeyed++ ))
      print -r -- "re-keyed: ${rk_rels[i]}  (local.sha256 -> local.stored.sha256)"
    else
      log_warn "rip: could not re-key the sidecar for ${rk_rels[i]} — its local.sha256 is now a stale hash of bytes this sweep has already rewritten"
    fi
  done

  print -r -- "rip: retagged $retagged of ${#books[@]} book(s)"
  (( ${#rk_rels[@]} > 0 )) && print -r -- "rip: re-keyed $rekeyed of ${#rk_rels[@]} sidecar(s)"
  local -i unfinished=$(( ${#books[@]} - retagged ))
  local -i unkeyed=$(( ${#rk_rels[@]} - rekeyed ))
  (( unfinished > 0 )) && print -r -- "rip: $unfinished book(s) could not be retagged"
  (( unfinished > 0 || unkeyed > 0 )) && return 1
  return 0
}

# --- the work uid an edition shares -----------------------------------------
#
# Two editions of one work carry the same `work.uid` (design doc
# docs/superpowers/specs/2026-08-25-audiobook-editions-design.md, S4). The
# panel does NOT resolve it — it holds only a set of stored paths, no identity
# — so rip::ab_worker does, per plan item carrying a non-empty `edition`.

# rip::_remote_sidecar_json <Author/Title> — the stored .fleet-book.json for
# ONE book, on stdout, exactly as it sits on the server.
#
# The TRI-STATE IS THE CONTRACT, the same one rip::_remote_test carries and
# for a sharper reason here:
#
#   0  read, and it parses — the JSON is on stdout
#   1  confirmed absent — no sidecar at that path
#   2  UNKNOWN — the server could not be asked, or what came back does not
#      parse as JSON.
#
# "Unknown" must never collapse into "absent". The only caller's only WRITE
# path fires on "the base book exists and carries no work.uid", and a book
# reported absent because an ssh died is a book whose uid is then minted
# fresh and can never match what it already holds; a sidecar that exists but
# is TRUNCATED is worse still, because composing a replacement over it
# destroys the only copy of that book's identity. Both refuse instead.
#
# ONE book, not the whole library: rip::_server_sidecars ships ~124 KB for 248
# books and this runs per plan item, inside the acquire loop.
rip::_remote_sidecar_json() {
  setopt localoptions noerrexit nopipefail
  # NFC, for the same reason rip::_remote_test normalizes: the server is
  # NFC-canonical (the push's --iconv guarantees it) and this relpath is
  # composed from a plan the panel built out of local folder names, which
  # macOS keeps in whatever form they were created.
  local rel; rel="$(rip::_nfc "${1:-}")"
  [[ -n "$rel" ]] || return 1
  local base; base="$(rip::remote_base)"
  local raw rc=0
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    local rfile="$rpath/audiobooks/$rel/.fleet-book.json"
    # -n IS LOAD-BEARING, NEVER REMOVE IT — the whole note at
    # rip::_remote_test applies verbatim, and this is exactly the shape that
    # has already bitten this subsystem three times: a remote read run once
    # per item from inside a worker loop. Without -n, ssh(1) drains THIS
    # shell's stdin and forwards it to the remote whether or not the remote
    # command consumes it.
    #
    # ${(q)}: a book title is untrusted tag data or a hand-typed string, and
    # an apostrophe alone breaks hand-rolled quoting. BatchMode+ConnectTimeout
    # as everywhere else in this module — a black-holed host must not hang an
    # acquire.
    raw="$("$ssh_bin" -n -o BatchMode=yes -o ConnectTimeout=5 \
      "$host" "cat -- ${(q)rfile}" 2>/dev/null)" || rc=$?
    # `cat` on a missing file exits 1 and ssh hands that status back; an ssh
    # that never connected exits 255. Same discrimination rip::_remote_test
    # makes between a remote `test` saying no and the check not running.
    (( rc == 1 )) && return 1
    (( rc != 0 )) && return 2
  else
    # No ':' — the hermetic tests' plain local dir.
    local lfile="$base/audiobooks/$rel/.fleet-book.json"
    [[ -f "$lfile" ]] || return 1
    raw="$(cat -- "$lfile" 2>/dev/null)" || return 2
  fi
  [[ -n "$raw" ]] || return 2
  print -r -- "$raw" | jq -e . >/dev/null 2>&1 || return 2
  print -r -- "$raw"
  return 0
}

# rip::_ab_anchor_work_uid <rel> <stored json> <uid> — record <uid> as the
# work anchor on the sidecar of ANOTHER book, additively.
#
# THIS IS THE ONLY WRITE IN THIS PHASE THAT TOUCHES A BOOK NOBODY ASKED TO
# RIP, on the operator's live server, mid-session, to the file holding the
# only copy of that book's identity (`fleet.uid`, `local.sha256` /
# `local.stored.sha256`). After
# rip::ab_backfill_work_uid has run it should never fire at all; it exists
# because a book can reach cantina by paths this subsystem does not own.
#
# THE GUARD IS STRUCTURAL, not a test the caller performs. The jq program
# emits `empty` for a sidecar that already carries a uid, so there is no
# payload to ship and nothing can be written — and in the branch that does
# write, the incoming uid is `del`eted from the overlay before the merge, so
# the value being recorded cannot be displaced by whatever was there. The
# caller's own read-side check is a SECOND, independent guard, not this one.
#
# The refusal tests `!= null and != ""`, NOT `($w.uid // "") != ""`: jq's `//`
# treats `false` as empty just as it treats null, so `"uid": false` — non-null,
# and therefore something we must never overwrite — would fall straight through
# the alternative form into the write branch (review finding, 2026-08-26; `0`,
# `12345`, `[]` and `{}` are all refused correctly by both, only `false` leaks).
# No producer in this codebase emits it; the point is that the guard is total
# by construction rather than total for the values that happen to occur.
#
# ADDITIVE: the object is rebuilt from the stored one, so every other key
# keeps its value, and any key `work` itself carried beyond uid/edition
# survives too. `edition: null` is the anchor's honest label — the edition
# name belongs to the book being ripped, never to the book it shares a work
# with.
#
# rc 0 only when the server REPORTED the write landed (the "ok" line
# rip::_sidecars_write prints per book) — never merely because the write was
# attempted, which is this module's recurring defect class.
rip::_ab_anchor_work_uid() {
  setopt localoptions noerrexit nopipefail
  local rel="${1:-}" stored="${2:-}" uid="${3:-}"
  [[ -n "$rel" && -n "$stored" && -n "$uid" ]] || return 1
  local patched
  patched="$(print -r -- "$stored" | jq -c --arg u "$uid" "$_RIP_JQ_WORK_DEF"'
      (.work | _work_obj) as $w
      | if ($w.uid != null and $w.uid != "") then empty
        else .work = ({uid: $u, edition: null} + ($w | del(.uid))) end' 2>/dev/null)"
  # Empty means either the refusal above or a jq that raised — both are
  # "write nothing", which is the safe answer for this file.
  [[ -n "$patched" ]] || return 1
  local payload; payload="$(rip::_sidecar_payload "$rel" "$patched")"
  # Never ship a half-composed payload: the remote would write it.
  [[ -n "$payload" && "$payload" == *$'\t'* ]] || return 1
  local base; base="$(rip::remote_base)"
  local out; out="$(rip::_sidecars_write "$base" "$payload")"
  [[ "$out" == ok$'\t'* ]] || return 1
  return 0
}

# rip::_ab_work_uid_for <base rel> — the uid of the work the book stored at
# <base rel> belongs to. stdout: one lowercase uuid. rc 0 on success, 1 when
# no uid could be produced at all (uuidgen failed), in which case nothing is
# printed and the caller must leave the row's `work` alone rather than record
# half an identity.
#
# Three outcomes, in the order design doc S4 states them:
#
#   * the base book carries a work.uid  -> REUSE it. NO WRITE ANYWHERE. Once
#     --backfill-work-uid has been run this is the only branch that fires.
#   * the base book exists with no uid  -> mint one, write it back to THAT
#     sidecar (rip::_ab_anchor_work_uid), and use it.
#   * no base book is stored, or the server could not be asked -> mint a
#     fresh uid and write nothing. The first is legal (the operator may be
#     importing the Full Cast edition first); the second is a refusal to
#     touch a book we could not read.
#
# THOSE LAST TWO ARE ONE BRANCH IN CODE AND OPPOSITE FACTS IN THE WORLD, so
# the second one SAYS SO (review finding, 2026-08-26). rip::_remote_sidecar_json
# is tri-state precisely because "unknown must never collapse into absent" —
# yet both landed here as "mint fresh, rc 0, stderr empty", which is the
# correct action for absent and a silent permanent split for unknown: the
# base book may be on cantina right now carrying a uid this rip is about to
# diverge from, and once both books hold a non-null `work` neither is ever a
# --backfill-work-uid candidate again. The write-back failure below already
# warns about that exact consequence; the read side now warns about it too.
# Absent stays SILENT — it is the expected case, and a warning on it would
# teach the operator to ignore the one that matters.
#
# A uid is only REUSED when it is a non-empty STRING. Anything else in that
# field is left strictly alone — not reused, not overwritten — because a
# value of the wrong type is a hand edit or a corruption, and guessing at
# either would spend the one write this design allows on the wrong book.
#
# THE RELPATH IS NFC-NORMALIZED HERE, ONCE, so the read and the write-back use
# THE SAME BYTES (review finding, 2026-08-26). rip::_remote_sidecar_json
# normalizes its own argument before asking the server, but the write path runs
# through rip::_sidecar_payload, whose contract is that the relpath it ships is
# the SERVER's own spelling — and the caller composes this path from a plan
# rip-provider-folder built out of ffprobe tags and macOS directory names, with
# no normalization anywhere. For a decomposed author ("Saint-Exupéry") the read
# then used NFC (`c3a9`) while the payload carried NFD (`cc81`): two byte
# sequences for one directory, so cantina's redirect lands nowhere, the operator
# sees "could not record the shared work uid", and --backfill-work-uid later
# mints the base book a DIFFERENT uid — the permanent split the minted-uid
# design exists to prevent. Normalizing at the entrance means both halves speak
# the server's spelling and rip::_remote_sidecar_json's own rip::_nfc becomes a
# no-op rather than a divergence.
#
# The hermetic tests could not see this on the plain-local-dir branch: APFS is
# normalization-INSENSITIVE, so both spellings open the same file. The guard for
# it is therefore an ssh-branch example, where the payload's base64 relpath is
# compared against the one the remote `cat --` used.
rip::_ab_work_uid_for() {
  setopt localoptions noerrexit nopipefail
  local rel; rel="$(rip::_nfc "${1:-}")"
  local stored="" rc=1
  if [[ -n "$rel" ]]; then
    stored="$(rip::_remote_sidecar_json "$rel")"; rc=$?
  fi
  local have_base=0
  (( rc == 0 )) && [[ -n "$stored" ]] && have_base=1
  if (( rc == 2 )); then
    log_warn "rip: could not read \"$rel\" from cantina — this edition takes a fresh uid and the two will not group as one work"
  fi
  if (( have_base )); then
    local existing
    # `_work_obj` before the subscript: `.work.uid` RAISES on an array (see
    # _RIP_JQ_WORK_DEF), and the raise here would be swallowed into an empty
    # string — which reads as "no uid" and sends us down the WRITE path on a
    # book whose work field we could not actually read.
    existing="$(print -r -- "$stored" | jq -r "$_RIP_JQ_WORK_DEF"'
      (.work | _work_obj | .uid) as $u
      | if ($u | type) == "string" then $u else "" end' 2>/dev/null)"
    if [[ -n "$existing" ]]; then
      print -r -- "$existing"
      return 0
    fi
  fi
  # Minted LOCALLY, one per call — the same pattern rip::ab_backfill_work_uid
  # and --repair-sidecars Case C follow. Lowercased so two runs (or a
  # hand-typed uid elsewhere) compare equal byte for byte.
  local uid; uid="$(uuidgen 2>/dev/null)"; uid="${(L)uid}"
  if [[ -z "$uid" ]]; then
    log_warn "rip: uuidgen produced nothing — cannot resolve the work this edition belongs to"
    return 1
  fi
  if (( have_base )); then
    rip::_ab_anchor_work_uid "$rel" "$stored" "$uid" \
      || log_warn "rip: could not record the shared work uid on \"$rel\" — this edition takes $uid, and the two will not group as one work until \"$rel\" carries the same uid (--backfill-work-uid would mint it a DIFFERENT one)"
  fi
  print -r -- "$uid"
  return 0
}

# rip::_sidecars_write <base> <payload…> — write a batch of
# already-composed sidecars, atomically, in ONE ssh.
#
# Whole-sidecar, not published-only: the payload is the COMPLETE new file, so
# the same transport carries a backfilled date (rip::ab_backfill_published), a
# sidecar created from nothing (rip::ab_repair_sidecars, Case A), an assigned
# local identity (Case C) and an adopted ASIN (rip::ab_adopt_asin). It was
# named `_sidecars_write_published` while backfill was its only caller;
# duplicating it per verb would have meant four copies of the guards below.
#
# NO jq ON THE SERVER. This used to run `jq --arg d … "$f" > "$t"` REMOTELY,
# one ssh per book. cantina (stock Debian) has no jq and media@ has no
# passwordless sudo, so every one of the 245 candidate books failed with
# "could not backfill" and the sweep reported "backfilled 0 of 245" (live
# finding, 2026-08-24). The read path already had this right —
# rip::_server_sidecars ships a pure-POSIX enumerator and parses the JSON
# locally — and the write path now follows it: the caller composes the
# complete new sidecar with the LOCAL jq and this ships it as bytes.
#
# Each <payload> is "<base64 of Author/Title><TAB><base64 of the new JSON>".
# Base64 specifically: a title carrying quotes, spaces, `$`, a colon or
# non-ASCII must not be able to break out of the remote command line or be
# word-split by the remote `read`, and the alphabet contains no character
# the default IFS splits on. Everything else interpolated is ${(q)}-quoted,
# BatchMode/ConnectTimeout as everywhere else in this module.
#
# ONE ssh for the whole batch, fed on stdin: 245 books is 245 round-trips
# otherwise, for a sweep that runs once.
#
# The remote script needs only POSIX sh plus `base64` — both present on a
# stock Debian server AND on macOS, which matters because the hermetic
# tests run this same script through the plain-local-dir branch. Because a
# real POSIX /bin/sh (dash on Debian) must be able to parse it, the command
# string that carries it over ssh must itself be POSIX-quoted — see the
# ${(qq)script} note below.
#
# THE GUARDS ARE LOAD-BEARING and must not be weakened: the temp file is
# written in the SAME directory and moved into place (never an in-place
# redirect), `test -s` rejects an empty payload BEFORE the move, and a
# failure removes the temp file and leaves the good sidecar untouched. The
# server holds the only copy of every book and staging is emptied after each
# verified push — a half-written sidecar destroys identity metadata that
# cannot be recovered from the audio.
#
# Prints one "ok<TAB><base64 of Author/Title>" or "fail<TAB>…" line per
# input line so the caller can count what ACTUALLY landed rather than infer
# it from an exit status: a connection that dies mid-stream simply stops
# reporting, and every unreported book is a failure.
rip::_sidecars_write() {
  setopt localoptions noerrexit nopipefail
  local base="$1"; shift
  (( $# > 0 )) || return 0
  # No IFS assignment needed: the default already splits on TAB, and base64
  # never contains one.
  local script='while read -r br bj; do
  [ -n "$br" ] || continue
  d=$(printf %s "$br" | base64 -d 2>/dev/null)
  j=$(printf %s "$bj" | base64 -d 2>/dev/null)
  if [ -z "$d" ] || [ -z "$j" ]; then printf "fail\t%s\n" "$br"; continue; fi
  f="$d/.fleet-book.json"; t="$f.tmp.$$"
  if printf "%s\n" "$j" 2>/dev/null > "$t" && test -s "$t" && mv -- "$t" "$f"; then
    printf "ok\t%s\n" "$br"
  else
    rm -f -- "$t"; printf "fail\t%s\n" "$br"
  fi
done'
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    # ${(qq)script}, NOT ${(q)}: this is the module's only multi-line
    # remote script, and ${(q)} renders an embedded newline as $'\n' —
    # bash/zsh ANSI-C quoting, not POSIX. A real POSIX /bin/sh (dash on
    # Debian) can't parse $'...' and aborts at parse time before the `cd`
    # even runs (deterministic, payload-independent no-op — but a repeat
    # of the "backfilled 0 of 245" bug this code exists to fix). ${(qq)}
    # emits single-quote POSIX style instead; safe here because $script
    # contains no single quote — reverify that if $script ever changes.
    print -rl -- "$@" | "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "cd ${(q)rpath}/audiobooks && sh -c ${(qq)script} sh" 2>/dev/null
  else
    # No ':' — the hermetic tests' plain local dir.
    print -rl -- "$@" | ( cd "$base/audiobooks" 2>/dev/null && sh -c "$script" sh ) 2>/dev/null
  fi
  return 0
}

# --- sidecar repair ---------------------------------------------------------
#
# A book folder is the unit the server stores; .fleet-book.json is the only
# copy of WHO that book is, and it cannot be recomputed from the audio.
# Measured 2026-08-24: 247 book directories, 246 sidecars — and among the 246,
# some carry `ids: {}` (the orphaned-identity fingerprint the canonicalization
# bug produced, fixed in 2f649ae6). Nothing reported either gap.
#
# --repair-sidecars is the report AND the repair, and it discriminates on
# EVIDENCE rather than on the `provider` field, because that field is exactly
# what is untrustworthy in a book whose identity was lost:
#
#   Case A  no sidecar at all, and a provider row matches the composed path
#           EXACTLY            -> compose and write. The only automatic write,
#                                 and only after the server itself confirms
#                                 the file really is absent: a sidecar that
#                                 EXISTS but does not parse is reported as
#                                 unreadable and never written over.
#   Case B  sidecar present, `ids` empty, a provider row IS findable (by exact
#           path, or by a title-component match that yields exactly ONE
#           candidate)         -> REPORT ONLY, never written, not under
#                                 --apply. Confirmed with --adopt-asin.
#   Case C  sidecar present, `ids` empty, NO provider row, and the recorded
#           provider is "manual" -> assign identity: a locally minted
#                                 `fleet.uid` plus a server-computed
#                                 `local.stored.sha256` of the primary audio
#                                 file. STORED, not `local.sha256`: this
#                                 repair can only hash the bytes on the
#                                 server, and since the enrichment retags a
#                                 book on its way in, those are no longer the
#                                 source bytes the byte-dedupe compares
#                                 against (review finding F3, 2026-08-26).
#   (4th)   sidecar present, `ids` empty, NO provider row, provider NOT
#           "manual"           -> UNIDENTIFIABLE. Reported by name, nothing
#                                 written, nothing minted.
#
# The fourth outcome is not a gap in the three — it is the refusal that keeps
# the other three honest. A Libation book that was returned or removed from
# the account lands there: stamping it with a `fleet.uid` would permanently
# disconnect it from an ASIN it may still be entitled to, and `fleet.uid` is
# durable precisely so that nothing later dislodges it. Refuse rather than
# guess, the same doctrine the exact-path join follows.

# rip::_sidecar_payload <relpath> <json-text> — one framed line for
# rip::_sidecars_write: "<base64 relpath><TAB><base64 json>".
#
# jq does the base64, not the local `base64` binary: GNU base64 wraps at 76
# columns by default and a wrapped payload would be word-split by the remote
# `read`. The relpath sent is the SERVER's own spelling (what its `find`
# printed), never a locally normalized one — NFC normalization exists to
# match, not to rename.
rip::_sidecar_payload() {
  setopt localoptions noerrexit nopipefail
  jq -rn --arg r "${1:-}" --arg b "${2:-}" '($r|@base64) + "\t" + ($b|@base64)' 2>/dev/null
}

# rip::_sidecar_index — stdin: rip::_server_sidecars rows. stdout: one
# TAB-separated line per sidecar, so a sweep can classify 247 books without
# spawning 247 jq processes (which is ~5s of pure fork on this laptop):
#
#   <_path> <ids state> <source.provider> <audible.asin> <fleet.uid> <json>
#
# EVERY column but the last is defaulted to "-" and is never empty: TAB is IFS
# whitespace, so `read` collapses two adjacent tabs into ONE separator and a
# single empty field would silently shift every field after it.
#
# NOT `@tsv`: it escapes backslashes, and the last column is `tojson` output
# full of `\"` — `@tsv` would turn those into `\\"` and corrupt the JSON. The
# other columns cannot contain a tab or a newline and `tojson` escapes both,
# so plain concatenation is exact.
#
# `_path` is stripped from the JSON column HERE, once. It is an annotation
# rip::_server_sidecars adds, not a schema field; writing it back would
# permanently add a bogus key to the only copy of a book's identity.
#
# "ids state" is computed from the VALUES, not from `has`: a sidecar carrying
# `{"audible.asin": ""}` has an ids object and no identity at all.
#
# `ids` is COERCED to an object first, and the JSON column is emitted with the
# coerced value (review finding, 2026-08-25). A sidecar carrying `"ids": []`
# (see _RIP_JQ_IDS_DEF) made `.ids["audible.asin"]` raise — swallowed by the
# `2>/dev/null` below — and the whole row was dropped, so the sweep that
# exists to REPAIR a book with no identity could not even see the one book
# whose identity was corrupt. Writing the coerced value back into the JSON
# column is deliberate: rip::ab_repair_sidecars and rip::ab_adopt_asin compose
# the replacement sidecar from this column, so the poison is repaired rather
# than round-tripped onto the server again.
rip::_sidecar_index() {
  setopt localoptions noerrexit nopipefail
  jq -r "$_RIP_JQ_IDS_DEF"'select((._path // "") != "")
    | _ids_fix
    | (if ([(.ids // {}) | to_entries[] | select((.value // "") != "")] | length) == 0
       then "empty" else "set" end) as $state
    | (._path) + "\t" + $state
      + "\t" + ((.source.provider // "") | if . == "" then "-" else . end)
      + "\t" + ((.ids["audible.asin"] // "") | if . == "" then "-" else . end)
      + "\t" + ((.ids["fleet.uid"] // "") | if . == "" then "-" else . end)
      + "\t" + (del(._path) | tojson)' 2>/dev/null
}

# rip::_provider_index — stdin: provider rows. stdout: "<path>\t<id>\t<row>".
# Same TAB framing and same "never empty" rule as above.
rip::_provider_index() {
  setopt localoptions noerrexit nopipefail
  jq -r "$_RIP_JQ_IDS_DEF"'select((.path // "") != "")
    | _ids_fix
    | (.path) + "\t" + (((.id // .ids["audible.asin"]) // "") | if . == "" then "-" else . end)
      + "\t" + tojson' 2>/dev/null
}

# rip::_sidecars_hash_primary <base> <base64 relpath…> — sha256 of each book's
# PRIMARY audio file, computed on the server, in ONE ssh.
#
# Server-side because the server holds the only copy: the local staging tree
# is emptied after every verified push, so there is nothing here to hash. The
# design's recovery story needs this hash to be re-derivable from an orphaned
# file years later, which is exactly what `sha256sum` on the stored bytes
# gives (the `shasum -a 256` fallback is for the hermetic tests' local
# branch, which runs this same script on macOS).
#
# WHAT THIS HASHES IS THE STORED BYTES, AND SINCE 2026-08-26 THAT IS NO
# LONGER THE SOURCE (review finding F3). The enrichment retags every book on
# its way into the library (rip::_retag_book), so the file on the server
# differs from the file that was imported. Both facts are still true and
# useful — this one is re-derivable from the orphan, the other is what the
# byte-dedupe compares — but they are DIFFERENT facts, so its only caller
# records this one as `local.stored.sha256` and leaves `local.sha256` to mean
# what it says: the hash of the source that was imported. See
# rip::ab_repair_sidecars' Case C block and the note on _RIP_SIDECAR_JQ.
#
# Primary audio file = the `.m4b` (Libation's own output, and one per book);
# failing that, the LARGEST audio file in the directory — a multi-part book's
# biggest part is at least stable, and `stat` avoids reading 1.7 GB to learn
# a size the way `wc -c` would.
#
# Prints "ok<TAB><b64 relpath><TAB><sha256>" or "fail<TAB><b64 relpath>" per
# input line, so the caller counts what it actually got rather than inferring
# it from an exit status. A book with no hash is NOT minted an identity.
#
# POSIX sh + coreutils only, and no `jq`: cantina has none (the live
# "backfilled 0 of 245" failure). No single quote appears in the script, so
# ${(qq)} — which is what a real POSIX /bin/sh needs, unlike ${(q)}'s $'\n' —
# wraps it exactly.
rip::_sidecars_hash_primary() {
  setopt localoptions noerrexit nopipefail
  local base="$1"; shift
  (( $# > 0 )) || return 0
  local script='while read -r br; do
  [ -n "$br" ] || continue
  d=$(printf %s "$br" | base64 -d 2>/dev/null)
  if [ -z "$d" ] || [ ! -d "$d" ]; then printf "fail\t%s\n" "$br"; continue; fi
  f=""
  for c in "$d"/*.m4b; do
    if [ -f "$c" ]; then f="$c"; break; fi
  done
  if [ -z "$f" ]; then
    best=""; bestsz=-1
    for c in "$d"/*; do
      [ -f "$c" ] || continue
      case "$c" in
        *.m4b|*.m4a|*.mp3|*.mp4|*.aac|*.flac|*.ogg|*.opus|*.wav|*.aax|*.aaxc) ;;
        *) continue ;;
      esac
      sz=$(stat -c %s "$c" 2>/dev/null || stat -f %z "$c" 2>/dev/null || echo -1)
      if [ "$sz" -gt "$bestsz" ]; then bestsz="$sz"; best="$c"; fi
    done
    f="$best"
  fi
  if [ -z "$f" ]; then printf "fail\t%s\n" "$br"; continue; fi
  h=$(sha256sum "$f" 2>/dev/null || shasum -a 256 "$f" 2>/dev/null)
  h=${h%% *}
  if [ -n "$h" ]; then printf "ok\t%s\t%s\n" "$br" "$h"; else printf "fail\t%s\n" "$br"; fi
done'
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    print -rl -- "$@" | "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "cd ${(q)rpath}/audiobooks && sh -c ${(qq)script} sh" 2>/dev/null
  else
    # No ':' — the hermetic tests' plain local dir.
    print -rl -- "$@" | ( cd "$base/audiobooks" 2>/dev/null && sh -c "$script" sh ) 2>/dev/null
  fi
  return 0
}

# rip::ab_repair_sidecars [--apply] — the four-outcome sweep described above.
#
# Dry run by default, like --retire / --canonicalize-authors /
# --backfill-published: every write here lands on the only copy of a book's
# identity.
#
# EXIT CODE: 0 only when nothing is left outstanding. A book that still needs
# an operator decision (Case B, ambiguous, unidentifiable, unreadable, or a
# missing sidecar with no provider row) or a sidecar that could not be written returns
# 1 — the same rule rip::ab_backfill_published follows, so a `&&` chain or a
# cron wrapper cannot read a partial sweep as a finished one.
rip::ab_repair_sidecars() {
  setopt localoptions noerrexit nopipefail
  local apply=0
  [[ "${1:-}" == "--apply" ]] && apply=1

  local base; base="$(rip::remote_base)"

  # (1) what the server HOLDS and (2) which of those carry a sidecar. Both are
  # captured as VALUES so their failure propagates: read through `< <(...)` an
  # unreachable server is byte-identical to an empty library, and reporting
  # "nothing to repair" for a server we never reached is the exact failure
  # this verb exists to catch.
  local lib rows
  lib="$(rip::ab_server_library)" || return 2
  rows="$(rip::_server_sidecars)" || return 2

  # (3) the provider's rows — the only place a recoverable identity can come
  # from. An empty list cannot be told apart from "the provider did not
  # answer", and that difference decides whether a book is stamped with a
  # locally minted uid it can never lose. REFUSE rather than guess.
  local pname="${RIP_AB_PROVIDER:-libation}"
  local pbin prows=""
  pbin="$(rip::ab_provider_bin "$pname")" || return 2
  prows="$("$pbin" list 2>/dev/null)"
  if [[ -z "$prows" ]]; then
    log_error "rip: the $pname provider returned no rows — refusing to classify book identity against an empty library"
    return 2
  fi

  # Both sides of every comparison go through rip::_nfc. The server is NFC
  # (the push's rsync --iconv guarantees it) and macOS composes NFD, so an
  # accented author would otherwise read as "no match" and be silently
  # skipped — the bug rip::_remote_has_file was already bitten by. The RAW
  # server spelling is what gets written to; the normalized one is only ever a
  # lookup key.
  #
  # asin_owner is the reverse index: an ASIN a STORED sidecar already carries
  # -> the book that carries it. The whole point of a sidecar is that one
  # edition identity names one book, so a proposal for an ASIN that is already
  # spoken for is not a repair, it is a collision (review finding 2,
  # 2026-08-24). Built here because the pass is already running; it costs
  # nothing and no extra round-trip.
  local -A sc_state=() sc_prov=() sc_uid=() sc_json=() asin_owner=()
  local irel istate iprov iasin iuid ijson
  while IFS=$'\t' read -r irel istate iprov iasin iuid ijson; do
    [[ -n "$irel" ]] || continue
    irel="$(rip::_nfc "$irel")"
    sc_state[$irel]="$istate"; sc_prov[$irel]="$iprov"
    sc_uid[$irel]="$iuid";     sc_json[$irel]="$ijson"
    # "-" is _sidecar_index's NEVER-EMPTY filler, not an identifier: it must
    # never become a key that two unrelated books share.
    if [[ -n "$iasin" && "$iasin" != "-" && -z "${asin_owner[$iasin]:-}" ]]; then
      asin_owner[$iasin]="$irel"
    fi
  done < <(print -r -- "$rows" | rip::_sidecar_index)

  # prow_of: NFC composed path -> "<id>\t<row>", first row wins.
  # ptitle_rows: NFC TITLE component -> newline-joined "<path>\t<id>\t<row>",
  # the Case B fallback. Libation files a book under "Shawn Speakman - editor"
  # where the server has "Shawn Speakman", and normalized author matching
  # fails too — what matches exactly is the composed title.
  local -A prow_of=() ptitle_rows=()
  local ppath pid prow ptitle
  while IFS=$'\t' read -r ppath pid prow; do
    [[ -n "$ppath" ]] || continue
    ppath="$(rip::_nfc "$ppath")"
    [[ -n "${prow_of[$ppath]:-}" ]] || prow_of[$ppath]="$pid"$'\t'"$prow"
    ptitle="${ppath##*/}"
    if [[ -n "${ptitle_rows[$ptitle]:-}" ]]; then
      ptitle_rows[$ptitle]+=$'\n'"$ppath"$'\t'"$pid"$'\t'"$prow"
    else
      ptitle_rows[$ptitle]="$ppath"$'\t'"$pid"$'\t'"$prow"
    fi
  done < <(print -r -- "$prows" | rip::_provider_index)

  local -a a_rel=() a_id=() a_row=()   # Case A — create from an exact-path row
  local -a norow=()                    # no sidecar AND no provider row
  local -a b_report=()                 # Case B — recoverable, REPORT ONLY
  local -a ambig=()                    # Case B with more than one candidate
  local -a unident=()                  # empty ids, no row, provider != manual
  local -a c_rel=() c_json=()          # Case C — assign a local identity
  local -a unread=()                   # a sidecar that EXISTS but does not parse
  local -i checked=0 identified=0
  local rel nrel row cands matched_on cpath rest
  # Declared HERE, not inside the loop: a bare `local` in a loop body re-runs
  # per iteration and has bitten this repo before.
  local -i hrc=0

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    (( checked++ ))
    nrel="$(rip::_nfc "$rel")"

    if [[ -z "${sc_state[$nrel]:-}" ]]; then
      # CASE A — no sidecar at all. EXACT composed-path join only: no fuzzy
      # matching, no closest title. A wrong identity is worse than a missing
      # one, because it silently joins this book to another work's key.
      row="${prow_of[$nrel]:-}"
      if [[ -n "$row" ]]; then
        # ABSENT FROM THE INDEX IS NOT ABSENT FROM THE DISK (review finding 2,
        # 2026-08-24). sc_state is built only from sidecars
        # rip::_server_sidecars could PARSE; one it could not is warned about
        # and dropped, so "unparseable" and "missing" arrive here identical —
        # and Case A is the one branch that composes a whole fresh sidecar and
        # moves it over the path. A hand-edited file with a stray trailing
        # comma is unreadable to jq yet fully recoverable by a human, until
        # this verb overwrites it; the server holds the only copy and there is
        # no undo. The design says it twice: "never overwrite an existing
        # sidecar — this verb only creates missing ones", and repairing a
        # MALFORMED one is explicitly out of scope, being a different failure
        # with a different remedy. So ask the server directly before enqueuing
        # anything. Case A candidates are rare (one in the live library), so
        # the extra round-trip costs nothing at the scale this runs at.
        rip::_remote_has_file "audiobooks/$rel/.fleet-book.json"
        hrc=$?
        if (( hrc == 0 )); then
          unread+=("$rel"$'\t'"malformed")
        elif (( hrc != 1 )); then
          # Tri-state: 2 is "the check itself did not run". Not knowing is not
          # permission to write — the invariant is never overwrite, and an
          # unverified absence cannot establish absence.
          unread+=("$rel"$'\t'"unverified")
        else
          a_rel+=("$rel"); a_id+=("${row%%$'\t'*}"); a_row+=("${row#*$'\t'}")
        fi
      else
        norow+=("$rel")
      fi
      continue
    fi

    if [[ "${sc_state[$nrel]:-}" != "empty" ]]; then
      # Already identified — including a Case C book repaired by an earlier
      # run, whose minted fleet.uid IS a non-empty ids entry. That is what
      # makes `--repair-sidecars --apply` idempotent: a second uid is never
      # minted because the book is never a candidate again.
      (( identified++ ))
      continue
    fi

    # ids EMPTY. Which of the three remaining outcomes applies is decided by
    # EVIDENCE — is a provider row findable? — and only then by the recorded
    # provider, which in a book whose identity was lost is the least
    # trustworthy field on the sidecar.
    row="${prow_of[$nrel]:-}"; matched_on="path (exact)"; cpath="$nrel"
    if [[ -z "$row" ]]; then
      cands="${ptitle_rows[${nrel##*/}]:-}"
      if [[ -n "$cands" ]]; then
        local -a carr=("${(f)cands}")
        if (( ${#carr[@]} == 1 )); then
          cpath="${carr[1]%%$'\t'*}"; row="${carr[1]#*$'\t'}"
          matched_on="title (author differs)"
        else
          # Ambiguity is REPORTED, never resolved.
          ambig+=("$rel"$'\t'"$cands")
          continue
        fi
      fi
    fi

    if [[ -n "$row" ]]; then
      # CASE B — recoverable, and never written by this verb, not even under
      # --apply. The title fallback is looser than an exact path match and the
      # cost of being wrong is a book permanently stamped with another book's
      # ASIN, which then propagates into edition grouping and every future
      # `work` join. The tool proposes; the operator disposes, by typing the
      # ASIN into --adopt-asin.
      b_report+=("$rel"$'\t'"${row%%$'\t'*}"$'\t'"$cpath"$'\t'"$matched_on")
      continue
    fi

    if [[ "${sc_prov[$nrel]:-}" == "manual" ]]; then
      # CASE C — genuinely not from the store. Belt and braces on top of the
      # "empty" test above: never mint over an existing uid.
      if [[ "${sc_uid[$nrel]:--}" != "-" ]]; then
        (( identified++ ))
        continue
      fi
      c_rel+=("$rel"); c_json+=("${sc_json[$nrel]:-}")
    else
      # THE FOURTH OUTCOME — unidentifiable. See the header: minting here
      # would permanently disconnect a book from an ASIN it may still be
      # entitled to.
      unident+=("$rel"$'\t'"${sc_prov[$nrel]:--}")
    fi
  done <<< "$lib"

  # --- report (both modes; these outcomes are never repaired) ---------------
  #
  # ONE ASIN, TWO BOOKS (review finding 3, 2026-08-24). Ambiguity was detected
  # in only one direction — one server book with two candidate rows. The
  # inverse shape is just as real and this module already knows it exists:
  # "J. R. R. Tolkien/The Hobbit" and "J.R.R. Tolkien/The Hobbit" are two
  # folders for one work (the author-variant collision --canonicalize-authors
  # was written for), and the title fallback happily proposes the SAME ASIN
  # for both — one of them presented as "matched on: path (exact)", which
  # reads as high confidence. --adopt-asin's own guard only ever inspects the
  # target book's sidecar, so an operator who confirms both ends up with two
  # folders carrying one audible.asin: precisely the duplicated edition
  # identity the sidecar exists to prevent. A proposal that is not unique is
  # not a proposal — it is an ambiguity, and it is reported as one.
  #
  # CASE A COUNTS TOO (review finding 2, 2026-08-24). This pre-pass used to
  # count proposals across b_report ONLY — and a Case A candidate never enters
  # b_report. So ONE provider row could stamp its ASIN on a bare folder
  # automatically AND be proposed for a second folder in the same report, one
  # presented as a high-confidence adopt and the other as an automatic write;
  # an operator following the printed instructions in the printed order ended
  # up with two folders carrying one edition identity, rc 0, no warning.
  # --adopt-asin's guard 5 only catches the reverse order (adopt first, sweep
  # second), and Case A is the one AUTOMATIC write this verb makes, which is
  # exactly why it is the one that most needs counting.
  #
  # "-" IS NOT AN ASIN (review finding 4, 2026-08-24). rip::_provider_index
  # emits "-" as its never-empty filler when a row carries neither `.id` nor
  # `.ids["audible.asin"]` (rip-provider-libation composes
  # `id: (.AudibleProductId // "")`, empty for a book the account no longer
  # lists), so counting it collapses every id-less row onto one key and
  # reports two unrelated books as sharing an ASIN — with an unusable
  # `--adopt-asin "<…>" -` remedy line to match. It is excluded from the
  # counting pass AND from the `> 1` test.
  local entry cand cid
  local -A bid_count=()
  local -i i
  for (( i = 1; i <= ${#a_id[@]}; i++ )); do
    cid="${a_id[i]}"
    [[ -n "$cid" && "$cid" != "-" ]] || continue
    bid_count[$cid]=$(( ${bid_count[$cid]:-0} + 1 ))
  done
  for entry in "${b_report[@]}"; do
    rest="${entry#*$'\t'}"; cid="${rest%%$'\t'*}"
    [[ -n "$cid" && "$cid" != "-" ]] || continue
    bid_count[$cid]=$(( ${bid_count[$cid]:-0} + 1 ))
  done

  # A Case A candidate whose ASIN is not its alone is DROPPED from the write
  # plan here, before `intended` is computed and before a single "would create
  # sidecar" line is printed. It cannot wait for --adopt-asin's guards: this
  # is the automatic write, and the operator is never asked.
  local -a ka_rel=() ka_id=() ka_row=() dup_a=()
  for (( i = 1; i <= ${#a_rel[@]}; i++ )); do
    cid="${a_id[i]}"
    if [[ -n "$cid" && "$cid" != "-" && -n "${asin_owner[$cid]:-}" ]]; then
      dup_a+=("${a_rel[i]}"$'\t'"$cid"$'\t'"stored"$'\t'"${asin_owner[$cid]}")
    elif [[ -n "$cid" && "$cid" != "-" ]] && (( ${bid_count[$cid]:-0} > 1 )); then
      dup_a+=("${a_rel[i]}"$'\t'"$cid"$'\t'"proposed"$'\t'"$(( ${bid_count[$cid]} - 1 ))")
    else
      ka_rel+=("${a_rel[i]}"); ka_id+=("$cid"); ka_row+=("${a_row[i]}")
    fi
  done
  a_rel=("${ka_rel[@]}"); a_id=("${ka_id[@]}"); a_row=("${ka_row[@]}")

  local -i need_n=0 amb_n=$(( ${#ambig[@]} + ${#dup_a[@]} ))
  for entry in "${dup_a[@]}"; do
    rel="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
    cid="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    print -r -- "ambiguous (nothing written): $rel"
    if [[ "${rest%%$'\t'*}" == "stored" ]]; then
      print -r -- "  proposed ASIN : $cid  — already carried by ${rest#*$'\t'}; one ASIN cannot identify two books"
    else
      print -r -- "  proposed ASIN : $cid  — also proposed for ${rest#*$'\t'} other book(s); one ASIN cannot identify two books"
    fi
    print -r -- "  left alone    : no sidecar was created — one ASIN identifies one book; resolve the collision first"
  done
  for entry in "${b_report[@]}"; do
    rel="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
    cid="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    cpath="${rest%%$'\t'*}"; matched_on="${rest#*$'\t'}"
    if [[ -n "$cid" && "$cid" != "-" ]] && (( ${bid_count[$cid]:-0} > 1 )); then
      (( amb_n++ ))
      print -r -- "ambiguous (nothing written): $rel"
      print -r -- "  proposed ASIN : $cid  — also proposed for $(( ${bid_count[$cid]} - 1 )) other book(s); one ASIN cannot identify two books"
      print -r -- "  matched row   : $cpath"
      print -r -- "  matched on    : $matched_on"
      print -r -- "  resolve with  : rip-audiobook --adopt-asin \"<the one book that is $cid>\" $cid"
      continue
    fi
    (( need_n++ ))
    print -r -- "recoverable (needs confirmation): $rel"
    print -r -- "  proposed ASIN : $cid"
    print -r -- "  matched row   : $cpath"
    print -r -- "  matched on    : $matched_on"
    print -r -- "  confirm with  : rip-audiobook --adopt-asin \"$rel\" $cid"
  done
  for entry in "${ambig[@]}"; do
    rel="${entry%%$'\t'*}"; cands="${entry#*$'\t'}"
    print -r -- "ambiguous (nothing written): $rel"
    for cand in "${(f)cands}"; do
      cpath="${cand%%$'\t'*}"; rest="${cand#*$'\t'}"; cid="${rest%%$'\t'*}"
      print -r -- "  candidate     : $cid  $cpath"
    done
    print -r -- "  pick one with : rip-audiobook --adopt-asin \"$rel\" <ASIN>"
  done
  for entry in "${unident[@]}"; do
    rel="${entry%%$'\t'*}"
    print -r -- "unidentifiable (empty identity, no provider row, provider \"${entry#*$'\t'}\"): $rel"
    print -r -- "  left alone    : only a \"manual\" book is given a locally minted identity"
  done
  # TALLIED APART, not together (review finding 3, 2026-08-24). The two labels
  # under this one headline rest on opposite evidence: "malformed" captured a
  # `test -f` that said the file IS there, while "unverified" captured nothing
  # at all — the probe never ran. Summing them let the closing line assert
  # "have a sidecar that could not be read" about a book for which no sidecar
  # was ever established, which is the same defect (a sentence stating an
  # outcome nothing captured) this subsystem has now paid for eight times.
  local -i unread_bad=0 unread_unk=0
  for entry in "${unread[@]}"; do
    rel="${entry%%$'\t'*}"
    print -r -- "unreadable sidecar (not repaired): $rel"
    if [[ "${entry#*$'\t'}" == "malformed" ]]; then
      (( unread_bad++ ))
      print -r -- "  malformed     : the stored .fleet-book.json exists but does not parse"
      print -r -- "  left alone    : this verb only CREATES a missing sidecar — fix this one by hand"
    else
      (( unread_unk++ ))
      print -r -- "  unverified    : could not confirm whether a sidecar is there"
      print -r -- "  left alone    : an absence that was not established is never written over"
    fi
  done
  for rel in "${norow[@]}"; do
    print -r -- "unrepairable (no sidecar, no provider row): $rel"
  done

  local -i intended=$(( ${#a_rel[@]} + ${#c_rel[@]} ))
  local -i outstanding=$(( need_n + amb_n + ${#unident[@]} + ${#norow[@]} + ${#unread[@]} ))

  if (( ! apply )); then
    for (( i = 1; i <= ${#a_rel[@]}; i++ )); do
      print -r -- "would create sidecar: ${a_rel[i]}  ->  ${a_id[i]}"
    done
    for (( i = 1; i <= ${#c_rel[@]}; i++ )); do
      print -r -- "would assign local identity: ${c_rel[i]}  (fleet.uid + local.stored.sha256)"
    done
    if (( intended > 0 )); then
      print -r -- "($intended book(s); re-run with --apply)"
    fi
    rip::_repair_summary 0 "$checked" "$identified" 0 "$intended" \
      "$need_n" "$amb_n" "${#unident[@]}" "${#norow[@]}" "$unread_bad" "$unread_unk"
    (( outstanding > 0 )) && return 1
    return 0
  fi

  # --- apply ---------------------------------------------------------------
  # COMPOSE LOCALLY, WRITE REMOTELY: the server has no jq (the live
  # "backfilled 0 of 245" failure). Case A composes a whole sidecar through
  # the module's ONE composer; Case C AMENDS the stored object, exactly the
  # way --backfill-published does, because the stored sidecar is already in
  # schema shape and re-composing it from a provider row it does not have
  # would rewrite fields nobody asked to change.
  local -a payloads=() sent_rels=() ok_flags=()
  local -A idx_of=()
  local composed payload uid sha

  for (( i = 1; i <= ${#a_rel[@]}; i++ )); do
    composed="$(rip::_sidecar_compose "${a_row[i]}")"
    payload=""
    [[ -n "$composed" ]] && payload="$(rip::_sidecar_payload "${a_rel[i]}" "$composed")"
    if [[ -z "$payload" || "$payload" != *$'\t'* ]]; then
      # Never ship a half-composed payload: the remote would write it.
      log_warn "rip: could not compose a sidecar for ${a_rel[i]}"
      continue
    fi
    payloads+=("$payload"); sent_rels+=("${a_rel[i]}"); ok_flags+=(0)
    idx_of[${payload%%$'\t'*}]=${#payloads}
  done

  if (( ${#c_rel[@]} > 0 )); then
    # ONE ssh for every Case C hash, before any write: an identity is minted
    # only for a book whose primary file was actually hashed. The uid is the
    # stable join key and the hash is the recovery anchor — half of that pair
    # is the very exposure this repair exists to close, so a book with no hash
    # gets nothing at all.
    #
    # THE HASH IS RECORDED AS `local.stored.sha256`, NOT `local.sha256`
    # (review finding F3, 2026-08-26). The two are different facts and only
    # one of them is knowable here. `local.sha256` means "the hash of the
    # SOURCE that was imported", and rip::ab_worker's byte-dedupe compares an
    # about-to-be-copied source file against exactly that. This repair has no
    # source to hash — it hashes the STORED bytes, on the server, because
    # that is the only copy there is — and since the enrichment now retags
    # every book on its way in (rip::_retag_book), stored bytes and source
    # bytes are no longer the same bytes. Recorded as `local.sha256` it would
    # hand the dedupe a value no source file can ever match: dedupe silently
    # stops firing for every repaired book, with nothing on screen to say so.
    # Under its own key it stays exactly what it is — the recovery anchor
    # that makes an orphaned file re-identifiable years later — and the
    # dedupe index simply does not list a book whose source hash nobody
    # knows, which is the honest answer rather than a wrong one.
    local -a c_b64=()
    for (( i = 1; i <= ${#c_rel[@]}; i++ )); do
      c_b64+=("$(jq -rn --arg r "${c_rel[i]}" '$r|@base64' 2>/dev/null)")
    done
    local hout=""
    hout="$(rip::_sidecars_hash_primary "$base" "${c_b64[@]}")"
    local -A sha_of=()
    local hst hkey hval
    while IFS=$'\t' read -r hst hkey hval; do
      [[ "$hst" == "ok" && -n "$hkey" && -n "$hval" ]] || continue
      sha_of[$hkey]="$hval"
    done <<< "$hout"
    for (( i = 1; i <= ${#c_rel[@]}; i++ )); do
      sha="${sha_of[${c_b64[i]}]:-}"
      if [[ -z "$sha" ]]; then
        log_warn "rip: could not hash the primary audio file for ${c_rel[i]} — refusing to mint an identity that cannot be re-derived"
        continue
      fi
      # uuidgen LOCALLY: the server has none. Lowercased so two runs of the
      # same repair on different machines write the same shape.
      uid="$(uuidgen 2>/dev/null)"; uid="${(L)uid}"
      if [[ -z "$uid" ]]; then
        log_warn "rip: uuidgen produced nothing — cannot assign an identity to ${c_rel[i]}"
        continue
      fi
      composed="$(print -r -- "${c_json[i]}" | jq -c --arg u "$uid" --arg s "$sha" \
        "$_RIP_JQ_IDS_DEF"'del(._path) | .ids = ((.ids | _ids_obj) + {"fleet.uid": $u, "local.stored.sha256": $s})' 2>/dev/null)"
      payload=""
      [[ -n "$composed" ]] && payload="$(rip::_sidecar_payload "${c_rel[i]}" "$composed")"
      if [[ -z "$payload" || "$payload" != *$'\t'* ]]; then
        log_warn "rip: could not compose the local identity for ${c_rel[i]}"
        continue
      fi
      payloads+=("$payload"); sent_rels+=("${c_rel[i]}"); ok_flags+=(0)
      idx_of[${payload%%$'\t'*}]=${#payloads}
    done
  fi

  local out=""
  (( ${#payloads[@]} > 0 )) && out="$(rip::_sidecars_write "$base" "${payloads[@]}")"

  # GATED ON THE REPORTED OUTCOME, never on the write having been attempted: a
  # book counts as repaired only when the remote loop said "ok" for it, so an
  # ssh that dies halfway leaves the rest counted as failures AND named.
  local -i repaired=0
  local rline st key
  while IFS= read -r rline; do
    [[ -n "$rline" ]] || continue
    st="${rline%%$'\t'*}"; key="${rline#*$'\t'}"
    [[ "$st" == "ok" ]] || continue
    i=${idx_of[$key]:-0}
    (( i > 0 )) && ok_flags[i]=1
  done <<< "$out"
  for (( i = 1; i <= ${#sent_rels[@]}; i++ )); do
    if (( ok_flags[i] )); then
      (( repaired++ ))
      print -r -- "repaired: ${sent_rels[i]}"
    else
      log_warn "rip: could not write the sidecar for ${sent_rels[i]}"
    fi
  done
  local -i unwritten=$(( intended - repaired ))
  rip::_repair_summary 1 "$checked" "$identified" "$repaired" "$intended" \
    "$need_n" "$amb_n" "${#unident[@]}" "${#norow[@]}" "$unread_bad" "$unread_unk"
  (( unwritten > 0 || outstanding > 0 )) && return 1
  return 0
}

# rip::_repair_summary <apply> <checked> <identified> <repaired> <intended>
# <needs confirmation> <ambiguous> <unidentifiable> <no row> <malformed>
# <unverified> — the closing tally.
#
# Printed in BOTH modes and even when everything is already fine: a silent
# --apply with nothing to do is otherwise byte-identical to a run that never
# reached the server, which is the ambiguity --backfill-published had to close
# too. The counts name every outcome, so a partial sweep can never read as a
# finished one.
#
# <apply> GATES THE WRITE TALLY, and it is the whole reason this takes a mode
# argument (review finding 1, 2026-08-24). The dry-run caller passes repaired=0
# because a dry run deliberately opens no write connection — but the tally then
# read "repaired 0 of 2 sidecar(s) / 2 sidecar(s) could not be written" for two
# writes that were never attempted, and exited 0 while saying it. That is a
# line stating an outcome nothing captured, on the very command an operator
# runs first. In dry-run mode the plan is already stated by the caller's
# "($intended book(s); re-run with --apply)"; the write tally belongs only to a
# run that actually wrote. --backfill-published's dry run never claimed this.
#
# THE LAST TWO COUNTS ARE SEPARATE ON PURPOSE (review finding 3, 2026-08-24).
# <malformed> is a sidecar the server confirmed IS there and jq could not
# parse; <unverified> is a book whose probe never ran, so nothing established
# that a sidecar exists at all. One line covering both had to assert existence
# for the second — the refusal was right, the sentence was not. Each line now
# says only what its own count captured.
rip::_repair_summary() {
  local -i apply=$1
  local -i checked=$2 identified=$3 repaired=$4 intended=$5
  local -i need=$6 amb=$7 unid=$8 norow=$9 unread=${10} unver=${11}
  if (( apply && intended > 0 )); then
    print -r -- "rip: repaired $repaired of $intended sidecar(s)"
    (( intended - repaired > 0 )) && print -r -- "rip: $(( intended - repaired )) sidecar(s) could not be written"
  fi
  (( need > 0 ))   && print -r -- "rip: $need book(s) need confirmation — see the --adopt-asin line(s) above"
  (( amb > 0 ))    && print -r -- "rip: $amb book(s) are ambiguous and were left alone"
  (( unid > 0 ))   && print -r -- "rip: $unid book(s) are unidentifiable and were left alone"
  (( unread > 0 )) && print -r -- "rip: $unread book(s) have a sidecar that could not be read and were left alone"
  (( unver > 0 ))  && print -r -- "rip: $unver book(s) were left alone: whether a sidecar is there could not be confirmed"
  (( norow > 0 ))  && print -r -- "rip: $norow book(s) have no sidecar and no provider row"
  if (( intended == 0 && need == 0 && amb == 0 && unid == 0 && norow == 0 && unread == 0 && unver == 0 )); then
    print -r -- "rip: nothing to repair ($checked book(s) checked, $identified already identified)"
  fi
  return 0
}

# --- companion repair -------------------------------------------------------
#
# The retroactive half of the companions feature. Task 5 records companions
# for every book written from now on; measured on the live library 2026-08-24,
# 13 stored books carry a PDF and 246 carry a cover image and the library
# describes NONE of them — they survive only because rsync moves whole
# directories, and nothing in the catalogue knows they exist.

# rip::_server_companion_files <base> — every stored book directory and the
# NON-AUDIO files it holds, in ONE ssh. TAB-separated, POSIX tools only:
#
#   D<TAB><1|0><TAB><Author>/<Title>          1 = a .fleet-book.json is present
#   F<TAB><Author>/<Title><TAB><bytes><TAB><sha256><TAB><basename>
#
# NO jq ON THE SERVER: cantina is stock Debian and shipping a remote jq is
# what broke --backfill-published entirely across 245 books. The server lists
# names, sizes and hashes; every byte of JSON is assembled locally, the same
# division of labour rip::_server_sidecars and rip::_sidecars_write already
# use.
#
# THE D LINE IS THE POINT. rip::_server_sidecars silently DROPS a sidecar it
# cannot parse, so without an independent listing of the directories
# themselves "unparseable" and "absent" are the same observation — and
# overwriting an unparseable sidecar destroys identity a human could otherwise
# have recovered by hand. This exact defect shipped once in this subsystem.
#
# AUDIO IS EXCLUDED ON THE SERVER, with the module's ONE audio-extension set
# (rip::_dir_has_audio, rip::_sidecars_hash_primary's scan,
# rip::_companions_json), matched case-insensitively the way
# rip::_companions_json matches it — hence the bracket patterns, which cost no
# fork where a `tr` would cost one per file. Not a taste question: hashing the
# audio would mean sha256-ing every stored book, hundreds of gigabytes, to
# learn something "the audio IS the book" says we do not want.
#
# ONE ssh for the whole library: 247 books must not be 247 round-trips. `-n`
# so this can never eat a caller's stdin — three defects of that shape so far
# in this module. And ${(qq)script}, NOT ${(q)}: the script is multi-line and
# ${(q)} renders a newline as $'\n', bash/zsh ANSI-C quoting that a real POSIX
# /bin/sh (dash, on Debian) cannot parse — a deterministic,
# payload-independent no-op, and the exact shape of the "backfilled 0 of 245"
# failure. No single quote appears in the script, which is what makes ${(qq)}
# exact; reverify that if it ever changes.
#
# The closing `:` makes the exit status deterministic: without it the status
# is whatever the last file of the last book happened to leave behind (a
# `continue` from the audio filter, say), and this status is the only thing
# that tells the sweep it reached the server at all.
#
# THE `E<TAB><rc>` LINE IS `find`'S OWN STATUS, AND IT IS NOT OPTIONAL (review
# finding 2, 2026-08-25 — the eleventh defect of this class here). This used to
# be `find … | while read`, and a POSIX pipeline reports only the LAST command,
# so a `find` that exited non-zero because it could not descend into a
# directory was silently discarded: with one author directory unreadable the
# sweep printed "recorded companions for 2 of 2" and exited 0 for a library
# whose third book it never saw. rip::_server_sidecars under-enumerates
# identically, so the denominator agrees with the short listing and nothing
# downstream can notice. `find` now runs in a command substitution, whose
# status IS its own, and the caller treats a non-zero one as an outstanding
# condition. (The same pipeline shape survives in rip::_server_sidecars:
# fixing it there is a separate change with its own callers to re-verify.)
rip::_server_companion_files() {
  setopt localoptions noerrexit nopipefail
  local base="${1:-}"
  local script='l=$(find . -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
frc=$?
printf "E\t%s\n" "$frc"
printf "%s\n" "$l" | while read -r d; do
  [ -n "$d" ] || continue
  d=${d#./}
  s=0
  if [ -f "$d/.fleet-book.json" ]; then s=1; fi
  printf "D\t%s\t%s\n" "$s" "$d"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.[mM]4[bB]|*.[mM]4[aA]|*.[mM][pP]3|*.[mM][pP]4|*.[aA][aA][cC]|*.[fF][lL][aA][cC]|*.[oO][gG][gG]|*.[oO][pP][uU][sS]|*.[wW][aA][vV]|*.[aA][aA][xX]|*.[aA][aA][xX][cC]) continue ;;
    esac
    sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)
    h=$(sha256sum "$f" 2>/dev/null || shasum -a 256 "$f" 2>/dev/null)
    h=${h%% *}
    printf "F\t%s\t%s\t%s\t%s\n" "$d" "$sz" "$h" "${f##*/}"
  done
done
:'
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    "$ssh_bin" -n -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "cd ${(q)rpath}/audiobooks && sh -c ${(qq)script} sh" 2>/dev/null
  else
    # No ':' — the hermetic tests' plain local dir.
    ( cd "$base/audiobooks" 2>/dev/null && sh -c "$script" sh ) 2>/dev/null
  fi
}

# rip::ab_repair_companions [--apply] — record each stored book's companion
# files in its sidecar.
#
# Modelled on rip::ab_backfill_published, deliberately: enumerate, compute
# LOCALLY, write in ONE batch. Dry run by default — every write here lands on
# the only copy of a book's identity, and the sidecar cannot be reconstructed
# from the audio.
#
# ADDITIVE ONLY. The stored object is amended (`.companions = …`) rather than
# recomposed, so a resolved `work`, an existing `ids` and every other field are
# carried through untouched — the same merge rule rip::_book_sidecar keeps.
#
# WHAT COUNTS AS "NEEDS RECORDING": the recorded array differs from what is on
# disk, comparing sorted by file name. An ABSENT `companions` key is not the
# same as `[]`: `[]` means "scanned, nothing there" and absent means "never
# looked", so a book with no companion files still gains the empty array once.
# (jq's `length` returns 0 for `null` as well as `[]` — only `type`
# discriminates the two, which is why the comparison tests it.)
#
# AN UNPARSEABLE SIDECAR IS REPORTED AND NEVER WRITTEN OVER. See
# rip::_server_companion_files for why that needs a second listing at all.
#
# EXIT CODE FOLLOWS WHAT LANDED, never whether the sweep ran: 0 only when
# nothing is left outstanding, so a `&&` chain or a wrapper cannot read a
# total failure as success.
rip::ab_repair_companions() {
  setopt localoptions noerrexit nopipefail
  local apply=0
  [[ "${1:-}" == "--apply" ]] && apply=1

  local base; base="$(rip::remote_base)"

  # THE ENUMERATION FIRST, and its failure is fatal. An unreachable server
  # yields an empty list, which without this refusal reads as "every stored
  # book is already described" — the ambiguity --backfill-published and
  # --editions both had to close.
  local rows rc=0
  rows="$(rip::_server_sidecars)" || rc=$?
  (( rc == 0 )) || return 2

  local listing lrc=0
  listing="$(rip::_server_companion_files "$base")" || lrc=$?
  if (( lrc != 0 )); then
    log_error "rip: could not list the stored book files on cantina (rc=$lrc) — refusing to record companions for a library we could not read"
    return 2
  fi

  # ONE jq for the whole enumeration, not one per book: 247 books is seconds
  # of pure fork otherwise, which is exactly why rip::_sidecar_index exists.
  # It also strips the `_path` annotation once, here — that key is NOT in the
  # stored file, and writing it back would permanently add a bogus field to
  # the only copy of every book's identity.
  local -A json_of=() has_sidecar=() computed=()
  local -a dirs=()
  local -i seen=0
  local idx comp_lines line rel state prov asin uid json flag
  if [[ -n "$rows" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      (( seen++ ))
    done <<< "$rows"
    idx="$(print -r -- "$rows" | rip::_sidecar_index)"
    while IFS=$'\t' read -r rel state prov asin uid json; do
      [[ -n "$rel" && -n "$json" ]] || continue
      json_of[$rel]="$json"
    done <<< "$idx"
  fi

  # `enum_seen` is deliberately separate from `enum_rc`: a listing carrying NO
  # `E` line at all is not a healthy enumeration either — it means the remote
  # script is not the one this function shipped — and defaulting a missing
  # health report to "fine" is the very inference this fix exists to remove.
  local -i enum_rc=0 enum_seen=0
  while IFS= read -r line; do
    if [[ "$line" == E$'\t'* ]]; then
      enum_seen=1
      enum_rc="${line#E$'\t'}"
      continue
    fi
    [[ "$line" == D$'\t'* ]] || continue
    line="${line#D$'\t'}"
    flag="${line%%$'\t'*}"
    rel="${line#*$'\t'}"
    [[ -n "$rel" ]] || continue
    dirs+=("$rel")
    has_sidecar[$rel]="$flag"
  done <<< "$listing"
  local -i enum_bad=0
  (( enum_seen && enum_rc == 0 )) || enum_bad=1

  # The companion array for every book, in ONE jq pass over the whole listing.
  # `.[4:] | join("\t")` rather than `.[4]`: the file name is the LAST field
  # precisely so a name containing a tab cannot shift the columns before it.
  local comp_prog='[ split("\n")[] | select(startswith("F\t")) | split("\t") ]
    | group_by(.[1])[]
    | .[0][1] + "\t" + ([ .[]
        | (.[4:] | join("\t")) as $f
        | {file: $f, kind: ($f | '"$_RIP_COMPANION_KIND_JQ"'),
           bytes: ((.[2] // "0") | tonumber? // 0),
           sha256: (if (.[3] // "") == "" then null else .[3] end)} ]
       | sort_by(.file) | tojson)'
  local crc=0
  comp_lines="$(print -r -- "$listing" | jq -rRs "$comp_prog" 2>/dev/null)" || crc=$?
  if (( crc != 0 )); then
    log_error "rip: could not read the server file listing — nothing recorded"
    return 2
  fi
  while IFS=$'\t' read -r rel json; do
    [[ -n "$rel" ]] || continue
    computed[$rel]="$json"
  done <<< "$comp_lines"

  # Emits "" when the recorded array already matches, otherwise
  # "<count><TAB><the whole amended sidecar>". Comparing SORTED means a
  # library whose sidecars were written in a different collation order is not
  # rewritten for nothing.
  # `(type != "object") or (length == 0)` -> "!", the malformed marker (review
  # finding 1, 2026-08-25). The guard below tests whether the enumerator
  # produced a row at all, which is NOT a test of shape: a sidecar whose entire
  # content is the JSON literal `null` survives the read path, because jq
  # accepts a null left operand for `+` — `null + {_path:$p}` is
  # `{"_path":"A/B"}`, which passes the `_path` filter and comes back out of
  # rip::_sidecar_index as `{}`. Non-empty, so the guard did not fire, and the
  # book was rewritten as `{"companions":[…]}`: laundered out of the malformed
  # report and left looking like a swept, identity-less book. A stored `{}` is
  # indistinguishable from it by this point and gets the same refusal, which is
  # correct — writing companions into an object with no identity manufactures a
  # book that looks scanned and identifies nothing.
  local cmp_prog='($c | sort_by(.file)) as $want
    | if (type != "object") or (length == 0) then "!"
      elif ((.companions | type) == "array") and ((.companions | sort_by(.file)) == $want)
      then "" else (($want | length | tostring) + "\t" + ((.companions = $want) | tojson)) end'

  local -a to_rel=() to_n=() to_json=() malformed=() nosidecar=()
  local -i failed=0 jrc=0
  local d comp out
  for d in "${dirs[@]}"; do
    if [[ "${has_sidecar[$d]}" != 1 ]]; then
      # No sidecar at all is --repair-sidecars' Case A, a different verb with
      # a different decision to make. Named here, but it does not fail this
      # sweep: on the live library it is a permanent one-book condition.
      nosidecar+=("$d")
      continue
    fi
    if [[ -z "${json_of[$d]}" ]]; then
      # The directory HAS a sidecar and the enumerator could not parse it.
      malformed+=("$d")
      continue
    fi
    comp="${computed[$d]}"
    [[ -n "$comp" ]] || comp='[]'
    jrc=0
    out="$(print -r -- "${json_of[$d]}" | jq -r --argjson c "$comp" "$cmp_prog" 2>/dev/null)" || jrc=$?
    if (( jrc != 0 )); then
      # NEVER write on a failure: an empty or half-composed payload would
      # replace a good sidecar with nothing.
      log_warn "rip: could not compose the companions of $d — nothing recorded for it"
      (( failed++ ))
      continue
    fi
    if [[ "$out" == "!" ]]; then
      # A parseable row that is not a usable identity object — see cmp_prog.
      malformed+=("$d")
      continue
    fi
    [[ -n "$out" ]] || continue          # already correct — never rewritten
    to_rel+=("$d")
    to_n+=("${out%%$'\t'*}")
    to_json+=("${out#*$'\t'}")
  done

  local -i outstanding=$(( ${#malformed[@]} + failed ))
  local f
  if (( ${#malformed[@]} )); then
    print -r -- "rip: ${#malformed[@]} stored book(s) carry a sidecar that does not parse — reported, NEVER overwritten:"
    for f in "${(@o)malformed}"; do print -r -- "    $f"; done
  fi
  if (( ${#nosidecar[@]} )); then
    print -r -- "rip: ${#nosidecar[@]} stored book(s) have no sidecar at all — run --repair-sidecars:"
    for f in "${(@o)nosidecar}"; do print -r -- "    $f"; done
  fi
  if (( enum_bad )); then
    print -r -- "rip: the server file listing was incomplete (find rc=$enum_rc) — at least one directory could not be read, so no count below is the whole library"
  fi

  if (( ${#to_rel[@]} == 0 )); then
    # Narrated in BOTH modes, and split by cause. A silent --apply with
    # nothing to record is otherwise byte-identical to a run that never
    # reached the server, and a run where every candidate FAILED must not
    # print the line an operator reads as "the sweep is done".
    if (( ${#dirs[@]} == 0 && seen == 0 )); then
      print -r -- "rip: no books found on the server — nothing to record (is cantina reachable?)"
      (( enum_bad )) && return 1
      return 0
    fi
    if (( outstanding > 0 )); then
      print -r -- "rip: nothing recorded — $outstanding book(s) could not be read"
      return 1
    fi
    if (( enum_bad )); then
      print -r -- "rip: nothing to record in the part of the library that could be read"
      return 1
    fi
    print -r -- "rip: nothing to record"
    return 0
  fi

  local -i i
  if (( ! apply )); then
    for (( i = 1; i <= ${#to_rel[@]}; i++ )); do
      print -r -- "would record: ${to_rel[i]}  ->  ${to_n[i]} companion(s)"
    done
    print -r -- "(${#to_rel[@]} book(s); re-run with --apply)"
    # A PARTIAL sweep must not read as a complete one, in dry run too: the
    # operator deciding whether to --apply needs to know the run will not
    # finish the job either way.
    if (( outstanding > 0 )); then
      print -r -- "rip: $outstanding book(s) could not be read"
    fi
    (( outstanding > 0 || enum_bad )) && return 1
    return 0
  fi

  # COMPOSE LOCALLY, WRITE REMOTELY, in ONE ssh for the whole sweep. The
  # payload is the COMPLETE new sidecar, base64-framed; see
  # rip::_sidecars_write for the atomic same-directory temp-file-then-mv
  # guards that make a half-written sidecar impossible.
  local -a payloads=() sent_rels=() ok_flags=()
  local -A idx_of=()
  local payload
  for (( i = 1; i <= ${#to_rel[@]}; i++ )); do
    payload="$(rip::_sidecar_payload "${to_rel[i]}" "${to_json[i]}")"
    if [[ -z "$payload" || "$payload" != *$'\t'* ]]; then
      log_warn "rip: could not frame the companions of ${to_rel[i]}"
      continue
    fi
    payloads+=("$payload"); sent_rels+=("${to_rel[i]}"); ok_flags+=(0)
    idx_of[${payload%%$'\t'*}]=${#payloads}
  done

  local written=""
  (( ${#payloads[@]} > 0 )) && written="$(rip::_sidecars_write "$base" "${payloads[@]}")"

  # GATED ON THE REPORTED OUTCOME, never on the write having been attempted:
  # a book counts only when the remote loop said "ok" for it, so a connection
  # that dies halfway leaves the rest counted as failures and named.
  local -i recorded=0
  local rline st key
  while IFS= read -r rline; do
    [[ -n "$rline" ]] || continue
    st="${rline%%$'\t'*}"; key="${rline#*$'\t'}"
    [[ "$st" == "ok" ]] || continue
    i=${idx_of[$key]:-0}
    (( i > 0 )) && ok_flags[i]=1
  done <<< "$written"
  for (( i = 1; i <= ${#sent_rels[@]}; i++ )); do
    if (( ok_flags[i] )); then
      (( recorded++ ))
    else
      log_warn "rip: could not record the companions of ${sent_rels[i]}"
    fi
  done
  print -r -- "rip: recorded companions for $recorded of ${#to_rel[@]} sidecar(s)"
  local -i unwritten=$(( ${#to_rel[@]} - recorded ))
  (( unwritten > 0 )) && print -r -- "rip: $unwritten sidecar(s) could not be written"
  (( outstanding > 0 )) && print -r -- "rip: $outstanding book(s) could not be read"
  # THE TALLY NEVER CLAIMS A COMPLETENESS NOTHING ESTABLISHED: an enumeration
  # that could not read the whole tree fails the sweep even when every book it
  # DID see was recorded.
  (( unwritten > 0 || outstanding > 0 || enum_bad )) && return 1
  return 0
}

# rip::ab_adopt_asin <Author/Title> <ASIN> [--apply] — confirm a Case B
# proposal. Typing the ASIN IS the confirmation; it cannot happen by accident.
#
# Five guards, all required:
#   1. the provider's library must contain the ASIN — never write an
#      identifier that resolves to nothing;
#   2. the sidecar must not already carry an `audible.asin` — this repairs
#      empty identity, it never overwrites identity;
#   3. the sidecar is populated from that row IN FULL (published, narrators,
#      duration_s, series, language, abridged), because recovering one field
#      and leaving the rest null leaves the book half-identified;
#   4. `source.provider` is corrected away from "unknown" to the provider that
#      supplied the row — "unknown" is a false statement about a book the
#      provider demonstrably owns;
#   5. no OTHER stored sidecar may already carry this ASIN — guard 2 sees only
#      the target, and adopting the same proposal for two folders one command
#      at a time is exactly the duplicated edition identity a sidecar exists
#      to prevent.
# `work` stays null (or whatever a resolver already put there), as at any
# fresh ingest.
rip::ab_adopt_asin() {
  setopt localoptions noerrexit nopipefail
  local rel="${1:-}" asin="${2:-}" apply=0
  [[ "${3:-}" == "--apply" ]] && apply=1
  [[ -n "$rel" ]]  || { log_error "rip: adopt needs \"<Author>/<Title>\""; return 2 }
  [[ -n "$asin" ]] || { log_error "rip: adopt needs an ASIN — typing it IS the confirmation"; return 2 }

  local base; base="$(rip::remote_base)"
  local pname="${RIP_AB_PROVIDER:-libation}"
  local pbin; pbin="$(rip::ab_provider_bin "$pname")" || return 2
  local prows; prows="$("$pbin" list 2>/dev/null)"

  # GUARD 1.
  local row=""
  [[ -n "$prows" ]] && row="$(print -r -- "$prows" | jq -c --arg a "$asin" \
    'select(((.id // "") == $a) or ((.ids["audible.asin"] // "") == $a))' 2>/dev/null | head -1)"
  if [[ -z "$row" ]]; then
    log_error "rip: the $pname library has no $asin — refusing to write an identifier that resolves to nothing"
    return 2
  fi

  local rows; rows="$(rip::_server_sidecars)" || return 2
  local nrel; nrel="$(rip::_nfc "$rel")"
  # srel is the SERVER's own spelling of the path — what gets written to.
  # dup_rel is GUARD 5's evidence: the index is already in hand, so the same
  # single pass that finds this book also notices any OTHER book already
  # carrying this ASIN. No early break any more — the scan has to see every
  # row for that to be true.
  local srel="" have_asin="" oldjson="" dup_rel=""
  local irel istate iprov iasin iuid ijson
  while IFS=$'\t' read -r irel istate iprov iasin iuid ijson; do
    [[ -n "$irel" ]] || continue
    if [[ -z "$srel" ]] && { [[ "$irel" == "$nrel" ]] || [[ "$(rip::_nfc "$irel")" == "$nrel" ]] }; then
      srel="$irel"; have_asin="$iasin"; oldjson="$ijson"
      continue
    fi
    [[ -z "$dup_rel" && "$iasin" == "$asin" ]] && dup_rel="$irel"
  done < <(print -r -- "$rows" | rip::_sidecar_index)

  if [[ -z "$srel" ]]; then
    log_error "rip: no stored sidecar for $rel — --repair-sidecars creates a missing one"
    return 2
  fi
  # GUARD 2.
  if [[ "$have_asin" != "-" ]]; then
    log_error "rip: $rel already carries audible.asin $have_asin — this verb repairs empty identity, it never overwrites it"
    return 2
  fi
  # GUARD 5 (review finding 3, 2026-08-24). Guard 2 only ever looked at the
  # TARGET's sidecar, so the same ASIN could be adopted for two different
  # folders one command at a time — and the author-variant collision this
  # module already knows about ("J. R. R. Tolkien" vs "J.R.R. Tolkien") makes
  # --repair-sidecars propose exactly that pair. An ASIN names one edition of
  # one work; two folders carrying it is the duplicated identity the sidecar
  # exists to prevent, and it would then propagate into edition grouping and
  # every future `work` join. If the two folders really are one book, the
  # remedy is --canonicalize-authors, not a second stamp.
  if [[ -n "$dup_rel" ]]; then
    log_error "rip: $dup_rel already carries audible.asin $asin — one ASIN identifies one book; refusing to stamp it on $rel as well"
    return 2
  fi
  [[ -n "$oldjson" ]] || oldjson='{}'

  # GUARDS 3 and 4. The row is composed through the module's ONE composer, so
  # an adopted sidecar comes out shaped like a freshly-pushed one, and then:
  #   * every meaningful value already on the sidecar WINS over the composed
  #     one — the server's author spelling is the truth about where the book
  #     lives, and Libation's ("Shawn Speakman - editor") is not. "Meaningful"
  #     excludes null, "", [] and {}: an empty narrators list is the absence
  #     the row is here to fill, not a recorded fact;
  #   * ids MERGE, with any pre-existing namespaced id kept (a Case C book
  #     later found in the store keeps its fleet.uid) and the ASIN written
  #     explicitly;
  #   * `work` is never overwritten;
  #   * source.provider is taken from the ROW — the one field the old sidecar
  #     must not win, because "unknown" is exactly what is being corrected.
  # companions is [] here for the same reason rip::_sidecar_compose passes
  # it: this composer works from the stored sidecar and a provider row, with
  # no local directory to rescan. $keep below does not special-case
  # companions the way it does ids/work/source, so any real array already on
  # the stored sidecar ($o) survives untouched via `$new * $keep` — only a
  # book with no companions recorded yet is left at [].
  local merged
  merged="$(jq -n --argjson row "$row" --argjson old "$oldjson" --arg pn "$pname" --arg a "$asin" --argjson companions '[]' '
    ($row | if ((.provider // "") == "" or .provider == "unknown") then .provider = $pn else . end) as $r
    | ('"$_RIP_SIDECAR_JQ"') as $new
    | ($old // {}) as $o
    | ($o | del(._path) | del(.ids) | del(.work) | del(.source)
          | with_entries(select(.value != null and .value != [] and .value != "" and .value != {}))) as $keep
    | ($new * $keep)
    | .ids = (($new.ids // {}) + (($o.ids // {}) | with_entries(select((.value // "") != ""))))
    | .ids["audible.asin"] = $a
    | .work = ($o.work // null)
    | .source = (($new.source // {})
                 * (($o.source // {}) | del(.provider)
                    | with_entries(select(.value != null and .value != ""))))' 2>/dev/null)"
  if [[ -z "$merged" ]]; then
    log_error "rip: could not compose the adopted sidecar for $rel"
    return 1
  fi

  if (( ! apply )); then
    print -r -- "would adopt: $rel"
    print -r -- "  ASIN         : $asin"
    print -r -- "  from row     : $(print -r -- "$row" | jq -r '.path // "?"' 2>/dev/null)"
    print -r -- "  published    : $(print -r -- "$merged" | jq -r '.published // "null"' 2>/dev/null)"
    print -r -- "  narrators    : $(print -r -- "$merged" | jq -r '(.narrators // []) | join(", ")' 2>/dev/null)"
    print -r -- "  provider     : $(print -r -- "$merged" | jq -r '.source.provider // "?"' 2>/dev/null)"
    print -r -- "(re-run with --apply)"
    return 0
  fi

  local payload; payload="$(rip::_sidecar_payload "$srel" "$merged")"
  if [[ -z "$payload" || "$payload" != *$'\t'* ]]; then
    log_error "rip: could not frame the adopted sidecar for $rel"
    return 1
  fi
  local out; out="$(rip::_sidecars_write "$base" "$payload")"
  # GATED ON THE REPORTED OUTCOME: "ok" for THIS book's key, or nothing
  # happened. The transport reports per book precisely so a success line is
  # never printed on the strength of control flow reaching it.
  local st="${out%%$'\t'*}" key="${out#*$'\t'}"
  if [[ "$st" != "ok" || "$key" != "${payload%%$'\t'*}" ]]; then
    log_error "rip: could not write the sidecar for $rel — it is unchanged"
    return 1
  fi
  print -r -- "rip: adopted $asin for $rel"
  return 0
}

# --- author identity --------------------------------------------------------
#
# Audible spells an author differently across purchases ("J. R. R. Tolkien" on
# two books, "J.R.R. Tolkien" on a third), Libation composes the folder from
# that per-purchase metadata, and the result is two author folders for one
# person — two author pages in Audiobookshelf, and a library that says
# something untrue. Measured 2026-08-23: exactly one such collision across 116
# distinct first-authors, and punctuation-and-case normalization catches it.
#
# The key is for COMPARISON ONLY. Never name a directory with it.
rip::_author_norm() {
  local n="${(L)1}"
  print -r -- "${n//[^a-z0-9]/}"
}

# rip::_author_display <name> — the canonical DISPLAY form: initials get a
# space after their period. This is a DIFFERENT job from _author_norm above:
# norm throws punctuation and case away to answer "is this the same person
# as that other spelling", and must never be shown or written anywhere: this
# one's output is meant to be READ, so the punctuation and case it preserves
# is exactly what makes it presentable.
#
# APPLIED TO THE PATH, AND — SEPARATELY — IN PLACE TO artist/composer.
#
# NOT to `album_artist` (coordinator ruling, 2026-08-26). The panel normalises
# the author field on blur and --canonicalize-authors repairs stored author
# directories; rip::_retag_book then writes whatever the path says, verbatim.
# Canonicalizing on the way into THAT tag instead would leave it disagreeing
# with the path, and the `--retag` sweep — which compares the two — would
# report a mismatch on every run and rewrite every book forever. See
# rip::_retag_book's header for the full argument.
#
# `artist` and `composer` are a different case entirely (second amendment,
# same day), and the difference is that NO PATH SPELLS THEM. They are
# normalised IN PLACE — never replaced — so there is nothing for the result to
# disagree with, and because this rule is idempotent the sweep still reaches a
# fixed point on the first pass. Applying it there is what makes the invariant
# visible in Audiobookshelf, which reads `artist` in preference to
# `album_artist` in some configurations.
#
# The rule: a SINGLE letter, a period, then immediately another letter (no
# space between them) gets a space inserted after the period. Two letters
# before the period is not an initial ("Dr.Smith" stays as-is — "Dr" is an
# abbreviation, not two initials), and a period already followed by a space
# is already correct ("St. Martin" is untouched). Scanned character by
# character rather than with a single regex substitution: a naive global
# "letter.letter" replace consumes the letter after the period as part of
# its match, which is fine for one initial but wrong for a run of them
# ("J.R.R. Tolkien") — the middle letter needs to be read BOTH as the
# letter following one period and as the single letter preceding the next,
# and a regex that consumes matched characters can't reuse it that way.
# A left-to-right scan that only ever consumes the period never has that
# problem. Idempotent by construction: once a period is followed by a
# space, the "immediately another letter" condition no longer holds.
rip::_author_display() {
  local s="$1"
  local -a chars
  chars=("${(@s::)s}")
  local n=${#chars}
  local out="" c prev prev2 nxt
  local i
  for (( i = 1; i <= n; i++ )); do
    c="${chars[i]}"
    out+="$c"
    if [[ "$c" == "." ]]; then
      prev="${chars[i-1]:-}"
      prev2="${chars[i-2]:-}"
      nxt="${chars[i+1]:-}"
      if [[ "$prev" == [A-Za-z] && "$prev2" != [A-Za-z] && "$nxt" == [A-Za-z] ]]; then
        out+=" "
      fi
    fi
  done
  print -r -- "$out"
}

# rip::_server_authors — the distinct author spellings the server holds.
# Derived from the ONE ssh rip::ab_server_library already makes, and cached for
# the life of the process: a push canonicalizes every staged author and must
# not open a connection per author.
typeset -g _RIP_SERVER_AUTHORS_FETCHED
typeset -g _RIP_SERVER_AUTHORS
rip::_server_authors() {
  setopt localoptions noerrexit nopipefail
  if [[ -z "${_RIP_SERVER_AUTHORS_FETCHED:-}" ]]; then
    _RIP_SERVER_AUTHORS_FETCHED=1
    _RIP_SERVER_AUTHORS="$(rip::ab_server_library 2>/dev/null | sed 's|/.*||' | sort -u)"
  fi
  print -r -- "$_RIP_SERVER_AUTHORS"
}

# rip::_canonical_author <name> — the spelling the server already uses for this
# author, when it holds one that normalizes equal but is written differently.
# Otherwise the input, unchanged.
#
# The server wins on purpose: it is the library's truth, and adopting its
# spelling makes repeated ingests converge instead of oscillating between two
# forms. Never fails — an unreachable server simply yields the input, and the
# book lands under its original spelling exactly as it does today.
rip::_canonical_author() {
  setopt localoptions noerrexit nopipefail
  local name="$1"
  [[ -n "$name" ]] || return 0
  local want; want="$(rip::_author_norm "$name")"
  # Call as a plain command, not inside `< <(...)` or `$(...)` — either forks
  # a subshell, and the cache assignments rip::_server_authors makes would
  # die with that subshell instead of surviving in THIS shell. Discard its
  # printed copy of the list here; read the now-populated global instead.
  rip::_server_authors >/dev/null
  local existing
  for existing in ${(f)_RIP_SERVER_AUTHORS}; do
    [[ -n "$existing" ]] || continue
    if [[ "$existing" != "$name" && "$(rip::_author_norm "$existing")" == "$want" ]]; then
      # THE CANONICAL DISPLAY FORM BEATS THE SERVER'S RAW SPELLING (review
      # finding F2, 2026-08-26). "The server wins" converges two arbitrary
      # spellings, which is what this function is for — but rip::_author_norm
      # strips punctuation, so "J.K. Rowling" and "J. K. Rowling" are the same
      # key and the server's raw form was adopted over the panel's canonical
      # one. With 248 books stored under the raw spelling, the panel showed
      # "J. K. Rowling" and the library got "J.K. Rowling": spec §1's stated
      # reason for having a panel rule at all, silently inert until
      # --canonicalize-authors swept afterwards. Keeping the caller's spelling
      # when it is exactly rip::_author_display of the server's still
      # converges — the sweep moves the server to that same form — and it
      # converges on the RIGHT one, first time, without a remux.
      if [[ "$(rip::_author_display "$existing")" == "$name" ]]; then
        print -r -- "$name"
        return 0
      fi
      print -r -- "$existing"
      return 0
    fi
  done
  print -r -- "$name"
}

# rip::_canonicalize_staged_authors <src> — rename each staged author dir to
# the spelling the server already uses.
#
# ORDERING IS LOAD-BEARING: this runs BEFORE rip::push_worker builds its
# listfile from `find "$src"`, because that listfile's relative paths are fed
# straight to `rsync --files-from`. Renaming after the list is built would
# leave every path in it naming a directory that no longer exists.
#
# Merges rather than clobbers: when the canonical directory already exists,
# each book moves into it individually and a book already present there is
# left alone (the push is idempotent; overwriting a staged book to "fix" a
# spelling would be a silent data change).
rip::_canonicalize_staged_authors() {
  setopt localoptions noerrexit nopipefail
  local src="$1"
  [[ -d "$src" ]] || return 0
  local -a authors=("$src"/*(N/))
  (( ${#authors} == 0 )) && return 0
  # Prime the server-author cache ONCE, right here, in THIS shell — before
  # the loop below ever runs. Every iteration calls rip::_canonical_author
  # through a `$(...)` capture, and `$(...)` forks a subshell in zsh: a
  # fork taken before this cache is populated starts with
  # _RIP_SERVER_AUTHORS_FETCHED unset in its own copy, re-fetches via
  # rip::_server_authors -> rip::ab_server_library, and that fetch dies
  # with the subshell — the parent's copy is never mutated. Left
  # unprimed, a 3-author push made 3 ssh round-trips instead of 1
  # (live-caught in review). Calling rip::_server_authors as a plain
  # command HERE, ahead of any fork, means every subsequent `$(...)` in
  # the loop inherits an already-populated cache and does no ssh at all.
  rip::_server_authors >/dev/null
  local dir name canon book title
  local -a staged_titles=() moved=()
  for dir in "${authors[@]}"; do
    name="${dir:t}"
    canon="$(rip::_canonical_author "$name")"
    [[ "$canon" == "$name" ]] && continue
    # Snapshot the book names BEFORE the move so the re-key below can tell,
    # per book, which ones actually ended up under $canon. Both branches
    # below can leave a book behind (a merge target that already held it, a
    # failed mv), and re-keying a book that did NOT move would point its
    # identity row at a path nothing will ever look up.
    staged_titles=("$dir"/*(N:t))
    if [[ -d "$src/$canon" ]]; then
      for book in "$dir"/*(N); do
        if [[ -e "$src/$canon/${book:t}" ]]; then
          log_warn "rip: canonical author target already holds ${book:t} — leaving it staged under $name"
        else
          mv -- "$book" "$src/$canon/" 2>/dev/null \
            || log_warn "rip: could not move ${book:t} into $canon"
        fi
      done
      rmdir -- "$dir" 2>/dev/null
    else
      mv -- "$dir" "$src/$canon" 2>/dev/null \
        || log_warn "rip: could not rename $name to $canon"
    fi
    # Only claim the rename happened when the staged entry under the old
    # spelling is actually GONE afterwards — that is the literal fact this
    # line asserts, and checking it directly (rather than tracking "did an
    # mv run") covers every way the merge branch can end up not fully
    # renamed: a book left behind because the target already held it, a
    # failed mv, or a leftover dotfile (e.g. .DS_Store — the (N) glob is
    # dot-blind) that makes rmdir fail even after every real book moved.
    # In the single-rename branch `mv` itself is what makes $dir vanish on
    # success and leaves it in place on failure, so the same check is
    # exactly right there too — nothing about that branch changed.
    [[ -e "$dir" ]] || log_error "rip: canonical author — staged \"$name\" renamed to \"$canon\" (the spelling cantina already uses)"

    # FOLLOW THE RENAME THROUGH THE IDENTITY PLUMBING (review finding 1,
    # 2026-08-24 — the merge blocker). The listfile is rebuilt from the NEW
    # path, so rip::_enrich_audiobooks asks rip::_book_meta_for for
    # "<canon>/<title>" — while the meta index rip::ab_worker wrote is keyed
    # on the plan's path, which carries the PROVIDER's spelling of the
    # author. Both the index lookup and the provider-rows fallback missed,
    # and the book got the path-derived MINIMAL identity written over a rich
    # row that was sitting in the index the whole time: `ids: {}`,
    # `published: null`, `narrators: []`, provider "unknown".
    #
    # That loss is PERMANENT. Staging is emptied after the verified push, so
    # nothing can re-merge later, and --backfill-published cannot repair it
    # either — with no ASIN in the sidecar it has nothing to match a
    # provider row on. The book is then invisible to --editions forever and
    # records false provenance. rip::ab_worker already solves the identical
    # hazard for its own "landed as" reconcile; this is the same treatment
    # on the other rename path.
    moved=()
    for title in "${staged_titles[@]}"; do
      [[ ! -e "$dir/$title" && -e "$src/$canon/$title" ]] && moved+=("$title")
    done
    (( ${#moved} )) && rip::_rekey_book_meta "$name" "$canon" "${moved[@]}"
  done
  return 0
}

# --- destructive operators ---------------------------------------------------
#
# rip::ab_retire <Author/Title> [--apply] — remove ONE stored book.
#
# Dry-run by default: this deletes the only copy. Staging is emptied after
# every verified push, so there is no local original to fall back on, and the
# store can only re-supply it by re-downloading.
#
# Files THEN the ABS item, and the item is resolved BEFORE anything is
# deleted: Audiobookshelf keeps an item whose files vanish and marks it
# missing (a rescan does not drop it), so a half-retired book — files gone,
# item present — is worse than one left alone.
rip::ab_retire() {
  setopt localoptions noerrexit nopipefail
  local rel="$1" apply=0
  [[ "${2:-}" == "--apply" ]] && apply=1
  [[ -n "$rel" ]] || { log_error "rip: retire needs \"<Author>/<Title>\""; return 2 }

  local base; base="$(rip::remote_base)"
  # Membership in the server's OWN listing, not a guessed filename.
  # rip::_remote_has_file tests one file, and "<Title>/<Title>.m4b" is only
  # Libation's convention — a manual import carries whatever filename it was
  # given, and would read as "not stored" and be un-retirable.
  # rip::ab_server_library is the canonical answer to "what does the server
  # hold", is filename-agnostic, costs one ssh, and returns 2 with no output
  # when the server is unreachable — which refuses rather than guessing.
  #
  # `< <(...)` forks a subshell for the PRODUCER only; the loop body still
  # runs in this shell, so `stored` survives.
  local stored=0 known
  while IFS= read -r known; do
    [[ "$known" == "$rel" ]] && { stored=1; break }
  done < <(rip::ab_server_library)
  if (( ! stored )); then
    log_error "rip: not stored on cantina: $rel"
    return 2
  fi

  local item
  item="$("$RIP_BIN_DIR/rip-abs-authors" --find-item "$rel" 2>/dev/null)"
  if [[ -z "$item" ]]; then
    log_error "rip: could not resolve the Audiobookshelf item for $rel — refusing to delete files that would leave a missing entry behind"
    return 2
  fi

  if (( ! apply )); then
    print -r -- "would remove: $rel"
    print -r -- "  files:       $base/audiobooks/$rel"
    print -r -- "  ABS item:    $item"
    print -r -- "(re-run with --apply)"
    return 0
  fi

  # NEVER widen this beyond the single resolved book directory.
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "rm -rf -- ${(q)rpath}/audiobooks/${(q)rel}" 2>/dev/null \
      || { log_error "rip: could not remove the files for $rel"; return 1 }
  else
    rm -rf -- "$base/audiobooks/$rel" || { log_error "rip: could not remove $rel"; return 1 }
  fi
  # CLAIM ONLY WHAT ACTUALLY HAPPENED (review finding 3A, 2026-08-24). The
  # delete used to be warned about and then followed, unconditionally, by
  # "rip: retired $rel" and rc 0 — files gone, ABS item alive, stdout saying
  # the book was retired. That is precisely the half-retired state this
  # function's header resolves the item early to avoid (Audiobookshelf keeps
  # an item whose files vanished and marks it missing; a rescan does not drop
  # it), announced as a success. This is the most destructive verb in the
  # module. rip::_canonicalize_one_author handles the identical situation
  # correctly and this now follows it: say what is true, and fail.
  if ! "$RIP_BIN_DIR/rip-abs-authors" --delete-item "$item" >/dev/null 2>&1; then
    log_error "rip: removed the files for $rel but its Audiobookshelf item ($item) could NOT be deleted — the item remains and will show as missing; remove it in the Audiobookshelf UI"
    return 1
  fi
  print -r -- "rip: retired $rel"
  return 0
}

# rip::ab_canonicalize_authors [--apply] — bring every stored author to ONE
# spelling, and to the CANONICAL one.
#
# Two rules, applied in that order:
#
#   1. collapse spelling variants of one author onto a single winner —
#      most books; tie → the longer string, which favours the more fully
#      punctuated form ("J. R. R." over "J.R.R.") and is deterministic;
#   2. rewrite that winner through rip::_author_display, the canonical
#      initials form ("J.K. Rowling" → "J. K. Rowling").
#
# RULE 2 IS NOT CONDITIONAL ON RULE 1 FINDING ANYTHING (2026-08-26). This
# verb used to skip every group holding a single spelling —
# `[[ "$variants" == *$nl* ]] || continue` — which made it a no-op on the
# library it was most needed for: the operator's server holds exactly ONE
# spelling of "J.K. Rowling", across seven books, so the sweep printed
# "nothing to do" and exited 0. Measured, not assumed. `--retag` mirrors
# whatever the PATH says into the audio, so leaving the path uncanonical
# bakes the wrong author into all seven files, and repairing it afterwards
# costs a SECOND full-library remux of ~248 multi-gigabyte files. The
# canonical form has to reach the path first; that is why --retag --apply
# was gated on this.
#
# Rule 2 is applied to the WINNER, never to each variant independently: the
# winner is what the group collapses onto, and its display form is what it
# should have been spelled as all along. Safe because
# norm(display(x)) == norm(x) for every x — the rule only ever inserts a
# space after an initial's period, and rip::_author_norm strips spaces — so
# the canonical form can never land in a different group from the variants
# converging on it, and the destination is always inside the group being
# swept. rip::_author_display is idempotent by construction (once a period
# is followed by a space the rule no longer fires), which is what makes a
# second --apply find nothing.
#
# THE MERGE THIS CREATES IS THE DANGEROUS PART. Canonicalizing can send a
# variant into a directory that ALREADY EXISTS — "J.K. Rowling" and
# "J. K. Rowling" both stored, both converging on the latter. That is the
# same merge the collision rule already performed and it stays deliberately
# conservative: rip::_canonicalize_one_author moves book by book with
# `mv -n`, so a title already present under the canonical spelling is LEFT
# WHERE IT IS rather than overwritten, `rmdir` then refuses, and the sweep
# says so and returns 1. The only copy of an audiobook is never clobbered to
# tidy a folder name.
#
# THE SIDECAR MOVES WITH THE DIRECTORY. A rename that repaired the path and
# left .fleet-book.json saying the old spelling would leave the library
# internally inconsistent — and .fleet-book.json is the only copy of who a
# book is. The rule is narrow on purpose: authors[0] is re-spelled ONLY when
# it rip::_author_norm-matches the author its directory names but is written
# differently. A sidecar naming a genuinely different person (a pen name) is
# not a spelling variant and is never touched.
#
# THE WRITE IS ADDRESSED BY THE SERVER'S OWN PATH, NEVER BY A COMPOSED ONE.
# Under --apply the sidecar pass reads the server AFTER the moves, so every
# `_path` it holds is a path that exists, and each payload is addressed to the
# very row it was read from. That is what keeps a book whose `mv -n` was
# refused from having its corrected sidecar written straight over the identity
# file of the DIFFERENT book occupying the destination — the destination is
# never named at all.
#
# WHICH SPELLING is a separate question from WHERE IT IS WRITTEN, and it is
# answered identically in both modes: the group's target. Deriving it from the
# post-move directory instead made --apply disagree with the dry run — for a
# refused book the directory still says the raw spelling, so a sidecar that
# was already canonical got rewritten BACKWARDS, and the dry run had named
# neither the file nor the change (review finding 2, 2026-08-26).
#
# WHETHER TO WRITE AT ALL is the third question, and the answer is: only where
# the book actually sits under the target. A book whose `mv -n` was refused is
# still in the raw directory, so a corrected sidecar there would name an
# author its own directory does not have, permanently and undetectably (review
# finding F3, 2026-08-26). --apply reports those as "left alone: <rel> did not
# move" and never counts them.
#
# Renaming the folder is NOT enough for Audiobookshelf: it matches the moved
# item by inode and updates its path, but keeps the item's STORED author, so
# the split survives in its database until the item is repointed (verified
# live 2026-08-23). Hence move, then repoint, then delete the emptied author.
rip::ab_canonicalize_authors() {
  setopt localoptions noerrexit nopipefail
  local apply=0
  [[ "${1:-}" == "--apply" ]] && apply=1

  # Capture the listing as a VALUE and propagate its failure. Read through
  # `< <(...)` the rc is discarded, and an unreachable server then looks
  # byte-identical to a clean library — "nothing to do" on stdout with rc 0,
  # which a wrapper or a cron job reads as a green light while the sweep never
  # reached the server at all. Same class as rip::ab_backfill_published's
  # seen==0 branch, and rip::ab_retire already refuses this way. (Review
  # finding 3, 2026-08-24.)
  local lib
  lib="$(rip::ab_server_library)" || return 2

  local -A spelling_count=()
  local rel author
  for rel in "${(@f)lib}"; do
    [[ -n "$rel" ]] || continue
    author="${rel%%/*}"
    spelling_count[$author]=$(( ${spelling_count[$author]:-0} + 1 ))
  done

  # $nl, not a literal $'\n' inside the ${...:+...} replacement below: the
  # replacement word of a :+ expansion is NOT re-scanned for ANSI-C quoting,
  # so writing $'\n' there joins the variants with the four LITERAL
  # characters $'\n' and a *$'\n'* test on the result never matches — every
  # collision silently reported "nothing to do". Caught by the sweep
  # examples 2026-08-24.
  local nl=$'\n'
  local -A groups=()
  local key
  for author in "${(@k)spelling_count}"; do
    key="$(rip::_author_norm "$author")"
    groups[$key]="${groups[$key]:-}${groups[$key]:+$nl}$author"
  done

  # PASS 1 — decide the target spelling for EVERY stored author before
  # anything moves. The dry run has to predict where each book will end up in
  # order to report its sidecar honestly, and that prediction is this map.
  local -a group_keys=("${(@k)groups}")
  local -A target_for=()
  local variants canon target a
  local -a vlist moves
  for key in "${group_keys[@]}"; do
    variants="${groups[$key]}"
    # MATERIALISE the variants before iterating them. A
    # `while IFS= read -r a; …; done <<< "$variants"` loop shares fd 0 with
    # every command it runs, and ssh READS STDIN unless told otherwise — so
    # the first ssh reached from inside that loop swallows the rest of the
    # here-string. rip::_canonicalize_one_author reaches three of them (two
    # directly, one inside rip::ab_server_library), so a group with four
    # spellings printed three variants and then swept exactly ONE: rc 0, no
    # warning, and a dry run that looked right because it short-circuits
    # before any ssh. Same fd-0 family as this project's
    # `LibationCli … </dev/null` gotcha — the next person will reintroduce it.
    # An array holds no fd. Adding -n to the two direct ssh calls would NOT
    # be enough: the one inside rip::ab_server_library would still drain it.
    # (Review finding 1, 2026-08-24.)
    vlist=("${(@f)variants}")
    canon=""
    for a in "${vlist[@]}"; do
      if [[ -z "$canon" ]] \
        || (( ${spelling_count[$a]:-0} > ${spelling_count[$canon]:-0} )) \
        || { (( ${spelling_count[$a]:-0} == ${spelling_count[$canon]:-0} )) && (( ${#a} > ${#canon} )) }; then
        canon="$a"
      fi
    done
    target="$(rip::_author_display "$canon")"
    for a in "${vlist[@]}"; do
      target_for[$a]="$target"
    done
  done

  # PASS 2 — report, and under --apply perform, the directory moves.
  local base; base="$(rip::remote_base)"
  local found=0 swept_fail=0
  local -i unpointed=0
  for key in "${group_keys[@]}"; do
    variants="${groups[$key]}"
    vlist=("${(@f)variants}")
    target="${target_for[${vlist[1]}]}"
    moves=()
    for a in "${vlist[@]}"; do
      [[ "$a" == "$target" ]] || moves+=("$a")
    done
    (( ${#moves} )) || continue
    found=1
    # Two different facts, said differently: a group holding several
    # spellings is a collision being collapsed, a group holding one is a
    # single author being re-spelled. Calling the second "author variants"
    # would be a report of something that is not there.
    if (( ${#vlist} > 1 )); then
      print -r -- "author variants → \"$target\""
    else
      print -r -- "author canonical form → \"$target\""
    fi
    for a in "${moves[@]}"; do
      print -r -- "    \"$a\" (${spelling_count[$a]:-0} book(s))"
    done
    (( apply )) || continue
    for a in "${moves[@]}"; do
      # rc 3 is NOT a failure: the books moved and the path is correct, but
      # Audiobookshelf holds no author record by the canonical name to
      # repoint them to. Counted separately and reported separately (see the
      # summary below) — folding it into swept_fail is what made a correct
      # rename exit 1 and taught the operator to ignore the exit status.
      rip::_canonicalize_one_author "$base" "$a" "$target"
      case $? in
        0) ;;
        3) (( unpointed++ )) ;;
        *) swept_fail=1 ;;
      esac
    done
  done

  # PASS 3 — the sidecars. Captured as a VALUE with its status checked, for
  # exactly the reason the library listing above is: read through
  # `< <(...)` an ssh that never landed yields an empty enumeration and rc 0,
  # and this verb would then report a clean, fully canonical library it never
  # saw. A sweep in this same file once printed "nothing to backfill" and
  # exited 0 on a dropped VPN.
  #
  # ONE fetch, placed AFTER the moves: under --apply that makes every row's
  # `_path` the post-move truth (see the header), and under a dry run
  # nothing has moved so it is simply the current truth.
  local rows
  rows="$(rip::_server_sidecars)" || return 2

  # ONE jq for the whole library, not one per book: 248 books is ~5s of pure
  # fork on this laptop. Raw string concatenation rather than @tsv — @tsv
  # escapes a backslash as two, which would corrupt any path or name that
  # contains one. A literal TAB inside a path would break the split, the same
  # assumption rip::_sidecar_index already makes.
  local idx=""
  if [[ -n "$rows" ]]; then
    idx="$(print -r -- "$rows" | jq -r '
      (._path // "") as $p
      | ((.authors) as $a
         | if ($a | type) == "array" and (($a[0] | type) == "string")
           then $a[0] else "" end) as $n
      | $p + "\t" + $n' 2>/dev/null)"
  fi

  local -a idx_lines=()
  [[ -n "$idx" ]] && idx_lines=("${(@f)idx}")
  local -a sc_payloads=()
  local sline srel sauth sdir seff snew payload
  local -i sc_seen=0
  for sline in "${idx_lines[@]}"; do
    [[ "$sline" == *$'\t'* ]] || continue
    srel="${sline%%$'\t'*}"; sauth="${sline#*$'\t'}"
    [[ -n "$srel" && -n "$sauth" ]] || continue
    sdir="${srel%%/*}"
    # ONE RULE FOR BOTH MODES (review finding 2, 2026-08-26). `--apply` used
    # to take the directory as `find` printed it, which is the CANONICAL
    # spelling for every book that moved but the RAW one for a book whose
    # `mv -n` was refused. A staged book can arrive with a canonical sidecar
    # under a raw-spelled directory — the panel canonicalises the author field
    # on blur while rip::_canonicalize_staged_authors renames the staged
    # DIRECTORY to whatever spelling the server already holds, and never
    # touches the sidecar — so that combination is reachable in the ordinary
    # workflow, and `--apply` would then rewrite a correct sidecar BACKWARDS,
    # to a spelling the dry run had named neither the file nor the change for.
    # The target spelling is the same fact in both modes; only the writing
    # differs.
    seff="${target_for[$sdir]:-$sdir}"
    [[ "$sauth" != "$seff" ]] || continue
    # The narrow guard: same person, different spelling. rip::_author_norm is
    # the module's comparison key and the same one the collision rule uses;
    # anything looser and this sweep would quietly rewrite a pen name.
    # Reached only by rows that already failed the cheap equality above, so
    # it forks for the handful that differ, not for all 248.
    [[ "$(rip::_author_norm "$sauth")" == "$(rip::_author_norm "$seff")" ]] || continue
    found=1
    (( sc_seen )) || print -r -- "sidecar author spellings to correct:"
    sc_seen=1
    # ONLY WHERE THE BOOK ACTUALLY SITS UNDER THE TARGET (review finding F3,
    # 2026-08-26). Under --apply these rows are post-move truth, so a book
    # whose `mv -n` was refused still has the RAW variant as its directory
    # while $seff is the canonical target. Writing there would leave the
    # sidecar naming an author its own directory does not have — and
    # PERMANENTLY: a later --apply finds sauth == seff and skips it forever,
    # and --retag compares tags against the PATH only, so neither surfaces
    # it. "re-spelled N of N" would be claiming a completed correction over a
    # row it had just made internally inconsistent. Name it and move on.
    #
    # The dry run has no post-state to test, so it predicts a successful
    # sweep — exactly as the directory half of this report already does — and
    # writes nothing either way.
    if (( apply )) && [[ "$sdir" != "$seff" ]]; then
      print -r -- "    left alone: $srel did not move"
      continue
    fi
    print -r -- "    $srel: \"$sauth\" → \"$seff\""
    (( apply )) || continue
    # Composed HERE, with the local jq, and shipped as opaque base64:
    # cantina has no jq (live finding, 2026-08-24 — every one of 245 books
    # failed when the write path asked the server to run it). `del(._path)`:
    # `_path` is rip::_server_sidecars' annotation, not a schema field, and
    # writing it back would stamp a bogus key into every sidecar touched.
    snew="$(print -r -- "$rows" | jq -c --arg p "$srel" --arg a "$seff" \
      'select(._path == $p) | del(._path) | .authors[0] = $a' 2>/dev/null)"
    if [[ -z "$snew" ]]; then
      log_warn "rip: could not compose the corrected sidecar for $srel"
      swept_fail=1
      continue
    fi
    payload="$(rip::_sidecar_payload "$srel" "$snew")"
    if [[ -z "$payload" ]]; then
      log_warn "rip: could not frame the corrected sidecar for $srel"
      swept_fail=1
      continue
    fi
    sc_payloads+=("$payload")
  done

  local -i sc_wanted=${#sc_payloads} sc_done=0
  if (( apply && sc_wanted > 0 )); then
    # COUNT WHAT LANDED, never what was attempted. rip::_sidecars_write
    # prints one ok/fail line per book precisely so a connection that dies
    # mid-stream simply stops reporting and every unreported book counts as
    # a failure.
    local wout wline
    wout="$(rip::_sidecars_write "$base" "${sc_payloads[@]}")"
    local -a wlines=()
    [[ -n "$wout" ]] && wlines=("${(@f)wout}")
    for wline in "${wlines[@]}"; do
      [[ "$wline" == ok$'\t'* ]] && sc_done+=1
    done
    print -r -- "rip: re-spelled $sc_done of $sc_wanted sidecar author(s)"
    if (( sc_done < sc_wanted )); then
      log_warn "rip: $(( sc_wanted - sc_done )) sidecar author(s) could not be re-spelled — the directory and the sidecar now disagree; re-run --canonicalize-authors --apply"
      swept_fail=1
    fi
  fi

  # THE SUMMARY SEPARATES THEM TOO, not just the exit status: "renamed but
  # not repointed" is an outcome the operator has to act on in a different
  # place (the Audiobookshelf UI), and one that no later run of this verb can
  # reach — the variant directory is gone by then.
  (( unpointed )) && print -r -- "rip: $unpointed author(s) renamed on disk but NOT repointed in Audiobookshelf — the files and sidecars are correct; rename the author in the Audiobookshelf UI (see the warnings above)"
  (( found )) || print -r -- "rip: nothing to do — every author is already in its canonical spelling"
  (( apply )) || { (( found )) && print -r -- "(re-run with --apply)" }
  # A variant that could not be fully swept is reported through the exit
  # status as well as on stderr, for the same reason the unreachable-server
  # refusal above is: stderr alone is invisible to a wrapper or a cron job.
  (( swept_fail )) && return 1
  return 0
}

# rip::_canonicalize_one_author <base> <variant> <canonical> — move every book
# out of <variant> into <canonical>, repoint each ABS item, then delete the
# emptied author record.
#
# rc 0 swept clean · rc 1 something genuinely failed · rc 3 the books moved and
# the path is correct, but Audiobookshelf holds no author record by the
# canonical name to repoint them to. rc 3 is NOT a failure — see the
# three-outcome note inside.
#
# `mv -n` throughout: a title already present under the canonical spelling is
# left where it is rather than overwritten — the only copy of an audiobook is
# never clobbered to tidy a folder name. The variant directory is removed with
# `rmdir`, which refuses unless it is genuinely empty.
#
# DELETING THE VARIANT'S AUTHOR RECORD IS THE LAST STEP AND IS GATED. `mv -n`
# exits 0 when it REFUSES (verified 2026-08-24: BSD and GNU alike), so a
# same-title collision leaves the book sitting under the old spelling while
# every command in this function reports success. Deleting the author record
# then leaves the library asserting something false: the book is still there,
# its ABS item still stores the variant spelling, and the record that spelling
# pointed at is gone. `rmdir`'s exit status is the one honest signal that the
# variant is genuinely bookless — ask for it rather than inferring it from
# `rmdir`, and keep the record whenever any book failed to move, or any item
# Audiobookshelf knows still names the variant. (Review findings 2 and 4,
# 2026-08-24; "still names the variant" separated from "the repoint failed"
# by the coordinator ruling of 2026-08-26 — the first is an outcome, only the
# second is an error.)
rip::_canonicalize_one_author() {
  setopt localoptions noerrexit nopipefail
  local base="$1" variant="$2" canon="$3"
  local aid; aid="$("$RIP_BIN_DIR/rip-abs-authors" --author-id "$canon" 2>/dev/null)"
  local stale; stale="$("$RIP_BIN_DIR/rip-abs-authors" --author-id "$variant" 2>/dev/null)"
  # A canonical spelling no book has ever used has NO Audiobookshelf author
  # record, so nothing below can repoint to it. That is the ORDINARY case for
  # the canonical-initials rule (a lone "J.K. Rowling" becoming
  # "J. K. Rowling"): the FILES move correctly — which is what --retag reads
  # and what this whole phase is about — but every item keeps the old author
  # in Audiobookshelf's own database, and no later sweep can fix it because
  # the variant directory is gone by then. The per-book warning further down
  # says "could not resolve its ABS item OR the canonical author" and does
  # not distinguish the two. Say which one, once, with the remedy.
  [[ -n "$aid" ]] || log_warn "rip: Audiobookshelf has no author record named \"$canon\" yet — the books move, but their items keep \"$variant\" until you rename that author in the Audiobookshelf UI"

  local lib
  lib="$(rip::ab_server_library)" \
    || { log_warn "rip: could not list the library while sweeping \"$variant\" — nothing moved"; return 1 }

  local -a books=()
  local rel
  for rel in "${(@f)lib}"; do
    [[ "$rel" == "$variant/"* ]] && books+=("${rel#*/}")
  done

  local title item
  # THREE OUTCOMES, NOT TWO (coordinator ruling, 2026-08-26). These used to
  # share one counter, so a rename that moved every book correctly into a
  # spelling Audiobookshelf has simply never seen — the ORDINARY case for the
  # canonical-initials rule — exited 1. Reporting failure for "there was
  # nothing to do here" trains the operator to ignore the exit status, which
  # costs more than the signal is worth, and it is this subsystem's own
  # recurring defect inverted: asserting a verdict the code never established.
  #
  #   a repoint ATTEMPTED and refused    a real failure. Counted, rc 1.
  #   $aid empty                         ABS holds no author record by the
  #                                      canonical name. Nothing to repoint
  #                                      TO — not a failure, not counted;
  #                                      named once, up front, with the
  #                                      remedy.
  #   $item empty                        ABS has not scanned this book. Not
  #                                      something this sweep did wrong —
  #                                      warned per book, not counted.
  #
  # `still_pointing` is a THIRD fact and deliberately neither of the above:
  # "an item Audiobookshelf KNOWS still names the variant author". Deleting
  # the variant's record then strands that item on a record that no longer
  # exists (review finding 2, 2026-08-24) — true whether the repoint failed
  # or was never possible in the first place. It gates the DELETE. It does
  # not set the exit status.
  local -i unrepointed=0 still_pointing=0 mvstate=0
  for title in "${books[@]}"; do
    # ASK WHETHER IT MOVED; DO NOT INFER IT FROM AN EXIT STATUS. This
    # function's own header records that `mv -n` exits 0 when it REFUSES
    # (verified 2026-08-24, BSD and GNU alike), and every line below this one
    # then went on to describe a book that had not moved — "moved $title, but
    # Audiobookshelf does not know this book yet" was printed for a book still
    # sitting in the variant directory. That is this subsystem's recurring
    # defect in a new message: a verdict reached because control got here, not
    # because anything established it. The source's absence is the fact, and
    # it is tested in the SAME round-trip. (Review finding F4, 2026-08-26.)
    #
    # 0 moved · 12 refused (a title of that name is already under the
    # canonical spelling, so the source is still there) · anything else a real
    # error.
    if [[ "$base" == *:* ]]; then
      local ssh_bin="${RIP_SSH_BIN:-ssh}"
      local host="${base%%:*}" rpath="${base#*:}"
      "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$host" \
        "mkdir -p ${(q)rpath}/audiobooks/${(q)canon} && mv -n -- ${(q)rpath}/audiobooks/${(q)variant}/${(q)title} ${(q)rpath}/audiobooks/${(q)canon}/ && { [ ! -e ${(q)rpath}/audiobooks/${(q)variant}/${(q)title} ] || exit 12; }" 2>/dev/null
      mvstate=$?
    else
      mvstate=1
      if mkdir -p "$base/audiobooks/$canon" 2>/dev/null \
        && mv -n -- "$base/audiobooks/$variant/$title" "$base/audiobooks/$canon/" 2>/dev/null; then
        if [[ -e "$base/audiobooks/$variant/$title" ]]; then mvstate=12; else mvstate=0; fi
      fi
    fi
    case $mvstate in
      0) ;;
      12)
        log_warn "rip: \"$title\" is already stored under \"$canon\" — left the copy under \"$variant\" exactly where it is, nothing overwritten"
        # Belt and braces. The rmdir probe below reports state 10 for this
        # variant (the refused book is still a directory at depth 1), so this
        # function returns 1 before the still_pointing branch is reached —
        # but the author record must be kept because a book still names the
        # variant, and that must not depend on a coincidence of the probe.
        (( still_pointing++ ))
        continue ;;
      *)
        log_warn "rip: could not move $title"
        continue ;;
    esac
    item="$("$RIP_BIN_DIR/rip-abs-authors" --find-item "$canon/$title" 2>/dev/null)"
    if [[ -z "$item" ]]; then
      # STILL GATES THE DELETE. --find-item matches ABS's STORED relPath, and
      # this lookup runs milliseconds after the `mv` — ABS only learns the new
      # path on its next scan (see this function's header). So an empty $item
      # here does NOT mean "ABS has nothing filed under the old author"; it
      # usually means the opposite. Left unrouted, `rmdir` succeeded, control
      # reached the delete block, and --delete-author removed the variant's
      # record while every un-repointed item still named it — review finding
      # 2 (2026-08-24) reproduced, now reporting rc 0, and a regression of the
      # collision behaviour that predates this feature. NOT counted as a
      # failure: nothing went wrong, there was simply nothing to repoint.
      # (Review finding 1, 2026-08-26.)
      log_warn "rip: moved $title, but Audiobookshelf does not know this book yet — nothing to repoint"
      (( still_pointing++ ))
      continue
    fi
    if [[ -z "$aid" ]]; then
      (( still_pointing++ ))
      continue
    fi
    if ! "$RIP_BIN_DIR/rip-abs-authors" --repoint-item "$item" "$aid" "$canon" >/dev/null 2>&1; then
      log_warn "rip: moved $title but could not repoint its ABS item"
      (( unrepointed++ ))
      (( still_pointing++ ))
    fi
  done

  # "rmdir failed" is NOT the same fact as "books remain", and conflating them
  # made the warning below assert something untrue. rip::ab_server_library
  # lists only `-mindepth 2 -maxdepth 2 -type d`, so ANY non-book entry sitting
  # directly under the author folder — a .DS_Store from a Finder mount of the
  # share is the obvious one — makes rmdir fail after every book has already
  # moved. Worse, the variant then stops appearing in the listing at all
  # (nothing at depth 2 any more), so a kept author record becomes permanently
  # unreachable by any future sweep. Ask the server the real question instead,
  # in the SAME round-trip, and answer 0 gone / 10 books remain / 11 no books
  # but not empty. (Review finding, 2026-08-24.)
  local rmscript='d="$1"; if [ -n "$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)" ]; then exit 10; fi; rmdir -- "$d" 2>/dev/null && exit 0; exit 11'
  local -i state
  if [[ "$base" == *:* ]]; then
    local ssh_bin2="${RIP_SSH_BIN:-ssh}"
    local host2="${base%%:*}" rpath2="${base#*:}"
    "$ssh_bin2" -o BatchMode=yes -o ConnectTimeout=5 "$host2" \
      "sh -c ${(q)rmscript} sh ${(q)rpath2}/audiobooks/${(q)variant}" 2>/dev/null
    state=$?
  else
    sh -c "$rmscript" sh "$base/audiobooks/$variant" 2>/dev/null
    state=$?
  fi

  case $state in
    0|11) ;;   # no books remain; 11 also has non-book leftovers, handled below
    10)
      log_warn "rip: \"$variant\" still holds books after the sweep — leaving its Audiobookshelf author record in place"
      return 1 ;;
    *)
      # An ssh that never answered (255) lands here. Unknown is not empty:
      # keep the record.
      log_warn "rip: could not tell whether \"$variant\" still holds books — leaving its Audiobookshelf author record in place"
      return 1 ;;
  esac
  if (( unrepointed )); then
    log_warn "rip: $unrepointed book(s) from \"$variant\" could not be repointed — leaving its Audiobookshelf author record in place"
    return 1
  fi
  # NOTHING TO REPOINT TO, which is not the same fact as A REPOINT THAT
  # FAILED. The books are where they should be and the path — the thing
  # --retag reads and this whole phase is about — is correct. The variant's
  # author record is still kept, because items Audiobookshelf knows still
  # name it, but this is reported as an outcome rather than as an error.
  # rc 3, so the caller can say so in its summary without treating it as a
  # failed sweep; nothing outside rip::ab_canonicalize_authors calls this.
  if (( still_pointing )); then
    # Two causes, two remedies, so two messages: with no canonical author
    # record there is nothing to repoint TO and the operator renames the
    # author; with one, Audiobookshelf simply has not scanned these books yet
    # and the leftover record is theirs to check. Saying only the first would
    # assert something untrue in the second case.
    if [[ -z "$aid" ]]; then
      log_warn "rip: $still_pointing book(s) moved out of \"$variant\" still name it in Audiobookshelf — there is no author record called \"$canon\" to repoint them to, so \"$variant\" is left in place; rename that author in the Audiobookshelf UI"
    else
      log_warn "rip: $still_pointing book(s) moved out of \"$variant\" were left unrepointed — Audiobookshelf has not seen them at their new path yet, so \"$variant\" is left in place; check for a leftover author in the Audiobookshelf UI"
    fi
    if (( state == 11 )); then
      log_warn "rip: \"$variant\" holds no books but is not empty (non-book files remain, left for you to clean up)"
      return 1
    fi
    return 3
  fi
  # Every book is out and repointed, so the variant author record is genuinely
  # empty and is removed — including in the 11 case. Keeping it there would
  # strand it: the variant is no longer listed, so no later sweep would ever
  # offer to clean it up, and the operator would be left with a zero-book
  # author in the Audiobookshelf UI forever. The leftover DIRECTORY is left
  # alone (it is not ours to delete blind) and named, so the operator knows
  # exactly what remains rather than being told a falsehood.
  #
  # CLAIM ONLY WHAT ACTUALLY HAPPENED. The delete can fail to happen two ways —
  # $stale never resolved (a transient API miss, or the record was already
  # gone), or --delete-author itself was rejected — and BOTH are permanent
  # here: by this point the variant has left rip::ab_server_library's listing,
  # in state 0 because the directory is gone and in state 11 because it holds
  # nothing at depth 2, so no future sweep will ever see this author again.
  # Announcing a removal that did not occur would hide exactly the artifact
  # this branch exists to prevent, behind a false success. Capture the status
  # and say what is true. (Review finding, 2026-08-24, round 3.)
  local -i dropped=0
  local drop_warn=""
  if [[ -z "$stale" ]]; then
    drop_warn="could not resolve its Audiobookshelf author record — no future sweep will see \"$variant\" again, so check for a leftover author in the Audiobookshelf UI"
  elif "$RIP_BIN_DIR/rip-abs-authors" --delete-author "$stale" >/dev/null 2>&1; then
    dropped=1
  else
    drop_warn="could not remove its Audiobookshelf author record — no future sweep will see \"$variant\" again, so remove it in the Audiobookshelf UI"
  fi

  if (( state == 11 )); then
    if (( dropped )); then
      log_warn "rip: \"$variant\" holds no books but is not empty (non-book files remain) — removed its Audiobookshelf author record and left the directory for you to clean up"
    else
      log_warn "rip: \"$variant\" holds no books but is not empty (non-book files remain, left for you to clean up) — $drop_warn"
    fi
    return 1
  fi
  (( dropped )) && return 0
  log_warn "rip: swept \"$variant\" but $drop_warn"
  return 1
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
    # <Title>.M4B and record format:"M4B" — a shape rip::ab_have used to be
    # unable to see at all, back when it probed a hardcoded "${rel:t}.m4b"
    # (2026-08-23 review finding). ab_have now probes the book DIRECTORY and
    # no longer cares, but the lowercasing stays: `format` is recorded in the
    # sidecar, and one library spelling "m4b" two ways is its own mess.
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

# rip::_sha256_of <file> — the file's sha256, or "" if it cannot be read.
# macOS ships `shasum`; Linux ships `sha256sum`. Try both, print nothing on
# failure so a caller never compares against a half-answer.
#
# extendedglob IS load-bearing here (review finding, this task): the `##`
# repeat operator in the validity check below is a no-op glob character
# without it — `[[ "$out" == [0-9a-f]## ]]` silently matched NOTHING and
# every real hash came back "" (reproduced: a correctly computed sha256
# failed this check and the dedupe below never fired). Nowhere else in
# this file's `[[ ]]` glob matches needs it — `<->` is a separate zsh
# operator that works unconditionally — so this is the one function that
# has to ask for it.
rip::_sha256_of() {
  setopt localoptions noerrexit nopipefail extendedglob
  local f="$1" out=""
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum -- "$f" 2>/dev/null | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 -- "$f" 2>/dev/null | cut -d' ' -f1)"
  fi
  [[ "$out" == [0-9a-f]## ]] && print -r -- "$out"
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
  # `_ids_fix` on every row: THIS is where a plan enters the meta index, and
  # the plan arrives from the panel through a Lua encode that turns an EMPTY
  # ids object into `[]` (see _RIP_JQ_IDS_DEF — the folder provider is the
  # only producer of an empty one, so this is the normal shape for a locally
  # imported book). Left uncoerced, `[]` reaches rip::_book_sidecar and every
  # `.ids + {…}` patch below, each of which raises on an array under a
  # `2>/dev/null`: the book ships, the job reports success, and its sidecar
  # carries no fleet.uid and no local.sha256 — identity silently lost, and
  # byte-dedupe permanently blind to that book. Coercing at the entrance means
  # no later stage has to know the panel's encoder exists.
  jq -c -s "$_RIP_JQ_IDS_DEF"'
    [.[] | select((.path // "") != "") | _ids_fix]
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
  #
  # FIVE fields per item, not two: `plus`/`absent` (the provider's
  # IsAudiblePlus / AbsentFromLastScan) are carried through so the
  # acquire-verification below can name the reason a lapsed title produced
  # nothing instead of guessing at one. Emitted as "1"/"0" rather than
  # true/false so an item whose row predates those keys reads as "0" and the
  # message falls back to the plain wording — never a cause we did not
  # establish.
  #
  # `edition` is the fifth and it is LAST, deliberately: TAB is IFS
  # whitespace, so `read` collapses two adjacent tabs into ONE separator and
  # every field after an empty one silently shifts. Every other field here is
  # non-empty by construction for exactly that reason; edition is the one
  # that is legitimately empty (most books have none), and in last position a
  # `read` that finds nothing after the final tab assigns it "" — which is
  # what it means — instead of eating a neighbour.
  local id bpath plus absent edition entry rest
  while IFS=$'\t' read -r id bpath plus absent edition; do
    [[ -n "$id$bpath" ]] && items+=("$id"$'\t'"$bpath"$'\t'"$plus"$'\t'"$absent"$'\t'"$edition")
  done < <(jq -r '(.items // [])[]
                  | [(.id // ""), (.path // ""),
                     (if (.plus // false) then "1" else "0" end),
                     (if (.absent // false) then "1" else "0" end),
                     (.edition // "")] | @tsv' "$plan" 2>/dev/null)

  local total=${#items} n=0 rc=0 line pct refused=0 dup=0
  local base span; span=$(( 70 / (total > 0 ? total : 1) ))
  # Declared ONCE, out here: a bare `local` in the loop body re-runs per
  # iteration, and this file has been bitten by that before.
  # pre_dirs is ASSOCIATIVE, not an array searched with (I): the (I) subscript
  # PATTERN-matches, and a book folder is free to contain [ ] ? or *.
  local -A pre_dirs=()
  local -a landed=()
  local pre_d bdir actual primary sha
  local ed_suffix base_rel base_raw base_rk work_uid
  # THE RE-KEY LEDGER, declared HERE with the other loop locals for the same
  # reason batch_work_uid is (a `local` re-run in the loop body prints
  # "name=value" onto the stream this worker writes progress lines to).
  #
  # Maps a plan path to the path the reconcile below re-keyed it to. The
  # anchor patch matches the base row by the path THE PLAN gave it, and the
  # reconcile rewrites exactly that key once a provider lands the book
  # somewhere else — so after the base item has been acquired, the anchor
  # matched nothing and the base shipped with `work: null` (review finding,
  # 2026-08-26, round 2). Only a provider that re-keys can reach this:
  # rip-provider-folder honours the relpath the worker hands it, while
  # rip-provider-libation's dispatcher forwards only its own first two
  # post-shift args to cmd_acquire, discarding that third argument — so
  # Libation lands where it likes and the ":" in "Title: Subtitle" comes back
  # sanitized.
  local -A rekeyed=()
  # THE BATCH'S OWN work-uid memo, declared HERE with the other loop locals —
  # never inside the loop body, where a re-run `local` prints "name=value" to
  # stdout and corrupts the stream this worker also writes progress lines to.
  #
  # Why it must exist (review finding, 2026-08-26): uid resolution reads the
  # BASE book from the SERVER, and a base book being ripped in the SAME batch
  # is not on the server yet. Two editions of one unstored work therefore both
  # fell through to "mint fresh" and landed with DIFFERENT uids — and because
  # both then carry a non-null `work`, neither is ever a --backfill-work-uid
  # candidate again, `--editions` reports two unrelated works, and there is no
  # repair verb: a hand edit on cantina is the only way back. Design doc S4
  # step 5's premise ("no such book is stored" means no such book exists) is
  # simply false within one plan; this table is what makes it true again.
  #
  # Keyed on the base relpath, populated only for a NON-EMPTY one: an empty
  # base_rel means "this row has no base path at all" (see below), and every
  # such row is a different book that must get its own uid, not share one.
  local -A batch_work_uid=()

  # Lazy dedupe (Task 4): the hash happens HERE, at acquire time, never in
  # `list` — `list` must stay responsive over an unbounded tree. Only a
  # folder-provider plan can possibly collide on bytes (libation's own
  # ASIN already rules out a re-download of the same book), so the index
  # is primed only when this plan is one.
  #
  # PRIMED ONCE, HERE, BEFORE THE LOOP — never inside it, and never through
  # a substitution. rip::_stored_sha_index's own contract (see its
  # definition) is that the cache lives in the globals it sets, not in its
  # stdout: `$(...)` and `< <(...)` both fork in zsh, and a fork's copy of
  # the cache dies with the fork, turning what should be ONE ssh into one
  # per item. Called bare, the cache lands in $_RIP_STORED_SHA in THIS
  # shell, read once into a lookup table below — exactly the discipline
  # rip::_canonicalize_staged_authors already owes rip::_server_authors.
  local sha_idx_rc=0
  local -A stored_sha=()
  if [[ "$provider" == folder ]]; then
    rip::_stored_sha_index >/dev/null
    sha_idx_rc=$?
    if (( sha_idx_rc != 0 )); then
      # Do NOT swallow this. An empty table would read as "nothing
      # collides" and silently disable the whole check for this batch —
      # the exact failure Task 3's own contract comment warns against.
      # Instead: warn ONCE here (not once per item) and let every folder
      # item's dedupe check below no-op, falling through to acquire
      # un-checked — "unknown" is not a refusal, the same rule
      # rip::_remote_has_file's rc-2 callers already follow for the
      # path-based check just below.
      log_warn "rip: could not reach cantina to check stored bytes — acquiring this batch's folder items without a duplicate-bytes check"
    else
      local sha_line sha_key sha_owner
      for sha_line in "${(f)_RIP_STORED_SHA}"; do
        [[ -n "$sha_line" ]] || continue
        sha_key="${sha_line%%$'\t'*}"; sha_owner="${sha_line#*$'\t'}"
        stored_sha[$sha_key]="$sha_owner"
      done
    fi
  fi

  for entry in "${items[@]}"; do
    id="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
    bpath="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    plus="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    absent="${rest%%$'\t'*}"; edition="${rest#*$'\t'}"
    base=$(( n * span )); n=$(( n + 1 ))
    rip::ab_have "$bpath"
    case $? in
      0)
        # The operator asked to be TOLD, not to have the batch aborted
        # (2026-08-24): a book already on the server is a refusal worth
        # logging, and the remaining books still acquire. This check stays at
        # ACQUIRE time only — rip-push audiobooks is deliberately idempotent
        # so a failed verify can be retried without re-downloading, and
        # refusing an already-present path there would break that retry.
        log_error "rip: already on cantina, refusing to re-acquire: $bpath"
        refused=$(( refused + 1 ))
        continue
        ;;
      2) log_warn "rip: could not ask cantina about $bpath — acquiring anyway" ;;
    esac
    # Warned, NOT refused (the operator's rule, 2026-08-24): AbsentFromLastScan
    # can be stale, and refusing on stale metadata would block a legitimate
    # rip. Attempting costs one no-op Libation invocation; the verification
    # after the acquire is what reports the truth.
    if [[ "$plus" == 1 && "$absent" == 1 ]]; then
      log_warn "rip: $bpath is Audible Plus and absent from Audible's last scan — its licence may already have lapsed; attempting anyway"
    fi
    # Lazy dedupe (Task 4): hash ONLY the book about to be acquired, and
    # only for the folder provider — a DIFFERENT rule from the "already on
    # cantina" refusal above (keyed on PATH); this one is keyed on BYTES,
    # and both must keep firing independently. $id is the folder provider's
    # SOURCE FILE here, ahead of any copy into staging.
    #
    # The hash is computed regardless of $sha_idx_rc now (Task 5, Step 3b):
    # only the DUPLICATE COMPARISON below needs the stored-sha index, but
    # "identity assigned at import" (spec) must not depend on cantina being
    # reachable — a folder book acquired while the dedupe index couldn't be
    # fetched still needs its own hash threaded through, or it would carry
    # no local.sha256 at all and re-enter exactly the gap this task closes.
    if [[ "$provider" == folder ]]; then
      # One .m4b is one book, so the plan's id IS the primary file. The
      # directory branch is kept for one reason only: a plan queued by a
      # panel from before that change still names a directory, and a queued
      # plan outlives the code that wrote it. It is not a shape we emit.
      if [[ -f "$id" ]]; then
        primary="$id"
      else
        primary="$(print -rl -- "$id"/*.m4b(N) | head -1)"
      fi
      if [[ -n "$primary" ]]; then
        sha="$(rip::_sha256_of "$primary")"
        if [[ $sha_idx_rc -eq 0 && -n "$sha" && -n "${stored_sha[$sha]:-}" ]]; then
          log_error "rip: $bpath is already stored as \"${stored_sha[$sha]}\" (identical bytes) — skipping"
          dup=$(( dup + 1 ))
          continue
        fi
        if [[ -n "$sha" ]]; then
          # Thread the hash into THIS item's meta-index row now, while it is
          # in hand — the same targeted by-path jq patch the re-key step
          # below uses on this same file. rip::_book_meta_for (called later,
          # from the enrichment stage after every item in this batch has
          # been acquired) mints the rest of this book's local identity from
          # it, rather than hashing the same multi-gigabyte file twice.
          jq -c --arg p "$bpath" --arg s "$sha" \
            "$_RIP_JQ_IDS_DEF"'if .path == $p then .ids = ((.ids | _ids_obj) + {"local.sha256": $s}) else . end' \
            "$index" > "$index.tmp" \
            && mv -f -- "$index.tmp" "$index" \
            || { rm -f -- "$index.tmp"; log_warn "rip: could not record the local hash for $bpath in the meta index — its identity will not be assigned this push" }
        fi
      fi
    fi
    # THE WORK THIS EDITION BELONGS TO (design doc S4). An item carrying a
    # non-empty `edition` is a different edition of a book cantina may
    # already hold, and the two are the same work only if they end up
    # carrying the same `work.uid`.
    #
    # THE BASE PATH IS DERIVED BY REMOVING ONE EXACT SUFFIX, never by parsing
    # parentheses. The panel composed `$bpath` as "<Author>/<Title> (<Edition>)"
    # from these very two strings, so stripping " ($edition)" off the end is
    # deterministic and reversible. A general parenthesis parser would mangle
    # a book legitimately titled "Something (Unabridged)" — and that title,
    # with no edition set, must reach the server exactly as it does today.
    # The quotes inside ${bpath%"$ed_suffix"} make the suffix LITERAL: an
    # edition containing a glob character would otherwise match as a pattern.
    #
    # Resolved AFTER the two refusals above, so a book that is already stored
    # (by path or by bytes) never costs a server round trip — and, far more
    # importantly, can never trigger the write-back below on a book the
    # operator was not even ripping.
    if [[ -n "$edition" ]]; then
      ed_suffix=" ($edition)"
      base_rel=""
      base_raw=""
      # No suffix, no base path: this row was not composed by the panel (a
      # hand-written or pre-suffix plan), so there is no book to share a work
      # with and the honest answer is a fresh uid — never a guess at which
      # stored book was meant. Same for a suffix that consumed the whole
      # title, which would leave a bogus "<Author>/" to read.
      if [[ "$bpath" == *"$ed_suffix" ]]; then
        base_raw="${bpath%"$ed_suffix"}"
        [[ "${base_raw##*/}" == "" ]] && base_raw=""
      fi
      # TWO spellings of the base path, deliberately. $base_raw is the plan's
      # OWN bytes — that is what an in-plan sibling row's `.path` is compared
      # against below, where the two strings were composed by one panel from
      # one pair of fields and a normalization pass would only introduce a
      # difference. $base_rel is the NFC one, for the SERVER: the read and the
      # write-back must both speak the server's spelling (see
      # rip::_ab_work_uid_for). Both are tried by the anchor patch.
      base_rel="$base_raw"
      # NFC on the KEY as well, for the same reason rip::_ab_work_uid_for
      # normalizes its argument: two spellings of one directory must be ONE
      # entry in this table, not two.
      [[ -n "$base_rel" ]] && base_rel="$(rip::_nfc "$base_rel")"
      # The memo (see batch_work_uid above) is consulted BEFORE the server:
      # a second edition of a base this batch already resolved must reuse
      # that answer whether the base is stored or not.
      work_uid=""
      if [[ -n "$base_rel" && -n "${batch_work_uid[$base_rel]:-}" ]]; then
        work_uid="${batch_work_uid[$base_rel]}"
      else
        work_uid="$(rip::_ab_work_uid_for "$base_rel")"
        [[ -n "$base_rel" && -n "$work_uid" ]] && batch_work_uid[$base_rel]="$work_uid"
      fi
      # The base row's CURRENT key, if this batch already re-keyed it. Both
      # spellings are tried for the same reason the patch tries both below:
      # the ledger is keyed on the base item's own plan path, which is the
      # plan's raw bytes.
      base_rk=""
      [[ -n "$base_raw" ]] && base_rk="${rekeyed[$base_raw]:-}"
      [[ -z "$base_rk" && -n "$base_rel" ]] && base_rk="${rekeyed[$base_rel]:-}"
      if [[ -n "$work_uid" ]]; then
        # Onto THIS item's meta-index row, by path — the same targeted jq
        # patch the local-hash thread above uses on the same file. The row is
        # what rip::_book_meta_for hands the sidecar composer, and
        # _RIP_SIDECAR_JQ emits `work: ($r.work | _work_obj)`, so this is the
        # single point where a rip records which work it belongs to.
        #
        # AND THE BASE ROW, IF IT IS IN THIS SAME PLAN (review finding,
        # 2026-08-26). The memo above makes two EDITIONS share a uid, but a
        # base book being ripped alongside its own edition carries no
        # `edition` of its own, so it never entered this block at all and
        # landed with `work: null` — then --backfill-work-uid minted it a
        # DIFFERENT uid, and with both rows non-null neither is ever a
        # candidate again: two unrelated works, repairable only by hand on
        # cantina. It is the NATURAL flow, not a corner: two files that both
        # derive <Author>/<Title> collide in the panel's path-keyed
        # rippable() dedupe, so setting an Edition on one is the only way to
        # rip both at once.
        #
        # The base row is anchored (`edition: null`) rather than labelled:
        # the edition name belongs to the book being ripped, never to the one
        # it shares a work with — the same rule rip::_ab_anchor_work_uid
        # follows for a base book already on the server.
        #
        # Keyed on `.path`, and the whole plan was merged into this index
        # before the loop started, so the base row is there to patch whether
        # it is acquired before or after its edition. That is order-independent
        # ONLY absent a re-key, and it is worth saying plainly rather than
        # shorter: the reconcile step further down REWRITES `.path` on the row
        # of any item whose provider landed the book somewhere other than the
        # planned relpath. Once the base item has been acquired, the planned
        # key is gone — so the patch also tries the spelling `rekeyed` recorded
        # for it (review finding, 2026-08-26, round 2; base-first was a silent
        # permanent split on every libation plan whose title contains a ":").
        #
        # Only a row whose `work` is still null is touched — never one an
        # earlier item already resolved, and never a book outside this plan
        # (this file is the meta index, not a sidecar).
        jq -c --arg p "$bpath" --arg b "$base_raw" --arg bn "$base_rel" \
              --arg br "$base_rk" --arg u "$work_uid" --arg e "$edition" \
          'if .path == $p then .work = {uid: $u, edition: $e}
           elif ($b != ""
                 and (.path == $b or .path == $bn or ($br != "" and .path == $br))
                 and .work == null)
             then .work = {uid: $u, edition: null}
           else . end' \
          "$index" > "$index.tmp" \
          && mv -f -- "$index.tmp" "$index" \
          || { rm -f -- "$index.tmp"; log_warn "rip: could not record the work uid for $bpath in the meta index — this edition will ship without one" }
      fi
    fi
    rip::_progress "$base" "downloading — ${bpath:t}"
    # Snapshot the author dir BEFORE the acquire. The reconcile below falls
    # back to "the newest book dir under this author", and in a batch of two
    # books by ONE author that fallback would happily hand book two the
    # folder book one just created — a failed acquire re-keyed onto, and
    # verified against, a sibling's files. Only a directory that was not
    # there a moment ago can be this acquisition.
    pre_dirs=(); for pre_d in "$ab_root/${bpath%%/*}"/*(N/); do pre_dirs[${pre_d:t}]=1; done
    # $bpath (the plan item's own path — <Author>/<Title>) is always passed
    # as the third, optional argument. It is authoritative: it is what the
    # panel displayed and what a later task lets the operator EDIT before
    # ripping, so it must win over anything a provider could re-derive from
    # the id alone. Passed unconditionally, not just for the folder
    # provider: rip-provider-libation's own dispatcher only ever forwards
    # its OWN first two (post-shift) positional args to cmd_acquire —
    # `acquire) shift; cmd_acquire "${1:?...}" "${2:?...}" ;;` — so a third
    # argument here is silently discarded there, exactly like `list [root]`
    # is ignored by a provider that owns its own catalogue (verified by
    # reading executable_rip-provider-libation's dispatcher, not assumed).
    zsh "$bin" acquire "$id" "$ab_root" "$bpath" 2>&1 \
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
    # on its way to the filesystem. If the composed dir is not there (or is
    # there but empty), the newest book dir under the author dir that was NOT
    # already present before this acquire (glob qualifier (N/om): dirs only,
    # most-recently-modified first, minus the pre_dirs snapshot) is taken to
    # BE this acquisition, and the meta index must be re-keyed to the real
    # path or the sidecar it feeds would never match the folder it belongs
    # to.
    bdir=""
    if rip::_dir_has_audio "$ab_root/$bpath"; then
      bdir="$ab_root/$bpath"
    else
      landed=()
      for pre_d in "$ab_root/${bpath%%/*}"/*(N/om); do
        [[ -n "${pre_dirs[${pre_d:t}]:-}" ]] && continue
        # A DIRECTORY WITH NO AUDIO IN IT IS NOT AN ACQUISITION. A provider
        # that creates its destination and then bails leaves the COMPOSED
        # path itself sitting here, new since the snapshot and therefore a
        # candidate — which produced "Red Rising landed as Red Rising —
        # re-keying the plan identity" (live 2026-08-24): a warning stating
        # a non-fact, plus a jq+mv rewrite of the meta index to no effect.
        # It is also mtime-order-fragile: were a provider ever to create the
        # composed dir AFTER writing into a sanitized sibling, the empty dir
        # would sort first and a genuinely successful acquire would be
        # reported as having produced nothing. Files are the evidence here,
        # exactly as they are for the outcome check below.
        rip::_dir_has_audio "$pre_d" || continue
        landed+=("$pre_d")
      done
      if (( ${#landed} )); then
        # NFC-normalize the landed folder name before writing it as the new
        # key: rip::_book_meta_for (this index's only reader) NFC-normalizes
        # its lookup via rip::_nfc before matching .path, so a provider that
        # lands an NFD-decomposed name — the exact case this reconcile step
        # exists for — would otherwise re-key to bytes the lookup can never
        # match, silently falling back to the path-derived minimal identity.
        # Same bug class as 21322287 (NFC-canonical server names) in this
        # same file.
        actual="${bpath%%/*}/$(rip::_nfc "${landed[1]:t}")"
        if [[ "$actual" == "$bpath" ]]; then
          # The composed path itself, reached through the fallback (its NFC
          # form equals the plan's). Nothing diverged, so there is nothing to
          # report and nothing to re-key — say neither.
          bdir="${landed[1]}"
        else
          log_warn "rip: $bpath landed as $actual — re-keying the plan identity"
          # Remembered for the work-uid anchor, which looks the base row up
          # by its PLANNED path and would otherwise find nothing here.
          rekeyed[$bpath]="$actual"
          jq -c --arg old "$bpath" --arg new "$actual" \
            'if .path == $old then .path = $new else . end' "$index" > "$index.tmp" \
            && mv -f -- "$index.tmp" "$index"
          bdir="${landed[1]}"
        fi
      fi
    fi

    # THE ACQUIRE'S ACTUAL OUTCOME. rc 0 from LibationCli is NOT it: a title
    # whose Audible Plus licence has lapsed makes the CLI exit 0 having
    # liberated nothing, so the worker called it a success, the push found no
    # new files, and the operator got a "ripping complete" toast for a book
    # that never arrived (reproduced live 2026-08-24, Pierce Brown/Red
    # Rising). That is this subsystem's NINTH defect of one shape — a success
    # asserted from control flow reaching a line rather than from a captured
    # outcome — so the success claim now rests on files that exist.
    #
    # Treated exactly like an acquire failure: logged, counted in rc, and the
    # rest of the batch continues (one item's failure is that item's failure).
    if [[ -z "$bdir" ]] || ! rip::_dir_has_audio "$bdir"; then
      if [[ "$plus" == 1 && "$absent" == 1 ]]; then
        log_error "rip: acquire produced no files for $bpath — this title is Audible Plus and absent from Audible's last scan, so its licence has lapsed and it can no longer be liberated"
      else
        # NEVER a cause we did not establish: without both flags all we know
        # is that nothing landed.
        log_error "rip: acquire produced no files for $bpath"
      fi
      rc=1
      continue
    fi
  done
  rm -f -- "$plan"
  (( refused > 0 )) && log_error "rip: $refused already on cantina — skipped"
  (( dup > 0 )) && log_error "rip: $dup already stored (identical bytes) — skipped"

  # A MACHINE MARKER for the caller, in the same spirit as the `progress`
  # lines above. The two log_error lines are for the job log; this one is for
  # whoever is watching, because a refusal is invisible otherwise: it does not
  # fail (nothing went wrong — the book is already there), so the session
  # exits 0 and a capsule that only reports non-zero shows plain success for a
  # run that shipped nothing. The panel now blocks the path collision it can
  # see; this covers the one it CANNOT — byte-identical content under a
  # different name, which is only knowable after hashing.
  (( refused > 0 || dup > 0 )) && print -r -- "skipped refused=$refused dup=$dup"

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
