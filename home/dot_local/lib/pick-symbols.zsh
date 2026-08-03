#!/usr/bin/env zsh
# pick-symbols.zsh — shared scaffolding for the symbols.db-backed
# pickers (pick-glyph, pick-gitmoji). They differ only in the SQL projection
# and their key map; everything else — option parsing, the DB-not-found guard,
# and the recency recorder — lived identically in both and now lives here.
#
# SOURCED, never executed. Pulls in pick-common.zsh (and transitively the base
# common.zsh) for require_cmd / die / pick::start, so a picker only needs to
#   source "$PICK_LIB_DIR/pick-symbols.zsh"
# instead of pick-common.zsh directly.

# Source pick-common relative to THIS file.
_pick_symbols_self="${(%):-%x}"
source "${PICK_COMMON_LIB:-$(dirname "$_pick_symbols_self")/pick-common.zsh}"
unset _pick_symbols_self

# pick_symbols::parse_args <arg>...
# Parse the shared picker flags into the script-scope vars multi/copy/query/
# resume/no_border (initialized here), and override DB_FILE on --db. On
# -h/--help it calls the caller's usage() and exits 0; unknown args die.
# DB_FILE must already hold the picker's default before this is called.
pick_symbols::parse_args() {
  multi=0
  copy=0
  query=""
  resume=0
  no_border=0
  while (($# > 0)); do
    case "$1" in
      -m | --multi)
        multi=1
        shift
        ;;
      -c | --copy)
        copy=1
        shift
        ;;
      -q | --query)
        [[ $# -ge 2 ]] || die "missing arg for $1"
        query="$2"
        shift 2
        ;;
      --db)
        [[ $# -ge 2 ]] || die "missing arg for $1"
        DB_FILE="$2"
        shift 2
        ;;
      --resume)
        resume=1
        shift
        ;;
      --no-border)
        no_border=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *) die "unknown arg: $1 (try --help)" ;;
    esac
  done
}

# pick_symbols::require_db — ensure sqlite3 is present and DB_FILE exists, with
# the consistent "build it with chezmoi apply" hint.
pick_symbols::require_db() {
  require_cmd sqlite3
  pick::sqlite_raw
  [[ -f "$DB_FILE" ]] || die "symbols DB not found: $DB_FILE
Build it with: chezmoi apply (runs the symbols-db hook)"

  # Per-picker recency (2026-07-24): the original symbols.last_used column is
  # shared by every symbols picker, so picking a gitmoji floated it to the top
  # of the glyph picker too. picker_recency is keyed (picker, symbol); it is
  # created lazily here and seeded idempotently from the legacy column so the
  # accumulated ordering carries over, then the pickers diverge. Extra seeded
  # rows for a picker are harmless — each feed filters its own symbol set.
  # The DB rebuild hook (build-symbols-db.py) only drops the tables it owns,
  # so this one survives rebuilds; symbols.last_used stays as the frozen seed.
  sqlite3 "$DB_FILE" "
    CREATE TABLE IF NOT EXISTS picker_recency (
      picker    TEXT NOT NULL,
      symbol    TEXT NOT NULL,
      last_used INTEGER NOT NULL,
      PRIMARY KEY (picker, symbol)
    );
    INSERT OR IGNORE INTO picker_recency (picker, symbol, last_used)
      SELECT '${PICK_NAME:-pick}', symbol, last_used
      FROM symbols WHERE last_used > 0;" 2>/dev/null || true
}

# pick_symbols::record_recency <symbol>...
# --on-items-picked hook: stamp the pick into THIS picker's recency rows so
# the next launch floats it to the top (feeds order by picker_recency).
# symbols.last_used is deliberately no longer written — a shared stamp is
# exactly the cross-picker bleed this table exists to prevent.
pick_symbols::record_recency() {
  (($#)) || return 0
  local now sym vals="" picker="${PICK_NAME:-pick}"
  now=$(date +%s)
  for sym in "$@"; do
    [[ -z "$sym" ]] && continue
    sym=${sym//\'/\'\'} # SQL-escape single quotes
    vals+="('${picker}','${sym}',${now}),"
  done
  [[ -z "$vals" ]] && return 0
  sqlite3 "$DB_FILE" "
    INSERT INTO picker_recency (picker, symbol, last_used)
    VALUES ${vals%,}
    ON CONFLICT(picker, symbol) DO UPDATE SET last_used=excluded.last_used;"
}
