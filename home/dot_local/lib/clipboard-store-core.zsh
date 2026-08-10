#!/usr/bin/env zsh
# clipboard-store-core.zsh — what the PICKERS still need from the retired zsh
# clipboard bridge: this machine's identity, byte-exact file reads, and the
# file-authority table.
#
# The RECOB cutover moved the bridge itself into `recobd` (see
# docs/recob-protocol-spec.md), which owns the wire, the store writes, the
# capability grants and every operation handler. What is left here is the
# small read/authority surface `pick-clipboard` and `common.zsh` call
# directly; the ~1000 lines of framing, ops and grant machinery that served
# the dispatcher went with it. Self-contained: safe to source from any zsh.
zmodload zsh/system     # sysread/syswrite: byte-exact reads, embedded NULs

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

mkdir -p "$STATE_DIR" 2>/dev/null

# --- byte-level helpers (see the "no base64 needed" note in the project doc:
# sysread/syswrite handle raw bytes, including embedded NULs, correctly when
# fed scalar literals directly -- never round-tripped through $(...), which
# WOULD mangle them) ------------------------------------------------------

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
    if [[ -L "$p" || ( ! -f "$p" && ! -d "$p" ) ]]; then
      rm -rf -- "$tmpd"
      REPLY="unsupported authority path type"
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
    [[ ! -L "$p" && ( -f "$p" || -d "$p" ) ]] ||
      { rm -rf -- "$tmpd"; return 1 }
    (( idx > 1 )) && REPLY_PATHS+=$'\0'
    REPLY_PATHS+="$p"
  done
  rm -rf -- "$tmpd"
  [[ -n "$REPLY_PATHS" ]]
}
