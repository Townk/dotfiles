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
PREVIEW_MAX=200 # clip::preview_of's soft budget, in bytes
GRANT_IDLE_S=1800
GRANT_HARD_S=86400

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
# a $(...) that would truncate an embedded NUL byte). Needed for op a's
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
# first embedded NUL. Mirrors stream_file_path's own sysread loop, just reading
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
# synchronous=NORMAL, clips incl. source_bundle_id, clip_types, file authority
# + grant tables, and indexes).
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
CREATE TABLE IF NOT EXISTS file_authorities (
  clip_id INTEGER NOT NULL,
  item_index INTEGER NOT NULL,
  path BLOB NOT NULL,
  PRIMARY KEY (clip_id, item_index)
);
CREATE TABLE IF NOT EXISTS file_grants (
  token TEXT NOT NULL,
  item_index INTEGER NOT NULL,
  path BLOB NOT NULL,
  created_ts REAL NOT NULL,
  last_used_ts REAL NOT NULL,
  hard_expires_ts REAL NOT NULL,
  PRIMARY KEY (token, item_index)
);
CREATE INDEX IF NOT EXISTS idx_clips_type_hash ON clips(type_hash);
CREATE INDEX IF NOT EXISTS idx_clips_last_ts ON clips(last_ts DESC);
CREATE INDEX IF NOT EXISTS idx_clips_pinned_ts ON clips(pinned DESC, last_ts DESC);
CREATE INDEX IF NOT EXISTS idx_file_grants_expiry
  ON file_grants(hard_expires_ts, last_used_ts);
SQL
}

# Existing macOS stores are normally migrated by clipboard-history.lua, but the
# bridge can receive a request before Hammerspoon reloads. File-boundary ops
# call this narrow idempotent DDL so rollout fails closed without requiring a
# schema check on unrelated text/window requests.
clip::ensure_file_security_schema() {
  sqlite3 "$DB_FILE" >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS file_authorities (
  clip_id INTEGER NOT NULL,
  item_index INTEGER NOT NULL,
  path BLOB NOT NULL,
  PRIMARY KEY (clip_id, item_index)
);
CREATE TABLE IF NOT EXISTS file_grants (
  token TEXT NOT NULL,
  item_index INTEGER NOT NULL,
  path BLOB NOT NULL,
  created_ts REAL NOT NULL,
  last_used_ts REAL NOT NULL,
  hard_expires_ts REAL NOT NULL,
  PRIMARY KEY (token, item_index)
);
CREATE INDEX IF NOT EXISTS idx_file_grants_expiry
  ON file_grants(hard_expires_ts, last_used_ts);
SQL
}

# Delete authority rows whose owning history row is gone and grants that are
# no longer usable. Grants deliberately survive row retention until their own
# expiry so an in-flight multi-item paste remains stable across clipboard churn.
clip::prune_file_security_state() {
  local now=$EPOCHREALTIME
  sqlite3 "$DB_FILE" "DELETE FROM file_authorities
    WHERE clip_id NOT IN (SELECT id FROM clips);
    DELETE FROM file_grants
    WHERE hard_expires_ts <= $now
       OR last_used_ts < ($now - $GRANT_IDLE_S);" >/dev/null 2>&1
}

