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
rip::_track_meta() {
  local mf="${RIP_METAFLAC_BIN:-metaflac}" f="$1"
  local artist album title date year samples rate dur=0
  artist="$("$mf" --show-tag=ARTIST "$f" 2>/dev/null | head -1)"; artist="${artist#*=}"
  album="$("$mf" --show-tag=ALBUM "$f" 2>/dev/null | head -1)";  album="${album#*=}"
  title="$("$mf" --show-tag=TITLE "$f" 2>/dev/null | head -1)";  title="${title#*=}"
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
  local relpath="$1"
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
    "$curl_bin" -sfL -o "$out" "$pic_url" 2>/dev/null && [[ -s "$out" ]] && return 0
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
  "$hb_bin" "${RIP_HB_ARGS[@]}" -i "$input" -o "$out_tmp" 2>&1 \
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
  local -a pty_wrap=(${=RIP_PTY_WRAP-script -q /dev/null})
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
