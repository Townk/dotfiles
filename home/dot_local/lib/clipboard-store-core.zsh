#!/usr/bin/env zsh
# clipboard-store-core.zsh — platform-neutral core of the clipboard bridge
# (Phase 7 spec §2): byte-exact framing, the SQLite store ops, and portable
# identity/hash/schema helpers. Sourced by clipboard-bridge-dispatch (both
# platforms) and by pick-clipboard (for clip::self_host). Self-contained:
# safe to source from any zsh — sets its own modules, options, and defaults.
zmodload zsh/system
zmodload zsh/datetime   # $EPOCHREALTIME for op_persist timestamps

# This handler speaks a raw BYTE protocol end to end: every length prefix,
# loop counter, and substring split below is meant to count/index bytes, not
# characters. Under the default multibyte (UTF-8) locale zsh counts decoded
# CHARACTERS instead -- so `$#chunk`, `$#payload`, and `${payload[a,b]}` all
# undercount whenever the bytes contain multibyte sequences or a length
# header byte >0x7f. That silently corrupts the framing: read_n's `got`
# never reaches `n` (loop spins to a false timeout/EOF even though every byte
# already arrived -- verified: the scalar holds the full payload byte-for-
# byte, only the count is wrong), send_frame advertises a short length so the
# client under-reads, and be32_to_int/op_copy split on the wrong offsets.
# Disabling multibyte makes $#, [a,b] indexing, and $(( #byte )) all operate
# on bytes -- exactly the protocol's unit -- fixing the whole class at once.
setopt nomultibyte

# Force a UTF-8 locale for the CHILD tools we shell out to. pbcopy/pbpaste
# transcode between the pasteboard's Unicode text and their stdio bytes using
# the locale's charset; under the clipboard-bridge service env (only PATH is
# set -- see services.toml.tmpl [clipboard-bridge.env]) that charset defaults
# to Mac OS Roman. So op_set's `... | pbcopy` reinterprets nvim's UTF-8 bytes
# as MacRoman -- e2 95 ad ("╭") lands as three chars "‚ï≠" -- and op_get's
# pbpaste can't emit non-MacRoman clip text at all (a bare "╭" comes back as
# "?"). Exporting a UTF-8 LC_CTYPE makes both round-trip byte-exact. This does
# NOT undo `setopt nomultibyte` above: that governs THIS shell's own string
# handling (byte-exact framing) and wins over the locale regardless; LC_CTYPE
# only reaches the child processes. Nothing in the service env sets LC_ALL, so
# this category is respected.
export LC_CTYPE=en_US.UTF-8

DB_FILE="${PICK_CLIPBOARD_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/pick-clipboard/history.db}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pick-clipboard"
ORIGIN_FILE="$STATE_DIR/current-origin"
LEGACY_GRACE_S=0.2
READ_TIMEOUT_S=5
MAX_ROWS=1000   # op_persist sweep cap (mirrors the HS watcher's row retention)

mkdir -p "$STATE_DIR" 2>/dev/null

# --- byte-level helpers (see the "no base64 needed" note in the project doc:
# sysread/syswrite handle raw bytes, including embedded NULs, correctly when
# fed scalar literals directly -- never round-tripped through $(...), which
# WOULD mangle them) ------------------------------------------------------

# read_n <nbytes> <timeout> -> sets $REPLY to the bytes read (may be short on
# timeout/EOF; caller checks $REPLY_STATUS: ok|timeout|eof).
read_n() {
  local n=$1 timeout=$2
  local -i got=0
  # `chunk` MUST be declared once, OUTSIDE the loop. A bare `local chunk`
  # (no assignment) re-run on a later iteration, when `chunk` already exists
  # in this function scope, is parsed by zsh as a request to DISPLAY the
  # parameter -- it prints `chunk=$'...<the bytes>...'` to stdout. A pipe/
  # socket read completes in several `sysread`s (partial reads), so putting
  # the declaration inside the loop dumped the whole payload onto the wire
  # and corrupted every framed response >~one read buffer. (A single-read
  # file completes in one iteration, which is why this hid during file-based
  # testing.) sysread overwrites chunk in full each call, so one declaration
  # is correct.
  local chunk
  REPLY=""
  REPLY_STATUS="ok"
  while (( got < n )); do
    sysread -s $(( n - got )) -t "$timeout" chunk
    case $? in
      0) REPLY+="$chunk"; (( got += $#chunk )) ;;
      4) REPLY_STATUS="timeout"; return 1 ;;
      5) REPLY_STATUS="eof"; return 1 ;;
      *) REPLY_STATUS="error"; return 1 ;;
    esac
  done
  return 0
}

