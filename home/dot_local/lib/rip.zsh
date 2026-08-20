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
  fi

  local marker; marker="$(rip::staging_root)/.work/push-$type.stamp"
  touch -- "$marker" || {
    log_error "rip: cannot stamp the push marker at $marker"
    rm -f -- "$listfile"
    return 1
  }

  rip::_progress 0 "pushing $type"
  local line pct file
  "$rsync_bin" -a --partial --exclude=.DS_Store --files-from="$listfile" \
      --info=progress2,name1 "$src/" "$dest" \
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
    rm -f -- "$listfile"
    return $rc
  fi
  rip::_verify_and_clean "$type" "$src" "$dest" "$marker" "$listfile"
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
  if ! diffs="$("$rsync_bin" -rcn --exclude=.DS_Store --files-from="$listfile" \
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

# rip::_track_meta <flac> — prints "artist<TAB>album<TAB>title<TAB>duration_s".
# Built with printf (not `print -r`): print -r takes its arguments RAW, so a
# literal \t embedded in a double-quoted string would ride through as the two
# characters backslash-t instead of becoming a real tab, breaking every
# consumer below that splits on $'\t' / cut. printf's format string is where
# \t is interpreted, and — unlike `print` without -r — it never reprocesses
# escape-like content inside the %s argument values themselves, so an artist
# or album tag that happens to contain a literal backslash sequence rides
# through unmolested.
rip::_track_meta() {
  local mf="${RIP_METAFLAC_BIN:-metaflac}" f="$1"
  local artist album title samples rate dur=0
  artist="$("$mf" --show-tag=ARTIST "$f" 2>/dev/null | head -1)"; artist="${artist#*=}"
  album="$("$mf" --show-tag=ALBUM "$f" 2>/dev/null | head -1)";  album="${album#*=}"
  title="$("$mf" --show-tag=TITLE "$f" 2>/dev/null | head -1)";  title="${title#*=}"
  samples="$("$mf" --show-total-samples "$f" 2>/dev/null)"
  rate="$("$mf" --show-sample-rate "$f" 2>/dev/null)"
  [[ "$samples" == <-> && "$rate" == <1-> ]] && dur=$(( samples / rate ))
  printf '%s\t%s\t%s\t%s\n' "$artist" "$album" "$title" "$dur"
}

rip::_fetch_cover() {
  local artist="$1" album="$2" out="$3"
  local curl_bin="${RIP_CURL_BIN:-curl}"
  local mb="${RIP_MB_URL:-https://musicbrainz.org/ws/2}"
  local caa="${RIP_CAA_URL:-https://coverartarchive.org}"
  local itunes="${RIP_ITUNES_URL:-https://itunes.apple.com}"
  local mbid
  mbid="$("$curl_bin" -sf -A 'fleet-rip/2.0' -G "$mb/release/" \
      --data-urlencode "query=release:\"$album\" AND artist:\"$artist\"" \
      --data-urlencode fmt=json --data-urlencode limit=1 2>/dev/null \
    | jq -r '(.releases // [])[0].id // empty')"
  if [[ -n "$mbid" ]]; then
    "$curl_bin" -sfL -o "$out" "$caa/release/$mbid/front-500" 2>/dev/null \
      && [[ -s "$out" ]] && return 0
  fi
  local art_url
  art_url="$("$curl_bin" -sf -G "$itunes/search" \
      --data-urlencode "term=$artist $album" --data-urlencode entity=album \
      --data-urlencode limit=1 2>/dev/null \
    | jq -r '(.results // [])[0].artworkUrl100 // empty' \
    | sed 's/100x100bb/600x600bb/')"
  [[ -n "$art_url" ]] || { rm -f -- "$out"; return 1 }
  "$curl_bin" -sfL -o "$out" "$art_url" 2>/dev/null && [[ -s "$out" ]] && return 0
  rm -f -- "$out"; return 1
}

# Deezer's empty-image placeholder cover, keyed by MD5 (live-discovered
# 2026-08-20): any picture_xl containing this must be rejected outright.
RIP_ARTIST_IMAGE_PLACEHOLDER_MD5='d41d8cd98f00b204e9800998ecf8427e'

