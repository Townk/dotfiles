# rip-audiobook specs: the shared sandbox (setup/cleanup) and the helpers
# more than one of tests/rip-audiobook*_spec.sh uses. Each spec Includes this
# and tests/rip_helper.sh, and registers setup/cleanup as its own hooks.

# What the fake server was asked to run, with the sandbox path replaced, so an
# assertion about the commands never matches the random temp path.
ssh_cmds() { sed "s|$RIP_SANDBOX|<sandbox>|g" "$RIP_SANDBOX/ssh.cmds"; }

setup() {
  # "jq" in the name on purpose: assertions that the server is never asked to run
  # jq must look past the sandbox path (see ssh_cmds). With a random name this
  # mistake failed about 1 run in 400; with this one it fails every run.
  export RIP_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/rip-jq.XXXXXX")
  export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
  export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
  export JOB_STATE_ROOT="$RIP_SANDBOX/state"
  export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
  export RIP_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
  export RIP_LIBEXEC_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec"
  export RIP_PUSH_MIN_AGE_S=0
  # rip::_abs_match_authors (rip.zsh) is a DEFAULT RIP_AB_REMOTE_HOPS
  # entry, so EVERY audiobooks push in this whole file now shells out to
  # "$RIP_BIN_DIR/rip-abs-authors" after a verified push. Left at its
  # production default ($HOME/.local/bin) that would resolve to a REAL
  # path on whatever machine runs the suite — exactly the live-network
  # escape this suite has already been bitten by once. A sandbox dir
  # holding a silent success stub (rip_stub_remote_hops, below) keeps it
  # hermetic by construction, not by per-example discipline.
  export RIP_BIN_DIR="$RIP_SANDBOX/bin"
  # The enrichment retags every staged book on the way to the push and
  # REFUSES one whose tags cannot be written and read back. The push and
  # session examples in this file stage six-byte text files named "*.m4b",
  # which a real ffmpeg cannot remux — so they run against the shared fake
  # ffmpeg/ffprobe pair. The retag section builds real media and points the
  # seams back at the real tools.
  rip_fake_ffmpeg_pair "$RIP_SANDBOX/tools"
  mkdir -p "$RIP_STAGING_ROOT/audiobooks" "$RIP_SANDBOX/server/audiobooks" "$RIP_BIN_DIR"
  rip_stub_remote_hops "$RIP_BIN_DIR"
  cat > "$RIP_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
EOF
  chmod +x "$RIP_SANDBOX/pueue"
  export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"

  # Fake LibationCli: `export -j -p <file>` writes a two-record library,
  # one Liberated and one not. Any other verb records its argv so an
  # example can assert what was (and was NOT) invoked.
  cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
if [ "$1" = "export" ]; then
out=""
while [ $# -gt 0 ]; do
  case "$1" in -p|--path) out="$2" ;; esac
  shift
done
cat > "$out" <<'JSON'
[
 {"AudibleProductId":"B00ECDZ08I","Title":"Steelheart","Subtitle":"The Reckoners, Book 1",
"AuthorNames":"Brandon Sanderson","NarratorNames":"MacLeod Andrews","LengthInMinutes":762,
"SeriesNames":"Reckoners","SeriesOrder":"1 : Reckoners","Language":"english","IsAbridged":false,
"HasPdf":false,"PictureId":"51kzMpLGP7L","BookStatus":"NotLiberated","LastDownloaded":null,
"DatePublished":"2013-09-24T07:00:00"},
 {"AudibleProductId":"B0DGKKZ123","Title":"Wind and Truth","Subtitle":"",
"AuthorNames":"Brandon Sanderson","NarratorNames":"Michael Kramer","LengthInMinutes":3360,
"SeriesNames":"The Stormlight Archive","SeriesOrder":"5 : The Stormlight Archive","Language":"english",
"IsAbridged":false,"HasPdf":true,"PictureId":"81abcDEF","BookStatus":"Liberated",
"LastDownloaded":"2026-08-22 08:18:03.838369","DatePublished":null}
]
JSON
echo "Library exported to: $out"
exit 0
fi
if [ "$1" = "liberate" ]; then
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
[ -n "$books" ] || { echo "no Books override" >&2; exit 1; }
[ -n "${FAKE_LIBERATE_FAIL:-}" ] && { echo "download failed" >&2; exit 4; }
mkdir -p "$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
echo "Decrypting  25%"
echo "Decrypting  90%"
echo "Completed"
exit 0
fi
exit 0
EOF
  chmod +x "$RIP_SANDBOX/LibationCli"
  export RIP_LIBATION_BIN="$RIP_SANDBOX/LibationCli"
  export RIP_LIBATION_IMAGES="$RIP_SANDBOX/Images"
  mkdir -p "$RIP_LIBATION_IMAGES"
}
cleanup() { rm -rf "$RIP_SANDBOX"; }

