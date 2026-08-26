# rip_helper.sh — shared doubles for the rip specs.
#
# Sourced (not `Include`d) from each rip spec's own setup(), the way
# tests/recob_helper.sh is shared: the functions here have to be callable
# from setup(), which runs before any Include-provided definitions would be
# in scope.

# rip_fake_ffmpeg_pair <dir> — install a fake ffmpeg/ffprobe pair in <dir>
# and point rip.zsh's RIP_FFMPEG_BIN / RIP_FFPROBE_BIN seams at it.
#
# WHY THIS EXISTS. rip::_enrich_audiobooks retags every staged book's audio
# on the way to the push and REFUSES a book whose tags cannot be written and
# read back (design doc 2026-08-26-audiobook-authoritative-tags, S3). That is
# the whole point of the feature — but ~75 push/session examples across the
# rip specs stage a six-byte text file named "*.m4b", which a real ffmpeg
# cannot remux, so every one of them would be refused for reasons that have
# nothing to do with what they are testing.
#
# The pair below is a TEST DOUBLE, not a simulator: the fake ffmpeg copies
# its input to its output byte-for-byte (so every "contents of file … should
# equal" assertion in those examples keeps meaning what it meant) and records
# the -metadata flags it was handed; the fake ffprobe replays exactly those
# as the file's format tags. Sequential by construction — the retag verifies
# the file it just wrote, one at a time — so a single last-write record is
# enough and no path bookkeeping is needed.
#
# Examples that are ABOUT the tags do NOT use this: they build real m4b media
# with the real ffmpeg and point the seams back at the real tools. Where a
# stub appears there, it stubs exactly one failure and never the verification.
rip_fake_ffmpeg_pair() {
  mkdir -p "$1"
  cat > "$1/ffmpeg" <<'FFMPEG'
#!/bin/sh
# -v error -y -i IN -map … -metadata k=v … -- OUT
in=""; out=""; tags=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) in="$2"; shift ;;
    -metadata) tags="$tags$2
"; shift ;;
    --) shift; out="$1" ;;
  esac
  shift
done
[ -n "$in" ] && [ -n "$out" ] || exit 1
cp "$in" "$out" || exit 1
printf '%s' "$tags" > "${RIP_FAKE_TAGS:?}"
exit 0
FFMPEG
  cat > "$1/ffprobe" <<'FFPROBE'
#!/bin/sh
# -v error -show_entries format_tags -of json -- FILE
tags="${RIP_FAKE_TAGS:-}"
[ -n "$tags" ] && [ -f "$tags" ] || { printf '{"format":{"tags":{}}}\n'; exit 0; }
printf '{"format":{"tags":'
# jq builds the object so a value containing a quote or a backslash is
# encoded rather than smuggled through.
jq -R -s 'split("\n") | map(select(length > 0)) | map(split("=") | {key: .[0], value: (.[1:] | join("="))}) | from_entries' "$tags"
printf '}}\n'
exit 0
FFPROBE
  chmod +x "$1/ffmpeg" "$1/ffprobe"
  export RIP_FFMPEG_BIN="$1/ffmpeg" RIP_FFPROBE_BIN="$1/ffprobe"
  export RIP_FAKE_TAGS="$1/last-tags"
}