# rip::_remote_has_artist_image <artist_reldir> — existence check on the
# server, ahead of any fetch (idempotency, per operator requirement). If
# rip::remote_base contains a ':' it's `user@host:path`: shell out to `ssh
# <host> test -f …`. No ':' (the hermetic tests use a plain local dir): a
# direct filesystem test. Returns 0 exists / 1 confirmed absent / 2 unknown
# (the ssh call itself failed to run — e.g. the host is unreachable — rc
# 255 on a real ssh; distinct from the remote `test -f` legitimately
# reporting rc 1). The caller treats 2 exactly like "unknown": never block,
# never refetch blindly, just skip the fetch this run and log one line.
rip::_remote_has_artist_image() {
  local artist_rel="$1"
  local base; base="$(rip::remote_base)"
  if [[ "$base" == *:* ]]; then
    local ssh_bin="${RIP_SSH_BIN:-ssh}"
    local host="${base%%:*}" rpath="${base#*:}"
    # Artist names are untrusted CDDB/MusicBrainz tag data — an apostrophe
    # ("Guns N' Roses") breaks hand-rolled single-quoting, and a crafted
    # tag can break OUT of it entirely and execute arbitrary commands on
    # cantina over the media@ ssh credentials. ${(q)...} is zsh's own
    # quoter: it safely shell-quotes the remote-file path for ANY content,
    # never hand-interpolated into a quoted string ourselves.
    # BatchMode+ConnectTimeout: a network black-hole or host-key prompt
    # must never hang the push worker — "never block" applies to the
    # check itself, not just its result.
    local rfile="$rpath/music/$artist_rel/artist.jpg"
    "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 \
      "$host" "test -f ${(q)rfile}" 2>/dev/null
    local rc=$?
    (( rc == 0 )) && return 0
    (( rc == 1 )) && return 1
    return 2
  fi
  [[ -f "$base/music/$artist_rel/artist.jpg" ]] && return 0
  return 1
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
    "$curl_bin" -sfL -o "$out" "$pic_url" 2>/dev/null && [[ -s "$out" ]] && return 0
    rm -f -- "$out"
  fi
  # Fallback: MusicBrainz artist search → url-rels → Wikidata P18 → Commons.
  local mbid
  mbid="$("$curl_bin" -sf -A 'fleet-rip/2.0' -G "$mb/artist/" \
      --data-urlencode "query=artist:\"$artist\"" \
      --data-urlencode fmt=json --data-urlencode limit=1 2>/dev/null \
    | jq -r '(.artists // [])[0].id // empty')"
  [[ -n "$mbid" ]] || return 1
  local resource wikidata_id
  resource="$("$curl_bin" -sf -A 'fleet-rip/2.0' \
      "$mb/artist/$mbid?inc=url-rels&fmt=json" 2>/dev/null \
    | jq -r '[(.relations // [])[] | select((.url.resource // "") | test("wikidata\\.org"))][0].url.resource // empty')"
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
  grep -qxF "$artist_rel/artist.jpg" "$listfile" || print -r -- "$artist_rel/artist.jpg" >> "$listfile"
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
    local rel2
    while IFS= read -r rel2; do
      [[ -n "$rel2" ]] && flacs+=("$src/$rel2")
    done <<< "${album_files[$adir]}"
    (( ${#flacs} )) || continue
    local meta artist album
    meta="$(rip::_track_meta "${flacs[1]}")"
    artist="${meta%%$'\t'*}"
    album="$(print -r -- "$meta" | cut -f2)"
    # cover: fetch once per album, embed where absent, ship cover.jpg
    local cover="$abs/cover.jpg" have_cover=0
    [[ -s "$cover" ]] && have_cover=1
    if (( ! have_cover )) && [[ -n "$artist" && -n "$album" ]]; then
      rip::_fetch_cover "$artist" "$album" "$cover" && have_cover=1 || failed=1
    fi
    if (( have_cover )); then
      grep -qxF "$adir/cover.jpg" "$listfile" || print -r -- "$adir/cover.jpg" >> "$listfile"
      local f
      for f in "${flacs[@]}"; do
        [[ -n "$("$mf" --list --block-type=PICTURE "$f" 2>/dev/null)" ]] && continue
        "$mf" --import-picture-from="$cover" "$f" 2>/dev/null || failed=1
      done
    fi
    # lyrics: per track
    local f tmeta title dur lyr
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
    local artist_rel="${adir:h}"
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
  "$hb_bin" "${RIP_HB_ARGS[@]}" -i "$input" -o "$out_tmp" 2>&1 \
    | tr '\r' '\n' \
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
  local cur total
  "$mkc" -r --progress=-same mkv disc:0 "$best_idx" "$rip_dir" 2>&1 \
    | while IFS= read -r line; do
        case "$line" in
          PRGV:*)
            cur="${line#PRGV:}"; total="${cur##*,}"; cur="${cur%%,*}"
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