# ssh_calls() — how many times the fake ssh ran. --server-library must
# make exactly ONE ssh call regardless of library size (the panel's
# hide-filter is a set-membership test against its output; 460 rows must
# never become 460 round-trips).
ssh_calls() { wc -l < "$RIP_SANDBOX/ssh.count" 2>/dev/null | tr -d ' '; }

# find_temp_dirs() — count .rip-import.* temp directories in the sandbox
find_temp_dirs() {
  find "$RIP_SANDBOX" -maxdepth 2 -name '.rip-import.*' -type d 2>/dev/null | wc -l | tr -d ' '
}

# find_temp_dirs_anywhere() — count .rip-import.* temp directories ANYWHERE
# under the sandbox, unbounded depth. Unlike find_temp_dirs (maxdepth 2,
# which only covers the top-level parent-of-staging location), this also
# catches a temp dir nested inside a destination — the exact failure mode
# of the mv-nesting bug this guard exists to prevent.
find_temp_dirs_anywhere() {
  find "$RIP_SANDBOX" -name '.rip-import.*' -type d 2>/dev/null | wc -l | tr -d ' '
}

# dest_entry_count() — count entries directly inside the fixed
# Author/Title destination used by the dot-directory nesting test below,
# to verify the destination is left exactly as it was (nothing added,
# nothing removed).
dest_entry_count() {
  find "$RIP_STAGING_ROOT/audiobooks/Author/Title" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# ---- helpers more than one rip-audiobook spec uses

# rt_probe <file> <tag> — one tag, read back with the real ffprobe, from
# WHERE THAT CONTAINER ACTUALLY KEEPS IT. mp4/mp3/flac put these at the
# format level; ogg and opus put them on the audio STREAM as VorbisComment,
# where a `-show_entries format_tags` read returns {} and sees nothing at
# all. Used only inside the `zsh -c` bodies below, never as the thing under
# test.
RT_PROBE='rt_probe() { ffprobe -v error -select_streams a:0 -show_entries format_tags:stream_tags -of json -- "$1" 2>/dev/null | jq -r --arg k "$2" "((.format.tags // {}) + (.streams[0].tags // {})) | .[\$k] // \"\""; }'

# rt_stub_silent — an ffmpeg that exits 0 and writes NOTHING. THE example
# of this section: without the read-back verification the retag would
# report success here, and the book would ship with the tags it arrived
# with — the original defect, wearing a hat.
rt_stub_silent() {
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$RIP_SANDBOX/ffmpeg-silent"
  chmod +x "$RIP_SANDBOX/ffmpeg-silent"
  export RIP_FFMPEG_BIN="$RIP_SANDBOX/ffmpeg-silent" RIP_FFPROBE_BIN=ffprobe
}

# titles() — read every enqueued job's title straight from its meta.json
titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }

# rip::ab_editions — works stored in more than one edition. --editions
# reads what is STORED, not what a provider offers, so these stage
# sidecars directly in the sandbox "server" tree.
mkbook() { # <author> <dir-title> <asin> <published> <bare-title>
  mkdir -p "$RIP_SANDBOX/server/audiobooks/$1/$2"
  jq -nc --arg t "$3" --arg p "$4" --arg ti "$5" --arg a "$1" \
    '{schema:1,kind:"audiobook",title:$ti,authors:[$a],ids:{"audible.asin":$t},published:(if $p=="" then null else $p end)}' \
    > "$RIP_SANDBOX/server/audiobooks/$1/$2/.fleet-book.json"
}

# --- the WRITE path against a server that has no jq ------------------------
#
# LIVE FINDING, 2026-08-24. `--backfill-published --apply` failed for all
# 245 candidate books ("backfilled 0 of 245"): the write path shipped a
# remote script that ran `jq` ON THE SERVER, and cantina (stock Debian,
# media@ without passwordless sudo) has no jq. Every example above runs
# the plain-local-dir branch, where jq sits on the dev machine's PATH — so
# the suite could not see it. These run the ssh branch through a fake ssh
# whose PATH holds a HANDPICKED set of stock binaries and, deliberately,
# NO jq: a re-introduced remote-jq dependency fails here the same way it
# failed live.
#
# fake_server_ssh — an ssh that actually EXECUTES the command it is handed,
# against the sandbox server tree, under that restricted PATH. It also logs
# every remote command string so an example can assert what was asked of
# the server.
#
# `stat`, `sha256sum` and `shasum` joined the list for --repair-sidecars'
# Case C hash, which cantina computes with sha256sum. `ffmpeg`/`ffprobe`
# joined it for --retag, which remuxes a STORED book in place on the server
# (design doc S4: cantina has both, verified 2026-08-26, which is what makes
# the sweep a remote operation with no round trip). jq is STILL absent and
# must stay absent: that is the whole point of the handpicked list.
fake_server_ssh() {
  mkdir -p "$RIP_SANDBOX/remotebin"
  for c in sh find sed tr mv rm mkdir rmdir head cat ls printf test base64 stat sha256sum shasum ffmpeg ffprobe; do
    p=$(command -v "$c" 2>/dev/null || true)
    if [ -n "$p" ]; then ln -sf "$p" "$RIP_SANDBOX/remotebin/$c"; fi
  done
  # The server's login shell runs the command string with a genuinely
  # POSIX /bin/sh (dash on Debian) — macOS's own /bin/sh is bash 3.2,
  # which (unlike dash) understands $'...' ANSI-C quoting, so it can't
  # catch a ${(q)} vs ${(qq)} quoting regression in rip.zsh's write
  # path. Fail loudly rather than silently falling back to /bin/sh,
  # which would just re-blind this guard.
  local dash_bin
  dash_bin=$(command -v dash 2>/dev/null || true)
  if [ -z "$dash_bin" ]; then
    print -u2 -- "fake_server_ssh: no dash on PATH — refusing to fall back to /bin/sh (would blind the POSIX-quoting regression guard)"
    return 1
  fi
  cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
for a in "\$@"; do cmd="\$a"; done
printf '%s\n' "\$cmd" >> "$RIP_SANDBOX/ssh.cmds"
PATH="$RIP_SANDBOX/remotebin"; export PATH
exec "$dash_bin" -c "\$cmd"
EOF
  chmod +x "$RIP_SANDBOX/ssh"
  export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
  export RIP_REMOTE_BASE="media@cantina:$RIP_SANDBOX/server"
}

