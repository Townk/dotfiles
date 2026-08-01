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

# C copy-rich: no pasteboard to write -- persist the representation
# directly (spec §3). kind mapped from the UTI; text_plain populated only
# for the plain-text UTI so G/R keep working on rich text clips.
clip::op_copy() {
  local payload=$1
  clip::parse_rich_payload "$payload" || { send_err "$REPLY"; return }
  local uti=$REPLY_UTI blob=$REPLY_BLOB
  local kind
  case "$uti" in
    (public.utf8-plain-text)   kind=text ;;
    (public.png|public.tiff)   kind=image ;;
    (*)                        kind=mixed ;;
  esac
  local host; host=$(clip::self_host)
  local hash; hash="$(print -rn -- "$blob" | clip::sha256)"
  local ts=$EPOCHREALTIME
  local eh=${host//\'/\'\'} eu=${uti//\'/\'\'}
  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/clip-rich.XXXXXX") || { send_err "mktemp failed"; return }
  local fd
  exec {fd}> "$tmpd/blob"
  syswrite -o $fd -- "$blob"
  exec {fd}>&-
  local existing
  existing=$(sqlite3 "$DB_FILE" "SELECT id FROM clips WHERE source_host='$eh' AND type_hash='$hash' AND type_kind='$kind' LIMIT 1;" 2>/dev/null)
  local row_id
  if [[ -n "$existing" ]]; then
    sqlite3 "$DB_FILE" "UPDATE clips SET last_ts=$ts WHERE id=$existing;" 2>/dev/null
    row_id=$existing
  else
    local text_sql="NULL" preview_sql="NULL" len=$#blob
    if [[ "$kind" == text ]]; then
      text_sql="CAST(readfile('$tmpd/blob') AS TEXT)"
      # Store-wide invariant: text_preview is always a SINGLE line (every
      # other writer flattens the same way -- clip::persist_text_row via
      # clip::preview_of, and the Hammerspoon watcher's own preview_of)
      # because pick-clipboard renders text-kind previews raw; a multi-line
      # preview would emit orphan fzf rows. Write the flattened snippet to
      # its OWN temp file (byte-safe via syswrite, same pattern as the blob
      # file above -- never a scalar substring fed through SQL) so
      # preview_sql reads only that line while text_sql keeps reading the
      # full blob.
      clip::preview_of "$blob"
      local preview=$REPLY
      local pfd
      exec {pfd}> "$tmpd/preview"
      syswrite -o $pfd -- "$preview"
      exec {pfd}>&-
      preview_sql="CAST(readfile('$tmpd/preview') AS TEXT)"
    fi
    row_id=$(sqlite3 "$DB_FILE" "INSERT INTO clips \
      (text_preview, text_plain, len, first_ts, last_ts, type_kind, pinned, type_hash, source_host) \
      VALUES ($preview_sql, $text_sql, $len, $ts, $ts, '$kind', 0, '$hash', '$eh'); \
      SELECT last_insert_rowid();" 2>/dev/null)
  fi
  if [[ -z "$row_id" ]]; then
    rm -rf -- "$tmpd"; send_err "store write failed"; return
  fi
  sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO clip_types (clip_id, uti, blob) VALUES ($row_id, '$eu', readfile('$tmpd/blob'));" 2>/dev/null
  sqlite3 "$DB_FILE" "DELETE FROM clips WHERE pinned=0 AND id NOT IN \
    (SELECT id FROM clips ORDER BY pinned DESC, last_ts DESC LIMIT $MAX_ROWS);" 2>/dev/null
  sqlite3 "$DB_FILE" "DELETE FROM clip_types WHERE clip_id NOT IN (SELECT id FROM clips);" 2>/dev/null
  rm -rf -- "$tmpd"
  send_ok ""
}

# U set-file-urls: form A persists the manifest row (there is no pasteboard
# to also write -- the row IS the clip); form B "restores" a stored row,
# which on this platform is purely a recency fact: bump last_ts (spec §3).
clip::op_set_file_urls() {
  local payload=$1
  if [[ "$payload" == id:<-> ]]; then
    local id=${payload#id:}
    local found
    found=$(sqlite3 "$DB_FILE" "SELECT id FROM clips WHERE id=$id LIMIT 1;" 2>/dev/null)
    [[ -n "$found" ]] || { send_err "no such row: $id"; return }
    sqlite3 "$DB_FILE" "UPDATE clips SET last_ts=$EPOCHREALTIME WHERE id=$id;" 2>/dev/null
    send_ok ""
    return
  fi
  local -a paths=( "${(@ps:\0:)payload}" )
  local p
  for p in "${paths[@]}"; do
    [[ "$p" == /* ]] || { send_err "not absolute: $p"; return }
  done
  if clip::persist_files_manifest_row "$(clip::self_host)" "$payload" 1; then
    send_ok ""
  else
    send_err "$REPLY"
  fi
}

# pb::parse_ns_filenames -- unreachable on Linux by construction (spec §3):
# NSFilenamesPboardType blobs are only ever written by the macOS watcher;
# Linux files rows always carry x-file-manifest, which op_list_files checks
# FIRST. Defined to keep the pb::* contract total.
pb::parse_ns_filenames() { REPLY=""; }
