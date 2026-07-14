# clipboard-platform-linux-headless.zsh — store-backed pb::* backend for
# headless Linux (Phase 7 spec §3). No OS pasteboard exists, so the store's
# most-recent row (ORDER BY last_ts DESC LIMIT 1) IS the current clipboard.
# Fed exclusively by the shims / nvim provider / materialize-on-use (§11) --
# capture is out of scope by design.

# pb::init -- lazy schema bootstrap (spec §3): no watcher exists to create
# the DB here. Only runs the DDL when the DB file is missing/empty (one
# stat per connection); CREATE IF NOT EXISTS + SQLite's own locking make
# concurrent first connections safe.
pb::init() {
  [[ -s "$DB_FILE" ]] || clip::ensure_schema
}

# pb::get_text -- latest row's text into $REPLY, byte-safe (writefile to a
# temp file + clip::read_file -- NEVER a $(...) capture, which truncates
# embedded NULs). text_plain when present, else text_preview (a files row
# reads as its newline-joined paths, mirroring what macOS pbpaste shows for
# a file clip). Empty store -> empty $REPLY.
pb::get_text() {
  REPLY=""
  local tmpf; tmpf=$(mktemp "${TMPDIR:-/tmp}/clipboard-linux-get.XXXXXX") || return 0
  sqlite3 "$DB_FILE" "SELECT writefile('$tmpf', CAST(COALESCE(text_plain, text_preview, '') AS BLOB)) FROM clips ORDER BY last_ts DESC LIMIT 1;" >/dev/null 2>&1
  [[ -s "$tmpf" ]] && clip::read_file "$tmpf"
  rm -f "$tmpf"
}

# pb::legacy_dump -- old bare-connect clients expect a raw pbpaste dump;
# here that is the latest row's text, byte-exact via syswrite.
pb::legacy_dump() {
  pb::get_text
  syswrite -- "$REPLY"
  exit 0
}

pb::enrich_manifest() { :; }   # mount enrichment is a macOS concern (spec §3)

clip::op_get() {
  pb::get_text
  send_ok "$REPLY"
}

# T set: the store IS the pasteboard -- insert/dedup a text row stamped with
# this machine's stable identity. regtype lands in the ROW's regtype column;
# there is no current-regtype state file on Linux (spec §3).
clip::op_set() {
  local payload=$1
  (( $#payload >= 1 )) || { send_err "empty payload"; return }
  local regtype=${payload[1,1]}
  local text=${payload[2,-1]}
  if clip::persist_text_row "$(clip::self_host)" text "" "$regtype" "$text"; then
    send_ok ""
  else
    send_err "store write failed: $REPLY"
  fi
}

# R get-regtype: latest row's regtype when it is a real vim regtype; else
# the same trailing-newline heuristic op T's macOS sibling uses (l vs v).
clip::op_get_regtype() {
  local rt
  rt=$(sqlite3 "$DB_FILE" "SELECT COALESCE(regtype,'') FROM clips ORDER BY last_ts DESC LIMIT 1;" 2>/dev/null)
  if [[ "$rt" != (v|l|b) ]]; then
    pb::get_text
    [[ "$REPLY" == *$'\n' ]] && rt=l || rt=v
  fi
  send_ok "$rt"
}