# be32_to_int <4-byte-scalar> -> prints the decimal value
#
# NOTE: `$(( #b[1,1] ))` (ordinal of an inline substring expression) silently
# computes the wrong thing in zsh arithmetic -- confirmed empirically
# (returns 0 regardless of the byte's real value). The substring MUST be
# extracted to its own variable first, then `$(( #var ))` gives the correct
# ordinal.
be32_to_int() {
  local b=$1
  local c1=${b[1,1]} c2=${b[2,2]} c3=${b[3,3]} c4=${b[4,4]}
  local -i b1=$(( #c1 )) b2=$(( #c2 )) b3=$(( #c3 )) b4=$(( #c4 ))
  print -r -- $(( (b1 << 24) | (b2 << 16) | (b3 << 8) | b4 ))
}

# int_to_be32 <n> -> writes the 4-byte big-endian scalar to $REPLY.
#
# NOTE: ${(e)string} does NOT interpret \NNN octal escapes the way $'...'
# does (confirmed empirically -- it left the literal backslash-digit text
# untouched). printf's OWN format-string handling of \NNN is standard and
# reliable, but its result must reach us via a real file descriptor, not
# $(command substitution), which truncates embedded NULs (relevant here:
# any byte in a length can legitimately be 0x00). Round-tripping through a
# small temp file is the verified-safe way to land raw computed bytes in a
# zsh scalar.
int_to_be32() {
  local -i n=$1
  local tmpf; tmpf=$(mktemp "${TMPDIR:-/tmp}/clipboard-bridge-be32.XXXXXX")
  printf "\\$(printf %03o $(( (n >> 24) & 255 )))\\$(printf %03o $(( (n >> 16) & 255 )))\\$(printf %03o $(( (n >> 8) & 255 )))\\$(printf %03o $(( n & 255 )))" > "$tmpf"
  local fd
  exec {fd}< "$tmpf"
  sysread -s 4 -i $fd REPLY
  exec {fd}<&-
  rm -f "$tmpf"
}

# int_to_be64 <n> -> writes the 8-byte big-endian scalar to $REPLY. Same
# mktemp round-trip as int_to_be32 above (same note applies -- ${(e)string}
# doesn't do \NNN escapes, printf's does but only survives via a real fd, not
# a $(...) that would truncate an embedded NUL byte). Needed for op A's
# BE64 total-byte-count header: a directory's `du`-based byte count can
# exceed 4 GiB, overflowing BE32.
int_to_be64() {
  local -i n=$1
  local tmpf; tmpf=$(mktemp "${TMPDIR:-/tmp}/clipboard-bridge-be64.XXXXXX")
  printf "\\$(printf %03o $(( (n >> 56) & 255 )))\\$(printf %03o $(( (n >> 48) & 255 )))\\$(printf %03o $(( (n >> 40) & 255 )))\\$(printf %03o $(( (n >> 32) & 255 )))\\$(printf %03o $(( (n >> 24) & 255 )))\\$(printf %03o $(( (n >> 16) & 255 )))\\$(printf %03o $(( (n >> 8) & 255 )))\\$(printf %03o $(( n & 255 )))" > "$tmpf"
  local fd
  exec {fd}< "$tmpf"
  sysread -s 8 -i $fd REPLY
  exec {fd}<&-
  rm -f "$tmpf"
}

# send_frame <status-byte> <payload-scalar>
# NOTE: the local is named stat_byte, not "status" -- zsh's $status is a
# read-only alias for $? and a `local status=...` errors out immediately
# ("read-only variable: status"). Confirmed empirically; same class of bug
# as pick-clipboard's earlier "local path" vs. zsh's special $path array.
send_frame() {
  local stat_byte=$1 payload=$2
  int_to_be32 $#payload
  syswrite -- "$stat_byte$REPLY$payload"
}

send_ok()  { send_frame O "${1:-}"; }
send_err() { send_frame E "$1"; }

# clip::read_file <path> -> sets $REPLY to the file's raw bytes, byte-exact
# (may contain embedded NULs -- e.g. a NUL-joined multi-path manifest). Never
# use $(<file)/$(cat file) for this: command substitution truncates at the
# first embedded NUL. Mirrors op_fetch_file's own sysread loop, just reading
# a whole local file into a scalar instead of streaming it over the wire.
clip::read_file() {
  local f=$1
  local -i sz
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || sz=0
  REPLY=""
  (( sz > 0 )) || return 0
  local fd
  exec {fd}< "$f"
  local -i got=0
  local chunk
  while (( got < sz )); do
    sysread -s $(( sz - got )) -i $fd chunk || break
    REPLY+="$chunk"
    (( got += $#chunk ))
  done
  exec {fd}<&-
}

# clip::sha256 -- stdin -> lowercase hex sha256 on stdout. macOS ships
# shasum (perl) but not sha256sum; minimal Linux images ship sha256sum but
# not always perl/shasum. Same hex output either way, so stores hashed on
# one platform stay dedup-compatible on the other.
clip::sha256() {
  if (( $+commands[shasum] )); then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# clip::self_host -- the identity this machine stamps/answers (spec §2).
# Precedence mirrors pbcopy's self_host() and mount_enrich's self-guard:
#   1. validated FIRST LINE of $XDG_STATE_HOME/clipboard/self-name (the wire
#      identity the sit-at machine pushes at connect -- ephemeral cloud
#      hostnames make `hostname -s` useless as a stable name);
#   2. scutil --get LocalHostName, where the command exists (macOS);
#   3. hostname -s (last resort).
# Shape rule: alnum first char, then alnum/dot/dash ([A-Za-z0-9][A-Za-z0-9.-]#,
# extended_glob) -- the value becomes an M-row host field and, on a peer, a
# mount-key/ssh target, so an unchecked value is a hazard, not cosmetics.
clip::self_host() {
  emulate -L zsh
  setopt extended_glob
  local f="${XDG_STATE_HOME:-$HOME/.local/state}/clipboard/self-name"
  if [[ -r "$f" ]]; then
    local -a lines; lines=( "${(f)"$(<"$f")"}" )
    local name=${lines[1]:-}
    if [[ "$name" == [A-Za-z0-9][A-Za-z0-9.-]# ]]; then
      print -rn -- "$name"
      return 0
    fi
  fi
  local h
  h=$(scutil --get LocalHostName 2>/dev/null) || h=""
  [[ -n "$h" ]] || h=$(hostname -s 2>/dev/null)
  print -rn -- "$h"
}

# clip::ensure_schema -- idempotent bootstrap of the store DDL (spec §3).
# Mirrors clipboard-history.lua's ensure_schema() CREATE set exactly (WAL +
# synchronous=NORMAL, clips incl. source_bundle_id, clip_types, 3 indexes).
# CREATE IF NOT EXISTS only: the watcher's Lua owns column MIGRATIONS on
# macOS; a headless store is always born current.
clip::ensure_schema() {
  mkdir -p "${DB_FILE:h}" 2>/dev/null
  # >/dev/null: `PRAGMA journal_mode=WAL` is itself a query and the sqlite3
  # CLI echoes its result ("wal") to stdout by default -- for --init-store
  # invoked standalone that's just a stray line, but for any future caller
  # sharing a framed connection's stdout it would corrupt the reply stream.
  # No caller of this function depends on stdout; real failures still surface
  # on stderr and via $?.
  sqlite3 "$DB_FILE" >/dev/null <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS clips (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text_preview TEXT,
  text_plain TEXT,
  len INTEGER,
  first_ts REAL,
  last_ts REAL,
  source_app TEXT,
  source_bundle_id TEXT,
  type_kind TEXT,
  regtype TEXT,
  pinned INTEGER DEFAULT 0,
  type_hash TEXT,
  source_host TEXT
);
CREATE TABLE IF NOT EXISTS clip_types (
  clip_id INTEGER,
  uti TEXT,
  blob BLOB,
  PRIMARY KEY (clip_id, uti)
);
CREATE INDEX IF NOT EXISTS idx_clips_type_hash ON clips(type_hash);
CREATE INDEX IF NOT EXISTS idx_clips_last_ts ON clips(last_ts DESC);
CREATE INDEX IF NOT EXISTS idx_clips_pinned_ts ON clips(pinned DESC, last_ts DESC);
SQL
}