# fake_server_ssh_reads_stdin — fake_server_ssh, plus the ONE behaviour of
# ssh(1) the shared fake does not model: without -n, ssh reads the local
# stdin EAGERLY and forwards it to the remote, whether or not the remote
# command consumes it. `test -f` never consumes it, so a probe run inside a
# `while read` loop fed by a here-string swallowed the whole remaining
# library and the loop ended after ONE book (review finding, 2026-08-24) —
# invisible to a fake that never touches fd 0.
#
# A VARIANT, deliberately, not a change to the shared fake: every other
# example here feeds ssh a payload batch on stdin, and a slurping fake would
# be one more moving part in all of them.
#
# -n is HONOURED, exactly as ssh honours it — that is what makes the guard
# observable: with -n the fake reads nothing, without it the fake drains.
fake_server_ssh_reads_stdin() {
  fake_server_ssh || return 1
  local dash_bin
  dash_bin=$(command -v dash 2>/dev/null || true)
  cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
noinput=0
for a in "\$@"; do
[ "\$a" = "-n" ] && noinput=1
cmd="\$a"
done
printf '%s\n' "\$cmd" >> "$RIP_SANDBOX/ssh.cmds"
PATH="$RIP_SANDBOX/remotebin"; export PATH
if [ "\$noinput" = 1 ]; then
exec "$dash_bin" -c "\$cmd" < /dev/null
fi
slurp="$RIP_SANDBOX/ssh.stdin.\$\$"
cat > "\$slurp"
"$dash_bin" -c "\$cmd" < "\$slurp"
rc=\$?
rm -f "\$slurp"
exit \$rc
EOF
  chmod +x "$RIP_SANDBOX/ssh"
}

stray_tmp_files() {
  find "$RIP_SANDBOX/server" -name '*.tmp.*' | wc -l | tr -d ' '
}

# mkbook_bare <Author/Title> — a stored book with audio and NO sidecar.
mkbook_bare() {
  mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
  printf 'audio-bytes-%s\n' "$1" > "$RIP_SANDBOX/server/audiobooks/$1/${1##*/}.m4b"
}

# mkbook_empty <Author/Title> <provider> — a stored book whose sidecar is in
# schema shape but carries NO identity: `ids: {}`. That is the fingerprint
# the canonicalization bug left behind (fixed 2f649ae6) and the shape all
# three of Case B, Case C and the unidentifiable refusal start from.
mkbook_empty() {
  mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
  printf 'audio-bytes-%s\n' "$1" > "$RIP_SANDBOX/server/audiobooks/$1/${1##*/}.m4b"
  jq -n --arg t "${1##*/}" --arg a "${1%%/*}" --arg p "$2" \
    '{schema:1,kind:"audiobook",title:$t,subtitle:null,authors:[$a],narrators:[],
      series:null,duration_s:null,language:null,abridged:null,published:null,
      ids:{},work:null,
      source:{provider:$p,provider_version:null,acquired_utc:null,format:"m4b"}}' \
    > "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"
}

# mkbook_malformed <Author/Title> — a stored book whose sidecar EXISTS but
# does not parse: truncated mid-object, the shape a hand edit or an
# interrupted write leaves behind. It still carries a resolved `work` and an
# id — recoverable by a human reading it, and unrecoverable once something
# composes a fresh sidecar over the top. rip::_server_sidecars warns and
# DROPS it, so to the classifier it is indistinguishable from a book with no
# sidecar at all, which is Case A: the one branch that writes.
mkbook_malformed() {
  mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
  printf 'audio-bytes-%s\n' "$1" > "$RIP_SANDBOX/server/audiobooks/$1/${1##*/}.m4b"
  printf '%s\n' '{"schema":1,"kind":"audiobook","work":{"id":"OL99W"},"ids":{"audible.asin":"B0HAND0001"},' \
    > "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"
}

sidecar_at() { printf '%s' "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"; }

# snapshot / sidecar_unchanged — the report-only guard. "Never written, not
# even under --apply" is only proved by comparing the BYTES before and
# after; an assertion that merely re-reads a field would pass against a
# rewrite that happened to preserve it.
snapshot() { SNAP_REL="$1"; cp "$(sidecar_at "$1")" "$RIP_SANDBOX/snapshot.json"; }