# clip::replace_file_authority <clip-id> <NUL-joined-paths>
# Atomically replaces one trusted row's immutable path snapshot. Each path is
# stored as its own BLOB so filenames containing newlines never cross SQL text.
clip::replace_file_authority() {
  local clip_id=$1 paths=$2
  clip::ensure_file_security_schema || { REPLY="schema update failed"; return 1 }
  [[ "$clip_id" == <-> ]] || { REPLY="bad clip id"; return 1 }
  local -a items=( "${(@ps:\0:)paths}" )
  (( ${#items[@]} > 0 )) || { REPLY="empty authority"; return 1 }

  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/clip-authority.XXXXXX") ||
    { REPLY="mktemp failed"; return 1 }
  local sqlf="$tmpd/authority.sql"
  print -r -- "BEGIN IMMEDIATE;" > "$sqlf"
  print -r -- "DELETE FROM file_authorities WHERE clip_id=$clip_id;" >> "$sqlf"

  local p pf ep
  local -i idx=0
  for p in "${items[@]}"; do
    if [[ -z "$p" || "$p" != /* || "$p" == */../* || "$p" == */.. ]]; then
      rm -rf -- "$tmpd"
      REPLY="unsafe authority path"
      return 1
    fi
    (( idx += 1 ))
    pf="$tmpd/path.$idx"
    print -rn -- "$p" > "$pf"
    ep=${pf//\'/\'\'}
    print -r -- "INSERT INTO file_authorities (clip_id,item_index,path)
      VALUES ($clip_id,$idx,readfile('$ep'));" >> "$sqlf"
  done
  print -r -- "COMMIT;" >> "$sqlf"

  if sqlite3 "$DB_FILE" < "$sqlf" >/dev/null 2>&1; then
    rm -rf -- "$tmpd"
    REPLY=""
    return 0
  fi
  rm -rf -- "$tmpd"
  REPLY="authority write failed"
  return 1
}

# clip::load_file_authority <clip-id> -> $REPLY_PATHS (NUL-joined).
clip::load_file_authority() {
  local clip_id=$1
  clip::ensure_file_security_schema || return 1
  [[ "$clip_id" == <-> ]] || return 1
  local indexes
  indexes="$(sqlite3 "$DB_FILE" "SELECT item_index FROM file_authorities
    WHERE clip_id=$clip_id ORDER BY item_index;" 2>/dev/null)"
  [[ -n "$indexes" ]] || return 1

  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/clip-authority-read.XXXXXX") ||
    return 1
  local idx pf ep p
  local -i expected=0
  REPLY_PATHS=""
  for idx in ${(f)indexes}; do
    (( expected += 1 ))
    [[ "$idx" == "$expected" ]] || { rm -rf -- "$tmpd"; return 1 }
    pf="$tmpd/path.$idx"
    ep=${pf//\'/\'\'}
    sqlite3 "$DB_FILE" "SELECT writefile('$ep',path) FROM file_authorities
      WHERE clip_id=$clip_id AND item_index=$idx;" >/dev/null 2>&1
    [[ -f "$pf" ]] || { rm -rf -- "$tmpd"; return 1 }
    clip::read_file "$pf"; p=$REPLY
    (( idx > 1 )) && REPLY_PATHS+=$'\0'
    REPLY_PATHS+="$p"
  done
  rm -rf -- "$tmpd"
  [[ -n "$REPLY_PATHS" ]]
}

# clip::random_token -> $REPLY_TOKEN (256 random bits as lowercase hex).
clip::random_token() {
  local token
  token="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null |
    od -An -tx1 | tr -d ' \n')"
  if (( $#token != 64 )) || [[ "$token" == *[^0-9a-f]* ]]; then
    REPLY="random token generation failed"
    return 1
  fi
  REPLY_TOKEN=$token
}

# clip::create_file_grant <clip-id> -> $REPLY_TOKEN. The grant copies the
# authority BLOBs so clipboard changes and row retention cannot change what an
# already-issued token means.
clip::create_file_grant() {
  local clip_id=$1
  clip::ensure_file_security_schema || { REPLY="schema update failed"; return 1 }
  [[ "$clip_id" == <-> ]] || return 1
  clip::prune_file_security_state
  local -i attempt
  local token inserted
  local now hard
  for attempt in 1 2 3; do
    clip::random_token || return 1
    token=$REPLY_TOKEN
    now=$EPOCHREALTIME
    hard=$(( EPOCHREALTIME + GRANT_HARD_S ))
    inserted="$(sqlite3 "$DB_FILE" "BEGIN IMMEDIATE;
      INSERT INTO file_grants
        (token,item_index,path,created_ts,last_used_ts,hard_expires_ts)
      SELECT '$token',item_index,path,$now,$now,$hard
      FROM file_authorities
      WHERE clip_id=$clip_id
        AND NOT EXISTS (SELECT 1 FROM file_grants WHERE token='$token');
      SELECT changes();
      COMMIT;" 2>/dev/null)" || inserted=0
    if [[ "$inserted" == <1-> ]]; then
      REPLY_TOKEN=$token
      return 0
    fi
    sqlite3 "$DB_FILE" "DELETE FROM file_grants WHERE token='$token';" \
      >/dev/null 2>&1
  done
  REPLY="grant creation failed"
  return 1
}

# clip::resolve_file_grant <token US item-index> -> $REPLY_PATH. Refreshes the
# whole manifest token's idle clock when any item opens; a hard expiry remains.
clip::resolve_file_grant() {
  local payload=$1 us=$'\x1f'
  clip::ensure_file_security_schema || { REPLY="schema update failed"; return 1 }
  local token=${payload%%${us}*} idx=${payload#*${us}}
  if [[ "$token" == "$payload" || $#token != 64 ||
        "$token" == *[^0-9a-f]* || "$idx" != <1-> || "$idx" == *${us}* ]]; then
    REPLY="invalid capability"
    return 1
  fi

  local now=$EPOCHREALTIME
  clip::prune_file_security_state
  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/clip-grant-read.XXXXXX") ||
    { REPLY="mktemp failed"; return 1 }
  local tmpf="$tmpd/path"
  local ep=${tmpf//\'/\'\'}
  sqlite3 "$DB_FILE" "SELECT writefile('$ep',path) FROM file_grants
    WHERE token='$token' AND item_index=$idx
      AND hard_expires_ts > $now
      AND last_used_ts >= ($now - $GRANT_IDLE_S);" >/dev/null 2>&1
  if [[ ! -f "$tmpf" ]]; then
    rm -rf -- "$tmpd"
    REPLY="invalid or expired capability"
    return 1
  fi
  clip::read_file "$tmpf"
  REPLY_PATH=$REPLY
  rm -rf -- "$tmpd"
  sqlite3 "$DB_FILE" "UPDATE file_grants SET last_used_ts=$now
    WHERE token='$token' AND hard_expires_ts > $now;" >/dev/null 2>&1
  return 0
}

# clip::parse_rich_payload <payload> -- op C's wire parse (<2 bytes uti_len>
# <uti><blob>), shared by both platform backends. 0 with $REPLY_UTI/
# $REPLY_BLOB set; 1 with $REPLY = the caller-facing error (unchanged
# wording, so existing E-frame assertions hold).
clip::parse_rich_payload() {
  local payload=$1
  (( $#payload >= 2 )) || { REPLY="short payload"; return 1 }
  local pc1=${payload[1,1]} pc2=${payload[2,2]}
  local -i uti_len=$(( (#pc1 << 8) | #pc2 ))
  (( $#payload >= 2 + uti_len )) || { REPLY="truncated payload"; return 1 }
  REPLY_UTI=${payload[3,2+uti_len]}
  REPLY_BLOB=${payload[3+uti_len,-1]}
  return 0
}

# clip::preview_of <text> -- $REPLY = the single-line snippet that goes in
# text_preview: blank lines dropped, every other line trimmed, the rest joined
# with a single space.
#
# This used to keep only the text up to the first newline (${text%%$'\n'*}),
# so a clip that OPENS with a blank line stored an EMPTY preview and rendered
# as a blank row -- nothing in the list to identify it by -- in both pickers.
# Flattening also puts more of a multi-line clip in the row, since the column
# is spent on content rather than on whatever happened to sit on line one.
# Mirrors preview_of() in clipboard-history.lua, the macOS watcher's writer.
#
# Lines stop being collected once PREVIEW_MAX bytes are covered, so a
# multi-megabyte clip is not flattened in full to fill one list row. The cut
# lands on a line boundary rather than mid-string, which is why there is no
# codepoint back-off here (the Lua side truncates to an exact byte budget and
# needs one); both pickers truncate to their own column width at render time.
clip::preview_of() {
  setopt local_options extended_glob
  local line trimmed
  local -a parts
  local -i len=0
  for line in ${(f)1}; do
    trimmed=${${line##[[:space:]]##}%%[[:space:]]##}
    [[ -n "$trimmed" ]] || continue
    parts+=( "$trimmed" )
    (( len += $#trimmed + 1 ))   # +1 for the joining space
    (( len > PREVIEW_MAX )) && break
  done
  REPLY=${(j: :)parts}
}

# clip::persist_text_row <host> <kind> <app> <regtype> <text> -- the
# dedup-scoped INSERT/UPDATE + retention sweep extracted from op_persist
# (byte-safe: temp files + readfile(), never SQL literals). 0 on success;
# 1 with $REPLY = error message. regtype outside v|l|b is stored as NULL.
clip::persist_text_row() {
  local host=$1 kind=${2:-text} app=${3:-} regtype=${4:-} text=$5
  [[ "$regtype" == (v|l|b) ]] || regtype=""
  local -i len=$#text
  local preview; clip::preview_of "$text"; preview=$REPLY
  local hash; hash="$(print -rn -- "$text" | clip::sha256)"
  local ts=$EPOCHREALTIME
  local eh=${host//\'/\'\'} ek=${kind//\'/\'\'}
  local rt_sql="NULL"; [[ -n "$regtype" ]] && rt_sql="'$regtype'"
  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/clip-persist.XXXXXX") || { REPLY="mktemp"; return 1 }
  print -rn -- "$text"    > "$tmpd/text"
  print -rn -- "$preview" > "$tmpd/preview"
  print -rn -- "$app"     > "$tmpd/app"
  local existing
  # Dedup scoped by type_kind too -- see the pre-split op_persist comment
  # (a files manifest of the same text hashes identically to plain text).
  existing=$(sqlite3 "$DB_FILE" "SELECT id FROM clips WHERE source_host='$eh' AND type_hash='$hash' AND type_kind='$ek' LIMIT 1;" 2>/dev/null)
  if [[ -n "$existing" ]]; then
    sqlite3 "$DB_FILE" "UPDATE clips SET last_ts=$ts WHERE id=$existing;" 2>/dev/null
    rm -rf -- "$tmpd"; REPLY=""; return 0
  fi
  sqlite3 "$DB_FILE" "INSERT INTO clips \
    (text_preview, text_plain, len, first_ts, last_ts, source_app, type_kind, regtype, pinned, type_hash, source_host) \
    VALUES (CAST(readfile('$tmpd/preview') AS TEXT), CAST(readfile('$tmpd/text') AS TEXT), \
    $len, $ts, $ts, CAST(readfile('$tmpd/app') AS TEXT), '$ek', $rt_sql, 0, '$hash', '$eh');" 2>/dev/null
  sqlite3 "$DB_FILE" "DELETE FROM clips WHERE pinned=0 AND id NOT IN \
    (SELECT id FROM clips ORDER BY pinned DESC, last_ts DESC LIMIT $MAX_ROWS);" 2>/dev/null
  sqlite3 "$DB_FILE" "DELETE FROM clip_types WHERE clip_id NOT IN (SELECT id FROM clips);" 2>/dev/null
  rm -rf -- "$tmpd"
  REPLY=""
  return 0
}

# S  get-current-ts (X9): the CURRENT clipboard's copy-time, so a consumer
# surfacing a peer's live clipboard as a synthetic row (pick-clipboard §22)
# can sort it chronologically against its own stored rows instead of always
# pinning it to the top. Fallback chain (documented here since it's easy to
# lose track of across the two SELECTs below):
#   1. Read the current clipboard text the SAME way op_get does (pbpaste),
#      into a temp file (byte-safe: arbitrary clip text, incl. embedded NULs,
#      would be mangled through a $(...) capture or a SQL string literal).
#   2. Match by TEXT CONTENT, not by any hash: find the store row whose
#      text_plain equals the current clipboard text, compared trailing-
#      newline-insensitively (rtrim char(10) on both sides) and byte-safely
#      (readfile, no SQL-escaping of the text). This is EXACTLY the picker's
#      own §22.5 dedup query -- and it's the whole point of this rework: a
#      hash match (shasum, = op_persist's formula) only ever matched a P/M-
#      persisted row, so a clip the Hammerspoon watcher captured on the HOME
#      machine (hashed over the sorted uti=blob SET, a different formula)
#      never matched and its real last_ts was lost. Content match hits the
#      watcher-captured common case too. Most-recent (ORDER BY last_ts DESC)
#      when several rows share the text.
#   3. If NO row has that text (a just-copied clip that hasn't round-tripped
#      into the store yet, or a non-text pasteboard entry), fall back to the
#      store's most-recent last_ts (MAX(last_ts)) -- acceptable: a genuinely-
#      not-in-store current clip is something freshly copied, so "recent /
#      near the top" is the right default.
#   4. If the store itself is empty, there is nothing to fall back to --
#      reply with an empty payload; the caller treats that as "unknown".
clip::op_get_ts() {
  # linux-headless short-circuit (spec §3): current clipboard == latest row,
  # so the content-match chain below degenerates to MAX(last_ts) directly.
  if [[ "${CLIPBOARD_PLATFORM:-$(uname -s)}" != Darwin && "${CLIPBOARD_PLATFORM:-}" != macos ]]; then
    local ts
    ts="$(sqlite3 "$DB_FILE" "SELECT MAX(last_ts) FROM clips;" 2>/dev/null)"
    send_ok "${ts:-}"
    return
  fi

  pb::get_text; local text=$REPLY
  local tmpf; tmpf=$(mktemp "${TMPDIR:-/tmp}/clipboard-bridge-curts.XXXXXX") || { send_ok ""; return }
  print -rn -- "$text" > "$tmpf"
  local ts
  ts="$(sqlite3 "$DB_FILE" "SELECT last_ts FROM clips WHERE rtrim(text_plain, char(10)) = rtrim(CAST(readfile('$tmpf') AS TEXT), char(10)) ORDER BY last_ts DESC LIMIT 1;" 2>/dev/null)"
  if [[ -z "$ts" ]]; then
    ts="$(sqlite3 "$DB_FILE" "SELECT MAX(last_ts) FROM clips;" 2>/dev/null)"
  fi
  rm -f "$tmpf"
  send_ok "${ts:-}"
}

# H  get-host: this machine's identity, so a consumer can stamp the origin of
# the clip it just read from here (materialization provenance, §11).
# Self-name-first (spec §5, Phase 7 change): clip::self_host prefers a
# validated $XDG_STATE_HOME/clipboard/self-name over scutil/hostname -s, the
# same precedence M-row stamping already uses -- so H and the store agree on
# this machine's identity. With no self-name file (every pre-Phase-7 test
# env and most macOS boxes today) it still answers scutil/hostname exactly
# as before.
clip::op_get_host() {
  send_ok "$(clip::self_host)"
}

# W  window action: do something to the TERMINAL WINDOW on this machine, on
# behalf of a session running on the other end of the tunnel.
#
#   fullscreen-toggle <ghostty|wezterm>   toggle that terminal's fullscreen
#   fullscreen-state                      answer true | false | "" (unknown)
#
# The bridge is already the wire between a remote mux session and the machine
# its terminal actually lives on — the clipboard just happened to be the first
# thing to need it. Fullscreen used to be REFUSED over SSH ("cannot control
# the local terminal"), which was a statement about the old plumbing rather
# than about what is possible.
#
# Both actions delegate to the same scripts the local path uses, so there is
# one implementation of "how does this terminal go fullscreen", not two. The
# terminal is named by the CALLER because this service has no terminal
# environment of its own to detect from.
clip::op_window_action() {
  local payload=$1
  local action="${payload%% *}" arg=""
  [[ "$payload" == *" "* ]] && arg="${payload#* }"

  case "$action" in
    fullscreen-toggle)
      case "$arg" in
        ghostty | wezterm) ;;
        *) send_err "unsupported terminal: ${arg:-<none>}"; return ;;
      esac
      local toggle="${MUX_TOGGLE_FULLSCREEN_BIN:-$HOME/.config/mux/scripts/terminal-toggle-fullscreen}"
      [[ -x "$toggle" ]] || { send_err "no fullscreen toggle on this machine"; return }
      local err
      # MUX_TERMINAL short-circuits detect_terminal, which would otherwise see
      # no TERM_PROGRAM here and give up. SSH_* are cleared for the same
      # reason: this service may itself have been started from an ssh login,
      # and the toggle reads them as "you are not the local machine".
      if err="$(SSH_CONNECTION= SSH_CLIENT= MUX_TERMINAL="$arg" "$toggle" 2>&1)"; then
        # Record it HERE too. The window that just moved is this machine's,
        # so this machine's own mirror is now wrong — and any tmux running
        # locally reads that mirror for its ribbon. --flip rather than a
        # fresh probe: we just inverted the state deliberately, and asking
        # the accessibility API again would cost seconds while the caller
        # waits. The local client-resized hook still re-asks authoritatively
        # a moment later, so a flip that guessed wrong is self-correcting.
        local probe="${MUX_FULLSCREEN_PROBE:-$HOME/.config/mux/scripts/mux-fullscreen-probe}"
        [[ -x "$probe" ]] && "$probe" --flip >/dev/null 2>&1
        send_ok ""
      else
        send_err "${err:-fullscreen toggle failed}"
      fi
      ;;
    fullscreen-state)
      local probe="${MUX_FULLSCREEN_PROBE:-$HOME/.config/mux/scripts/mux-fullscreen-probe}"
      [[ -x "$probe" ]] || { send_err "no fullscreen probe on this machine"; return }
      send_ok "$("$probe" --print 2>/dev/null)"
      ;;
    *)
      send_err "unknown window action: ${action:-<none>}"
      ;;
  esac
}

# Resolve the CURRENT file manifest once for both L (display only) and K
# (capability issuance). On success, sets REPLY_CLIP_ID/KIND/HOST/TS/PATHS.
clip::resolve_current_file_manifest() {
  local us=$'\x1f'
  local id kind host ts row
  local -a f
  local -i attempt
  for attempt in 1 2; do
    row="$(sqlite3 -separator "$us" "$DB_FILE" "SELECT id, type_kind, source_host, last_ts FROM clips ORDER BY last_ts DESC LIMIT 1;" 2>/dev/null)"
    if [[ -z "$row" ]]; then
      REPLY="empty-store"
      return 1
    fi
    f=()
    IFS=$us read -rA f <<< "$row"
    id=${f[1]:-} kind=${f[2]:-} host=${f[3]:-} ts=${f[4]:-}
    [[ "$kind" == (files|file|directory) ]] && break
    if (( attempt == 1 )); then
      # Watcher capture lag (spec §4): the store trails the pasteboard by up
      # to ~0.5s, so a paste right after a Finder copy can still see the
      # PREVIOUS (non-files) row. One retry covers it without stalling every
      # ordinary text paste.
      sleep 0.3
      continue
    fi
    REPLY="not-files"
    return 1
  done

  local tmpdir; tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/clipboard-bridge-listfiles.XXXXXX") ||
    { REPLY="mktemp failed"; return 1 }
  local paths=""

  local manifestfile="$tmpdir/x-file-manifest"
  local emanifest=${manifestfile//\'/\'\'}
  sqlite3 "$DB_FILE" "SELECT writefile('$emanifest', blob) FROM clip_types WHERE clip_id=$id AND uti='x-file-manifest';" >/dev/null 2>&1
  if [[ -s "$manifestfile" ]]; then
    clip::read_file "$manifestfile"
    paths=$REPLY
  else
    # NSFilenamesPboardType BEFORE x-resolved-path: the HS watcher's
    # classify_file_or_directory() resolves x-resolved-path via readURL(),
    # which only ever inspects pasteboard item 1 -- so on a genuine
    # multi-file local capture (Finder multi-select, yazi multi-yank,
    # `pbcopy a b c`) that blob holds just the FIRST of N paths, while
    # NSFilenamesPboardType (set once, on item 1, as the full array) already
    # carries all of them. Checking it first here means a multi-file row
    # resolves completely instead of silently truncating to one path.
    # Safe for single-file rows too: those still carry a matching
    # NSFilenamesPboardType blob (one-element array) from the same capture.
    # pick-clipboard's own localized single-path rows (copy_files_by_id)
    # never write a NSFilenamesPboardType blob -- only x-resolved-path -- so
    # they fall through to the fallback below exactly as before.
    local nsfile="$tmpdir/ns-filenames"
    local ensfile=${nsfile//\'/\'\'}
    sqlite3 "$DB_FILE" "SELECT writefile('$ensfile', blob) FROM clip_types WHERE clip_id=$id AND uti='NSFilenamesPboardType';" >/dev/null 2>&1
    if [[ -s "$nsfile" ]]; then
      pb::parse_ns_filenames "$nsfile" "$tmpdir"
      paths=$REPLY
    else
      local resolvedfile="$tmpdir/x-resolved-path"
      local eresolved=${resolvedfile//\'/\'\'}
      sqlite3 "$DB_FILE" "SELECT writefile('$eresolved', blob) FROM clip_types WHERE clip_id=$id AND uti='x-resolved-path';" >/dev/null 2>&1
      if [[ -s "$resolvedfile" ]]; then
        clip::read_file "$resolvedfile"
        paths=$REPLY
      fi
    fi
  fi
  rm -rf -- "$tmpdir"

  if [[ -z "$paths" ]]; then
    REPLY="not-files"
    return 1
  fi
  REPLY_CLIP_ID=$id
  REPLY_KIND=$kind
  REPLY_HOST=$host
  REPLY_TS=$ts
  REPLY_PATHS=$paths
  return 0
}

# L  list-files: display-only manifest. It deliberately contains no authority.
clip::op_list_files() {
  local us=$'\x1f'
  clip::resolve_current_file_manifest || { send_err "$REPLY"; return }
  send_ok "${REPLY_KIND}${us}${REPLY_HOST}${us}${REPLY_TS}${us}${REPLY_PATHS}"
}

# K  grant-files: current manifest plus an opaque authority token. A pointer-only
# peer M row returns "-" so a client on the source host can still use its paths
# locally, while cross-machine streaming fails closed.
clip::op_grant_files() {
  local us=$'\x1f'
  clip::resolve_current_file_manifest || { send_err "$REPLY"; return }
  local clip_id=$REPLY_CLIP_ID kind=$REPLY_KIND host=$REPLY_HOST ts=$REPLY_TS
  local paths=$REPLY_PATHS token="-"
  if clip::load_file_authority "$clip_id"; then
    paths=$REPLY_PATHS
    if clip::create_file_grant "$clip_id"; then
      token=$REPLY_TOKEN
    else
      send_err "${REPLY:-grant creation failed}"
      return
    fi
  fi
  send_ok "${kind}${us}${host}${us}${ts}${us}${token}${us}${paths}"
}

# Stream a server-resolved path. Wire callers must enter through
# clip::op_fetch_authorized; this helper never consumes caller path text.
clip::stream_file_path() {
  local fpath=$1
  # M3: a directory can't be read/streamed as flat bytes -- reply with this
  # EXACT string (not just "starts with E"). Task 13's remote pbpaste greps
  # for it to know "retry this capability as an a archive-stream instead."
  # Checked before the -r test: a
  # directory usually passes -r (it's listable), so without this check
  # `wc -c < "$fpath"` below would instead fail on "is a directory" and
  # muddy the error.
  if [[ -d "$fpath" ]]; then
    send_err "is-directory"
    return
  fi
  if [[ ! -r "$fpath" ]]; then
    send_err "cannot read: $fpath"
    return
  fi
  local bytes; bytes=$(wc -c < "$fpath" | tr -d ' ')
  if (( bytes > 4294967295 )); then
    send_err "file-too-large"
    return
  fi
  local fd
  exec {fd}< "$fpath"
  int_to_be32 "$bytes"
  syswrite -- "O$REPLY"
  local -i remaining=$bytes
  # `chunk` declared once, outside the loop -- a bare `local chunk` re-run
  # inside the loop prints `chunk=$'...'` to stdout on the 2nd+ iteration
  # (zsh displays an already-existing parameter), which here would inject the
  # file's own bytes back into the response stream. See the matching note in
  # read_n().
  local chunk
  while (( remaining > 0 )); do
    sysread -s $(( remaining < 65536 ? remaining : 65536 )) -i $fd chunk || break
    syswrite -- "$chunk"
    # NOTE: bare `remaining-=$#chunk` is not valid zsh syntax at all (it's
    # parsed as an attempt to RUN A COMMAND named "remaining-=N", regardless
    # of `-i` typing -- confirmed empirically). The compound assignment only
    # works inside arithmetic `(( ))`.
    (( remaining -= $#chunk ))
  done
  exec {fd}<&-
}

# f  fetch-authorized-file: resolve token/index, then retain the exact-size
# file response used by the retired F.
clip::op_fetch_authorized() {
  clip::resolve_file_grant "$1" || { send_err "$REPLY"; return }
  clip::stream_file_path "$REPLY_PATH"
}

# a  archive-authorized-directory: f's directory sibling. The file stream
# handles only flat bytes, so a directory pull goes through `tar` here
# instead. Reply: O + BE32 len=8 + BE64 total-byte-count, then the raw
# `tar -cf - -C <parent> <basename>` stream until EOF -- unlike f's reply,
# there is NO trailing frame.
#
# BE64 size semantics: `du -sk <dir>` (the filesystem's own KiB block
# accounting) x 1024 -- a size ESTIMATE for progress display only, with NO
# directional guarantee. tar's per-entry headers plus bsdtar's fixed 10 KiB
# blocking-factor padding push the real stream ABOVE it (empirically: this
# repo's own two-small-files test fixture is du 8192 vs a 20480-byte real
# archive), while sparse files push it the other way (du charges only
# allocated blocks; tar writes the holes as real bytes -- or vice versa
# with hole-detecting tar modes). The client MUST read to EOF (never use
# the count to decide when to stop) and MUST clamp its progress display
# at 100%.
#
# Error semantics: every detectable failure -- bad path AND any unreadable
# entry inside the tree (the common mid-stream tar killer, caught by the
# pre-flight walk below) -- is reported as a normal E frame BEFORE any
# stream byte. Residual limitation, inherent to the EOF-terminated design:
# an I/O error striking MID-stream (disk fault, file deleted between the
# pre-flight walk and tar reaching it) can no longer be signaled -- the O
# header is already out and EOF is the only terminator, so the client just
# sees a short-but-clean stream. Client-side mitigation (treating tar
# extraction failure as the error signal) lands in Task 13's pbpaste.
clip::stream_archive_path() {
  local dir=$1
  if [[ "$dir" != /* ]]; then
    send_err "not absolute: $dir"
    return
  fi
  if [[ ! -e "$dir" ]]; then
    send_err "cannot read: $dir"
    return
  fi
  if [[ ! -d "$dir" ]]; then
    send_err "not a directory: $dir"
    return
  fi
  if [[ ! -r "$dir" ]]; then
    send_err "cannot read: $dir"
    return
  fi

  # Pre-flight readability walk: an entry tar can't open would otherwise
  # fail MID-stream, after the O header -- where the EOF-terminated design
  # has no error channel left and the client would accept a silently
  # truncated archive as a clean EOF. Catch the common trigger (permission-
  # denied entries) up front, where a real E frame is still possible. A zsh
  # recursive glob, not `find ... ! -readable`: macOS /usr/bin/find has no
  # -readable primary (verified: "unknown primary or operator"), and
  # `[[ -r ]]` tests EFFECTIVE access, which is the thing tar actually
  # needs -- a -perm bit heuristic would miss ACLs and root-squash cases.
  # (D) includes dotfiles, (N) makes an empty dir yield nothing, (oN) skips
  # sorting. Symlinks are exempt: tar archives the link itself, never the
  # target. An unreadable nested DIR is caught as itself (the glob can't
  # descend into it, but the dir entry still appears and fails -r/-x).
  local entry
  for entry in "$dir"/**/*(DNoN); do
    if [[ -L "$entry" ]]; then
      continue
    elif [[ -d "$entry" ]]; then
      [[ -r "$entry" && -x "$entry" ]] || { send_err "unreadable-entries: $entry"; return }
    else
      [[ -r "$entry" ]] || { send_err "unreadable-entries: $entry"; return }
    fi
  done

  local kb
  kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
  local -i total_bytes=$(( ${kb:-0} * 1024 ))

  # tar wants a parent dir + basename (so the archive's entries are rooted
  # at the basename, not an absolute path) -- zsh's :h/:t modifiers split
  # exactly that without a subshell.
  local parent=${dir:h} base=${dir:t}

  int_to_be32 8
  local len_hdr=$REPLY
  int_to_be64 "$total_bytes"
  syswrite -- "O$len_hdr$REPLY"

  local fd
  exec {fd}< <(tar --no-xattrs -cf - -C "$parent" -- "$base" 2>/dev/null)
  # `chunk` declared once, outside the loop -- see the matching gotcha
  # comment on read_n()/stream_file_path above: a bare `local chunk` re-run
  # inside the loop on a later iteration gets parsed by zsh as a request to
  # DISPLAY the parameter instead of declaring it, which here would inject
  # `chunk=$'...'` text into the middle of the tar stream.
  local chunk
  while true; do
    sysread -s 65536 -i $fd chunk || break
    syswrite -- "$chunk"
  done
  exec {fd}<&-
}

clip::op_archive_authorized() {
  clip::resolve_file_grant "$1" || { send_err "$REPLY"; return }
  clip::stream_archive_path "$REPLY_PATH"
}

# P  persist: materialize a used peer clip into THIS machine's store (§11) so a
# self-contained copy lands here and survives the origin going offline. Sent by
# the nvim provider to the LOCAL bridge on paste-over-tunnel. Byte-safe direct
# SQLite insert (same technique as the rest of this script).
#   payload = source_host US kind US app US regtype RS text
# Dedup on (source_host, sha256(text)) -- repeated pastes just bump last_ts. A
# bounded sweep caps growth when this machine never captures locally itself
# (headless / SSH-only remote, where the HS watcher's own retention never runs).
clip::op_persist() {
  local payload=$1
  local us=$'\x1f' rs=$'\x1e'
  local meta=${payload%%${rs}*}
  local text=${payload#*${rs}}
  local -a f
  IFS=$us read -rA f <<< "$meta"
  local host=${f[1]:-} kind=${f[2]:-text} app=${f[3]:-} regtype=${f[4]:-}
  [[ -n "$host" ]] || { send_err "no source_host"; return }
  [[ "$kind" != (files|file|directory) ]] ||
    { send_err "P cannot persist file kinds"; return }
  if clip::persist_text_row "$host" "$kind" "$app" "$regtype" "$text"; then
    send_ok ""
  else
    send_err "$REPLY"
  fi
}

# O  declare-origin: record that the NEXT pasteboard change hashing to
# sha256(text) was really copied on <source_host> (spec §23) — sent by a machine
# SSH'd into the peer, just before it sets the peer clipboard. The HS watcher's
# captured_origin() consults this (hash-keyed + TTL'd) to stamp the row
# remote(source_host) instead of local. Payload: <source_host> US <text>.
# clip::declare_origin_core <host> <text> [suppress] -- the actual origin-file
# write op O performs, split out so a caller needing origin declaration
# without a reply frame of its own could invoke it directly (mirrors
# set_pasteboard_core above; see the header comment there).
#
# The optional 3rd arg extends the origin-file contract with a 4th line,
# `suppress-echo`: it tells the HS watcher's captured_origin() that, beyond
# stamping provenance, it must SKIP capturing the matching pasteboard change
# entirely and consume the file (one-shot -- a later identical local copy
# captures normally). Historically only the now-retired `N` push-manifest op
# set it: N inserted its own authoritative store row, so the watcher's echo
# of N's pasteboard write would otherwise have landed a duplicate, NEWER text
# row that shadowed the manifest (the watcher's type_hash formula differs
# from this script's, so dedup never merged them). Plain O flows (nvim /
# pbcopy text) NEED the capture and never set the flag. Fix A retired N (see
# the header opcode table) because its pasteboard write was itself the bug --
# the peer's live clipboard must never be touched by a files-over-SSH push.
# No current caller passes a truthy 3rd arg, so this parameter and the
# suppress-echo consumption in clipboard-history.lua's captured_origin() are
# both unused but deliberately left in place: harmless, and the mechanism may
# still matter for other origin-declaring flows down the line. A 3-line file
# (no flag) is exactly the pre-existing format; readers that stop at line 3
# are unaffected. Same hash-key + TTL semantics as the base mechanism
# (spec §23). This is a coordinator-authorized extension of the origin-file
# seam shared with clipboard-history.lua's captured_origin().
clip::declare_origin_core() {
  local host=$1 text=$2 suppress=${3:-}
  local hash; hash="$(print -rn -- "$text" | clip::sha256)"
  {
    print -r -- "$host"
    print -r -- "$hash"
    print -r -- "$EPOCHSECONDS"
    if [[ -n "$suppress" ]]; then print -r -- "suppress-echo"; fi
  } > "$ORIGIN_FILE"
}

clip::op_declare_origin() {
  local payload=$1
  local us=$'\x1f'
  local host=${payload%%${us}*}
  local text=${payload#*${us}}
  [[ -n "$host" && "$host" != "$payload" ]] || { send_err "bad origin payload"; return }
  clip::declare_origin_core "$host" "$text"
  send_ok ""
}

# clip::parse_manifest_payload <payload> -- shared parse+validate for M's
# wire payload (<source_host> US path NUL path ...): splits off the host,
# NUL-splits the path list, and rejects anything not absolute. On success
# returns 0 with $REPLY_HOST/$REPLY_PATHS set (host, and the raw NUL-joined
# path substring, ready for clip::persist_files_manifest_row); on failure
# returns 1 with $REPLY set to the caller-facing error message (unchanged
# wording from the pre-refactor inline checks, so existing E-frame assertions
# still hold). Originally shared with the now-retired `N` push-manifest op
# (Fix A) -- the name and "shared" framing stuck around because M is itself
# now sent to two different destinations (local + peer, see the header
# comment on op M above), not because another opcode uses this helper.
clip::parse_manifest_payload() {
  local payload=$1
  local us=$'\x1f'
  local host=${payload%%${us}*}
  local paths=${payload#*${us}}
  if [[ -z "$host" || "$host" == "$payload" || -z "$paths" ]]; then
    REPLY="bad manifest payload"
    return 1
  fi
  local -a f
  f=( "${(@ps:\0:)paths}" )
  if (( ${#f[@]} == 0 )); then
    REPLY="bad manifest payload"
    return 1
  fi
  local p
  for p in "${f[@]}"; do
    if [[ -z "$p" || "$p" != /* ]]; then
      REPLY="not absolute: $p"
      return 1
    fi
    if [[ "$p" == */../* || "$p" == */.. ]]; then
      REPLY="unsafe path: $p"
      return 1
    fi
  done
  REPLY_HOST=$host
  REPLY_PATHS=$paths
  return 0
}

# clip::persist_files_manifest_row <host> <paths> [trusted=0] -- the row-insert core used
# by M (manifest-persist-local, X2-redo; Fix A): a dedup-scoped INSERT/UPDATE
# of a `files` store row carrying the text_preview (newline-joined paths, X3)
# + x-file-manifest blob (NUL-joined paths -- <paths> is stored verbatim).
# Pure store write: no pasteboard access, no origin declaration. Originally
# shared with the now-retired `N` push-manifest op, which needed those two
# extra steps itself (see the header comment on op M above for why N was
# retired) -- M never needs them, by design. Returns 0 on success
# ($REPLY==""); 1 with $REPLY set to an error message on mktemp failure (the
# only failure mode once the caller has already validated host/paths via
# clip::parse_manifest_payload).
clip::persist_files_manifest_row() {
  local host=$1 paths=$2 trusted=${3:-0}
  clip::ensure_file_security_schema || { REPLY="schema update failed"; return 1 }
  local -a f
  f=( "${(@ps:\0:)paths}" )
  local text="${(pj:\n:)f}"

  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/clip-manifest.XXXXXX") || { REPLY="mktemp failed"; return 1 }
  print -rn -- "$text"  > "$tmpd/preview"
  print -rn -- "$paths" > "$tmpd/manifest"
  local hash; hash="$(print -rn -- "$text" | clip::sha256)"
  local eh=${host//\'/\'\'}
  local ts=$EPOCHREALTIME
  local -i len=$#text

  local existing
  # Scoped to type_kind='files' -- host+hash alone collides with a plain text
  # row hashing the same string (e.g. a remote pbcopy of a path that matches
  # an old text clip verbatim). Without this filter the dedup would bump that
  # text row's last_ts instead of inserting/updating the files manifest,
  # leaving both pickers showing "text" and nothing to paste as files.
  local authority_predicate
  if (( trusted )); then
    authority_predicate="EXISTS (SELECT 1 FROM file_authorities fa WHERE fa.clip_id=clips.id)"
  else
    authority_predicate="NOT EXISTS (SELECT 1 FROM file_authorities fa WHERE fa.clip_id=clips.id)"
  fi
  existing=$(sqlite3 "$DB_FILE" "SELECT id FROM clips WHERE source_host='$eh'
    AND type_hash='$hash' AND type_kind='files' AND $authority_predicate
    LIMIT 1;" 2>/dev/null)
  local row_id
  if [[ -n "$existing" ]]; then
    sqlite3 "$DB_FILE" "UPDATE clips SET last_ts=$ts WHERE id=$existing;" 2>/dev/null
    row_id=$existing
  else
    row_id=$(sqlite3 "$DB_FILE" "INSERT INTO clips \
      (text_preview, len, first_ts, last_ts, type_kind, pinned, type_hash, source_host) \
      VALUES (CAST(readfile('$tmpd/preview') AS TEXT), $len, $ts, $ts, 'files', 0, '$hash', '$eh'); \
      SELECT last_insert_rowid();" 2>/dev/null)
  fi
  if [[ -n "$row_id" ]]; then
    sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO clip_types (clip_id, uti, blob) VALUES ($row_id, 'x-file-manifest', readfile('$tmpd/manifest'));" 2>/dev/null
    if (( trusted )) && ! clip::replace_file_authority "$row_id" "$paths"; then
      rm -rf -- "$tmpd"
      return 1
    fi
  fi
  sqlite3 "$DB_FILE" "DELETE FROM clips WHERE pinned=0 AND id NOT IN \
    (SELECT id FROM clips ORDER BY pinned DESC, last_ts DESC LIMIT $MAX_ROWS);" 2>/dev/null
  sqlite3 "$DB_FILE" "DELETE FROM clip_types WHERE clip_id NOT IN (SELECT id FROM clips);" 2>/dev/null
  clip::prune_file_security_state
  rm -rf -- "$tmpd"
  REPLY_ROW_ID=$row_id
  REPLY=""
  return 0
}

# M  manifest-persist-local (X2-redo, see the header opcode table): record-
# only -- ONLY the row-insert (via clip::persist_files_manifest_row), no
# pasteboard write, no declare-origin. Sent by pbcopy's SSH files branch to
# persist the SSH'd-into machine's OWN origin clip directly into ITS OWN
# store, since that machine is typically locked/headless over SSH and the
# Hammerspoon watcher's loginwindow guard then skips ALL capture (a plain `U`
# sets the pasteboard but nothing ever lands in the store -- confirmed live).
# Mirrors how `P` (persist, plain text) already bypasses the watcher for the
# identical reason -- text-over-SSH never sets the origin pasteboard at all,
# it only P-persists to the store, so this brings files-over-SSH in line with
# that. Fix A: pbcopy's SSH files branch now ALSO sends this same op to the
# peer bridge (see the header opcode table's note on the retired `N` op) --
# so this handler runs for both trusted local-socket and public peer sends,
# with no direct pasteboard side effect on either machine.
clip::op_manifest_persist_local() {
  local payload=$1 trusted=${2:-0}
  clip::parse_manifest_payload "$payload" || { send_err "$REPLY"; return }
  local host=$REPLY_HOST paths=$REPLY_PATHS
  local self_host; self_host=$(clip::self_host)
  if (( trusted )); then
    if [[ "$host" != "$self_host" ]]; then
      send_err "source host does not match this machine"
      return
    fi
  elif [[ -n "$self_host" && "$host" == "$self_host" ]]; then
    send_err "public M cannot claim this machine"
    return
  fi
  if clip::persist_files_manifest_row "$host" "$paths" "$trusted"; then
    send_ok ""
    # Mount enrichment AFTER the reply (spec §3.4): backgrounded + disowned,
    # so pbcopy's reply window never stretches and a dead mount can't hang
    # this handler. See clip::mount_enrich for the full chain.
    pb::enrich_manifest "$host" "$paths"
  else
    send_err "$REPLY"
  fi
}
